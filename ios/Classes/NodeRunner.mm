// NodeRunner.mm — Objective-C++ wrapper that loads nodejs-mobile v18.20.4
// (NodeMobile.framework) and runs our bridge.js as the entry point.
//
// Pattern follows the official nodejs-mobile iOS sample:
//   1. Background NSThread with stack size 2 MB.
//   2. Build argv in contiguous memory (libuv requirement).
//   3. Redirect stdout/stderr to a pipe, spawn reader threads, then call
//      node_start().
//
// The reader threads pump data into the NodeRunnerDelegate, which the
// Flutter plugin uses to push events onto the EventChannel.

#import "NodeRunner.h"
#import <NodeMobile/NodeMobile.h>
#import <Foundation/Foundation.h>
#import <pthread.h>
#import <unistd.h>

// Module-level state. Node is single-instance; this is fine.
static __weak id<NodeRunnerDelegate> g_delegate;
static BOOL g_started = NO;
static int g_pipe_out[2];
static int g_pipe_err[2];
static int g_pipe_in[2];
static pthread_t g_thread_out;
static pthread_t g_thread_err;

static void* stdout_reader_main(void* /*arg*/) {
    char buf[8192];
    while (true) {
        ssize_t n = read(g_pipe_out[0], buf, sizeof(buf));
        if (n <= 0) break;
        id<NodeRunnerDelegate> d = g_delegate;
        if (d) {
            NSData* data = [NSData dataWithBytes:buf length:(NSUInteger)n];
            [d nodeRunner:[NodeRunner class] didProduceStdout:data];
        }
    }
    return NULL;
}

static void* stderr_reader_main(void* /*arg*/) {
    char buf[8192];
    while (true) {
        ssize_t n = read(g_pipe_err[0], buf, sizeof(buf));
        if (n <= 0) break;
        id<NodeRunnerDelegate> d = g_delegate;
        if (d) {
            NSData* data = [NSData dataWithBytes:buf length:(NSUInteger)n];
            [d nodeRunner:[NodeRunner class] didProduceStderr:data];
        }
    }
    return NULL;
}

@implementation NodeRunner

+ (void)setDelegate:(id<NodeRunnerDelegate>)delegate {
    g_delegate = delegate;
}

+ (BOOL)isStarted {
    return g_started;
}

+ (void)redirectStdout {
    setvbuf(stdout, 0, _IONBF, 0);
    pipe(g_pipe_out);
    dup2(g_pipe_out[1], STDOUT_FILENO);
    close(g_pipe_out[1]);

    setvbuf(stderr, 0, _IONBF, 0);
    pipe(g_pipe_err);
    dup2(g_pipe_err[1], STDERR_FILENO);
    close(g_pipe_err[1]);

    pthread_create(&g_thread_out, NULL, stdout_reader_main, NULL);
    pthread_detach(g_thread_out);
    pthread_create(&g_thread_err, NULL, stderr_reader_main, NULL);
    pthread_detach(g_thread_err);
}

+ (void)redirectStdin {
    pipe(g_pipe_in);
    dup2(g_pipe_in[0], STDIN_FILENO);
    close(g_pipe_in[0]);
}

+ (void)writeToStdin:(NSString*)line {
    if (g_pipe_in[1] < 0) return;
    NSData* data = [line dataUsingEncoding:NSUTF8StringEncoding];
    const char* bytes = (const char*)data.bytes;
    size_t remaining = data.length;
    while (remaining > 0) {
        ssize_t n = write(g_pipe_in[1], bytes, remaining);
        if (n < 0) break;
        bytes += n;
        remaining -= (size_t)n;
    }
}

+ (void)startEngineWithArguments:(NSArray<NSString*>*)arguments {
    if (g_started) {
        NSLog(@"[NcmNodeBridge] already started");
        return;
    }
    g_started = YES;

    // 1. stdin pipe FIRST (before node_start) so node inherits it.
    [self redirectStdin];

    // 2. stdout/stderr pipes + reader threads.
    [self redirectStdout];

    // 3. Build argv in contiguous memory (libuv requirement).
    int argc = (int)arguments.count;
    size_t c_arguments_size = 0;
    for (NSString* arg in arguments) {
        c_arguments_size += strlen([arg UTF8String]) + 1;
    }
    char* args_buffer = (char*)calloc(c_arguments_size, sizeof(char));
    char* argv[argc];
    char* cursor = args_buffer;
    int idx = 0;
    for (NSString* arg in arguments) {
        const char* cstr = [arg UTF8String];
        strncpy(cursor, cstr, strlen(cstr));
        argv[idx] = cursor;
        idx++;
        cursor += strlen(cursor) + 1;
    }

    // 4. node_start is blocking — call it directly on this (background)
    //    thread. It only returns when node exits.
    int rc = node_start(argc, argv);
    NSLog(@"[NcmNodeBridge] node_start returned %d", rc);
    free(args_buffer);
    g_started = NO;
}

@end