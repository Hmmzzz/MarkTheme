#import "MTRuntimeWeakObjectMapSnapshotTests.h"

#import "MTRuntimeWeakObjectMapSnapshot.h"

static NSUInteger MTRuntimeWeakObjectMapSnapshotAssertionCount = 0;

static void MTWeakMapSnapshotAssert(BOOL condition, NSString *message) {
    MTRuntimeWeakObjectMapSnapshotAssertionCount++;
    if (condition) return;
    fprintf(stderr, "FAIL: %s\n", message.UTF8String);
    exit(1);
}

NSUInteger MTRunRuntimeWeakObjectMapSnapshotTests(void) {
    MTRuntimeWeakObjectMapSnapshotAssertionCount = 0;
    NSMapTable *trackedObjects = [NSMapTable weakToWeakObjectsMapTable];
    NSObject *keyA = [[NSObject alloc] init];
    NSObject *keyB = [[NSObject alloc] init];
    NSObject *valueA = [[NSObject alloc] init];
    NSObject *valueB = [[NSObject alloc] init];
    [trackedObjects setObject:valueA forKey:keyA];
    [trackedObjects setObject:valueB forKey:keyB];

    NSArray<NSArray *> *snapshot =
        MTRuntimeWeakObjectMapSnapshot(trackedObjects);
    NSSet *snapshotKeys = [NSSet setWithArray:
        [snapshot valueForKeyPath:@"@unionOfArrays.self"]];
    MTWeakMapSnapshotAssert(snapshot.count == 2 &&
        [snapshotKeys containsObject:keyA] &&
        [snapshotKeys containsObject:keyB] &&
        [snapshotKeys containsObject:valueA] &&
        [snapshotKeys containsObject:valueB],
        @"A weak-map snapshot must retain every live key/value pair");

    BOOL refreshCompleted = YES;
    @try {
        for (NSArray *pair in snapshot) {
            [trackedObjects setObject:pair[1] forKey:pair[0]];
        }
    } @catch (__unused NSException *exception) {
        refreshCompleted = NO;
    }
    MTWeakMapSnapshotAssert(refreshCompleted && trackedObjects.count == 2,
        @"Refresh callbacks may update the source weak map after snapshotting");

    NSMapTable *retainingMap = [NSMapTable weakToWeakObjectsMapTable];
    __weak NSObject *retainedKey = nil;
    __weak NSObject *retainedValue = nil;
    NSArray *retainingSnapshot = nil;
    @autoreleasepool {
        NSObject *temporaryKey = [[NSObject alloc] init];
        NSObject *temporaryValue = [[NSObject alloc] init];
        retainedKey = temporaryKey;
        retainedValue = temporaryValue;
        [retainingMap setObject:temporaryValue forKey:temporaryKey];
        retainingSnapshot = MTRuntimeWeakObjectMapSnapshot(retainingMap);
    }
    MTWeakMapSnapshotAssert(retainingSnapshot.count == 1 &&
        retainedKey != nil && retainedValue != nil,
        @"An in-flight weak-map snapshot must retain the objects it invokes");

    NSMapTable *expiredMap = [NSMapTable weakToWeakObjectsMapTable];
    NSObject *liveKey = [[NSObject alloc] init];
    @autoreleasepool {
        NSObject *temporaryValue = [[NSObject alloc] init];
        [expiredMap setObject:temporaryValue forKey:liveKey];
    }
    MTWeakMapSnapshotAssert(
        MTRuntimeWeakObjectMapSnapshot(expiredMap).count == 0,
        @"A weak-map snapshot must omit entries whose value expired");
    MTWeakMapSnapshotAssert(
        MTRuntimeWeakObjectMapSnapshot(nil).count == 0,
        @"A missing weak map must produce an empty refresh snapshot");
    return MTRuntimeWeakObjectMapSnapshotAssertionCount;
}
