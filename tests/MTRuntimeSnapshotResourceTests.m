#import "MTRuntimeSnapshotResourceTests.h"

#import "MTResourceKey.h"
#import "MTFolderIconContract.h"
#import "MTIconMaskContract.h"
#import "MTIconShadowContract.h"
#import "MTStaticIconConfiguration.h"
#import "MTBadgeContract.h"
#import "MTDialerContract.h"
#import "MTDialerModule.h"
#import "MTRuntimeAsyncObjectCache.h"
#import "MTRuntimeObjectCache.h"
#import "MTRuntimeSnapshot.h"
#import "MTRuntimeState.h"
#import "adapters/MTShareSheetActivityIdentity.h"
#import "modules/MTSpringBoardDecorationSnapshotResolver.h"
#import "modules/MTBadgeSnapshotResolver.h"
#import "modules/MTDialerSnapshotResolver.h"
#import "modules/MTIconShadowSnapshotResolver.h"
#import "modules/MTStaticIconSnapshotResolver.h"
#import "modules/MTStatusBarSnapshotResolver.h"
#import "modules/MTUIResourceSnapshotResolver.h"

static NSUInteger MTRuntimeSnapshotResourceAssertionCount;

static void MTRuntimeSnapshotResourceAssert(BOOL condition,
                                             NSString *message) {
    MTRuntimeSnapshotResourceAssertionCount++;
    if (condition) return;
    fprintf(stderr, "FAIL: %s\n", message.UTF8String);
    exit(1);
}

@interface MTTestSnapshotResource : NSObject
@property(nonatomic, copy) NSString *identity;
@end
@implementation MTTestSnapshotResource
@end

@interface MTTestSnapshotGeneration : NSObject
@property(nonatomic, copy) NSString *generationIdentifier;
@property(nonatomic, copy) NSDictionary<NSString *, id> *resources;
@property(nonatomic, strong) NSMutableArray<NSString *> *requestedKeys;
@property(nonatomic, strong, nullable) NSError *lookupError;
@property(nonatomic, strong, nullable) id descriptor;
@end

@implementation MTTestSnapshotGeneration

- (instancetype)init {
    self = [super init];
    if (self == nil) return nil;
    _requestedKeys = [NSMutableArray array];
    return self;
}

- (id)resourceForCanonicalResourceKey:(NSString *)key
                                 error:(NSError **)error {
    [self.requestedKeys addObject:key];
    if (self.lookupError != nil) {
        if (error != NULL) *error = self.lookupError;
        return nil;
    }
    return self.resources[key];
}

@end

static NSString *MTTestStaticIconKeyForSubject(NSString *subject,
                                               NSString *trait,
                                               NSUInteger scale,
                                               NSString *variant) {
    NSError *error = nil;
    MTResourceKey *key = [[MTResourceKey alloc]
        initWithModuleID:@"icons.static"
                 surface:@"springboard.home"
                 subject:subject
                 variant:variant
                   scale:scale
                   trait:trait
                   error:&error];
    MTRuntimeSnapshotResourceAssert(key != nil && error == nil,
        @"Snapshot resource fixtures require canonical keys");
    return key.canonicalString;
}

static NSString *MTTestStaticIconKey(NSString *trait, NSUInteger scale) {
    return MTTestStaticIconKeyForSubject(
        @"com.example.target", trait, scale,
        MTStaticIconSourceVariantPrimary);
}

@interface MTTestSnapshotDescriptor : NSObject
@property(nonatomic, copy)
    NSDictionary<NSString *, NSDictionary<NSString *, id> *> *
        moduleConfigurations;
@end
@implementation MTTestSnapshotDescriptor
@end

static NSString *MTTestPreferencesIconKey(NSString *resourceName,
                                          NSString *trait,
                                          NSUInteger scale,
                                          NSString *variant) {
    NSError *error = nil;
    MTResourceKey *key = [[MTResourceKey alloc]
        initWithModuleID:@"ui.resources"
                 surface:@"preferences.icon"
                 subject:resourceName
                 variant:variant
                   scale:scale
                   trait:trait
                   error:&error];
    MTRuntimeSnapshotResourceAssert(key != nil && error == nil,
        @"Preferences resource fixtures require canonical keys");
    return key.canonicalString;
}

static NSString *MTTestShareActivityKey(NSString *activityName,
                                        NSString *trait,
                                        NSUInteger scale,
                                        NSString *variant) {
    NSError *error = nil;
    MTResourceKey *key = [[MTResourceKey alloc]
        initWithModuleID:@"ui.resources"
                 surface:@"share.activity"
                 subject:activityName
                 variant:variant
                   scale:scale
                   trait:trait
                   error:&error];
    MTRuntimeSnapshotResourceAssert(key != nil && error == nil,
        @"Share activity fixtures require canonical keys");
    return key.canonicalString;
}

static NSString *MTTestDecorationKey(NSString *moduleID,
                                     NSString *surface,
                                     NSString *subject,
                                     NSString *variant) {
    NSError *error = nil;
    MTResourceKey *key = [[MTResourceKey alloc]
        initWithModuleID:moduleID
                 surface:surface
                 subject:subject
                 variant:variant
                   scale:0
                   trait:@"any"
                   error:&error];
    MTRuntimeSnapshotResourceAssert(key != nil && error == nil,
        @"SpringBoard decoration fixtures require canonical keys");
    return key.canonicalString;
}

static NSString *MTTestBadgeKey(NSString *variant,
                                NSString *trait,
                                NSUInteger scale) {
    NSError *error = nil;
    MTResourceKey *key = [[MTResourceKey alloc]
        initWithModuleID:MTBadgesModuleID
                 surface:MTBadgeSurface
                 subject:MTBadgeGlobalSubject
                 variant:variant
                   scale:scale
                   trait:trait
                   error:&error];
    MTRuntimeSnapshotResourceAssert(key != nil && error == nil,
        @"Badge resource fixtures require canonical keys");
    return key.canonicalString;
}

static NSString *MTTestIconShadowKey(NSString *subject,
                                     NSString *variant,
                                     NSString *trait,
                                     NSUInteger scale) {
    NSError *error = nil;
    MTResourceKey *key = [[MTResourceKey alloc]
        initWithModuleID:MTIconShadowsModuleID
                 surface:MTIconShadowSurface
                 subject:subject
                 variant:variant
                   scale:scale
                   trait:trait
                   error:&error];
    MTRuntimeSnapshotResourceAssert(key != nil && error == nil,
        @"Icon Shadow resource fixtures require canonical keys");
    return key.canonicalString;
}

static NSString *MTTestDialerKey(NSString *subject,
                                 NSString *trait,
                                 NSUInteger scale) {
    NSError *error = nil;
    MTResourceKey *key = [[MTResourceKey alloc]
        initWithModuleID:MTDialerModuleID
                 surface:MTDialerSurface
                 subject:subject
                 variant:@"primary"
                   scale:scale
                   trait:trait
                   error:&error];
    MTRuntimeSnapshotResourceAssert(key != nil && error == nil,
        @"Dialer resource fixtures require canonical keys");
    return key.canonicalString;
}

static NSString *MTTestStatusBarKey(NSString *subject,
                                    NSString *trait,
                                    NSUInteger scale) {
    NSError *error = nil;
    MTResourceKey *key = [[MTResourceKey alloc]
        initWithModuleID:MTStatusBarModuleID
                 surface:MTStatusBarSurface
                 subject:subject
                 variant:@"primary"
                   scale:scale
                   trait:trait
                   error:&error];
    MTRuntimeSnapshotResourceAssert(key != nil && error == nil,
        @"Status Bar resource fixtures require canonical keys");
    return key.canonicalString;
}

@interface MTTestShareActivity : NSObject
@property(nonatomic, copy, nullable) id imageCreationBundleIdentifier;
@property(nonatomic, copy, nullable) id containingAppBundleIdentifier;
@end
@implementation MTTestShareActivity
- (id)_bundleIdentifierForActivityImageCreation {
    return self.imageCreationBundleIdentifier;
}
@end

@interface MTTestShareActivityConfiguration : NSObject
@property(nonatomic, copy) NSString *activityClassName;
@property(nonatomic, strong, nullable) id activity;
@end
@implementation MTTestShareActivityConfiguration
@end

@interface MTTestShareActivityProxy : NSObject
@property(nonatomic, strong) MTTestShareActivityConfiguration
    *activityConfiguration;
@end
@implementation MTTestShareActivityProxy
@end

static MTRuntimeSnapshot *MTTestReadySnapshot(
    MTTestSnapshotGeneration *generation) {
    NSError *error = nil;
    MTRuntimeState *state = [[MTRuntimeState alloc]
        initWithSequence:1
        runtimeEnabled:YES
        activeGenerationIdentifier:generation.generationIdentifier
        previousGenerationIdentifier:nil
        error:&error];
    MTRuntimeSnapshotResourceAssert(state != nil && error == nil,
        @"Snapshot resource fixtures require canonical state");
    return [[MTRuntimeSnapshot alloc]
        initWithState:state generation:(id)generation];
}

NSUInteger MTRunRuntimeSnapshotResourceTests(void) {
    MTRuntimeSnapshotResourceAssertionCount = 0;

    MTRuntimeObjectCache<NSObject *> *cache = [[MTRuntimeObjectCache alloc]
        initWithMaximumCount:2 maximumCost:5];
    NSObject *a = [[NSObject alloc] init];
    NSObject *b = [[NSObject alloc] init];
    NSObject *c = [[NSObject alloc] init];
    NSObject *replacementA = [[NSObject alloc] init];
    MTRuntimeSnapshotResourceAssert(
        [cache setObject:a forKey:@"a" cost:2] &&
        [cache setObject:b forKey:@"b" cost:2] &&
        cache.count == 2 && cache.totalCost == 4,
        @"Exact Runtime cache must admit objects within both budgets");
    MTRuntimeSnapshotResourceAssert([cache objectForKey:@"a"] == a,
        @"Runtime cache lookup must return the exact retained object");
    MTRuntimeSnapshotResourceAssert(
        [cache setObject:c forKey:@"c" cost:2] &&
        [cache objectForKey:@"b"] == nil &&
        [cache objectForKey:@"a"] == a &&
        [cache objectForKey:@"c"] == c &&
        cache.evictionCount == 1,
        @"Runtime cache must evict the exact least-recently-used entry");
    MTRuntimeSnapshotResourceAssert(
        [cache setObject:replacementA forKey:@"a" cost:4] &&
        [cache objectForKey:@"a"] == replacementA &&
        [cache objectForKey:@"c"] == nil &&
        cache.count == 1 && cache.totalCost == 4 &&
        cache.evictionCount == 2,
        @"Runtime cache replacement must enforce cost without double counting");
    MTRuntimeSnapshotResourceAssert(
        ![cache setObject:b forKey:@"oversized" cost:6] &&
        [cache objectForKey:@"oversized"] == nil &&
        cache.count == 1 && cache.totalCost == 4,
        @"An individually oversized Runtime object must not enter the cache");
    [cache removeAllObjects];
    MTRuntimeSnapshotResourceAssert(
        cache.count == 0 && cache.totalCost == 0 &&
        cache.evictionCount == 2,
        @"Runtime cache clear must release contents without rewriting history");

    MTRuntimeAsyncObjectCache<NSObject *> *asyncCache =
        [[MTRuntimeAsyncObjectCache alloc]
            initWithMaximumReadyCount:2
            maximumReadyCost:4
            maximumPendingCount:2
            maximumFailureCount:2];
    id readyObject = nil;
    uint64_t firstEpoch = 0;
    MTRuntimeAsyncCacheDisposition disposition = [asyncCache
        lookupObjectForGenerationIdentifier:@"generation-a"
        key:@"one" object:&readyObject epoch:&firstEpoch];
    MTRuntimeSnapshotResourceAssert(
        disposition == MTRuntimeAsyncCacheDispositionScheduled &&
        firstEpoch == 1 && readyObject == nil &&
        asyncCache.pendingCount == 1 &&
        [asyncCache claimPendingKey:@"one"
            generationIdentifier:@"generation-a" epoch:firstEpoch] &&
        ![asyncCache claimPendingKey:@"one"
            generationIdentifier:@"generation-a" epoch:firstEpoch] &&
        [asyncCache isPendingKey:@"one"
            generationIdentifier:@"generation-a" epoch:firstEpoch],
        @"Async cache must admit and single-owner one generation-scoped decode task");
    disposition = [asyncCache
        lookupObjectForGenerationIdentifier:@"generation-a"
        key:@"one" object:&readyObject epoch:NULL];
    MTRuntimeSnapshotResourceAssert(
        disposition == MTRuntimeAsyncCacheDispositionPending &&
        asyncCache.pendingCount == 1,
        @"Async cache must single-flight a repeated pending key");
    uint64_t secondEpoch = 0;
    MTRuntimeSnapshotResourceAssert([asyncCache
        lookupObjectForGenerationIdentifier:@"generation-a"
        key:@"two" object:NULL epoch:&secondEpoch] ==
            MTRuntimeAsyncCacheDispositionScheduled &&
        secondEpoch == firstEpoch &&
        [asyncCache
            lookupObjectForGenerationIdentifier:@"generation-a"
            key:@"three" object:NULL epoch:NULL] ==
                MTRuntimeAsyncCacheDispositionSaturated,
        @"Async cache must enforce its exact pending-task ceiling");
    MTRuntimeSnapshotResourceAssert([asyncCache
        completeKey:@"one" generationIdentifier:@"generation-a"
        epoch:firstEpoch object:a cost:2] &&
        [asyncCache waitForPendingKey:@"one"
            generationIdentifier:@"generation-a" epoch:firstEpoch] == a &&
        asyncCache.readyCount == 1 && asyncCache.pendingCount == 1,
        @"An accepted async completion must enter the bounded ready cache and wake its waiter");
    readyObject = nil;
    MTRuntimeSnapshotResourceAssert([asyncCache
        lookupObjectForGenerationIdentifier:@"generation-a"
        key:@"one" object:&readyObject epoch:NULL] ==
            MTRuntimeAsyncCacheDispositionReady && readyObject == a,
        @"Async cache ready lookup must return the exact decoded object");
    NSUInteger readyCountBeforePeek = asyncCache.readyCount;
    NSUInteger pendingCountBeforePeek = asyncCache.pendingCount;
    MTRuntimeSnapshotResourceAssert(
        [asyncCache readyObjectForGenerationIdentifier:@"generation-a"
                                                   key:@"one"] == a &&
        [asyncCache readyObjectForGenerationIdentifier:@"generation-a"
                                                   key:@"missing"] == nil &&
        [asyncCache readyObjectForGenerationIdentifier:@"generation-b"
                                                   key:@"one"] == nil &&
        [asyncCache.activeGenerationIdentifier
            isEqualToString:@"generation-a"] &&
        asyncCache.readyCount == readyCountBeforePeek &&
        asyncCache.pendingCount == pendingCountBeforePeek,
        @"A ready-only peek must not select a Generation or schedule work");
    MTRuntimeSnapshotResourceAssert([asyncCache
        completeKey:@"two" generationIdentifier:@"generation-a"
        epoch:secondEpoch object:nil cost:0] &&
        [asyncCache
            lookupObjectForGenerationIdentifier:@"generation-a"
            key:@"two" object:NULL epoch:NULL] ==
                MTRuntimeAsyncCacheDispositionFailed &&
        asyncCache.failureCount == 1,
        @"A failed decode must become one bounded generation-local failure");
    uint64_t staleEpoch = 0;
    dispatch_semaphore_t cancelledWaiter = dispatch_semaphore_create(0);
    __block id cancelledResult = [NSNull null];
    MTRuntimeSnapshotResourceAssert([asyncCache
        lookupObjectForGenerationIdentifier:@"generation-a"
        key:@"stale" object:NULL epoch:&staleEpoch] ==
            MTRuntimeAsyncCacheDispositionScheduled &&
        [asyncCache claimPendingKey:@"stale"
            generationIdentifier:@"generation-a" epoch:staleEpoch],
        @"The cancellation fixture must own one pending old-generation task");
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        cancelledResult = [asyncCache waitForPendingKey:@"stale"
            generationIdentifier:@"generation-a" epoch:staleEpoch];
        dispatch_semaphore_signal(cancelledWaiter);
    });
    MTRuntimeSnapshotResourceAssert(
        [asyncCache
            lookupObjectForGenerationIdentifier:@"generation-b"
            key:@"fresh" object:NULL epoch:NULL] ==
                MTRuntimeAsyncCacheDispositionScheduled &&
        dispatch_semaphore_wait(cancelledWaiter,
            dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0 &&
        cancelledResult == nil &&
        asyncCache.readyCount == 0 && asyncCache.failureCount == 0 &&
        asyncCache.pendingCount == 1 &&
        ![asyncCache isPendingKey:@"stale"
            generationIdentifier:@"generation-a" epoch:staleEpoch] &&
        ![asyncCache completeKey:@"stale"
            generationIdentifier:@"generation-a" epoch:staleEpoch
            object:b cost:2],
        @"Generation exchange must clear old state and reject stale completion");
    uint64_t purgeEpoch = asyncCache.epoch;
    [asyncCache purgeReadyObjectsAndCancelPending];
    MTRuntimeSnapshotResourceAssert(asyncCache.epoch == purgeEpoch + 1 &&
        asyncCache.readyCount == 0 && asyncCache.pendingCount == 0,
        @"Memory-pressure purge must invalidate pending work and ready objects");

    MTBadgeSnapshotContext *badgePhoneContext =
        [MTBadgeSnapshotContext contextWithScale:3 deviceTrait:@"iphone"];
    MTBadgeSnapshotContext *sameBadgePhoneContext =
        [MTBadgeSnapshotContext contextWithScale:3 deviceTrait:@"iphone"];
    MTBadgeSnapshotContext *badgePadContext =
        [MTBadgeSnapshotContext contextWithScale:2 deviceTrait:@"ipad"];
    MTRuntimeSnapshotResourceAssert(
        badgePhoneContext != nil && badgePadContext != nil &&
        badgePhoneContext == sameBadgePhoneContext &&
        [badgePhoneContext isEqual:sameBadgePhoneContext] &&
        badgePhoneContext.hash == sameBadgePhoneContext.hash &&
        [badgePhoneContext.cacheKey
            isEqualToString:@"badge-background/iphone/3"] &&
        ![badgePhoneContext.cacheKey
            isEqualToString:badgePadContext.cacheKey],
        @"Badge preparation context must be deterministic from safe primitive UI coordinates");
    MTRuntimeSnapshotResourceAssert(
        [MTBadgeSnapshotContext contextWithScale:0
                                     deviceTrait:@"iphone"] == nil &&
        [MTBadgeSnapshotContext contextWithScale:4
                                     deviceTrait:@"iphone"] == nil &&
        [MTBadgeSnapshotContext contextWithScale:3
                                     deviceTrait:@"unknown"] == nil &&
        [MTBadgeSnapshotContext contextWithScale:3
                                     deviceTrait:nil] == nil,
        @"Unavailable or unsupported Badge UI coordinates must remain a clean stock fallback");

    MTIconShadowSnapshotContext *shadowPhoneContext =
        [MTIconShadowSnapshotContext contextWithScale:3
                                          deviceTrait:@"iphone"
                             prefersLargeIPadCanvas:NO];
    MTIconShadowSnapshotContext *sameShadowPhoneContext =
        [MTIconShadowSnapshotContext contextWithScale:3
                                          deviceTrait:@"iphone"
                             prefersLargeIPadCanvas:NO];
    MTIconShadowSnapshotContext *normalizedShadowPhoneContext =
        [MTIconShadowSnapshotContext contextWithScale:3
                                          deviceTrait:@"iphone"
                             prefersLargeIPadCanvas:YES];
    MTIconShadowSnapshotContext *shadowPadContext =
        [MTIconShadowSnapshotContext contextWithScale:2
                                          deviceTrait:@"ipad"
                             prefersLargeIPadCanvas:NO];
    MTIconShadowSnapshotContext *shadowLargePadContext =
        [MTIconShadowSnapshotContext contextWithScale:2
                                          deviceTrait:@"ipad"
                             prefersLargeIPadCanvas:YES];
    MTRuntimeSnapshotResourceAssert(
        shadowPhoneContext != nil && normalizedShadowPhoneContext != nil &&
        shadowPadContext != nil &&
        shadowLargePadContext != nil &&
        [shadowPhoneContext isEqual:sameShadowPhoneContext] &&
        [shadowPhoneContext isEqual:normalizedShadowPhoneContext] &&
        !normalizedShadowPhoneContext.prefersLargeIPadCanvas &&
        shadowPhoneContext.hash == sameShadowPhoneContext.hash &&
        [shadowPhoneContext.cacheKey isEqualToString:@"iphone:3:regular"] &&
        ![shadowPadContext.cacheKey
            isEqualToString:shadowLargePadContext.cacheKey],
        @"Icon Shadow context must derive one stable cache identity from actual view primitives");
    MTRuntimeSnapshotResourceAssert(
        [MTIconShadowSnapshotContext contextWithScale:0
                                           deviceTrait:@"iphone"
                              prefersLargeIPadCanvas:NO] == nil &&
        [MTIconShadowSnapshotContext contextWithScale:4
                                           deviceTrait:@"iphone"
                              prefersLargeIPadCanvas:NO] == nil &&
        [MTIconShadowSnapshotContext contextWithScale:3
                                           deviceTrait:@"unknown"
                              prefersLargeIPadCanvas:NO] == nil,
        @"Icon Shadow must fail to stock when safe view coordinates are unavailable");

    MTRuntimeAsyncObjectCache<NSObject *> *badgePreparationCache =
        [[MTRuntimeAsyncObjectCache alloc]
            initWithMaximumReadyCount:2
            maximumReadyCost:4
            maximumPendingCount:2
            maximumFailureCount:2];
    NSLock *badgeCounterLock = [[NSLock alloc] init];
    __block NSUInteger badgeScheduledCount = 0;
    __block NSUInteger badgeUnexpectedCount = 0;
    dispatch_apply(64,
        dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0),
        ^(size_t index) {
            (void)index;
            MTRuntimeAsyncCacheDisposition concurrentDisposition =
                [badgePreparationCache
                    lookupObjectForGenerationIdentifier:@"badge-generation-a"
                    key:badgePhoneContext.cacheKey object:NULL epoch:NULL];
            [badgeCounterLock lock];
            if (concurrentDisposition ==
                    MTRuntimeAsyncCacheDispositionScheduled) {
                badgeScheduledCount++;
            } else if (concurrentDisposition !=
                    MTRuntimeAsyncCacheDispositionPending) {
                badgeUnexpectedCount++;
            }
            [badgeCounterLock unlock];
        });
    uint64_t badgeFirstEpoch = badgePreparationCache.epoch;
    MTRuntimeSnapshotResourceAssert(
        badgeScheduledCount == 1 && badgeUnexpectedCount == 0 &&
        badgePreparationCache.pendingCount == 1 &&
        [badgePreparationCache claimPendingKey:badgePhoneContext.cacheKey
            generationIdentifier:@"badge-generation-a"
            epoch:badgeFirstEpoch] &&
        ![badgePreparationCache claimPendingKey:badgePhoneContext.cacheKey
            generationIdentifier:@"badge-generation-a"
            epoch:badgeFirstEpoch],
        @"Concurrent first Badge requests must create exactly one nonblocking preparation owner");
    NSObject *badgeImageSetA = [[NSObject alloc] init];
    MTRuntimeSnapshotResourceAssert(
        [badgePreparationCache completeKey:badgePhoneContext.cacheKey
            generationIdentifier:@"badge-generation-a"
            epoch:badgeFirstEpoch object:badgeImageSetA cost:2] &&
        [badgePreparationCache
            readyObjectForGenerationIdentifier:@"badge-generation-a"
            key:badgePhoneContext.cacheKey] == badgeImageSetA,
        @"A safe Badge preparation boundary must publish one deterministic ready image set");

    uint64_t badgeReadyEpoch = badgePreparationCache.epoch;
    [badgePreparationCache purgeReadyObjectsAndCancelPending];
    MTRuntimeSnapshotResourceAssert(
        badgePreparationCache.epoch == badgeReadyEpoch + 1 &&
        badgePreparationCache.readyCount == 0 &&
        badgePreparationCache.pendingCount == 0 &&
        [badgePreparationCache
            readyObjectForGenerationIdentifier:@"badge-generation-a"
            key:badgePhoneContext.cacheKey] == nil,
        @"Badge reload or disable must atomically discard ready and in-flight replacements");

    uint64_t badgeForwardEpoch = 0;
    MTRuntimeSnapshotResourceAssert(
        [badgePreparationCache
            lookupObjectForGenerationIdentifier:@"badge-generation-b"
            key:badgePhoneContext.cacheKey object:NULL
            epoch:&badgeForwardEpoch] ==
                MTRuntimeAsyncCacheDispositionScheduled &&
        [badgePreparationCache claimPendingKey:badgePhoneContext.cacheKey
            generationIdentifier:@"badge-generation-b"
            epoch:badgeForwardEpoch],
        @"A later Badge Generation must own a fresh preparation epoch");
    uint64_t badgeRollbackEpoch = 0;
    MTRuntimeSnapshotResourceAssert(
        [badgePreparationCache
            lookupObjectForGenerationIdentifier:@"badge-generation-a"
            key:badgePhoneContext.cacheKey object:NULL
            epoch:&badgeRollbackEpoch] ==
                MTRuntimeAsyncCacheDispositionScheduled &&
        badgeRollbackEpoch != badgeForwardEpoch &&
        ![badgePreparationCache completeKey:badgePhoneContext.cacheKey
            generationIdentifier:@"badge-generation-b"
            epoch:badgeForwardEpoch object:[[NSObject alloc] init] cost:2] &&
        [badgePreparationCache claimPendingKey:badgePhoneContext.cacheKey
            generationIdentifier:@"badge-generation-a"
            epoch:badgeRollbackEpoch],
        @"Badge rollback must reject stale forward-Generation completion and schedule the restored Generation once");
    NSObject *badgeRollbackImageSet = [[NSObject alloc] init];
    MTRuntimeSnapshotResourceAssert(
        [badgePreparationCache completeKey:badgePhoneContext.cacheKey
            generationIdentifier:@"badge-generation-a"
            epoch:badgeRollbackEpoch object:badgeRollbackImageSet cost:2] &&
        [badgePreparationCache
            readyObjectForGenerationIdentifier:@"badge-generation-a"
            key:badgePhoneContext.cacheKey] == badgeRollbackImageSet,
        @"Badge rollback must deterministically publish only the restored Generation");

    __block MTRuntimeSnapshot *currentSnapshot =
        MTRuntimeSnapshot.stockSnapshot;
    MTStaticIconSnapshotResolver *resolver =
        [[MTStaticIconSnapshotResolver alloc]
            initWithSnapshotProvider:^MTRuntimeSnapshot *{
                return currentSnapshot;
            }];
    NSError *error = nil;
    MTRuntimeSnapshotResourceAssert(
        [resolver resolutionForBundleIdentifier:@"com.example.target"
                                           scale:3 error:&error] == nil &&
        error == nil,
        @"A disabled Runtime snapshot must be a clean resource miss");

    NSString *identifier =
        @"g1-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    NSString *iphoneKey = MTTestStaticIconKey(@"iphone", 3);
    NSString *anyKey = MTTestStaticIconKey(@"any", 3);
    NSString *universalAnyKey = MTTestStaticIconKey(@"any", 0);
    MTTestSnapshotResource *iphone = [[MTTestSnapshotResource alloc] init];
    iphone.identity = @"iphone";
    MTTestSnapshotResource *any = [[MTTestSnapshotResource alloc] init];
    any.identity = @"any";
    MTTestSnapshotGeneration *generation =
        [[MTTestSnapshotGeneration alloc] init];
    generation.generationIdentifier = identifier;
    generation.resources = @{ iphoneKey : iphone, anyKey : any };
    currentSnapshot = MTTestReadySnapshot(generation);

    NSString *largeKey = MTTestStaticIconKeyForSubject(
        @"com.example.target", @"any", 0,
        MTStaticIconSourceVariantLarge);
    NSString *exactScaleKey = MTTestStaticIconKeyForSubject(
        @"com.example.target", @"any", 3,
        MTStaticIconSourceVariantScale);
    NSString *alternateScaleKey = MTTestStaticIconKeyForSubject(
        @"com.example.target", @"any", 2,
        MTStaticIconSourceVariantScale);
    NSString *plainKey = MTTestStaticIconKeyForSubject(
        @"com.example.target", @"any", 0,
        MTStaticIconSourceVariantPlain);
    MTTestSnapshotResource *large = [[MTTestSnapshotResource alloc] init];
    large.identity = @"large";
    MTTestSnapshotResource *exactScale = [[MTTestSnapshotResource alloc] init];
    exactScale.identity = @"exact-scale";
    MTTestSnapshotResource *alternateScale =
        [[MTTestSnapshotResource alloc] init];
    alternateScale.identity = @"alternate-scale";
    MTTestSnapshotResource *plain = [[MTTestSnapshotResource alloc] init];
    plain.identity = @"plain";
    generation.resources = @{
        largeKey : large,
        exactScaleKey : exactScale,
        alternateScaleKey : alternateScale,
        plainKey : plain,
        iphoneKey : iphone,
    };
    error = nil;
    NSArray<MTStaticIconSnapshotResolution *> *snowBoardResolutions = [resolver
        resolutionsForBundleIdentifier:@"com.example.target"
        scale:3 deviceTrait:@"iphone" error:&error];
    MTRuntimeSnapshotResourceAssert(
        snowBoardResolutions.count == 5 &&
        snowBoardResolutions[0].resource == (id)large &&
        snowBoardResolutions[1].resource == (id)exactScale &&
        snowBoardResolutions[2].resource == (id)alternateScale &&
        snowBoardResolutions[3].resource == (id)plain &&
        snowBoardResolutions[4].resource == (id)iphone && error == nil,
        @"Static icon resolution must retain SnowBoard -large, exact, cross-scale, plain, and legacy fallbacks in order");

    generation.resources = @{ iphoneKey : iphone, anyKey : any };
    error = nil;
    MTStaticIconSnapshotResolution *resolution = [resolver
        resolutionForBundleIdentifier:@"com.example.target"
        scale:3 error:&error];
    MTRuntimeSnapshotResourceAssert(
        resolution.resource == (id)iphone &&
        resolution.generation == (id)generation &&
        [resolution.generationIdentifier isEqualToString:identifier] &&
        [resolution.canonicalResourceKey isEqualToString:iphoneKey] &&
        error == nil,
        @"Snapshot resolver must prefer the exact iPhone key in one snapshot");

    generation.requestedKeys = [NSMutableArray array];
    generation.resources = @{ anyKey : any };
    resolution = [resolver
        resolutionForBundleIdentifier:@"com.example.target"
        scale:3 error:&error];
    MTRuntimeSnapshotResourceAssert(
        resolution.resource == (id)any &&
        [resolution.canonicalResourceKey isEqualToString:anyKey] &&
        [generation.requestedKeys containsObject:anyKey],
        @"Snapshot resolver must use deterministic iphone-to-any fallback");

    generation.requestedKeys = [NSMutableArray array];
    generation.resources = @{ universalAnyKey : any };
    resolution = [resolver
        resolutionForBundleIdentifier:@"com.example.target"
        scale:3 error:&error];
    MTRuntimeSnapshotResourceAssert(
        resolution.resource == (id)any &&
        [resolution.canonicalResourceKey isEqualToString:universalAnyKey] &&
        [generation.requestedKeys containsObject:universalAnyKey],
        @"Snapshot resolver must fall back from exact device scale to one universal SnowBoard resource");

    generation.requestedKeys = [NSMutableArray array];
    generation.resources = @{};
    error = nil;
    MTRuntimeSnapshotResourceAssert(
        [resolver resolutionForBundleIdentifier:@"com.example.target"
                                           scale:3 error:&error] == nil &&
        error == nil,
        @"A valid absent Generation resource must remain a clean miss");

    MTTestSnapshotDescriptor *fuzzyDescriptor =
        [[MTTestSnapshotDescriptor alloc] init];
    fuzzyDescriptor.moduleConfigurations = @{
        @"icons.static" : @{
            @"bundleAliases" : @{
                @"TEAM.com.example.target" : @"com.example.missing",
            },
            @"fuzzyBundleIdentifiers" : @[
                @"com.example.target", @"example.target",
            ],
        },
    };
    generation.descriptor = fuzzyDescriptor;
    generation.requestedKeys = [NSMutableArray array];
    NSString *fuzzyKey = MTTestStaticIconKeyForSubject(
        @"example.target", @"iphone", 3,
        MTStaticIconSourceVariantPrimary);
    generation.resources = @{ fuzzyKey : iphone };
    resolution = [resolver
        resolutionForBundleIdentifier:@"TEAM.com.example.target"
        scale:3 error:&error];
    MTRuntimeSnapshotResourceAssert(
        resolution.resource == (id)iphone &&
        [resolution.canonicalResourceKey isEqualToString:fuzzyKey] &&
        [generation.requestedKeys containsObject:fuzzyKey],
        @"Snapshot resolver must continue from an absent alias and longer fuzzy subject to the next configured fallback");
    generation.descriptor = nil;

    error = nil;
    MTRuntimeSnapshotResourceAssert(
        [resolver resolutionForBundleIdentifier:@"../unsafe"
                                           scale:3 error:&error] == nil &&
        [error.domain isEqualToString:MTResourceKeyErrorDomain],
        @"Snapshot resolver must reject a noncanonical bundle subject");
    error = nil;
    MTRuntimeSnapshotResourceAssert(
        [resolver resolutionForBundleIdentifier:@"com.example.target"
                                           scale:4 error:&error] == nil &&
        [error.domain isEqualToString:MTResourceKeyErrorDomain],
        @"Snapshot resolver must reject a scale outside ResourceKey v1");

    NSError *lookupError = [NSError errorWithDomain:@"test.snapshot-index"
                                                code:7 userInfo:nil];
    generation.lookupError = lookupError;
    error = nil;
    MTRuntimeSnapshotResourceAssert(
        [resolver resolutionForBundleIdentifier:@"com.example.target"
                                           scale:3 error:&error] == nil &&
        error == lookupError,
        @"Snapshot resolver must preserve an immutable index lookup failure");

    generation.lookupError = nil;
    generation.requestedKeys = [NSMutableArray array];
    NSString *iconMaskKey = MTTestDecorationKey(
        MTIconMaskModuleID, MTIconMaskSurface, MTIconMaskGlobalSubject,
        MTIconMaskVariantMask);
    NSString *folderLightKey = MTTestDecorationKey(
        MTFolderIconsModuleID, MTFolderIconSurface,
        MTFolderIconGlobalSubject, MTFolderIconVariantBackgroundLight);
    MTTestSnapshotResource *iconMaskResource =
        [[MTTestSnapshotResource alloc] init];
    iconMaskResource.identity = @"icon-mask";
    MTTestSnapshotResource *folderLightResource =
        [[MTTestSnapshotResource alloc] init];
    folderLightResource.identity = @"folder-light";
    generation.resources = @{
        iconMaskKey : iconMaskResource,
        folderLightKey : folderLightResource,
    };
    MTSpringBoardDecorationSnapshotResolver *decorationResolver =
        [[MTSpringBoardDecorationSnapshotResolver alloc]
            initWithSnapshotProvider:^MTRuntimeSnapshot *{
                return currentSnapshot;
            }];
    error = nil;
    MTSpringBoardDecorationSnapshotResolution *decorationResolution =
        [decorationResolver
            resolutionForKind:MTSpringBoardDecorationKindIconMask
                         error:&error];
    MTRuntimeSnapshotResourceAssert(
        decorationResolution.resource == (id)iconMaskResource &&
        decorationResolution.generation == (id)generation &&
        [decorationResolution.generationIdentifier
            isEqualToString:identifier] &&
        [decorationResolution.canonicalResourceKey
            isEqualToString:iconMaskKey] &&
        [generation.requestedKeys isEqualToArray:@[iconMaskKey]] &&
        error == nil,
        @"Decoration resolver must map the typed icon-mask kind to one exact Generation key");

    generation.requestedKeys = [NSMutableArray array];
    decorationResolution = [decorationResolver
        resolutionForKind:MTSpringBoardDecorationKindFolderBackgroundLight
                     error:&error];
    MTRuntimeSnapshotResourceAssert(
        decorationResolution.resource == (id)folderLightResource &&
        [decorationResolution.canonicalResourceKey
            isEqualToString:folderLightKey] &&
        [generation.requestedKeys isEqualToArray:@[folderLightKey]],
        @"Decoration resolver must preserve the base/light folder semantic boundary");

    generation.requestedKeys = [NSMutableArray array];
    error = nil;
    MTRuntimeSnapshotResourceAssert(
        [decorationResolver resolutionForKind:
            (MTSpringBoardDecorationKind)NSUIntegerMax error:&error] == nil &&
        error == nil && generation.requestedKeys.count == 0,
        @"Unknown decoration kinds must remain clean misses before index lookup");

    MTBadgeSnapshotResolver *badgeResolver = [[MTBadgeSnapshotResolver alloc]
        initWithSnapshotProvider:^MTRuntimeSnapshot *{
            return currentSnapshot;
        }];
    NSString *badgePhoneDarkKey = MTTestBadgeKey(
        @"oxy-blue", @"iphone-dark", 3);
    NSString *badgeDarkKey = MTTestBadgeKey(@"oxy-blue", @"dark", 3);
    NSString *badgePhoneKey = MTTestBadgeKey(@"oxy-blue", @"iphone", 3);
    NSString *badgeAnyKey = MTTestBadgeKey(@"oxy-blue", @"any", 3);
    NSString *badgePhoneDarkUniversalKey = MTTestBadgeKey(
        @"oxy-blue", @"iphone-dark", 0);
    NSString *badgeDarkUniversalKey = MTTestBadgeKey(
        @"oxy-blue", @"dark", 0);
    NSString *badgePhoneUniversalKey = MTTestBadgeKey(
        @"oxy-blue", @"iphone", 0);
    NSString *badgeAnyUniversalKey = MTTestBadgeKey(
        @"oxy-blue", @"any", 0);
    MTTestSnapshotResource *badgeDark = [[MTTestSnapshotResource alloc] init];
    badgeDark.identity = @"badge-dark";
    generation.requestedKeys = [NSMutableArray array];
    generation.resources = @{ badgePhoneDarkKey : badgeDark };
    error = nil;
    MTBadgeSnapshotResolution *badgeResolution = [badgeResolver
        resolutionForVariant:@"oxy-blue"
                       scale:3
                 deviceTrait:@"iphone"
                  appearance:MTBadgeAppearanceDark
                       error:&error];
    MTRuntimeSnapshotResourceAssert(
        badgeResolution.resource == (id)badgeDark && error == nil &&
        [badgeResolution.canonicalResourceKey
            isEqualToString:badgePhoneDarkKey] &&
        [generation.requestedKeys isEqualToArray:@[badgePhoneDarkKey]],
        @"Badge resolver must prefer the selected style's exact dark appearance resource");

    generation.requestedKeys = [NSMutableArray array];
    generation.resources = @{ badgeAnyUniversalKey : badgeDark };
    badgeResolution = [badgeResolver
        resolutionForVariant:@"oxy-blue"
                       scale:3
                 deviceTrait:@"iphone"
                  appearance:MTBadgeAppearanceDark
                       error:&error];
    MTRuntimeSnapshotResourceAssert(
        badgeResolution.resource == (id)badgeDark &&
        [badgeResolution.canonicalResourceKey
            isEqualToString:badgeAnyUniversalKey] &&
        [generation.requestedKeys isEqualToArray:@[
            badgePhoneDarkKey, badgeDarkKey, badgePhoneKey, badgeAnyKey,
            badgePhoneDarkUniversalKey, badgeDarkUniversalKey,
            badgePhoneUniversalKey, badgeAnyUniversalKey,
        ]],
        @"Badge resolver must fall back across appearance before scale without leaving the selected style");

    generation.requestedKeys = [NSMutableArray array];
    generation.resources = @{
        MTTestBadgeKey(@"oxy-blue", @"light", 3) : badgeDark,
        MTTestBadgeKey(@"oxy-red", @"any", 3) : badgeDark,
    };
    error = nil;
    MTRuntimeSnapshotResourceAssert(
        [badgeResolver resolutionForVariant:@"oxy-blue"
                                      scale:3
                                deviceTrait:@"iphone"
                                 appearance:MTBadgeAppearanceDark
                                      error:&error] == nil &&
        error == nil && generation.requestedKeys.count == 8,
        @"Badge dark lookup must not consume light artwork or another authored style");

    MTTestSnapshotResource *badgeLight = [[MTTestSnapshotResource alloc] init];
    badgeLight.identity = @"badge-light";
    NSString *badgeLightKey = MTTestBadgeKey(@"oxy-blue", @"light", 3);
    generation.requestedKeys = [NSMutableArray array];
    generation.resources = @{
        badgeLightKey : badgeLight,
        badgeDarkKey : badgeDark,
    };
    error = nil;
    badgeResolution = [badgeResolver
        resolutionForVariant:@"oxy-blue"
                       scale:3
                 deviceTrait:@"iphone"
                  appearance:MTBadgeAppearanceLight
                       error:&error];
    MTRuntimeSnapshotResourceAssert(
        badgeResolution.resource == (id)badgeLight && error == nil &&
        [badgeResolution.canonicalResourceKey isEqualToString:badgeLightKey],
        @"Badge light lookup must select light artwork without consuming the same style's dark resource");

    error = nil;
    MTRuntimeSnapshotResourceAssert(
        [badgeResolver resolutionForVariant:@"oxy-blue"
                                      scale:3
                                deviceTrait:@"iphone"
                                 appearance:@"contrast"
                                      error:&error] == nil &&
        [error.domain isEqualToString:MTResourceKeyErrorDomain],
        @"Badge resolver must reject an unsupported appearance trait");

    MTDialerSnapshotContext *dialerPhone3 = [MTDialerSnapshotContext
        contextWithScale:3 deviceTrait:@"iphone"];
    MTDialerSnapshotContext *dialerPhone2 = [MTDialerSnapshotContext
        contextWithScale:2 deviceTrait:@"iphone"];
    MTRuntimeSnapshotResourceAssert(
        dialerPhone3 != nil && dialerPhone2 != nil &&
        dialerPhone3.scale == 3 &&
        [dialerPhone3.deviceTrait isEqualToString:@"iphone"] &&
        [dialerPhone3.cacheKey isEqualToString:@"dialer/iphone/3"] &&
        [dialerPhone3 copy] == dialerPhone3 &&
        [MTDialerSnapshotContext contextWithScale:0
                                      deviceTrait:@"iphone"] == nil &&
        [MTDialerSnapshotContext contextWithScale:3
                                      deviceTrait:@"watch"] == nil,
        @"Dialer rendering context must retain only primitive scale and device-trait state");
    MTDialerSnapshotResolver *dialerResolver =
        [[MTDialerSnapshotResolver alloc]
            initWithSnapshotProvider:^MTRuntimeSnapshot *{
                return currentSnapshot;
            }];
    NSString *dialerExactKey = MTTestDialerKey(@"1", @"iphone", 3);
    MTTestSnapshotResource *dialerExact = [[MTTestSnapshotResource alloc] init];
    dialerExact.identity = @"dialer-one";
    generation.requestedKeys = [NSMutableArray array];
    generation.resources = @{ dialerExactKey : dialerExact };
    error = nil;
    MTDialerSnapshotResolution *dialerResolution = [dialerResolver
        resolutionForSubject:@"1" context:dialerPhone3 error:&error];
    MTRuntimeSnapshotResourceAssert(
        dialerResolution.resource == (id)dialerExact && error == nil &&
        [dialerResolution.canonicalResourceKey
            isEqualToString:dialerExactKey] &&
        [generation.requestedKeys isEqualToArray:@[dialerExactKey]],
        @"Dialer resolver must stop at an exact legacy subject, scale, and iPhone trait match");

    NSString *dialerScale2PhoneKey = MTTestDialerKey(@"1", @"iphone", 2);
    NSString *dialerScale2AnyKey = MTTestDialerKey(@"1", @"any", 2);
    NSString *dialerScale3PhoneKey = MTTestDialerKey(@"1", @"iphone", 3);
    NSString *dialerScale3AnyKey = MTTestDialerKey(@"1", @"any", 3);
    MTTestSnapshotResource *dialerFallback = [[MTTestSnapshotResource alloc] init];
    dialerFallback.identity = @"dialer-three-x-fallback";
    generation.requestedKeys = [NSMutableArray array];
    generation.resources = @{ dialerScale3AnyKey : dialerFallback };
    error = nil;
    dialerResolution = [dialerResolver
        resolutionForSubject:@"1" context:dialerPhone2 error:&error];
    MTRuntimeSnapshotResourceAssert(
        dialerResolution.resource == (id)dialerFallback && error == nil &&
        [dialerResolution.canonicalResourceKey
            isEqualToString:dialerScale3AnyKey] &&
        [generation.requestedKeys isEqualToArray:@[
            dialerScale2PhoneKey, dialerScale2AnyKey,
            dialerScale3PhoneKey, dialerScale3AnyKey,
        ]],
        @"A 2x Dialer context must deterministically downsample an authored 3x resource before lower-scale fallback");

    generation.requestedKeys = [NSMutableArray array];
    error = nil;
    MTRuntimeSnapshotResourceAssert(
        [dialerResolver resolutionForSubject:@"../unsafe"
                                      context:dialerPhone3
                                        error:&error] == nil &&
        [error.domain isEqualToString:MTResourceKeyErrorDomain] &&
        generation.requestedKeys.count == 0,
        @"Dialer resolver must reject unknown subjects before Generation lookup");
    currentSnapshot = MTRuntimeSnapshot.stockSnapshot;
    generation.requestedKeys = [NSMutableArray array];
    error = nil;
    MTRuntimeSnapshotResourceAssert(
        [dialerResolver resolutionForSubject:@"1"
                                      context:dialerPhone3
                                        error:&error] == nil &&
        error == nil && generation.requestedKeys.count == 0,
        @"Dialer disable must remain a clean stock miss without stale resource lookup");
    currentSnapshot = MTTestReadySnapshot(generation);

    MTStatusBarSnapshotContext *statusPhone3 =
        [MTStatusBarSnapshotContext
            contextWithScale:3 deviceTrait:@"iphone"];
    MTStatusBarSnapshotContext *statusPhone2 =
        [MTStatusBarSnapshotContext
            contextWithScale:2 deviceTrait:@"iphone"];
    MTRuntimeSnapshotResourceAssert(
        statusPhone3 != nil && statusPhone2 != nil &&
        statusPhone3.scale == 3 &&
        [statusPhone3.deviceTrait isEqualToString:@"iphone"] &&
        [statusPhone3.cacheKey isEqualToString:@"statusbar/iphone/3"] &&
        [statusPhone3 copy] == statusPhone3 &&
        [MTStatusBarSnapshotContext contextWithScale:0
                                      deviceTrait:@"iphone"] == nil &&
        [MTStatusBarSnapshotContext contextWithScale:3
                                      deviceTrait:@"watch"] == nil,
        @"Status Bar context must retain only primitive scale and device-trait state");
    MTStatusBarSnapshotResolver *statusResolver =
        [[MTStatusBarSnapshotResolver alloc]
            initWithSnapshotProvider:^MTRuntimeSnapshot *{
                return currentSnapshot;
            }];
    NSString *statusSubject = @"Black_3_WifiBars";
    NSString *statusExactKey = MTTestStatusBarKey(
        statusSubject, @"iphone", 3);
    MTTestSnapshotResource *statusExact =
        [[MTTestSnapshotResource alloc] init];
    statusExact.identity = @"status-wifi-black-three";
    generation.requestedKeys = [NSMutableArray array];
    generation.resources = @{ statusExactKey : statusExact };
    error = nil;
    MTStatusBarSnapshotResolution *statusResolution = [statusResolver
        resolutionForKind:MTStatusBarSignalKindWiFi
                     style:MTStatusBarArtworkStyleBlack
                     level:3 context:statusPhone3 error:&error];
    MTRuntimeSnapshotResourceAssert(
        statusResolution.resource == (id)statusExact && error == nil &&
        [statusResolution.generationIdentifier isEqualToString:identifier] &&
        [statusResolution.canonicalResourceKey
            isEqualToString:statusExactKey] &&
        [generation.requestedKeys isEqualToArray:@[statusExactKey]],
        @"Status Bar resolver must stop at the exact signal kind, style, level, scale, and trait");

    NSString *statusScale2PhoneKey = MTTestStatusBarKey(
        statusSubject, @"iphone", 2);
    NSString *statusScale2AnyKey = MTTestStatusBarKey(
        statusSubject, @"any", 2);
    NSString *statusScale3PhoneKey = MTTestStatusBarKey(
        statusSubject, @"iphone", 3);
    NSString *statusScale3AnyKey = MTTestStatusBarKey(
        statusSubject, @"any", 3);
    MTTestSnapshotResource *statusFallback =
        [[MTTestSnapshotResource alloc] init];
    statusFallback.identity = @"status-wifi-three-x-fallback";
    generation.requestedKeys = [NSMutableArray array];
    generation.resources = @{ statusScale3AnyKey : statusFallback };
    statusResolution = [statusResolver
        resolutionForKind:MTStatusBarSignalKindWiFi
                     style:MTStatusBarArtworkStyleBlack
                     level:3 context:statusPhone2 error:&error];
    MTRuntimeSnapshotResourceAssert(
        statusResolution.resource == (id)statusFallback && error == nil &&
        [statusResolution.canonicalResourceKey
            isEqualToString:statusScale3AnyKey] &&
        [generation.requestedKeys isEqualToArray:@[
            statusScale2PhoneKey, statusScale2AnyKey,
            statusScale3PhoneKey, statusScale3AnyKey,
        ]],
        @"A 2x Status Bar context must prefer 3x authored artwork before lower-scale fallback");

    generation.requestedKeys = [NSMutableArray array];
    generation.resources = @{
        MTTestStatusBarKey(@"LockScreen_3_WifiBars", @"iphone", 3) :
            statusExact,
    };
    error = nil;
    MTRuntimeSnapshotResourceAssert(
        [statusResolver resolutionForKind:MTStatusBarSignalKindWiFi
                                    style:MTStatusBarArtworkStyleBlack
                                    level:3 context:statusPhone3
                                    error:&error] == nil &&
        error == nil && generation.requestedKeys.count == 8,
        @"Status Bar lookup must not cross from Black into LockScreen artwork");

    generation.requestedKeys = [NSMutableArray array];
    error = nil;
    MTRuntimeSnapshotResourceAssert(
        [statusResolver resolutionForKind:MTStatusBarSignalKindWiFi
                                    style:MTStatusBarArtworkStyleBlack
                                    level:4 context:statusPhone3
                                    error:&error] == nil &&
        [error.domain isEqualToString:MTResourceKeyErrorDomain] &&
        generation.requestedKeys.count == 0,
        @"Status Bar resolver must reject an out-of-range level before Generation lookup");
    currentSnapshot = MTRuntimeSnapshot.stockSnapshot;
    generation.requestedKeys = [NSMutableArray array];
    error = nil;
    MTRuntimeSnapshotResourceAssert(
        [statusResolver resolutionForKind:MTStatusBarSignalKindWiFi
                                    style:MTStatusBarArtworkStyleBlack
                                    level:3 context:statusPhone3
                                    error:&error] == nil &&
        error == nil && generation.requestedKeys.count == 0,
        @"Status Bar disable must be a clean stock miss with no stale lookup");
    currentSnapshot = MTTestReadySnapshot(generation);

    MTIconShadowSnapshotResolver *shadowResolver =
        [[MTIconShadowSnapshotResolver alloc]
            initWithSnapshotProvider:^MTRuntimeSnapshot *{
                return currentSnapshot;
            }];
    NSString *shadowPhoneKey = MTTestIconShadowKey(
        MTIconShadowSubjectIPhone, @"oxy-shadow", @"iphone", 3);
    NSString *shadowPhoneAnyKey = MTTestIconShadowKey(
        MTIconShadowSubjectIPhone, @"oxy-shadow", @"any", 3);
    NSString *shadowPhoneUniversalKey = MTTestIconShadowKey(
        MTIconShadowSubjectIPhone, @"oxy-shadow", @"iphone", 0);
    MTTestSnapshotResource *shadowResource =
        [[MTTestSnapshotResource alloc] init];
    shadowResource.identity = @"shadow-phone";
    generation.requestedKeys = [NSMutableArray array];
    generation.resources = @{ shadowPhoneKey : shadowResource };
    error = nil;
    MTIconShadowSnapshotResolution *shadowResolution = [shadowResolver
        resolutionForVariant:@"oxy-shadow"
                      context:shadowPhoneContext
                        error:&error];
    MTRuntimeSnapshotResourceAssert(
        shadowResolution.resource == (id)shadowResource && error == nil &&
        [shadowResolution.generationIdentifier isEqualToString:identifier] &&
        [shadowResolution.canonicalResourceKey
            isEqualToString:shadowPhoneKey] &&
        [shadowResolution.subject
            isEqualToString:MTIconShadowSubjectIPhone] &&
        shadowResolution.sourceScale == 3 &&
        shadowResolution.targetPixelDimension == 330 &&
        shadowResolution.canvasPointDimension == 110.0 &&
        [generation.requestedKeys isEqualToArray:@[shadowPhoneKey]],
        @"Icon Shadow resolver must select the exact iPhone 110pt canvas for the active style");

    generation.requestedKeys = [NSMutableArray array];
    generation.resources = @{ shadowPhoneUniversalKey : shadowResource };
    shadowResolution = [shadowResolver
        resolutionForVariant:@"oxy-shadow"
                      context:shadowPhoneContext
                        error:&error];
    MTRuntimeSnapshotResourceAssert(
        shadowResolution.resource == (id)shadowResource &&
        shadowResolution.sourceScale == 0 &&
        [generation.requestedKeys isEqualToArray:@[
            shadowPhoneKey, shadowPhoneAnyKey, shadowPhoneUniversalKey,
        ]],
        @"Icon Shadow resolver must use exact trait before one scale-neutral canvas");

    NSString *shadowPadProKey = MTTestIconShadowKey(
        MTIconShadowSubjectIPadPro, @"oxy-shadow", @"ipad", 2);
    generation.requestedKeys = [NSMutableArray array];
    generation.resources = @{ shadowPadProKey : shadowResource };
    shadowResolution = [shadowResolver
        resolutionForVariant:@"oxy-shadow"
                      context:shadowLargePadContext
                        error:&error];
    MTRuntimeSnapshotResourceAssert(
        shadowResolution.resource == (id)shadowResource &&
        [shadowResolution.subject
            isEqualToString:MTIconShadowSubjectIPadPro] &&
        shadowResolution.targetPixelDimension == 306 &&
        shadowResolution.canvasPointDimension == 153.0 &&
        [generation.requestedKeys isEqualToArray:@[shadowPadProKey]],
        @"A large iPad icon context must prefer the authored 153pt iPad Pro canvas");

    generation.requestedKeys = [NSMutableArray array];
    generation.resources = @{
        MTTestIconShadowKey(MTIconShadowSubjectIPhone,
            @"another-shadow", @"iphone", 3) : shadowResource,
    };
    error = nil;
    MTRuntimeSnapshotResourceAssert(
        [shadowResolver resolutionForVariant:@"oxy-shadow"
                                     context:shadowPhoneContext
                                       error:&error] == nil &&
        error == nil && generation.requestedKeys.count == 6,
        @"Icon Shadow lookup must not cross into another authored style");

    error = nil;
    MTRuntimeSnapshotResourceAssert(
        [shadowResolver resolutionForVariant:@"unsafe/variant"
                                     context:shadowPhoneContext
                                       error:&error] == nil &&
        [error.domain isEqualToString:MTResourceKeyErrorDomain] &&
        [shadowResolver resolutionForVariant:@"oxy-shadow"
                                     context:(id)@"invalid-context"
                                       error:&error] == nil,
        @"Icon Shadow resolver must reject noncanonical styles and absent UI contexts");

    generation.requestedKeys = [NSMutableArray array];
    NSString *preferencesExactKey =
        MTTestPreferencesIconKey(@"WiFi", @"iphone", 3,
            MTStaticIconSourceVariantPrimary);
    NSString *preferencesUniversalAnyKey =
        MTTestPreferencesIconKey(@"WiFi", @"any", 0,
            MTStaticIconSourceVariantPrimary);
    MTTestSnapshotResource *preferencesIcon =
        [[MTTestSnapshotResource alloc] init];
    preferencesIcon.identity = @"preferences-wifi";
    generation.resources = @{
        preferencesUniversalAnyKey : preferencesIcon,
    };
    MTUIResourceSnapshotResolver *uiResolver =
        [[MTUIResourceSnapshotResolver alloc]
            initWithSnapshotProvider:^MTRuntimeSnapshot *{
                return currentSnapshot;
            }];
    NSString *preferencesLargeKey = MTTestPreferencesIconKey(
        @"WiFi", @"any", 0, MTStaticIconSourceVariantLarge);
    NSString *preferencesScale3Key = MTTestPreferencesIconKey(
        @"WiFi", @"any", 3, MTStaticIconSourceVariantScale);
    NSString *preferencesScale2Key = MTTestPreferencesIconKey(
        @"WiFi", @"any", 2, MTStaticIconSourceVariantScale);
    MTTestSnapshotResource *preferencesLarge =
        [[MTTestSnapshotResource alloc] init];
    MTTestSnapshotResource *preferencesScale3 =
        [[MTTestSnapshotResource alloc] init];
    MTTestSnapshotResource *preferencesScale2 =
        [[MTTestSnapshotResource alloc] init];
    generation.resources = @{
        preferencesLargeKey : preferencesLarge,
        preferencesScale3Key : preferencesScale3,
        preferencesScale2Key : preferencesScale2,
        preferencesUniversalAnyKey : preferencesIcon,
    };
    NSArray<MTUIResourceSnapshotResolution *> *uiResolutions = [uiResolver
        resolutionsForPreferencesIconName:@"WiFi" scale:3
        deviceTrait:@"iphone" error:&error];
    MTRuntimeSnapshotResourceAssert(
        uiResolutions.count == 4 &&
        uiResolutions[0].resource == (id)preferencesLarge &&
        uiResolutions[1].resource == (id)preferencesScale3 &&
        uiResolutions[2].resource == (id)preferencesScale2 &&
        uiResolutions[3].resource == (id)preferencesIcon,
        @"UI resource resolution must preserve SnowBoard universal, exact, cross-scale, and legacy candidates");

    generation.resources = @{
        preferencesUniversalAnyKey : preferencesIcon,
    };
    error = nil;
    MTUIResourceSnapshotResolution *uiResolution = [uiResolver
        resolutionForPreferencesIconName:@"WiFi"
                                   scale:3
                                   error:&error];
    MTRuntimeSnapshotResourceAssert(
        uiResolution.resource == (id)preferencesIcon &&
        uiResolution.generation == (id)generation &&
        [uiResolution.generationIdentifier isEqualToString:identifier] &&
        [uiResolution.canonicalResourceKey
            isEqualToString:preferencesUniversalAnyKey] &&
        [generation.requestedKeys containsObject:
            preferencesUniversalAnyKey] && error == nil,
        @"Preferences resolver must use the exact deterministic scale and device fallback order");

    generation.requestedKeys = [NSMutableArray array];
    generation.resources = @{ preferencesExactKey : preferencesIcon };
    uiResolution = [uiResolver
        resolutionForPreferencesIconName:@"WiFi"
                                   scale:3
                                   error:&error];
    MTRuntimeSnapshotResourceAssert(
        uiResolution.resource == (id)preferencesIcon &&
        [uiResolution.canonicalResourceKey
            isEqualToString:preferencesExactKey] &&
        [generation.requestedKeys containsObject:preferencesExactKey],
        @"Preferences resolver must stop at an exact scale-and-device match");

    MTTestShareActivity *testActivity = [[MTTestShareActivity alloc] init];
    testActivity.imageCreationBundleIdentifier = @"com.tencent.xin";
    testActivity.containingAppBundleIdentifier = @"com.example.fallback";
    MTTestShareActivityConfiguration *testConfiguration =
        [[MTTestShareActivityConfiguration alloc] init];
    testConfiguration.activityClassName = @"UIMessageActivity";
    testConfiguration.activity = testActivity;
    MTTestShareActivityProxy *testProxy =
        [[MTTestShareActivityProxy alloc] init];
    testProxy.activityConfiguration = testConfiguration;
    MTRuntimeSnapshotResourceAssert(
        [MTShareSheetUIActivityIdentity(testActivity)
            isEqualToString:@"MTTestShareActivity"] &&
        [MTShareSheetProxyActivityIdentity(testProxy)
            isEqualToString:@"UIMessageActivity"] &&
        MTShareSheetProxyActivityIdentity([[NSObject alloc] init]) == nil &&
        [MTShareSheetApplicationBundleIdentity(@"com.apple.mobilesafari")
            isEqualToString:@"com.apple.mobilesafari"] &&
        [MTShareSheetApplicationBundleIdentityForActivity(testActivity)
            isEqualToString:@"com.tencent.xin"] &&
        [MTShareSheetApplicationBundleIdentityForActivityProxy(testProxy)
            isEqualToString:@"com.tencent.xin"] &&
        [MTShareSheetApplicationBundleIdentityForActivityIdentity(
            @"UIMailActivity")
            isEqualToString:@"com.apple.mobilemail"] &&
        [MTShareSheetApplicationBundleIdentityForActivityIdentity(
            @"UIMessageActivity")
            isEqualToString:@"com.apple.MobileSMS"] &&
        MTShareSheetApplicationBundleIdentityForActivityIdentity(
            @"UIPrintActivity") == nil &&
        MTShareSheetApplicationBundleIdentityForActivityIdentity(
            @"unsafe/activity") == nil &&
        MTShareSheetApplicationBundleIdentity(@"unsafe/bundle") == nil &&
        MTShareSheetApplicationBundleIdentity(@42) == nil,
        @"Share identities must recover safe extension-host App identifiers while preserving the two built-in mappings");

    testActivity.imageCreationBundleIdentifier = nil;
    MTRuntimeSnapshotResourceAssert(
        [MTShareSheetApplicationBundleIdentityForActivity(testActivity)
            isEqualToString:@"com.example.fallback"],
        @"An extension activity must fall back to its exact containing-App getter");
    testActivity.containingAppBundleIdentifier = @"unsafe/activity";
    MTRuntimeSnapshotResourceAssert(
        MTShareSheetApplicationBundleIdentityForActivity(testActivity) == nil,
        @"Extension-host identities must pass the same canonical safety gate");

    generation.requestedKeys = [NSMutableArray array];
    NSString *shareUniversalAnyKey =
        MTTestShareActivityKey(@"UIMessageActivity", @"any", 0,
            MTStaticIconSourceVariantPrimary);
    MTTestSnapshotResource *shareIcon =
        [[MTTestSnapshotResource alloc] init];
    shareIcon.identity = @"share-message";
    generation.resources = @{ shareUniversalAnyKey : shareIcon };
    error = nil;
    uiResolution = [uiResolver
        resolutionForShareActivityName:@"UIMessageActivity"
                                 scale:3
                                 error:&error];
    MTRuntimeSnapshotResourceAssert(
        uiResolution.resource == (id)shareIcon &&
        [uiResolution.canonicalResourceKey
            isEqualToString:shareUniversalAnyKey] &&
        [generation.requestedKeys containsObject:shareUniversalAnyKey] &&
        error == nil,
        @"Share resolver must use the same deterministic scale and device fallback order");

    return MTRuntimeSnapshotResourceAssertionCount;
}
