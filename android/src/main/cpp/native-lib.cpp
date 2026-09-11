// JNI bridge to libnode.so (nodejs-mobile v18.20.4) for ncm_api_enhanced.
//
// Model: libnode embeds node into the host process via `node::Start`. We:
//   1. Copy `assets/ncm_bridge/` (bridge.js + node_modules) to filesDir.
//   2. Redirect stdout/stderr to pipes + spawn reader threads.
//   3. Call `node::Start(["node", filesDir + "/ncm_bridge/bridge.js"])` on a
//      dedicated pthread (it never returns).
//   4. The reader threads parse NDJSON from stdout line-by-line and call
//      back into Kotlin via `node_stdout_callback(...)`, which the Flutter
//      plugin pushes onto the EventChannel.
//
// `node::Start` is blocking; do not call it on the Android main thread or
// any UI thread. The Kotlin plugin does this on a fresh background thread.
//
// Symbol layout note: `node::Start` lives in libnode's compiled namespace.
// We expose it via this wrapper library (libncm_node_bridge.so) which
// links against libnode.so via CMake's IMPORTED target.

#include <jni.h>
#include <android/log.h>
#include <cstdlib>
#include <cstring>
#include <pthread.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <cerrno>
#include <string>
#include <vector>
#include <atomic>

// node.h ships with the libnode headers (see android/libnode/include/node/).
#include "node.h"

#define ADBTAG "NcmNodeBridge"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  ADBTAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN,  ADBTAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, ADBTAG, __VA_ARGS__)

// ---------------------------------------------------------------------------
// JavaVM + callbacks (set from JNI_OnLoad by Kotlin via registerCallbacks()).
// ---------------------------------------------------------------------------

static JavaVM* g_jvm = nullptr;
static jobject g_kotlin_plugin = nullptr; // global ref
static jmethodID g_on_stdout_line = nullptr;
static jmethodID g_on_stderr_line = nullptr;
static std::atomic<bool> g_started{false};

extern "C" JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM* vm, void* /*reserved*/) {
    g_jvm = vm;
    return JNI_VERSION_1_6;
}

// Called from Kotlin after System.loadLibrary + before startNode(). Wires up
// the stdout callback so the plugin can forward NDJSON lines to Flutter.
extern "C" JNIEXPORT void JNICALL
Java_com_example_ncm_1api_1enhanced_NcmNodeBridge_registerCallbacks(
        JNIEnv* env, jobject /*thiz*/, jobject plugin_instance) {

    if (g_kotlin_plugin != nullptr) {
        env->DeleteGlobalRef(g_kotlin_plugin);
    }
    g_kotlin_plugin = env->NewGlobalRef(plugin_instance);

    jclass cls = env->GetObjectClass(plugin_instance);
    g_on_stdout_line = env->GetMethodID(cls, "onStdoutLine", "(Ljava/lang/String;)V");
    g_on_stderr_line = env->GetMethodID(cls, "onStderrLine", "(Ljava/lang/String;)V");
    if (g_on_stdout_line == nullptr || g_on_stderr_line == nullptr) {
        LOGE("registerCallbacks: method lookup failed (stdout=%p stderr=%p)",
             g_on_stdout_line, g_on_stderr_line);
    }
}

// ---------------------------------------------------------------------------
// stdout/stderr → pipe → reader threads → Kotlin callback
// ---------------------------------------------------------------------------

static int g_pipe_out[2];
static int g_pipe_err[2];
static int g_pipe_in[2];        // dart → node stdin
static pthread_t g_thread_out;
static pthread_t g_thread_err;

static void emit_to_kotlin(jmethodID mid, const char* s, size_t n) {
    if (g_jvm == nullptr || g_kotlin_plugin == nullptr || mid == nullptr) return;
    JNIEnv* env = nullptr;
    // The reader threads are detached — we must attach to call Java.
    if (g_jvm->AttachCurrentThread(&env, nullptr) != JNI_OK) return;
    // Strip trailing \n (callback expects one logical line).
    while (n > 0 && (s[n - 1] == '\n' || s[n - 1] == '\r')) --n;
    jstring js = env->NewStringUTF(s);
    env->CallVoidMethod(g_kotlin_plugin, mid, js);
    env->DeleteLocalRef(js);
}

static void* thread_out_reader(void*) {
    char buf[8192];
    std::string line_buf;
    while (true) {
        ssize_t n = read(g_pipe_out[0], buf, sizeof(buf));
        if (n <= 0) break;
        // Naive line splitter. NDJSON is line-oriented so this is sufficient.
        line_buf.append(buf, n);
        size_t start = 0;
        while (true) {
            size_t eol = line_buf.find('\n', start);
            if (eol == std::string::npos) break;
            std::string line = line_buf.substr(start, eol - start);
            emit_to_kotlin(g_on_stdout_line, line.c_str(), line.size());
            start = eol + 1;
        }
        line_buf.erase(0, start);
    }
    return nullptr;
}

static void* thread_err_reader(void*) {
    char buf[8192];
    while (true) {
        ssize_t n = read(g_pipe_err[0], buf, sizeof(buf));
        if (n <= 0) break;
        emit_to_kotlin(g_on_stderr_line, buf, static_cast<size_t>(n));
    }
    return nullptr;
}

static int redirect_stdout_stderr() {
    setvbuf(stdout, 0, _IONBF, 0);
    if (pipe(g_pipe_out) != 0) { LOGE("pipe stdout: %s", strerror(errno)); return -1; }
    if (dup2(g_pipe_out[1], STDOUT_FILENO) < 0) { LOGE("dup2 stdout: %s", strerror(errno)); return -1; }
    close(g_pipe_out[1]);

    setvbuf(stderr, 0, _IONBF, 0);
    if (pipe(g_pipe_err) != 0) { LOGE("pipe stderr: %s", strerror(errno)); return -1; }
    if (dup2(g_pipe_err[1], STDERR_FILENO) < 0) { LOGE("dup2 stderr: %s", strerror(errno)); return -1; }
    close(g_pipe_err[1]);

    if (pthread_create(&g_thread_out, nullptr, thread_out_reader, nullptr) != 0) return -1;
    if (pthread_create(&g_thread_err, nullptr, thread_err_reader, nullptr) != 0) return -1;
    pthread_detach(g_thread_out);
    pthread_detach(g_thread_err);
    return 0;
}

// Replace stdin with a pipe so Kotlin (via writeToNodeStdin) can inject
// NDJSON lines. Must be called BEFORE node::Start so node inherits the
// redirected fd as its stdin.
static int redirect_stdin() {
    if (pipe(g_pipe_in) != 0) { LOGE("pipe stdin: %s", strerror(errno)); return -1; }
    if (dup2(g_pipe_in[0], STDIN_FILENO) < 0) { LOGE("dup2 stdin: %s", strerror(errno)); return -1; }
    close(g_pipe_in[0]);
    return 0;
}

// ---------------------------------------------------------------------------
// node::Start — the actual embedded node runtime.
// ---------------------------------------------------------------------------

struct StartArgs {
    std::vector<std::string> args;
};

static void* node_thread_main(void* arg) {
    StartArgs* a = static_cast<StartArgs*>(arg);

    // Build argv in contiguous memory (libuv requirement).
    size_t total = 0;
    for (const auto& s : a->args) total += s.size() + 1;
    char* buf = static_cast<char*>(calloc(total, 1));
    std::vector<char*> argv;
    argv.reserve(a->args.size());
    char* cursor = buf;
    for (const auto& s : a->args) {
        std::memcpy(cursor, s.c_str(), s.size() + 1);
        argv.push_back(cursor);
        cursor += s.size() + 1;
    }

    if (redirect_stdout_stderr() != 0) {
        LOGE("redirect_stdout_stderr failed");
        free(buf);
        g_started = false;
        return nullptr;
    }
    if (redirect_stdin() != 0) {
        LOGE("redirect_stdin failed");
        free(buf);
        g_started = false;
        return nullptr;
    }

    LOGI("node::Start argc=%zu", argv.size());
    // node::Start is blocking; the only way out is for node to exit.
    int rc = node::Start(static_cast<int>(argv.size()), argv.data());
    LOGI("node::Start returned %d", rc);

    free(buf);
    g_started = false;
    return nullptr;
}

extern "C" JNIEXPORT jint JNICALL
Java_com_example_ncm_1api_1enhanced_NcmNodeBridge_startNode(
        JNIEnv* env, jobject /*thiz*/, jobjectArray arguments) {

    if (g_started.load()) {
        LOGW("startNode: already started");
        return -1;
    }
    g_started = true;

    jsize n = env->GetArrayLength(arguments);
    StartArgs* a = new StartArgs();
    a->args.reserve(n);
    for (jsize i = 0; i < n; i++) {
        jstring s = (jstring)env->GetObjectArrayElement(arguments, i);
        const char* c = env->GetStringUTFChars(s, nullptr);
        a->args.emplace_back(c);
        env->ReleaseStringUTFChars(s, c);
        env->DeleteLocalRef(s);
    }

    pthread_t t;
    if (pthread_create(&t, nullptr, node_thread_main, a) != 0) {
        delete a;
        g_started = false;
        return -1;
    }
    pthread_detach(t);
    return 0;
}

// Best-effort shutdown — there is no clean exit for node::Start. The only
// way to stop the runtime is to terminate the process. We expose this as a
// hint for the Kotlin side (it logs + emits a fatal event); production code
// should treat node as long-running.
extern "C" JNIEXPORT void JNICALL
Java_com_example_ncm_1api_1enhanced_NcmNodeBridge_requestShutdown(
        JNIEnv* /*env*/, jobject /*thiz*/) {
    LOGW("requestShutdown: no clean shutdown for embedded node; " \
         "caller should tear down the Activity instead");
}

// Write a single NDJSON line to node's stdin pipe. Safe to call from any
// thread; the write end of the pipe is process-shared (we never forked).
extern "C" JNIEXPORT void JNICALL
Java_com_example_ncm_1api_1enhanced_NcmNodeBridge_writeToNodeStdin(
        JNIEnv* env, jobject /*thiz*/, jstring line) {
    if (g_pipe_in[1] < 0) {
        LOGE("writeToNodeStdin: stdin pipe not initialized");
        return;
    }
    const char* s = env->GetStringUTFChars(line, nullptr);
    size_t len = std::strlen(s);
    size_t off = 0;
    while (off < len) {
        ssize_t n = write(g_pipe_in[1], s + off, len - off);
        if (n < 0) {
            if (errno == EINTR) continue;
            LOGE("writeToNodeStdin: %s", strerror(errno));
            break;
        }
        off += static_cast<size_t>(n);
    }
    env->ReleaseStringUTFChars(line, s);
}