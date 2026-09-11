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
// Callback memory:
//   The bridge allocates callback buffers with malloc().
//   Dart must call ncm_node_free_buffer() after copying the data.
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
// This bridge is therefore tied to a libnode.so whose ABI provides exactly
// this symbol/signature.
//
// ===========================================================================

namespace node {

int Start(int argc, char** argv);

} // namespace node


// ===========================================================================
// C ABI
// ===========================================================================

extern "C" {

typedef void (*ncm_node_output_callback)(
    const unsigned char* data,
    size_t length
);

typedef void (*ncm_node_error_callback)(
    const unsigned char* data,
    size_t length
);


// Register callbacks.
//
// stdout_callback:
//   Called whenever a complete stdout line is received.
//
// stderr_callback:
//   Called whenever stderr data is received.
//
// Callbacks may be invoked from native reader threads.
void ncm_node_set_callbacks(
    ncm_node_output_callback stdout_callback,
    ncm_node_error_callback stderr_callback
);


// Start embedded Node.
//
// argv follows the normal C argv convention:
//
//   argv[0] = "node"
//   argv[1] = "/path/to/bridge.js"
//   ...
//
// ncm_node_start() itself returns immediately after creating the
// Node thread.
//
// Return:
//    0  success
//   -1  already started / invalid arguments / pthread failure
int ncm_node_start(
    int argc,
    const char* const* argv
);


// Write bytes to Node's stdin.
//
// This function does NOT append '\n'.
//
// Return:
//    0  success
//   -1  failure
int ncm_node_write_stdin(
    const unsigned char* data,
    size_t length
);


// Request shutdown.
//
// The current embedded Node design does not expose a reliable clean
// shutdown mechanism.
//
// Therefore this is currently a no-op.
void ncm_node_request_shutdown();


// Query whether node::Start() is currently running.
//
// Return:
//   1 running
//   0 not running
int ncm_node_is_running();


// Free memory passed to an output callback.
//
// Dart MUST call this after copying callback data.
void ncm_node_free_buffer(
    const unsigned char* data
);

} // extern "C"


// ===========================================================================
// Global state
// ===========================================================================

static std::atomic<bool> g_started{false};

static ncm_node_output_callback g_stdout_callback = nullptr;
static ncm_node_error_callback g_stderr_callback = nullptr;


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
// Callback helper
// ===========================================================================

static void emit_callback(
    ncm_node_output_callback callback,
    const char* data,
    size_t length
) {
    if (callback == nullptr || data == nullptr || length == 0) {
        return;
    }

    //
    // NativeCallable.listener() is asynchronous.
    //
    // Therefore the memory cannot point into a temporary std::string or
    // stack buffer.
    //
    // Allocate stable memory and let Dart explicitly free it.
    //
    unsigned char* copy =
        static_cast<unsigned char*>(std::malloc(length));

    if (copy == nullptr) {
        LOGE(
            "malloc(%zu) failed while emitting callback",
            length
        );

        return;
    }

    std::memcpy(copy, data, length);

    callback(copy, length);
}


// ===========================================================================
// stdout reader
// ===========================================================================

static void* stdout_reader_thread(void*) {
    char buffer[8192];

    std::string line_buffer;
    line_buffer.reserve(8192);

    while (true) {
        ssize_t n = read(
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
                line_buffer.find('\n', start);

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
                emit_callback(
                    g_stdout_callback,
                    line.data(),
                    line.size()
                );
            }

            start = eol + 1;
        }

        if (start != 0) {
            line_buffer.erase(0, start);
        }
    }

    // Flush the final unterminated line, if any.
    if (!line_buffer.empty()) {
        emit_callback(
            g_stdout_callback,
            line_buffer.data(),
            line_buffer.size()
        );
    }

    return nullptr;
}


// ===========================================================================
// stderr reader
// ===========================================================================

static void* stderr_reader_thread(void*) {
    char buffer[8192];

    while (true) {
        ssize_t n = read(
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

        emit_callback(
            g_stderr_callback,
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

    close(g_pipe_out[1]);
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

    close(g_pipe_err[1]);
    g_pipe_err[1] = -1;


    if (pthread_create(
            &g_thread_out,
            nullptr,
            stdout_reader_thread,
            nullptr
        ) != 0) {

        LOGE("failed to create stdout reader");

        return -1;
    }


    if (pthread_create(
            &g_thread_err,
            nullptr,
            stderr_reader_thread,
            nullptr
        ) != 0) {

        LOGE("failed to create stderr reader");

        return -1;
    }


    pthread_detach(g_thread_out);
    pthread_detach(g_thread_err);

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

    close(g_pipe_in[0]);
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


static void* node_thread_main(void* arg) {
    StartArgs* args =
        static_cast<StartArgs*>(arg);


    // -----------------------------------------------------------------------
    // Build contiguous argv storage.
    // -----------------------------------------------------------------------

    size_t total_size = 0;

    for (const std::string& value : args->argv) {
        total_size += value.size() + 1;
    }

    char* buffer =
        static_cast<char*>(
            std::calloc(total_size, 1)
        );

    if (buffer == nullptr) {
        LOGE("failed to allocate argv buffer");

        delete args;
        g_started = false;

        return nullptr;
    }


    std::vector<char*> argv;
    argv.reserve(args->argv.size());

    char* cursor = buffer;

    for (const std::string& value : args->argv) {
        const size_t size = value.size();

        std::memcpy(
            cursor,
            value.c_str(),
            size + 1
        );

        argv.push_back(cursor);

        cursor += size + 1;
    }


    // -----------------------------------------------------------------------
    // These must happen BEFORE node::Start().
    // -----------------------------------------------------------------------

    if (redirect_stdout_stderr() != 0) {
        LOGE("stdout/stderr redirection failed");

        std::free(buffer);
        delete args;

        g_started = false;

        return nullptr;
    }


    if (redirect_stdin() != 0) {
        LOGE("stdin redirection failed");

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

void ncm_node_set_callbacks(
    ncm_node_output_callback stdout_callback,
    ncm_node_error_callback stderr_callback
) {
    g_stdout_callback = stdout_callback;
    g_stderr_callback = stderr_callback;
}


int ncm_node_start(
    int argc,
    const char* const* argv
) {
    if (argc <= 0 || argv == nullptr) {
        LOGE("ncm_node_start: invalid arguments");

        return -1;
    }


    if (g_started.exchange(true)) {
        LOGW(
            "ncm_node_start: node is already running"
        );

        return -1;
    }


    StartArgs* args = new StartArgs();

    args->argc = argc;

    args->argv.reserve(
        static_cast<size_t>(argc)
    );


    for (int i = 0; i < argc; ++i) {
        if (argv[i] == nullptr) {
            delete args;

            g_started = false;

            LOGE(
                "ncm_node_start: argv[%d] is null",
                i
            );

            return -1;
        }

        args->argv.emplace_back(argv[i]);
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


    pthread_detach(thread);

    return 0;
}


int ncm_node_write_stdin(
    const unsigned char* data,
    size_t length
) {
    if (data == nullptr && length != 0) {
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
        ssize_t n =
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

        offset += static_cast<size_t>(n);
    }


    return 0;
}


void ncm_node_request_shutdown() {
    //
    // node::Start() currently has no clean shutdown API in this design.
    //
    LOGW(
        "shutdown requested, but embedded Node has no clean shutdown"
    );
}


int ncm_node_is_running() {
    return g_started.load()
        ? 1
        : 0;
}


void ncm_node_free_buffer(
    const unsigned char* data
) {
    std::free(
        const_cast<unsigned char*>(data)
    );
}

} // extern "C"