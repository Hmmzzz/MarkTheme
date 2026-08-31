#import "MTRuntimeKernel.h"

#import <CoreFoundation/CoreFoundation.h>
#import <dispatch/dispatch.h>

#import "MTGenerationReader.h"
#import "MTRuntimeSnapshot.h"

static void MTRuntimeKernelNotificationCallback(
    CFNotificationCenterRef center,
    void *observer,
    CFNotificationName name,
    const void *object,
    CFDictionaryRef userInfo) {
    (void)center;
    (void)name;
    (void)object;
    (void)userInfo;
    MTRuntimeKernel *kernel = (__bridge MTRuntimeKernel *)observer;
    [kernel requestReload];
}

@interface MTRuntimeKernel ()
@property(nonatomic, strong) id<MTRuntimeSnapshotLoading> loader;
@property(nonatomic, copy, nullable) NSString *notificationName;
@property(nonatomic, copy, nullable) MTRuntimeReloadHandler reloadHandler;
@property(atomic, strong, readwrite) MTRuntimeSnapshot *currentSnapshot;
@property(atomic, assign, readwrite, getter=isRunning) BOOL running;
@property(nonatomic, strong, nullable) dispatch_queue_t reloadQueue;
@property(nonatomic, strong, nullable) dispatch_source_t reloadSource;
- (void)performReload;
- (void)startSchedulingInitialReload:(BOOL)scheduleInitialReload;
- (BOOL)performReloadReturningError:(NSError **)outError;
@end

@implementation MTRuntimeKernel

- (instancetype)initWithSnapshot:(MTRuntimeSnapshot *)snapshot {
    NSParameterAssert(snapshot != nil);
    self = [super init];
    if (self == nil) return nil;
    _currentSnapshot = snapshot;
    return self;
}

- (instancetype)initWithLoader:(id<MTRuntimeSnapshotLoading>)loader
               notificationName:(NSString *)notificationName
                   reloadHandler:(MTRuntimeReloadHandler)reloadHandler {
    NSParameterAssert(loader != nil);
    self = [super init];
    if (self == nil) return nil;
    _loader = loader;
    _notificationName = [notificationName copy];
    _reloadHandler = [reloadHandler copy];
    _currentSnapshot = MTRuntimeSnapshot.stockSnapshot;
    return self;
}

- (void)startSchedulingInitialReload:(BOOL)scheduleInitialReload {
    @synchronized (self) {
        if (self.isRunning) return;
        dispatch_queue_t queue = dispatch_queue_create(
            "com.hmmzzz.marktheme.runtime-reload",
            dispatch_queue_attr_make_with_qos_class(
                DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
        dispatch_source_t source = dispatch_source_create(
            DISPATCH_SOURCE_TYPE_DATA_ADD, 0, 0, queue);
        __weak typeof(self) weakSelf = self;
        dispatch_source_set_event_handler(source, ^{
            [weakSelf performReload];
        });
        self.reloadQueue = queue;
        self.reloadSource = source;
        self.running = YES;
        if (self.notificationName.length > 0) {
            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                (__bridge void *)self,
                MTRuntimeKernelNotificationCallback,
                (__bridge CFStringRef)self.notificationName,
                NULL,
                CFNotificationSuspensionBehaviorDeliverImmediately);
        }
        dispatch_resume(source);
        if (scheduleInitialReload) dispatch_source_merge_data(source, 1);
    }
}

- (void)start {
    [self startSchedulingInitialReload:YES];
}

- (BOOL)startSynchronouslyWithError:(NSError **)error {
    if (error != NULL) *error = nil;
    [self startSchedulingInitialReload:NO];
    __block BOOL loaded = NO;
    __block NSError *reloadError = nil;
    dispatch_sync(self.reloadQueue, ^{
        loaded = [self performReloadReturningError:&reloadError];
    });
    if (error != NULL) *error = reloadError;
    return loaded;
}

- (void)requestReload {
    @synchronized (self) {
        if (!self.isRunning) return;
        if (self.reloadSource != nil) {
            dispatch_source_merge_data(self.reloadSource, 1);
        }
    }
}

- (void)stop {
    dispatch_source_t source = nil;
    @synchronized (self) {
        if (!self.isRunning) return;
        self.running = NO;
        if (self.notificationName.length > 0) {
            CFNotificationCenterRemoveObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                (__bridge void *)self,
                (__bridge CFStringRef)self.notificationName,
                NULL);
        }
        source = self.reloadSource;
        self.reloadSource = nil;
        self.reloadQueue = nil;
    }
    if (source != nil) dispatch_source_cancel(source);
}

- (BOOL)performReloadReturningError:(NSError **)outError {
    NSError *error = nil;
    MTRuntimeSnapshot *candidate = [self.loader loadSnapshotWithError:&error];
    MTRuntimeSnapshot *accepted = nil;
    MTRuntimeReloadDisposition disposition =
        MTRuntimeReloadDispositionRetainedAfterFailure;
    MTRuntimeReloadHandler handler = nil;
    @synchronized (self) {
        if (!self.isRunning) return NO;
        if (candidate != nil) {
            self.currentSnapshot = candidate;
            disposition = candidate.isReady
                ? MTRuntimeReloadDispositionReady
                : MTRuntimeReloadDispositionDisabled;
        }
        accepted = self.currentSnapshot;
        handler = self.reloadHandler;
    }
    if (handler != nil) handler(disposition, accepted, error);
    if (outError != NULL) *outError = error;
    return candidate != nil;
}

- (void)performReload {
    [self performReloadReturningError:NULL];
}

- (MTGenerationResource *)resourceForCanonicalResourceKey:
    (NSString *)canonicalResourceKey
                                                      error:(NSError **)error {
    MTRuntimeSnapshot *snapshot = self.currentSnapshot;
    return [snapshot.generation
        resourceForCanonicalResourceKey:canonicalResourceKey
        error:error];
}

- (void)dealloc {
    [self stop];
}

@end
