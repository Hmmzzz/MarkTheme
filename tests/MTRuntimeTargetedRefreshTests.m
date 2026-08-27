#import "MTRuntimeTargetedRefreshTests.h"

#import "MTRuntimeTargetedRefresh.h"

static NSUInteger MTRuntimeTargetedRefreshAssertionCount = 0;

static void MTRefreshAssert(BOOL condition, NSString *message) {
    MTRuntimeTargetedRefreshAssertionCount++;
    if (condition) return;
    fprintf(stderr, "FAIL: %s\n", message.UTF8String);
    exit(1);
}

static MTRuntimeRefreshTarget *MTTargetForRecipient(
    NSArray<MTRuntimeRefreshTarget *> *targets,
    id recipient) {
    for (MTRuntimeRefreshTarget *target in targets) {
        if (target.recipient == recipient) return target;
    }
    return nil;
}

NSUInteger MTRunRuntimeTargetedRefreshTests(void) {
    MTRuntimeTargetedRefreshAssertionCount = 0;
    MTRuntimeTargetedRefreshTracker *tracker =
        [[MTRuntimeTargetedRefreshTracker alloc] init];
    NSObject *cacheA = [[NSObject alloc] init];
    NSObject *cacheB = [[NSObject alloc] init];
    NSObject *iconA = [[NSObject alloc] init];
    NSObject *iconB = [[NSObject alloc] init];
    NSObject *iconC = [[NSObject alloc] init];
    [tracker recordRecipient:cacheA subject:iconA identifier:@"app.a"];
    [tracker recordRecipient:cacheA subject:iconA identifier:@"app.a"];
    [tracker recordRecipient:cacheA subject:iconB identifier:@"app.b"];
    [tracker recordRecipient:cacheB subject:iconC identifier:@"app.a"];

    MTRuntimeTargetedRefreshSnapshot *snapshot = tracker.snapshot;
    MTRefreshAssert([snapshot.identifiers isEqualToArray:@[@"app.a", @"app.b"]],
        @"Refresh identifiers must be unique and deterministic");
    MTRefreshAssert(snapshot.subjectCount == 3,
        @"Refresh tracking must deduplicate the same recipient/subject pair");

    NSArray<MTRuntimeRefreshTarget *> *allTargets =
        [snapshot targetsForIdentifiers:nil];
    MTRefreshAssert(allTargets.count == 2,
        @"A refresh snapshot must preserve each live recipient");
    MTRefreshAssert(MTTargetForRecipient(allTargets, cacheA).subjects.count == 2 &&
        MTTargetForRecipient(allTargets, cacheB).subjects.count == 1,
        @"A full refresh must group subjects by recipient");

    NSArray<MTRuntimeRefreshTarget *> *filteredTargets =
        [snapshot targetsForIdentifiers:[NSSet setWithObject:@"app.a"]];
    MTRefreshAssert(filteredTargets.count == 2,
        @"An identifier can target more than one cache recipient");
    MTRefreshAssert(MTTargetForRecipient(filteredTargets, cacheA).subjects.count == 1 &&
        MTTargetForRecipient(filteredTargets, cacheA).subjects.firstObject == iconA &&
        MTTargetForRecipient(filteredTargets, cacheB).subjects.firstObject == iconC,
        @"A filtered refresh must exclude unrelated subjects");
    MTRefreshAssert([snapshot targetsForIdentifiers:[NSSet setWithObject:@"missing"]].count == 0,
        @"An unknown identifier must produce no private refresh target");

    __weak NSObject *weakCache = nil;
    __weak NSObject *weakIcon = nil;
    @autoreleasepool {
        NSObject *temporaryCache = [[NSObject alloc] init];
        NSObject *temporaryIcon = [[NSObject alloc] init];
        weakCache = temporaryCache;
        weakIcon = temporaryIcon;
        [tracker recordRecipient:temporaryCache
                         subject:temporaryIcon
                      identifier:@"temporary"];
    }
    MTRefreshAssert(weakCache == nil && weakIcon == nil,
        @"The long-lived refresh tracker must not extend private object lifetimes");
    MTRefreshAssert(![tracker.snapshot.identifiers containsObject:@"temporary"],
        @"A new snapshot must compact dead weak refresh entries");

    __weak NSObject *snapshotRetainedIcon = nil;
    MTRuntimeTargetedRefreshSnapshot *retainingSnapshot = nil;
    @autoreleasepool {
        NSObject *temporaryIcon = [[NSObject alloc] init];
        snapshotRetainedIcon = temporaryIcon;
        [tracker recordRecipient:cacheA
                         subject:temporaryIcon
                      identifier:@"snapshot"];
        retainingSnapshot = tracker.snapshot;
    }
    MTRefreshAssert(snapshotRetainedIcon != nil &&
        [retainingSnapshot.identifiers containsObject:@"snapshot"],
        @"An in-flight snapshot must retain exactly the objects it will invoke");
    retainingSnapshot = nil;
    MTRefreshAssert(snapshotRetainedIcon == nil,
        @"Completing a refresh snapshot must release its private subjects");

    [tracker recordRecipient:nil subject:iconA identifier:@"ignored"];
    [tracker recordRecipient:cacheA subject:nil identifier:@"ignored"];
    [tracker recordRecipient:cacheA subject:iconA identifier:@""];
    MTRefreshAssert(![tracker.snapshot.identifiers containsObject:@"ignored"],
        @"Incomplete refresh identities must be ignored");

    __weak MTRuntimeTargetedRefreshTracker *weakTracker = nil;
    NSObject *longLivedSubject = [[NSObject alloc] init];
    @autoreleasepool {
        MTRuntimeTargetedRefreshTracker *temporaryTracker =
            [[MTRuntimeTargetedRefreshTracker alloc] init];
        weakTracker = temporaryTracker;
        [temporaryTracker recordRecipient:cacheA
                                  subject:longLivedSubject
                               identifier:@"association-lifetime"];
        temporaryTracker = nil;
        MTRefreshAssert(weakTracker == nil,
            @"A subject registration token must not retain its tracker");
    }

    __block __weak NSObject *lateBoundKernel = nil;
    __block NSUInteger reloadDispatches = 0;
    void (^reloadHandler)(void) = ^{
        NSObject *strongKernel = lateBoundKernel;
        if (strongKernel != nil) reloadDispatches++;
    };
    NSObject *kernel = [[NSObject alloc] init];
    lateBoundKernel = kernel;
    reloadHandler();
    MTRefreshAssert(reloadDispatches == 1,
        @"A late-bound weak Kernel reference must reach the refresh callback");
    kernel = nil;
    reloadHandler();
    MTRefreshAssert(reloadDispatches == 1,
        @"The refresh callback must not retain its owning Runtime Kernel");
    return MTRuntimeTargetedRefreshAssertionCount;
}
