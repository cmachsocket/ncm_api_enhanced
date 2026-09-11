// node_bridge.cpp
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
//
// Dart calls:
//
//     ncm_node_initialize_dart_api(
//         NativeApi.initializeApiDLData
//     );
//
// Native then calls:
//
//     Dart_InitializeApiDL(data);
//
// Return:
//     0 on success
//     non-zero on failure
//
intptr_t ncm_node_initialize_dart_api(
    void* data
);


// ---------------------------------------------------------------------------
// Dart native port
// ---------------------------------------------------------------------------
//
// Dart passes:
//
//     ReceivePort.sendPort.nativePort
//
// Native stores the port ID and uses Dart_PostCObject_DL() from native
// threads to deliver messages to the Dart isolate.
//
// ---------------------------------------------------------------------------

void ncm_node_set_dart_port(
    int64_t port
);


// ---------------------------------------------------------------------------
// Start embedded Node.
//
// argv follows the normal C argv convention:
//
//   argv[0] = "node"
//   argv[1] = "/path/to/bundle.js"
//   ...
//
// ncm_node_start() itself returns immediately after creating the
// Node thread.
//
// Return:
//    0  success
//   -1  already started / invalid arguments / pthread failure
// ---------------------------------------------------------------------------

int ncm_node_start(
    int argc,
    const char* const* argv
);


// ---------------------------------------------------------------------------
// Write bytes to Node's stdin.
//
// This function does NOT append '\n'.
//
// Return:
//    0  success
//   -1  failure
// ---------------------------------------------------------------------------

int ncm_node_write_stdin(
    const unsigned char* data,
    size_t length
);


// ---------------------------------------------------------------------------
// Request shutdown.
//
// The current embedded Node design does not expose a reliable clean
// shutdown mechanism.
//
// Therefore this remains a no-op for now.
// ---------------------------------------------------------------------------

void ncm_node_request_shutdown();


// ---------------------------------------------------------------------------
// Query whether node::Start() is currently running.
//
// Return:
//   1 running
//   0 not running
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
//
// This is intentionally Dart_Port_DL rather than a Dart callback pointer.
//
// Dart_PostCObject_DL() is safe to call from native threads after the Dart
// API DL has been initialized.
//
// ---------------------------------------------------------------------------

static std::atomic<Dart_Port_DL> g_dart_port{
    ILLEGAL_PORT
};


// stdout pipe:
//
//   Node stdout
//       |
//       v
//   g_pipe_out[1]
//       |
//       v
//   g_pipe_out[0]
//       |
//       v
//   stdout reader thread
//
static int g_pipe_out[2] = {-1, -1};


// stderr pipe.
static int g_pipe_err[2] = {-1, -1};


// stdin pipe:
//
//   Dart
//       |
//       v
//   g_pipe_in[1]
//       |
//       v
//   g_pipe_in[0]
//       |
//       v
//   Node stdin
//
static int g_pipe_in[2] = {-1, -1};


static pthread_t g_thread_out;
static pthread_t g_thread_err;


// ===========================================================================
// Dart message helper
// ===========================================================================
//
// Message format:
//
//   [ "stdout", "<text>" ]
//
// or:
//
//   [ "stderr", "<text>" ]
//
// Dart receives this through ReceivePort.
//
//
// IMPORTANT:
//
// Dart_PostCObject_DL() copies the Dart_CObject contents into the message
// that is posted to the isolate. Therefore the strings only need to remain
// valid for the duration of this call.
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
        return false;
    }


    const Dart_Port_DL port =
        g_dart_port.load(std::memory_order_acquire);


    if (port == ILLEGAL_PORT) {
        LOGW(
            "cannot post native message: Dart port is not initialized"
        );

        return false;
    }


    //
    // Dart_CObject strings require a NUL-terminated C string.
    //
    // stdout/stderr data is not necessarily NUL terminated.
    //
    std::string text(
        data,
        length
    );


    Dart_CObject type_object;

    type_object.type =
        Dart_CObject_kString;

    type_object.value.as_string =
        const_cast<char*>(type);


    Dart_CObject data_object;

    data_object.type =
        Dart_CObject_kString;

    data_object.value.as_string =
        const_cast<char*>(text.c_str());


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


    const bool result =
        Dart_PostCObject_DL(
            port,
            &message
        );


    if (!result) {
        LOGW(
            "Dart_PostCObject_DL failed"
        );
    }


    return result;
}


// ===========================================================================
// stdout emitter
// ===========================================================================

static void emit_stdout(
    const char* data,
    size_t length
) {
    if (data == nullptr || length == 0) {
        return;
    }

    std::string framed(data, length);
    framed.push_back('\n');

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
    post_dart_message(
        "stderr",
        data,
        length
    );
}


// ===========================================================================
// stdout reader
// ===========================================================================
//
// stdout is line-framed here.
//
// This is intentional because the Node bridge protocol is NDJSON:
//
//     one JSON object per line
//
// Dart still keeps NdjsonLineSplitter so the transport contract remains
// robust and equivalent to DesktopNcmBridge.
//
// ===========================================================================

static void* stdout_reader_thread(void*) {
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
            // EOF.
            break;
        }


        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }


            LOGE(
                "stdout read failed: %s",
                std::strerror(errno)
            );

            break;
        }


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


            // Remove CR from CRLF.
            if (!line.empty() &&
                line.back() == '\r') {
                line.pop_back();
            }


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


    // Flush final unterminated line.
    if (!line_buffer.empty()) {
        emit_stdout(
            line_buffer.data(),
            line_buffer.size()
        );
    }


    return nullptr;
}


// ===========================================================================
// stderr reader
// ===========================================================================
//
// stderr is intentionally not line-framed.
//
// Node may write arbitrary chunks here and Dart simply exposes them as log
// events.
//
// ===========================================================================

static void* stderr_reader_thread(void*) {
    char buffer[8192];


    while (true) {
        const ssize_t n =
            read(
                g_pipe_err[0],
                buffer,
                sizeof(buffer)
            );


        if (n == 0) {
            break;
        }


        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }


            LOGE(
                "stderr read failed: %s",
                std::strerror(errno)
            );

            break;
        }


        emit_stderr(
            buffer,
            static_cast<size_t>(n)
        );
    }


    return nullptr;
}


// ===========================================================================
// stdout/stderr redirection
// ===========================================================================

static int redirect_stdout_stderr() {

    setvbuf(
        stdout,
        nullptr,
        _IONBF,
        0
    );


    if (pipe(g_pipe_out) != 0) {
        LOGE(
            "pipe(stdout) failed: %s",
            std::strerror(errno)
        );

        return -1;
    }


    if (dup2(
            g_pipe_out[1],
            STDOUT_FILENO
        ) < 0) {

        LOGE(
            "dup2(stdout) failed: %s",
            std::strerror(errno)
        );

        return -1;
    }


    close(
        g_pipe_out[1]
    );

    g_pipe_out[1] = -1;


    setvbuf(
        stderr,
        nullptr,
        _IONBF,
        0
    );


    if (pipe(g_pipe_err) != 0) {
        LOGE(
            "pipe(stderr) failed: %s",
            std::strerror(errno)
        );

        return -1;
    }


    if (dup2(
            g_pipe_err[1],
            STDERR_FILENO
        ) < 0) {

        LOGE(
            "dup2(stderr) failed: %s",
            std::strerror(errno)
        );

        return -1;
    }


    close(
        g_pipe_err[1]
    );

    g_pipe_err[1] = -1;


    if (pthread_create(
            &g_thread_out,
            nullptr,
            stdout_reader_thread,
            nullptr
        ) != 0) {

        LOGE(
            "failed to create stdout reader"
        );

        return -1;
    }


    if (pthread_create(
            &g_thread_err,
            nullptr,
            stderr_reader_thread,
            nullptr
        ) != 0) {

        LOGE(
            "failed to create stderr reader"
        );

        return -1;
    }


    pthread_detach(
        g_thread_out
    );

    pthread_detach(
        g_thread_err
    );


    return 0;
}


// ===========================================================================
// stdin redirection
// ===========================================================================

static int redirect_stdin() {

    if (pipe(g_pipe_in) != 0) {
        LOGE(
            "pipe(stdin) failed: %s",
            std::strerror(errno)
        );

        return -1;
    }


    if (dup2(
            g_pipe_in[0],
            STDIN_FILENO
        ) < 0) {

        LOGE(
            "dup2(stdin) failed: %s",
            std::strerror(errno)
        );

        return -1;
    }


    close(
        g_pipe_in[0]
    );

    g_pipe_in[0] = -1;


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

static void* node_thread_main(void* arg) {
    StartArgs* args =
        static_cast<StartArgs*>(arg);


    // -----------------------------------------------------------------------
    // Build contiguous argv storage.
    // -----------------------------------------------------------------------

    size_t total_size = 0;


    for (const std::string& value : args->argv) {
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
            "failed to allocate argv buffer"
        );

        delete args;

        g_started = false;

        return nullptr;
    }


    std::vector<char*> argv;

    argv.reserve(
        args->argv.size()
    );


    char* cursor = buffer;


    for (const std::string& value : args->argv) {
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


    // -----------------------------------------------------------------------
    // Redirect stdio BEFORE node::Start().
    // -----------------------------------------------------------------------

    if (redirect_stdout_stderr() != 0) {
        LOGE(
            "stdout/stderr redirection failed"
        );

        std::free(buffer);
        delete args;

        g_started = false;

        return nullptr;
    }


    if (redirect_stdin() != 0) {
        LOGE(
            "stdin redirection failed"
        );

        std::free(buffer);
        delete args;

        g_started = false;

        return nullptr;
    }


    LOGI(
        "starting embedded node, argc=%d",
        args->argc
    );


    // -----------------------------------------------------------------------
    // Start Node.
    //
    // libnode.so exports:
    //
    //     _ZN4node5StartEiPPc
    //
    // which is:
    //
    //     node::Start(int, char**)
    //
    // -----------------------------------------------------------------------

    const int rc =
        node::Start(
            args->argc,
            argv.data()
        );


    LOGI(
        "node::Start returned %d",
        rc
    );


    std::free(buffer);

    delete args;


    g_started = false;


    return nullptr;
}


// ===========================================================================
// Public C API
// ===========================================================================

extern "C" {


// ---------------------------------------------------------------------------
// Dart API DL
// ---------------------------------------------------------------------------

intptr_t ncm_node_initialize_dart_api(
    void* data
) {
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


    if (result != 0) {
        LOGE(
            "Dart_InitializeApiDL failed: %ld",
            static_cast<long>(result)
        );
    } else {
        LOGI(
            "Dart API DL initialized"
        );
    }


    return result;
}


// ---------------------------------------------------------------------------
// Dart port
// ---------------------------------------------------------------------------

void ncm_node_set_dart_port(
    int64_t port
) {
    g_dart_port.store(
        static_cast<Dart_Port_DL>(port),
        std::memory_order_release
    );


    LOGI(
        "Dart native port set: %lld",
        static_cast<long long>(port)
    );
}


// ---------------------------------------------------------------------------
// Start
// ---------------------------------------------------------------------------

int ncm_node_start(
    int argc,
    const char* const* argv
) {
    if (argc <= 0 ||
        argv == nullptr) {

        LOGE(
            "ncm_node_start: invalid arguments"
        );

        return -1;
    }


    if (g_dart_port.load(
            std::memory_order_acquire
        ) == ILLEGAL_PORT) {

        LOGE(
            "ncm_node_start: Dart port is not initialized"
        );

        return -1;
    }


    if (g_started.exchange(true)) {
        LOGW(
            "ncm_node_start: node is already running"
        );

        return -1;
    }


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

            g_started = false;

            return -1;
        }


        args->argv.emplace_back(
            argv[i]
        );
    }


    pthread_t thread;


    const int rc =
        pthread_create(
            &thread,
            nullptr,
            node_thread_main,
            args
        );


    if (rc != 0) {
        LOGE(
            "pthread_create failed: %s",
            std::strerror(rc)
        );

        delete args;

        g_started = false;

        return -1;
    }


    pthread_detach(
        thread
    );


    return 0;
}


// ---------------------------------------------------------------------------
// stdin
// ---------------------------------------------------------------------------

int ncm_node_write_stdin(
    const unsigned char* data,
    size_t length
) {
    if (data == nullptr &&
        length != 0) {

        return -1;
    }


    if (g_pipe_in[1] < 0) {
        LOGE(
            "stdin pipe is not initialized"
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
                "write(stdin) failed: %s",
                std::strerror(errno)
            );

            return -1;
        }


        if (n == 0) {
            LOGE(
                "write(stdin) returned zero"
            );

            return -1;
        }


        offset +=
            static_cast<size_t>(n);
    }


    return 0;
}


// ---------------------------------------------------------------------------
// Shutdown
// ---------------------------------------------------------------------------

void ncm_node_request_shutdown() {
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


// ---------------------------------------------------------------------------
// Running state
// ---------------------------------------------------------------------------

int ncm_node_is_running() {
    return g_started.load(
        std::memory_order_acquire
    )
        ? 1
        : 0;
}

} // extern "C"
