#import <Foundation/Foundation.h>

#import "MTRuntimeSnapshotLoader.h"

@class MTGenerationResource;
@class MTRuntimeSnapshot;

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, MTRuntimeReloadDisposition) {
    MTRuntimeReloadDispositionReady = 1,
    MTRuntimeReloadDispositionDisabled = 2,
    MTRuntimeReloadDispositionRetainedAfterFailure = 3,
};

typedef void (^MTRuntimeReloadHandler)(
    MTRuntimeReloadDisposition disposition,
    MTRuntimeSnapshot *snapshot,
    NSError * _Nullable error);

// One process-local Runtime data-plane instance. It serializes complete
// validation off the caller thread and atomically exchanges one immutable
// State+Generation snapshot. It owns no private API or Hook implementation.
@interface MTRuntimeKernel : NSObject

@property(atomic, strong, readonly) MTRuntimeSnapshot *currentSnapshot;
@property(atomic, assign, readonly, getter=isRunning) BOOL running;

// Display Runtime processes use one immutable startup snapshot. Their product
// boundary is Respring, so this form allocates no listener or reload queue.
- (instancetype)initWithSnapshot:(MTRuntimeSnapshot *)snapshot
    NS_DESIGNATED_INITIALIZER;

// IconServices is long-lived across Apply and therefore retains the live
// notification-driven form.
- (instancetype)initWithLoader:(id<MTRuntimeSnapshotLoading>)loader
               notificationName:(nullable NSString *)notificationName
                   reloadHandler:
                       (nullable MTRuntimeReloadHandler)reloadHandler
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (void)start;
// IconServices uses this entry point before installing its image hook. The
// first complete snapshot is published before the method returns, so a hook
// can never observe the temporary stock bootstrap snapshot. Later Darwin
// invalidations remain serialized on the regular reload queue.
- (BOOL)startSynchronouslyWithError:(NSError **)error;
- (void)requestReload;
- (void)stop;

// A nil result, with or without an error, is always interpreted by the
// ProcessAdapter as stock fallback.
- (nullable MTGenerationResource *)resourceForCanonicalResourceKey:
    (NSString *)canonicalResourceKey
                                                               error:
    (NSError **)error;

@end

NS_ASSUME_NONNULL_END
