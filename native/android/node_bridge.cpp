// native/android/node_bridge.cpp
//
// Native bridge for embedded Node.js (nodejs-mobile v18.20.4).
//
// Architecture:
//
//   Dart FFI
//       |
//       v
//   libncm_node_bridge.so
//       |
//       v
//   libnode.so
//       |
//       v
//   node::Start()
//
// Native -> Dart communication:
//
//   Node / native pthread
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
//   This bridge intentionally does NOT include node.h.
//
//   libnode.so exports:
//
//       _ZN4node5StartEiPPc
//
//   which demangles to:
//
//       node::Start(int, char**)
//
//   Therefore we declare the function ourselves and link against
//   libnode.so directly.
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
#include <string>
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
// libnode.so exports:
//
//     _ZN4node5StartEiPPc
//
// which is:
//
//     node::Start(int, char**)
//
// We intentionally declare it here instead of including node.h.
//
// ===========================================================================

namespace node {

int Start(int argc, char** argv);

} // namespace node


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
// Start embedded Node
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
// stdout/stderr redirection
// ===========================================================================

static int redirect_stdout_stderr() {

    LOGE(
        "redirect_stdout_stderr: START"
    );


    setvbuf(
        stdout,
        nullptr,
        _IONBF,
        0
    );


    // -----------------------------------------------------------------------
    // stdout pipe
    // -----------------------------------------------------------------------

    if (pipe(g_pipe_out) != 0) {

        LOGE(
            "pipe(stdout) FAILED: %s",
            std::strerror(errno)
        );

        return -1;
    }


    LOGE(
        "stdout pipe created: read=%d write=%d",
        g_pipe_out[0],
        g_pipe_out[1]
    );


    if (dup2(
            g_pipe_out[1],
            STDOUT_FILENO
        ) < 0) {

        LOGE(
            "dup2(stdout) FAILED: %s",
            std::strerror(errno)
        );

        return -1;
    }


    LOGE(
        "stdout redirected successfully"
    );


    close(
        g_pipe_out[1]
    );

    g_pipe_out[1] = -1;


    // -----------------------------------------------------------------------
    // stderr pipe
    // -----------------------------------------------------------------------

    setvbuf(
        stderr,
        nullptr,
        _IONBF,
        0
    );


    if (pipe(g_pipe_err) != 0) {

        LOGE(
            "pipe(stderr) FAILED: %s",
            std::strerror(errno)
        );

        return -1;
    }


    LOGE(
        "stderr pipe created: read=%d write=%d",
        g_pipe_err[0],
        g_pipe_err[1]
    );


    if (dup2(
            g_pipe_err[1],
            STDERR_FILENO
        ) < 0) {

        LOGE(
            "dup2(stderr) FAILED: %s",
            std::strerror(errno)
        );

        return -1;
    }


    LOGE(
        "stderr redirected successfully"
    );


    close(
        g_pipe_err[1]
    );

    g_pipe_err[1] = -1;


    // -----------------------------------------------------------------------
    // stdout reader
    // -----------------------------------------------------------------------

    const int out_rc =
        pthread_create(
            &g_thread_out,
            nullptr,
            stdout_reader_thread,
            nullptr
        );


    if (out_rc != 0) {

        LOGE(
            "pthread_create(stdout reader) FAILED: "
            "rc=%d (%s)",
            out_rc,
            std::strerror(out_rc)
        );

        return -1;
    }


    LOGE(
        "stdout reader thread CREATED"
    );


    // -----------------------------------------------------------------------
    // stderr reader
    // -----------------------------------------------------------------------

    const int err_rc =
        pthread_create(
            &g_thread_err,
            nullptr,
            stderr_reader_thread,
            nullptr
        );


    if (err_rc != 0) {

        LOGE(
            "pthread_create(stderr reader) FAILED: "
            "rc=%d (%s)",
            err_rc,
            std::strerror(err_rc)
        );

        return -1;
    }


    LOGE(
        "stderr reader thread CREATED"
    );


    pthread_detach(
        g_thread_out
    );


    pthread_detach(
        g_thread_err
    );


    LOGE(
        "redirect_stdout_stderr: SUCCESS"
    );


    return 0;
}


// ===========================================================================
// stdin redirection
// ===========================================================================

static int redirect_stdin() {

    LOGE(
        "redirect_stdin: START"
    );


    if (pipe(g_pipe_in) != 0) {

        LOGE(
            "pipe(stdin) FAILED: %s",
            std::strerror(errno)
        );

        return -1;
    }


    LOGE(
        "stdin pipe created: read=%d write=%d",
        g_pipe_in[0],
        g_pipe_in[1]
    );


    if (dup2(
            g_pipe_in[0],
            STDIN_FILENO
        ) < 0) {

        LOGE(
            "dup2(stdin) FAILED: %s",
            std::strerror(errno)
        );

        return -1;
    }


    LOGE(
        "stdin redirected successfully"
    );


    close(
        g_pipe_in[0]
    );

    g_pipe_in[0] = -1;


    LOGE(
        "redirect_stdin: SUCCESS"
    );


    return 0;
}


// ===========================================================================
// Node thread
// ===========================================================================

struct StartArgs {
    int argc;

    std::vector<std::string> argv;
};


// ---------------------------------------------------------------------------
// Node thread entry
// ---------------------------------------------------------------------------

static void* node_thread_main(
    void* arg
) {
    LOGE(
        "================================================"
    );

    LOGE(
        "node_thread_main: ENTER"
    );


    StartArgs* args =
        static_cast<StartArgs*>(
            arg
        );


    if (args == nullptr) {

        LOGE(
            "node_thread_main: args == nullptr"
        );

        g_started = false;

        return nullptr;
    }


    LOGE(
        "node_thread_main: argc=%d",
        args->argc
    );


    for (int i = 0; i < args->argc; ++i) {

        LOGE(
            "node_thread_main: argv[%d]=%s",
            i,
            args->argv[i].c_str()
        );
    }


    // -----------------------------------------------------------------------
    // Build contiguous argv storage.
    // -----------------------------------------------------------------------

    size_t total_size = 0;


    for (const std::string& value :
         args->argv) {

        total_size +=
            value.size() + 1;
    }


    LOGE(
        "node_thread_main: argv buffer size=%zu",
        total_size
    );


    char* buffer =
        static_cast<char*>(
            std::calloc(
                total_size,
                1
            )
        );


    if (buffer == nullptr) {

        LOGE(
            "node_thread_main: failed to allocate argv buffer"
        );


        delete args;


        g_started = false;


        return nullptr;
    }


    std::vector<char*> argv;

    argv.reserve(
        args->argv.size()
    );


    char* cursor =
        buffer;


    for (const std::string& value :
         args->argv) {

        const size_t size =
            value.size();


        std::memcpy(
            cursor,
            value.c_str(),
            size + 1
        );


        argv.push_back(
            cursor
        );


        cursor +=
            size + 1;
    }


    LOGE(
        "node_thread_main: argv buffer initialized"
    );


    // -----------------------------------------------------------------------
    // Redirect stdio BEFORE node::Start().
    // -----------------------------------------------------------------------

    LOGE(
        "node_thread_main: redirecting stdout/stderr"
    );


    if (redirect_stdout_stderr() != 0) {

        LOGE(
            "node_thread_main: "
            "stdout/stderr redirection FAILED"
        );


        std::free(buffer);

        delete args;

        g_started = false;

        return nullptr;
    }


    LOGE(
        "node_thread_main: stdout/stderr redirection OK"
    );


    LOGE(
        "node_thread_main: redirecting stdin"
    );


    if (redirect_stdin() != 0) {

        LOGE(
            "node_thread_main: "
            "stdin redirection FAILED"
        );


        std::free(buffer);

        delete args;

        g_started = false;

        return nullptr;
    }


    LOGE(
        "node_thread_main: stdin redirection OK"
    );


    // -----------------------------------------------------------------------
    // IMPORTANT:
    //
    // After stdout/stderr redirection, use Android log only.
    // -----------------------------------------------------------------------

    LOGE(
        "================================================"
    );

    LOGE(
        "node_thread_main: ABOUT TO CALL node::Start()"
    );


    if (argv.empty()) {

        LOGE(
            "node_thread_main: argv is EMPTY"
        );
    } else {

        LOGE(
            "node_thread_main: argv[0]=%s",
            argv[0]
        );


        if (argv.size() > 1) {

            LOGE(
                "node_thread_main: argv[1]=%s",
                argv[1]
            );
        }
    }


    LOGE(
        "node_thread_main: calling node::Start NOW"
    );


    // -----------------------------------------------------------------------
    // Start embedded Node.
    // -----------------------------------------------------------------------

    const int rc =
        node::Start(
            args->argc,
            argv.data()
        );


    LOGE(
        "node_thread_main: node::Start() RETURNED rc=%d",
        rc
    );


    LOGE(
        "node_thread_main: Node has exited"
    );


    std::free(buffer);

    delete args;


    g_started = false;


    LOGE(
        "node_thread_main: END"
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


    StartArgs* args =
        new StartArgs();


    args->argc =
        argc;


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

            g_started = false;

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


    pthread_t thread;


    LOGE(
        "ncm_node_start: creating Node pthread"
    );


    const int rc =
        pthread_create(
            &thread,
            nullptr,
            node_thread_main,
            args
        );


    if (rc != 0) {

        LOGE(
            "ncm_node_start: pthread_create FAILED "
            "rc=%d (%s)",
            rc,
            std::strerror(rc)
        );


        delete args;

        g_started = false;

        return -1;
    }


    LOGE(
        "ncm_node_start: Node pthread CREATED"
    );


    pthread_detach(
        thread
    );


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
    // Node's current embedded startup does not expose a reliable clean
    // shutdown API.
    //
    // Keep this as a no-op for now.
    //

    LOGW(
        "shutdown requested, but embedded Node "
        "has no clean shutdown API"
    );
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