#ifndef NodeRunner_h
#define NodeRunner_h

#import <Foundation/Foundation.h>

@class NodeRunner;

/// Objective-C delegate that NodeRunner invokes on background threads when
/// new stdout/stderr data arrives. The Flutter plugin installs itself as the
/// delegate and forwards the data onto the main thread.
@protocol NodeRunnerDelegate <NSObject>
- (void)nodeRunner:(NodeRunner* _Nonnull)runner didProduceStdout:(NSData* _Nonnull)data;
- (void)nodeRunner:(NodeRunner* _Nonnull)runner didProduceStderr:(NSData* _Nonnull)data;
@end

@interface NodeRunner : NSObject

/// Set the delegate. Only one delegate at a time; set this before calling
/// startEngineWithArguments:.
+ (void)setDelegate:(id<NodeRunnerDelegate> _Nullable)delegate;
+ (BOOL)isStarted;

/// Replace stdin with a pipe so writeToStdin: can inject NDJSON lines.
/// MUST be called before startEngineWithArguments:.
+ (void)redirectStdin;

/// Replace stdout/stderr with pipes and start reader threads that fire
/// the delegate callbacks. MUST be called before node_start.
+ (void)redirectStdout;

/// Write a UTF-8 NDJSON line into node's stdin. Safe from any thread.
+ (void)writeToStdin:(NSString* _Nonnull)line;

/// Run node_start on the calling (background) thread. Blocks until node
/// exits; the caller is responsible for thread setup (e.g. NSThread with
/// 2 MB stack size).
+ (void)startEngineWithArguments:(NSArray<NSString*>* _Nonnull)arguments;

@end

#endif /* NodeRunner_h */