#import "MTRuntimeKernelTests.h"

#import <dispatch/dispatch.h>
#import <unistd.h>

#import "MTGenerationReader.h"
#import "MTRuntimeInvalidation.h"
#import "MTRuntimeKernel.h"
#import "MTRuntimeSnapshot.h"
#import "MTRuntimeSnapshotLoader.h"
#import "MTRuntimeState.h"

static NSUInteger MTRuntimeKernelAssertionCount = 0;

static void MTRuntimeKernelAssert(BOOL condition, NSString *message) {
    MTRuntimeKernelAssertionCount++;
    if (condition) return;
    fprintf(stderr, "FAIL: %s\n", message.UTF8String);
    exit(1);
}

static BOOL MTRuntimeKernelWait(dispatch_semaphore_t semaphore) {
    return dispatch_semaphore_wait(semaphore,
        dispatch_time(DISPATCH_TIME_NOW, 5LL * NSEC_PER_SEC)) == 0;
}

@interface MTTestRuntimeGeneration : NSObject
@property(nonatomic, copy) NSString *generationIdentifier;
@property(nonatomic, strong) id resource;
@end

@implementation MTTestRuntimeGeneration
- (MTGenerationResource *)resourceForCanonicalResourceKey:(NSString *)key
                                                     error:(NSError **)error {
    (void)key;
    (void)error;
    return self.resource;
}
@end

@interface MTRuntimeSnapshotLoader (MTRuntimeKernelTestOverrides)
- (nullable MTRuntimeState *)readStateWithError:(NSError **)error;
- (nullable MTGeneration *)readGenerationWithIdentifier:
    (NSString *)identifier error:(NSError **)error;
@end

@interface MTTestSnapshotLoader : MTRuntimeSnapshotLoader
@property(nonatomic, copy) NSArray<MTRuntimeState *> *states;
@property(nonatomic, strong) MTGeneration *generation;
@property(nonatomic, assign) NSUInteger stateReadCount;
@property(nonatomic, assign) NSUInteger generationReadCount;
@end

@implementation MTTestSnapshotLoader
- (MTRuntimeState *)readStateWithError:(NSError **)error {
    (void)error;
    NSUInteger index = MIN(self.stateReadCount, self.states.count - 1);
    self.stateReadCount++;
    return self.states[index];
}
- (MTGeneration *)readGenerationWithIdentifier:(NSString *)identifier
                                           error:(NSError **)error {
    (void)identifier;
    (void)error;
    self.generationReadCount++;
    return self.generation;
}
@end

@interface MTTestRuntimeLoader : NSObject <MTRuntimeSnapshotLoading>
@property(nonatomic, copy) NSArray *results;
@property(nonatomic, strong) NSLock *lock;
@property(nonatomic, assign) NSUInteger callCount;
@property(nonatomic, assign) NSUInteger concurrentCalls;
@property(nonatomic, assign) NSUInteger maximumConcurrentCalls;
@property(nonatomic, assign) BOOL blocksFirstCall;
@property(nonatomic, strong) dispatch_semaphore_t firstCallStarted;
@property(nonatomic, strong) dispatch_semaphore_t releaseFirstCall;
@end

@implementation MTTestRuntimeLoader
- (instancetype)init {
    self = [super init];
    if (self == nil) return nil;
    _lock = [[NSLock alloc] init];
    _firstCallStarted = dispatch_semaphore_create(0);
    _releaseFirstCall = dispatch_semaphore_create(0);
    return self;
}
- (MTRuntimeSnapshot *)loadSnapshotWithError:(NSError **)error {
    [self.lock lock];
    NSUInteger callIndex = self.callCount++;
    self.concurrentCalls++;
    self.maximumConcurrentCalls = MAX(
        self.maximumConcurrentCalls, self.concurrentCalls);
    BOOL shouldBlock = self.blocksFirstCall && callIndex == 0;
    id result = self.results[MIN(callIndex, self.results.count - 1)];
    [self.lock unlock];
    if (shouldBlock) {
        dispatch_semaphore_signal(self.firstCallStarted);
        dispatch_semaphore_wait(self.releaseFirstCall,
            dispatch_time(DISPATCH_TIME_NOW, 5LL * NSEC_PER_SEC));
    }
    [self.lock lock];
    self.concurrentCalls--;
    [self.lock unlock];
    if ([result isKindOfClass:NSError.class]) {
        if (error != NULL) *error = result;
        return nil;
    }
    return result;
}
@end

static MTRuntimeState *MTTestRuntimeState(
    uint64_t sequence,
    BOOL enabled,
    NSString *active,
    NSString *previous) {
    NSError *error = nil;
    MTRuntimeState *state = [[MTRuntimeState alloc]
        initWithSequence:sequence
        runtimeEnabled:enabled
        activeGenerationIdentifier:active
        previousGenerationIdentifier:previous
        error:&error];
    MTRuntimeKernelAssert(state != nil && error == nil,
        @"Runtime Kernel fixtures must use canonical state");
    return state;
}

NSUInteger MTRunRuntimeKernelTests(void) {
    MTRuntimeKernelAssertionCount = 0;
    NSString *identifierA =
        @"g1-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    NSString *identifierB =
        @"g1-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    NSObject *resource = [[NSObject alloc] init];
    MTTestRuntimeGeneration *generationA = [[MTTestRuntimeGeneration alloc] init];
    generationA.generationIdentifier = identifierA;
    generationA.resource = resource;
    MTTestRuntimeGeneration *generationB = [[MTTestRuntimeGeneration alloc] init];
    generationB.generationIdentifier = identifierB;
    generationB.resource = resource;
    MTRuntimeState *stateA = MTTestRuntimeState(1, YES, identifierA, nil);
    MTRuntimeState *stateB = MTTestRuntimeState(
        2, YES, identifierB, identifierA);
    MTRuntimeState *disabled = MTTestRuntimeState(
        3, NO, identifierB, identifierA);
    MTRuntimeSnapshot *snapshotA = [[MTRuntimeSnapshot alloc]
        initWithState:stateA generation:(MTGeneration *)generationA];
    MTRuntimeSnapshot *snapshotB = [[MTRuntimeSnapshot alloc]
        initWithState:stateB generation:(MTGeneration *)generationB];
    MTRuntimeSnapshot *disabledSnapshot = [[MTRuntimeSnapshot alloc]
        initWithState:disabled generation:nil];
    MTRuntimeKernelAssert(!MTRuntimeSnapshot.stockSnapshot.isReady &&
        MTRuntimeSnapshot.stockSnapshot.state.sequence == 0,
        @"A fresh Runtime snapshot must be canonical stock");

    MTTestRuntimeLoader *synchronousLoader =
        [[MTTestRuntimeLoader alloc] init];
    synchronousLoader.results = @[ snapshotA ];
    __block NSUInteger synchronousEvents = 0;
    MTRuntimeKernel *synchronousKernel = [[MTRuntimeKernel alloc]
        initWithLoader:synchronousLoader
        notificationName:nil
        reloadHandler:^(MTRuntimeReloadDisposition disposition,
                        MTRuntimeSnapshot *accepted,
                        NSError *reloadError) {
            if (disposition == MTRuntimeReloadDispositionReady &&
                accepted == snapshotA && reloadError == nil) {
                synchronousEvents++;
            }
        }];
    NSError *synchronousError = nil;
    MTRuntimeKernelAssert(
        [synchronousKernel startSynchronouslyWithError:&synchronousError] &&
        synchronousError == nil && synchronousKernel.isRunning &&
        synchronousKernel.currentSnapshot == snapshotA &&
        synchronousLoader.callCount == 1 && synchronousEvents == 1,
        @"Synchronous Kernel start must publish the first complete snapshot before returning");
    [synchronousKernel stop];

    NSURL *dummyRoot = [NSURL fileURLWithPath:@"/tmp/marktheme-runtime-kernel"];
    MTTestSnapshotLoader *stableLoader = [[MTTestSnapshotLoader alloc]
        initWithRuntimeRootURL:dummyRoot];
    stableLoader.states = @[ stateA, stateA ];
    stableLoader.generation = (MTGeneration *)generationA;
    NSError *error = nil;
    MTRuntimeSnapshot *stable = [stableLoader loadSnapshotWithError:&error];
    MTRuntimeKernelAssert(stable.isReady && error == nil &&
        stable.state == stateA && stable.generation == (id)generationA &&
        stableLoader.stateReadCount == 2 &&
        stableLoader.generationReadCount == 1,
        @"Loader must confirm enabled state after full Generation validation");

    MTTestSnapshotLoader *racingLoader = [[MTTestSnapshotLoader alloc]
        initWithRuntimeRootURL:dummyRoot];
    racingLoader.states = @[ stateA, stateB ];
    racingLoader.generation = (MTGeneration *)generationA;
    error = nil;
    MTRuntimeKernelAssert([racingLoader loadSnapshotWithError:&error] == nil &&
        [error.domain isEqualToString:MTRuntimeSnapshotLoaderErrorDomain] &&
        error.code == MTRuntimeSnapshotLoaderErrorStateChanged,
        @"Loader must reject a Generation validated across a state change");

    MTTestSnapshotLoader *disabledLoader = [[MTTestSnapshotLoader alloc]
        initWithRuntimeRootURL:dummyRoot];
    disabledLoader.states = @[ MTRuntimeState.initialState ];
    disabledLoader.generation = (MTGeneration *)generationA;
    error = nil;
    MTRuntimeSnapshot *stock = [disabledLoader loadSnapshotWithError:&error];
    MTRuntimeKernelAssert(stock != nil && !stock.isReady && error == nil &&
        disabledLoader.stateReadCount == 1 &&
        disabledLoader.generationReadCount == 0,
        @"Disabled state must reach stock without opening a Generation");

    NSError *syntheticError = [NSError errorWithDomain:@"test.runtime-load"
                                                   code:9
                                               userInfo:nil];
    MTTestRuntimeLoader *sequenceLoader = [[MTTestRuntimeLoader alloc] init];
    sequenceLoader.results = @[ snapshotA, syntheticError, disabledSnapshot ];
    dispatch_semaphore_t sequenceEvents = dispatch_semaphore_create(0);
    NSMutableArray<NSNumber *> *dispositions = [NSMutableArray array];
    MTRuntimeKernel *kernel = [[MTRuntimeKernel alloc]
        initWithLoader:sequenceLoader
        notificationName:nil
        reloadHandler:^(MTRuntimeReloadDisposition disposition,
                        MTRuntimeSnapshot *accepted,
                        NSError *reloadError) {
            (void)accepted;
            (void)reloadError;
            @synchronized (dispositions) {
                [dispositions addObject:@(disposition)];
            }
            dispatch_semaphore_signal(sequenceEvents);
        }];
    [kernel start];
    MTRuntimeKernelAssert(MTRuntimeKernelWait(sequenceEvents) &&
        kernel.currentSnapshot == snapshotA && kernel.currentSnapshot.isReady,
        @"Kernel start must asynchronously publish one ready snapshot");
    error = nil;
    MTRuntimeKernelAssert(
        [kernel resourceForCanonicalResourceKey:@"test-key" error:&error] ==
            (id)resource && error == nil,
        @"Kernel hot lookup must use the current immutable Generation");
    [kernel requestReload];
    MTRuntimeKernelAssert(MTRuntimeKernelWait(sequenceEvents) &&
        kernel.currentSnapshot == snapshotA,
        @"A failed reload must retain the exact last-known-good snapshot");
    [kernel requestReload];
    MTRuntimeKernelAssert(MTRuntimeKernelWait(sequenceEvents) &&
        kernel.currentSnapshot == disabledSnapshot &&
        !kernel.currentSnapshot.isReady,
        @"A valid disabled state must atomically return Runtime to stock");
    @synchronized (dispositions) {
        MTRuntimeKernelAssert([dispositions isEqualToArray:@[
            @(MTRuntimeReloadDispositionReady),
            @(MTRuntimeReloadDispositionRetainedAfterFailure),
            @(MTRuntimeReloadDispositionDisabled),
        ]], @"Kernel reload events must distinguish ready, retained and disabled");
    }
    [kernel stop];

    MTTestRuntimeLoader *burstLoader = [[MTTestRuntimeLoader alloc] init];
    burstLoader.results = @[ snapshotA, snapshotB ];
    burstLoader.blocksFirstCall = YES;
    dispatch_semaphore_t burstEvents = dispatch_semaphore_create(0);
    MTRuntimeKernel *burstKernel = [[MTRuntimeKernel alloc]
        initWithLoader:burstLoader
        notificationName:nil
        reloadHandler:^(MTRuntimeReloadDisposition disposition,
                        MTRuntimeSnapshot *accepted,
                        NSError *reloadError) {
            (void)disposition;
            (void)accepted;
            (void)reloadError;
            dispatch_semaphore_signal(burstEvents);
        }];
    [burstKernel start];
    MTRuntimeKernelAssert(MTRuntimeKernelWait(burstLoader.firstCallStarted),
        @"Coalescing fixture must block the first background validation");
    for (NSUInteger index = 0; index < 100; index++) {
        [burstKernel requestReload];
    }
    dispatch_semaphore_signal(burstLoader.releaseFirstCall);
    MTRuntimeKernelAssert(MTRuntimeKernelWait(burstEvents) &&
        MTRuntimeKernelWait(burstEvents) &&
        burstLoader.callCount == 2 &&
        burstLoader.maximumConcurrentCalls == 1 &&
        burstKernel.currentSnapshot == snapshotB,
        @"Reload bursts must coalesce into one serial follow-up validation");
    [burstKernel stop];
    NSUInteger callsAfterStop = burstLoader.callCount;
    [burstKernel requestReload];
    usleep(50000);
    MTRuntimeKernelAssert(burstLoader.callCount == callsAfterStop &&
        !burstKernel.isRunning,
        @"A stopped Runtime Kernel must ignore further invalidation requests");

    (void)MTRuntimePostInvalidation();
    MTRuntimeKernelAssert(
        [MTRuntimeInvalidationNotificationName isEqualToString:
            @"com.hmmzzz.marktheme.runtime-store-changed"],
        @"Runtime invalidation must use one stable best-effort Darwin name");
    NSString *expectedAcknowledgement = [NSString stringWithFormat:
        @"com.hmmzzz.marktheme.runtime-applied.b%llu.s42",
        (unsigned long long)MARKTHEME_RUNTIME_BUILD_NUMBER];
    MTRuntimeKernelAssert(
        [MTRuntimeAcknowledgementNotificationName(42)
            isEqualToString:expectedAcknowledgement] &&
        ![MTRuntimeAcknowledgementNotificationName(42) isEqualToString:
            MTRuntimeAcknowledgementNotificationName(43)],
        @"Apply acknowledgement must bind the exact Runtime build and state sequence");
    return MTRuntimeKernelAssertionCount;
}
