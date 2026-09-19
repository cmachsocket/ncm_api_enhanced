// native/android/node_bridge.cpp
//
// Native bridge for an external Node.js executable (aarch64-android
// build of upstream Node.js — see ../node/arm64-v8a/node).
//
// Architecture:
//
//   Dart FFI
//       |
//       v
//   libncm_node_bridge.so
//       |
//       v
//   fork() + execvp(<extracted node binary>, [node, bundle.js])
//
// The Node process is a *separate* child process spawned from this
// bridge; the bridge itself does NOT link libnode.so.
//
// Native -> Dart communication:
//
//   Node child process
//       |  (stdout/stderr via pipes, stdin via pipe)
//       v
//   Bridge reader pthreads
//       |
//       v
//   Dart_PostCObject_DL()
//       |
//       v
//   Dart ReceivePort
//
// There is NO JNI dependency.
//
// IMPORTANT:
//   Node is invoked as a child process. The Dart side is responsible
//   for:
//     - Extracting the embedded node binary to a writable path
//       (e.g. via rootBundle + getApplicationSupportDirectory)
//     - chmod 0755 on the extracted binary
//     - Passing the absolute path via ncm_node_set_executable_path()
//
//   Once set, ncm_node_start() will fork+execvp that binary with the
//   caller-supplied argv (whose argv[0] is the same absolute path).
//
// IMPORTANT:
//   We do NOT use Pointer.fromFunction() / Dart native callbacks here.
//
//   stdout/stderr reader threads are native pthreads and cannot directly
//   invoke a Dart callback trampoline.
//
//   Instead, Dart initializes the Dart API DL and provides a SendPort ID.
//   Native threads use Dart_PostCObject_DL() to deliver messages into the
//   Dart isolate.
//
// ---------------------------------------------------------------------------

#include <android/log.h>

#include <atomic>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <pthread.h>
#include <signal.h>
#include <string>
#include <sys/stat.h>
#include <sys/wait.h>
#include <vector>

#include <unistd.h>

#include <dart_api_dl.h>


// ===========================================================================
// Logging
// ===========================================================================

#define LOG_TAG "NcmNodeBridge"

#define LOGI(...) \
    __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)

#define LOGW(...) \
    __android_log_print(ANDROID_LOG_WARN, LOG_TAG, __VA_ARGS__)

#define LOGE(...) \
    __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)


// ===========================================================================
// Node ABI
// ===========================================================================
//
// Node is invoked as an *external* child process. The bridge spawns it
// via fork()+execvp(). There is no in-process linkage to libnode.so.
//
// The absolute path of the executable must be supplied by the Dart
// side via ncm_node_set_executable_path() before ncm_node_start().
//
// ===========================================================================


// ===========================================================================
// C ABI
// ===========================================================================

extern "C" {


// ---------------------------------------------------------------------------
// Dart API initialization
// ---------------------------------------------------------------------------

intptr_t ncm_node_initialize_dart_api(
    void* data
);


// ---------------------------------------------------------------------------
// Dart native port
// ---------------------------------------------------------------------------

void ncm_node_set_dart_port(
    int64_t port
);


// ---------------------------------------------------------------------------
// Set the absolute path of the Node executable to fork+exec
// ---------------------------------------------------------------------------
//
// Must be called once at startup, before ncm_node_start().
//
// Path is copied internally; the caller's buffer may be freed afterwards.
//
// Passing nullptr or empty clears the stored path and causes
// ncm_node_start() to fail with -1.

void ncm_node_set_executable_path(
    const char* path
);


// ---------------------------------------------------------------------------
// Start Node as a child process
// ---------------------------------------------------------------------------

int ncm_node_start(
    int argc,
    const char* const* argv
);


// ---------------------------------------------------------------------------
// Write bytes to Node stdin
// ---------------------------------------------------------------------------

int ncm_node_write_stdin(
    const unsigned char* data,
    size_t length
);


// ---------------------------------------------------------------------------
// Request shutdown
// ---------------------------------------------------------------------------

void ncm_node_request_shutdown();


// ---------------------------------------------------------------------------
// Query running state
// ---------------------------------------------------------------------------

int ncm_node_is_running();

} // extern "C"


// ===========================================================================
// Global state
// ===========================================================================

static std::atomic<bool> g_started{false};


// ---------------------------------------------------------------------------
// Dart native port
// ---------------------------------------------------------------------------

static std::atomic<Dart_Port_DL> g_dart_port{
    ILLEGAL_PORT
};


// ---------------------------------------------------------------------------
// Node child process
// ---------------------------------------------------------------------------

//
// Absolute path of the Node executable to fork+execvp.
// Set via ncm_node_set_executable_path().
//
static std::string g_node_exe_path;

//
// PID of the running Node child process. -1 when none is alive.
//
static std::atomic<pid_t> g_node_pid{-1};

//
// Caller-supplied argv (deep-copied). Used as the argv for execvp().
//
struct StartArgs {
    int argc;
    std::vector<std::string> argv;
};

//
// Storage for the in-flight start call's argv.
// Once ncm_node_start() returns 0, ownership transfers to the wait
// thread, which deletes StartArgs after the child exits.
//
static StartArgs* g_active_args = nullptr;


// ---------------------------------------------------------------------------
// stdout pipe
// ---------------------------------------------------------------------------

static int g_pipe_out[2] = {
    -1,
    -1
};


// ---------------------------------------------------------------------------
// stderr pipe
// ---------------------------------------------------------------------------

static int g_pipe_err[2] = {
    -1,
    -1
};


// ---------------------------------------------------------------------------
// stdin pipe
// ---------------------------------------------------------------------------

static int g_pipe_in[2] = {
    -1,
    -1
};


static pthread_t g_thread_out;
static pthread_t g_thread_err;


// ===========================================================================
// Dart message helper
// ===========================================================================
//
// Message:
//
//     [ "stdout", "<text>" ]
//
// or:
//
//     [ "stderr", "<text>" ]
//
// ===========================================================================

static bool post_dart_message(
    const char* type,
    const char* data,
    size_t length
) {
    if (type == nullptr ||
        data == nullptr ||
        length == 0) {

        LOGE(
            "post_dart_message: invalid arguments "
            "type=%p data=%p length=%zu",
            type,
            data,
            length
        );

        return false;
    }


    const Dart_Port_DL port =
        g_dart_port.load(
            std::memory_order_acquire
        );


    if (port == ILLEGAL_PORT) {

        LOGE(
            "post_dart_message: Dart port is ILLEGAL_PORT"
        );

        return false;
    }


    //
    // Dart_CObject_kString requires a NUL-terminated string.
    //
    // Make an owned temporary copy.
    //
    std::string text(
        data,
        length
    );


    Dart_CObject type_object;

    type_object.type =
        Dart_CObject_kString;

    type_object.value.as_string =
        const_cast<char*>(
            type
        );


    Dart_CObject data_object;

    data_object.type =
        Dart_CObject_kString;

    data_object.value.as_string =
        const_cast<char*>(
            text.c_str()
        );


    Dart_CObject* values[2] = {
        &type_object,
        &data_object,
    };


    Dart_CObject message;

    message.type =
        Dart_CObject_kArray;

    message.value.as_array.values =
        values;

    message.value.as_array.length =
        2;


    LOGE(
        "POST -> DART: type=%s length=%zu port=%lld",
        type,
        length,
        static_cast<long long>(port)
    );


    const bool result =
        Dart_PostCObject_DL(
            port,
            &message
        );


    LOGE(
        "POST <- DART: type=%s result=%s",
        type,
        result ? "true" : "false"
    );


    if (!result) {

        LOGE(
            "Dart_PostCObject_DL FAILED: "
            "type=%s length=%zu",
            type,
            length
        );
    }


    return result;
}


// ===========================================================================
// stdout emitter
// ===========================================================================
//
// Node bridge protocol is NDJSON:
//
//     one JSON object per line
//
// Native strips the original newline while parsing the pipe, then adds
// exactly one newline back before sending the message to Dart.
//
// This keeps NdjsonLineSplitter on the Dart side working normally.
//
// ===========================================================================

static void emit_stdout(
    const char* data,
    size_t length
) {
    if (data == nullptr ||
        length == 0) {

        LOGW(
            "emit_stdout: empty data"
        );

        return;
    }


    LOGE(
        "emit_stdout: Node stdout line length=%zu",
        length
    );


    std::string framed(
        data,
        length
    );


    framed.push_back(
        '\n'
    );


    LOGE(
        "emit_stdout: posting framed stdout length=%zu",
        framed.size()
    );


    post_dart_message(
        "stdout",
        framed.data(),
        framed.size()
    );
}


// ===========================================================================
// stderr emitter
// ===========================================================================

static void emit_stderr(
    const char* data,
    size_t length
) {
    if (data == nullptr ||
        length == 0) {

        return;
    }


    LOGE(
        "emit_stderr: Node stderr chunk length=%zu",
        length
    );


    post_dart_message(
        "stderr",
        data,
        length
    );
}


// ===========================================================================
// stdout reader thread
// ===========================================================================

static void* stdout_reader_thread(
    void*
) {
    LOGE(
        "stdout_reader_thread: START"
    );


    char buffer[8192];


    std::string line_buffer;

    line_buffer.reserve(
        sizeof(buffer)
    );


    while (true) {

        const ssize_t n =
            read(
                g_pipe_out[0],
                buffer,
                sizeof(buffer)
            );


        if (n == 0) {

            LOGE(
                "stdout_reader_thread: EOF"
            );

            break;
        }


        if (n < 0) {

            if (errno == EINTR) {
                continue;
            }


            LOGE(
                "stdout_reader_thread: read FAILED: %s",
                std::strerror(errno)
            );

            break;
        }


        LOGE(
            "stdout_reader_thread: read %zd bytes",
            n
        );


        line_buffer.append(
            buffer,
            static_cast<size_t>(n)
        );


        size_t start = 0;


        while (true) {

            const size_t eol =
                line_buffer.find(
                    '\n',
                    start
                );


            if (eol == std::string::npos) {
                break;
            }


            std::string line =
                line_buffer.substr(
                    start,
                    eol - start
                );


            //
            // Remove CR from CRLF.
            //
            if (!line.empty() &&
                line.back() == '\r') {

                line.pop_back();
            }


            LOGE(
                "stdout_reader_thread: complete line "
                "length=%zu",
                line.size()
            );


            if (!line.empty()) {

                emit_stdout(
                    line.data(),
                    line.size()
                );
            }


            start =
                eol + 1;
        }


        if (start != 0) {

            line_buffer.erase(
                0,
                start
            );
        }
    }


    //
    // Flush final unterminated line.
    //
    if (!line_buffer.empty()) {

        LOGE(
            "stdout_reader_thread: flushing final line "
            "length=%zu",
            line_buffer.size()
        );


        emit_stdout(
            line_buffer.data(),
            line_buffer.size()
        );
    }


    LOGE(
        "stdout_reader_thread: END"
    );


    return nullptr;
}


// ===========================================================================
// stderr reader thread
// ===========================================================================

static void* stderr_reader_thread(
    void*
) {
    LOGE(
        "stderr_reader_thread: START"
    );


    char buffer[8192];


    while (true) {

        const ssize_t n =
            read(
                g_pipe_err[0],
                buffer,
                sizeof(buffer)
            );


        if (n == 0) {

            LOGE(
                "stderr_reader_thread: EOF"
            );

            break;
        }


        if (n < 0) {

            if (errno == EINTR) {
                continue;
            }


            LOGE(
                "stderr_reader_thread: read FAILED: %s",
                std::strerror(errno)
            );

            break;
        }


        LOGE(
            "stderr_reader_thread: read %zd bytes",
            n
        );


        emit_stderr(
            buffer,
            static_cast<size_t>(n)
        );
    }


    LOGE(
        "stderr_reader_thread: END"
    );


    return nullptr;
}



// ===========================================================================
// stdin redirection

// ===========================================================================
// Node thread
// ===========================================================================


// ---------------------------------------------------------------------------
// Node thread entry
// ---------------------------------------------------------------------------

static void* node_thread_main(
    void* /* arg */
) {
    //
    // In the new architecture, this thread simply waits for the Node
    // child process spawned by ncm_node_start() to exit, then cleans
    // up global state. The actual Node runtime runs in a separate
    // process; this thread does NOT execute any Node code itself.
    //
    LOGE(
        "================================================"
    );

    LOGE(
        "node_thread_main (wait): ENTER"
    );


    const pid_t child_pid =
        g_node_pid.load(
            std::memory_order_acquire
        );


    LOGE(
        "node_thread_main: waiting for child pid=%d",
        static_cast<int>(
            child_pid
        )
    );


    int status = 0;


    pid_t result = ::waitpid(
        child_pid,
        &status,
        0
    );


    if (result < 0) {

        LOGE(
            "node_thread_main: waitpid FAILED: %s",
            std::strerror(
                errno
            )
        );

    } else if (WIFEXITED(status)) {

        LOGE(
            "node_thread_main: child exited normally code=%d",
            WEXITSTATUS(status)
        );

    } else if (WIFSIGNALED(status)) {

        LOGE(
            "node_thread_main: child killed by signal=%d",
            WTERMSIG(status)
        );

    } else {

        LOGE(
            "node_thread_main: child terminated with unknown status=0x%x",
            static_cast<unsigned>(
                status
            )
        );
    }


    //
    // Reset child-tracking state.
    //
    g_node_pid.store(
        -1,
        std::memory_order_release
    );


    //
    // Close the write end of stdin if it is still open.
    //
    if (g_pipe_in[1] >= 0) {

        ::close(
            g_pipe_in[1]
        );

        g_pipe_in[1] = -1;
    }


    //
    // Free the StartArgs that ncm_node_start handed us.
    //
    StartArgs* owned_args =
        g_active_args;

    g_active_args = nullptr;


    if (owned_args != nullptr) {

        delete owned_args;
    }


    //
    // Mark the bridge as no longer running.
    //
    g_started.store(
        false,
        std::memory_order_release
    );


    LOGE(
        "node_thread_main: bridge marked stopped"
    );


    LOGE(
        "================================================"
    );


    return nullptr;
}

// ===========================================================================
// Public C API
// ===========================================================================

extern "C" {


// ===========================================================================
// Dart API DL initialization
// ===========================================================================

intptr_t ncm_node_initialize_dart_api(
    void* data
) {
    LOGE(
        "ncm_node_initialize_dart_api: ENTER data=%p",
        data
    );


    if (data == nullptr) {

        LOGE(
            "ncm_node_initialize_dart_api: data is null"
        );

        return -1;
    }


    const intptr_t result =
        Dart_InitializeApiDL(
            data
        );


    LOGE(
        "ncm_node_initialize_dart_api: "
        "Dart_InitializeApiDL result=%ld",
        static_cast<long>(result)
    );


    if (result == 0) {

        LOGE(
            "ncm_node_initialize_dart_api: SUCCESS"
        );

    } else {

        LOGE(
            "ncm_node_initialize_dart_api: FAILED"
        );
    }


    return result;
}


// ===========================================================================
// Dart port
// ===========================================================================

void ncm_node_set_dart_port(
    int64_t port
) {
    LOGE(
        "ncm_node_set_dart_port: ENTER port=%lld",
        static_cast<long long>(port)
    );


    g_dart_port.store(
        static_cast<Dart_Port_DL>(port),
        std::memory_order_release
    );


    const Dart_Port_DL stored =
        g_dart_port.load(
            std::memory_order_acquire
        );


    LOGE(
        "ncm_node_set_dart_port: STORED port=%lld",
        static_cast<long long>(stored)
    );
}


// ===========================================================================
// Executable path
// ===========================================================================

void ncm_node_set_executable_path(
    const char* path
) {
    LOGE(
        "ncm_node_set_executable_path: ENTER path=%s",
        path == nullptr
            ? "<null>"
            : path
    );


    if (path == nullptr ||
        path[0] == '\0') {

        g_node_exe_path.clear();

        LOGE(
            "ncm_node_set_executable_path: cleared"
        );

        return;
    }


    //
    // std::string assignment copies the bytes; we no longer depend
    // on the caller's storage.
    //
    g_node_exe_path = path;


    LOGE(
        "ncm_node_set_executable_path: STORED length=%zu",
        g_node_exe_path.size()
    );
}


// ===========================================================================
// Start
// ===========================================================================

int ncm_node_start(
    int argc,
    const char* const* argv
) {
    LOGE(
        "================================================"
    );

    LOGE(
        "ncm_node_start: ENTER argc=%d",
        argc
    );


    if (argc <= 0 ||
        argv == nullptr) {

        LOGE(
            "ncm_node_start: invalid arguments"
        );

        return -1;
    }


    const Dart_Port_DL port =
        g_dart_port.load(
            std::memory_order_acquire
        );


    LOGE(
        "ncm_node_start: Dart port=%lld",
        static_cast<long long>(port)
    );


    if (port == ILLEGAL_PORT) {

        LOGE(
            "ncm_node_start: Dart port is not initialized"
        );

        return -1;
    }


    if (g_started.exchange(true)) {

        LOGE(
            "ncm_node_start: Node is already running"
        );

        return -1;
    }


    //
    // Copy the executable path and the argv before we fork so the
    // child sees a stable snapshot.
    //
    if (g_node_exe_path.empty()) {

        LOGE(
            "ncm_node_start: executable path is not set; "
            "call ncm_node_set_executable_path() first"
        );

        g_started.store(false);
        return -1;
    }


    LOGE(
        "ncm_node_start: executable=%s",
        g_node_exe_path.c_str()
    );


    //
    // Reject a non-existent or non-executable node binary up front.
    // Saves us from forking a doomed child.
    //
    struct stat exe_stat;


    if (::stat(
            g_node_exe_path.c_str(),
            &exe_stat
        ) != 0) {

        LOGE(
            "ncm_node_start: stat(%s) FAILED: %s",
            g_node_exe_path.c_str(),
            std::strerror(errno)
        );

        g_started.store(false);
        return -1;
    }


    if (::access(
            g_node_exe_path.c_str(),
            X_OK
        ) != 0) {

        LOGE(
            "ncm_node_start: executable not X_OK: %s (%s)",
            g_node_exe_path.c_str(),
            std::strerror(errno)
        );

        g_started.store(false);
        return -1;
    }


    //
    // Deep-copy argv into a StartArgs we can hand off to the wait
    // thread once fork() succeeds.
    //
    StartArgs* args =
        new StartArgs();


    args->argc = argc;

    args->argv.reserve(
        static_cast<size_t>(argc)
    );


    for (int i = 0; i < argc; ++i) {

        if (argv[i] == nullptr) {

            LOGE(
                "ncm_node_start: argv[%d] is null",
                i
            );


            delete args;

            g_started.store(false);
            return -1;
        }


        args->argv.emplace_back(
            argv[i]
        );
    }


    LOGE(
        "ncm_node_start: arguments copied successfully"
    );


    for (int i = 0; i < argc; ++i) {

        LOGE(
            "ncm_node_start: copied argv[%d]=%s",
            i,
            args->argv[i].c_str()
        );
    }


    //
    // Set up stdout/stderr/stdin pipes BEFORE fork().
    //
    if (::pipe(g_pipe_out) != 0) {

        LOGE(
            "ncm_node_start: pipe(stdout) FAILED: %s",
            std::strerror(errno)
        );

        delete args;

        g_started.store(false);
        return -1;
    }


    if (::pipe(g_pipe_err) != 0) {

        LOGE(
            "ncm_node_start: pipe(stderr) FAILED: %s",
            std::strerror(errno)
        );

        ::close(g_pipe_out[0]);
        ::close(g_pipe_out[1]);

        delete args;

        g_started.store(false);
        return -1;
    }


    if (::pipe(g_pipe_in) != 0) {

        LOGE(
            "ncm_node_start: pipe(stdin) FAILED: %s",
            std::strerror(errno)
        );

        ::close(g_pipe_out[0]);
        ::close(g_pipe_out[1]);
        ::close(g_pipe_err[0]);
        ::close(g_pipe_err[1]);

        delete args;

        g_started.store(false);
        return -1;
    }


    LOGE(
        "ncm_node_start: pipes created"
    );


    //
    // Hand the argv to the future wait thread.
    //
    g_active_args = args;


    const pid_t child_pid =
        ::fork();


    if (child_pid < 0) {

        LOGE(
            "ncm_node_start: fork FAILED: %s",
            std::strerror(errno)
        );

        ::close(g_pipe_out[0]);
        ::close(g_pipe_out[1]);
        ::close(g_pipe_err[0]);
        ::close(g_pipe_err[1]);
        ::close(g_pipe_in[0]);
        ::close(g_pipe_in[1]);
        g_pipe_out[0] = g_pipe_out[1] = -1;
        g_pipe_err[0] = g_pipe_err[1] = -1;
        g_pipe_in[0] = g_pipe_in[1] = -1;

        g_active_args = nullptr;
        delete args;

        g_started.store(false);
        return -1;
    }


    if (child_pid == 0) {
        //
        // CHILD PROCESS
        //

        LOGE(
            "ncm_node_start[child]: ENTER pid=%d",
            ::getpid()
        );


        //
        // Wire up stdin/stdout/stderr to the pipes.
        //
        if (::dup2(
                g_pipe_in[0],
                STDIN_FILENO
            ) < 0) {

            LOGE(
                "ncm_node_start[child]: dup2(stdin) FAILED: %s",
                std::strerror(errno)
            );

            ::_exit(126);
        }


        if (::dup2(
                g_pipe_out[1],
                STDOUT_FILENO
            ) < 0) {

            LOGE(
                "ncm_node_start[child]: dup2(stdout) FAILED: %s",
                std::strerror(errno)
            );

            ::_exit(126);
        }


        if (::dup2(
                g_pipe_err[1],
                STDERR_FILENO
            ) < 0) {

            LOGE(
                "ncm_node_start[child]: dup2(stderr) FAILED: %s",
                std::strerror(errno)
            );

            ::_exit(126);
        }


        //
        // Close the original pipe fds; the dup2'd fds are now in
        // stdin/stdout/stderr positions.
        //
        ::close(g_pipe_in[0]);
        ::close(g_pipe_out[1]);
        ::close(g_pipe_err[1]);
        ::close(g_pipe_in[1]);
        ::close(g_pipe_out[0]);
        ::close(g_pipe_err[0]);


        //
        // Build a contiguous argv for execvp. argv[0] is expected
        // to be the executable path.
        //
        size_t total_size = 0;


        for (const std::string& value :
             args->argv) {

            total_size +=
                value.size() + 1;
        }


        char* buffer =
            static_cast<char*>(
                std::calloc(
                    total_size,
                    1
                )
            );


        if (buffer == nullptr) {

            LOGE(
                "ncm_node_start[child]: failed to allocate argv buffer"
            );

            ::_exit(127);
        }


        std::vector<char*> argv_ptrs;

        argv_ptrs.reserve(
            args->argv.size()
        );

        char* cursor = buffer;


        for (const std::string& value :
             args->argv) {

            const size_t size =
                value.size();


            std::memcpy(
                cursor,
                value.c_str(),
                size + 1
            );


            argv_ptrs.push_back(
                cursor
            );


            cursor +=
                size + 1;
        }


        //
        // execvp replaces the child. We pass g_node_exe_path as
        // argv[0] too (matches argv[1..n] which the Dart side set
        // up assuming argv[0] is the executable path).
        //
        ::execvp(
            g_node_exe_path.c_str(),
            argv_ptrs.data()
        );


        //
        // execvp only returns on failure.
        //
        const int exec_errno = errno;


        LOGE(
            "ncm_node_start[child]: execvp(%s) FAILED: %s",
            g_node_exe_path.c_str(),
            std::strerror(exec_errno)
        );


        ::_exit(127);

        //
        // Unreachable; the parent path continues below.
        //
    }


    //
    // PARENT PROCESS
    //

    g_node_pid.store(
        child_pid,
        std::memory_order_release
    );


    LOGE(
        "ncm_node_start: forked child pid=%d",
        static_cast<int>(child_pid)
    );


    //
    // Close the child-side fds the parent doesn't need.
    //
    ::close(g_pipe_in[0]);
    g_pipe_in[0] = -1;


    ::close(g_pipe_out[1]);
    g_pipe_out[1] = -1;


    ::close(g_pipe_err[1]);
    g_pipe_err[1] = -1;


    //
    // Start the stdout/stderr reader pthreads (these were already
    // used by the in-process bridge; they block on read() and
    // post NDJSON lines to Dart).
    //
    const int out_rc =
        ::pthread_create(
            &g_thread_out,
            nullptr,
            stdout_reader_thread,
            nullptr
        );


    if (out_rc != 0) {

        LOGE(
            "ncm_node_start: pthread_create(stdout) FAILED: rc=%d (%s)",
            out_rc,
            std::strerror(out_rc)
        );


        //
        // Best-effort cleanup. We do NOT reset g_started here;
        // that gets done by the wait thread when it sees the
        // child exit.
        //

        ::kill(child_pid, SIGKILL);

        return -1;
    }


    ::pthread_detach(g_thread_out);


    const int err_rc =
        ::pthread_create(
            &g_thread_err,
            nullptr,
            stderr_reader_thread,
            nullptr
        );


    if (err_rc != 0) {

        LOGE(
            "ncm_node_start: pthread_create(stderr) FAILED: rc=%d (%s)",
            err_rc,
            std::strerror(err_rc)
        );


        ::kill(child_pid, SIGKILL);

        return -1;
    }


    ::pthread_detach(g_thread_err);


    //
    // Spawn the wait thread. It does waitpid() and cleans up
    // g_started / g_active_args / g_pipe_in[1] when the child
    // exits.
    //
    pthread_t wait_thread;


    const int wait_rc =
        ::pthread_create(
            &wait_thread,
            nullptr,
            node_thread_main,
            args
        );


    if (wait_rc != 0) {

        LOGE(
            "ncm_node_start: pthread_create(wait) FAILED: rc=%d (%s)",
            wait_rc,
            std::strerror(wait_rc)
        );


        ::kill(child_pid, SIGKILL);

        g_active_args = nullptr;
        delete args;

        g_started.store(false);
        return -1;
    }


    ::pthread_detach(wait_thread);


    LOGE(
        "ncm_node_start: RETURN 0"
    );


    LOGE(
        "================================================"
    );


    return 0;
}

// ===========================================================================
// stdin
// ===========================================================================

int ncm_node_write_stdin(
    const unsigned char* data,
    size_t length
) {
    LOGE(
        "ncm_node_write_stdin: ENTER length=%zu",
        length
    );


    if (data == nullptr &&
        length != 0) {

        LOGE(
            "ncm_node_write_stdin: invalid data pointer"
        );

        return -1;
    }


    if (g_pipe_in[1] < 0) {

        LOGE(
            "ncm_node_write_stdin: stdin pipe "
            "is not initialized fd=%d",
            g_pipe_in[1]
        );

        return -1;
    }


    size_t offset = 0;


    while (offset < length) {

        const ssize_t n =
            write(
                g_pipe_in[1],
                data + offset,
                length - offset
            );


        if (n < 0) {

            if (errno == EINTR) {
                continue;
            }


            LOGE(
                "ncm_node_write_stdin: write FAILED: %s",
                std::strerror(errno)
            );

            return -1;
        }


        if (n == 0) {

            LOGE(
                "ncm_node_write_stdin: write returned zero"
            );

            return -1;
        }


        offset +=
            static_cast<size_t>(n);
    }


    LOGE(
        "ncm_node_write_stdin: SUCCESS wrote=%zu",
        offset
    );


    return 0;
}


// ===========================================================================
// Shutdown
// ===========================================================================

void ncm_node_request_shutdown() {

    LOGE(
        "ncm_node_request_shutdown: ENTER"
    );


    //
    // We have a real child process now (fork+execvp). Give it a
    // chance to exit cleanly by closing its stdin (which makes a
    // well-behaved Node bundle.js see EOF and return), and follow
    // up with SIGTERM, then SIGKILL if it is still alive.
    //

    if (g_pipe_in[1] >= 0) {

        ::close(
            g_pipe_in[1]
        );

        g_pipe_in[1] = -1;
    }


    const pid_t child_pid =
        g_node_pid.load(
            std::memory_order_acquire
        );


    if (child_pid <= 0) {

        LOGW(
            "ncm_node_request_shutdown: no live child (pid=%d)",
            static_cast<int>(child_pid)
        );

        return;
    }


    LOGE(
        "ncm_node_request_shutdown: sending SIGTERM to pid=%d",
        static_cast<int>(child_pid)
    );


    if (::kill(
            child_pid,
            SIGTERM
        ) != 0) {

        LOGE(
            "ncm_node_request_shutdown: SIGTERM FAILED: %s",
            std::strerror(errno)
        );
    }


    //
    // The wait thread is detached and will eventually clean up
    // g_started / g_active_args / g_pipe_in[1]. We deliberately
    // do NOT block here waiting for the child — Dart's
    // shutdown() is allowed to return immediately.
    //
}


// ===========================================================================
// Running state
// ===========================================================================

int ncm_node_is_running() {

    const int running =
        g_started.load(
            std::memory_order_acquire
        )
            ? 1
            : 0;


    LOGE(
        "ncm_node_is_running: %d",
        running
    );


    return running;
}


} // extern "C"