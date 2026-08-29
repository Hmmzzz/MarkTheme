#import "MTIconServiceStoreInvalidator.h"

#import <CydiaSubstrate/CydiaSubstrate.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <os/lock.h>

#include <stdatomic.h>
#include <string.h>

#import "MTIconServiceABI.h"
#import "MTIconServiceStoreIndex.h"
#import "MTStaticIconConfiguration.h"

NSString *const MTIconServiceStoreInvalidatorErrorDomain =
    @"com.hmmzzz.marktheme.icon-service-store-invalidator";

MTIconServiceStoreInvalidatorObservation
    MTIconServiceStoreInvalidatorRuntimeObservation = {
        .schemaVersion = 1,
        .installed = ATOMIC_VAR_INIT(0),
        .capturedServices = ATOMIC_VAR_INIT(0),
        .recordedMappings = ATOMIC_VAR_INIT(0),
        .transactions = ATOMIC_VAR_INIT(0),
        .verifiedTransactions = ATOMIC_VAR_INIT(0),
        .broadFallbacks = ATOMIC_VAR_INIT(0),
        .removedMappings = ATOMIC_VAR_INIT(0),
    };

_Static_assert(sizeof(MTIconServiceStoreInvalidatorObservation) == 56,
    "Icon service invalidator observation ABI changed");

static NSString *const MTIconServicesPath =
    @"/System/Library/PrivateFrameworks/IconServices.framework/IconServices";
static NSString *const MTIconServiceExecutablePath =
    @"/System/Library/CoreServices/iconservicesagent";
static const char *const MTServiceClassName = "IconCacheService";
static const char *const MTServiceSelectorName =
    "initWithServiceName:";
static const char *const MTServiceTypeEncoding = "@24@0:8@16";
static const char *const MTPerformSelectorName = "performBlock:";
static const char *const MTPerformTypeEncoding = "v24@0:8@?16";
static const char *const MTEnumerateSelectorName =
    "enumerateValuesForUUID:bock:";
static const char *const MTEnumerateTypeEncoding = "v32@0:8[16C]16@?24";
static const char *const MTRemoveSelectorName =
    "removeValueForUUID:passingTest:";
static const char *const MTRemoveTypeEncoding = "B32@0:8[16C]16@?24";

typedef id (*MTServiceInitializerFunction)(id, SEL, id);
typedef id (*MTObjectGetterFunction)(id, SEL);
typedef void (^MTIndexEnumerationBlock)(const void *, BOOL *);
typedef void (*MTIndexEnumerationFunction)(
    id, SEL, const uint8_t *, MTIndexEnumerationBlock);
typedef void (*MTPerformBlockFunction)(id, SEL, dispatch_block_t);
typedef BOOL (^MTRemovePredicateBlock)(const void *);
typedef BOOL (*MTRemoveFunction)(
    id, SEL, const uint8_t *, MTRemovePredicateBlock);

static MTServiceInitializerFunction MTOriginalServiceInitializer;
static __weak MTIconServiceStoreInvalidator *MTInstalledInvalidator;

@interface MTIconServiceStoreTarget : NSObject
@property(nonatomic, copy) NSString *bundleIdentifier;
@property(nonatomic, strong) NSUUID *iconDigest;
@property(nonatomic, strong) NSUUID *descriptorDigest;
@property(nonatomic, copy) NSData *descriptorDigestData;
@property(nonatomic, copy) NSString *mappingKey;
- (instancetype)initWithBundleIdentifier:(NSString *)bundleIdentifier
                               iconDigest:(NSUUID *)iconDigest
                         descriptorDigest:(NSUUID *)descriptorDigest;
@end

@implementation MTIconServiceStoreTarget

- (instancetype)initWithBundleIdentifier:(NSString *)bundleIdentifier
                               iconDigest:(NSUUID *)iconDigest
                         descriptorDigest:(NSUUID *)descriptorDigest {
    if (!MTStaticIconBundleIdentifierIsValid(bundleIdentifier) ||
        ![iconDigest isKindOfClass:NSUUID.class] ||
        ![descriptorDigest isKindOfClass:NSUUID.class]) {
        return nil;
    }
    self = [super init];
    if (self == nil) return nil;
    _bundleIdentifier = [bundleIdentifier copy];
    _iconDigest = iconDigest;
    _descriptorDigest = descriptorDigest;
    uint8_t descriptorBytes[16] = {0};
    [_descriptorDigest getUUIDBytes:descriptorBytes];
    _descriptorDigestData = [NSData dataWithBytes:descriptorBytes length:16];
    _mappingKey = [[NSString alloc] initWithFormat:@"%@|%@",
        _iconDigest.UUIDString, _descriptorDigest.UUIDString];
    return self;
}

@end

@interface MTIconServiceStoreInvalidationResult ()
@property(nonatomic, assign, readwrite, getter=isVerified) BOOL verified;
@property(nonatomic, assign, readwrite) BOOL requiresBroadFallback;
@property(nonatomic, assign, readwrite) NSUInteger bundleCount;
@property(nonatomic, assign, readwrite) NSUInteger digestCount;
@property(nonatomic, assign, readwrite) NSUInteger mappingCount;
@property(nonatomic, assign, readwrite) NSUInteger removedValueCount;
@property(nonatomic, copy, readwrite) NSString *outcome;
- (instancetype)initWithVerified:(BOOL)verified
           requiresBroadFallback:(BOOL)requiresBroadFallback
                      bundleCount:(NSUInteger)bundleCount
                      digestCount:(NSUInteger)digestCount
                     mappingCount:(NSUInteger)mappingCount
                removedValueCount:(NSUInteger)removedValueCount
                          outcome:(NSString *)outcome;
@end

@implementation MTIconServiceStoreInvalidationResult

- (instancetype)initWithVerified:(BOOL)verified
           requiresBroadFallback:(BOOL)requiresBroadFallback
                      bundleCount:(NSUInteger)bundleCount
                      digestCount:(NSUInteger)digestCount
                     mappingCount:(NSUInteger)mappingCount
                removedValueCount:(NSUInteger)removedValueCount
                          outcome:(NSString *)outcome {
    self = [super init];
    if (self == nil) return nil;
    _verified = verified;
    _requiresBroadFallback = requiresBroadFallback;
    _bundleCount = bundleCount;
    _digestCount = digestCount;
    _mappingCount = mappingCount;
    _removedValueCount = removedValueCount;
    _outcome = [outcome copy];
    return self;
}

@end

static BOOL MTIconServiceMethodMatches(Method method,
                                       const char *encoding,
                                       NSString *imagePath) {
    if (method == NULL || encoding == NULL || imagePath.length == 0) return NO;
    const char *actual = method_getTypeEncoding(method);
    IMP implementation = method_getImplementation(method);
    Dl_info info = {0};
    return actual != NULL && strcmp(actual, encoding) == 0 &&
        implementation != NULL &&
        dladdr((const void *)implementation, &info) != 0 &&
        info.dli_fname != NULL &&
        [[NSString stringWithUTF8String:info.dli_fname]
            isEqualToString:imagePath];
}

static id MTIconServiceObjectGetter(id object,
                                    const char *selectorName,
                                    NSString *imagePath) {
    if (object == nil || selectorName == NULL) return nil;
    SEL selector = sel_registerName(selectorName);
    Method method = class_getInstanceMethod(object_getClass(object), selector);
    if (!MTIconServiceMethodMatches(
            method, "@16@0:8", imagePath)) return nil;
    IMP implementation = method_getImplementation(method);
    return implementation == NULL ? nil :
        ((MTObjectGetterFunction)implementation)(object, selector);
}

static void MTIconServiceInvalidatorSetError(NSError **error,
                                              NSInteger code,
                                              NSString *description) {
    if (error == NULL) return;
    *error = [NSError errorWithDomain:MTIconServiceStoreInvalidatorErrorDomain
                                 code:code
                             userInfo:@{
        NSLocalizedDescriptionKey : description,
    }];
}

@interface MTIconServiceStoreInvalidator () {
    os_unfair_lock _lock;
}
@property(nonatomic, weak, nullable) id liveService;
@property(nonatomic, strong)
    NSMutableDictionary<NSString *,
        NSMutableDictionary<NSString *, MTIconServiceStoreTarget *> *>
            *targetsByBundle;
@property(nonatomic, strong) dispatch_queue_t completionQueue;
- (void)captureLiveService:(id)service;
- (void)recordGeneratedContext:(MTIconServiceRequestContext *)context;
- (BOOL)recordTargetForBundleIdentifier:(NSString *)bundleIdentifier
                              iconDigest:(NSUUID *)iconDigest
                        descriptorDigest:(NSUUID *)descriptorDigest;
- (void)forgetTargets:(NSArray<MTIconServiceStoreTarget *> *)targets;
- (void)invalidateBundleIdentifiers:(NSSet<NSString *> *)bundleIdentifiers
                 matchingIconDigest:(nullable NSUUID *)matchingIconDigest
           matchingDescriptorDigest:(nullable NSUUID *)matchingDescriptorDigest
                           coverage:(MTIconServiceDigestCoverage)coverage
                         completion:
    (MTIconServiceStoreInvalidationCompletion)completion;
@end

static id MTIconServiceHookedServiceInitializer(
    id self,
    SEL selector,
    id serviceName) {
    id result = MTOriginalServiceInitializer(self, selector, serviceName);
    if (result != nil) {
        [MTInstalledInvalidator captureLiveService:result];
    }
    return result;
}

void MTIconServiceStoreInvalidatorRecordGeneratedContext(
    MTIconServiceRequestContext *context) {
    [MTInstalledInvalidator recordGeneratedContext:context];
}

@implementation MTIconServiceStoreInvalidator

- (instancetype)init {
    self = [super init];
    if (self == nil) return nil;
    _lock = OS_UNFAIR_LOCK_INIT;
    _targetsByBundle = [NSMutableDictionary dictionary];
    _completionQueue = dispatch_queue_create(
        "com.hmmzzz.marktheme.icon-service-invalidation-completion",
        DISPATCH_QUEUE_SERIAL);
    return self;
}

- (BOOL)installWithError:(NSError **)error {
    if (error != NULL) *error = nil;
    if (MTInstalledInvalidator != nil) {
        MTIconServiceInvalidatorSetError(error, 1,
            @"Icon service lifecycle Hook is already installed.");
        return NO;
    }
    if (!MTIconServiceABIValidateRuntime(NULL, error)) return NO;
    Class serviceClass = objc_getClass(MTServiceClassName);
    SEL selector = sel_registerName(MTServiceSelectorName);
    Method method = serviceClass == Nil ? NULL :
        class_getInstanceMethod(serviceClass, selector);
    if (!MTIconServiceMethodMatches(
            method, MTServiceTypeEncoding, MTIconServiceExecutablePath)) {
        MTIconServiceInvalidatorSetError(error, 2,
            @"IconCacheService initializer ABI changed.");
        return NO;
    }
    MTInstalledInvalidator = self;
    MTOriginalServiceInitializer = NULL;
    MSHookMessageEx(serviceClass, selector,
        (IMP)MTIconServiceHookedServiceInitializer,
        (IMP *)&MTOriginalServiceInitializer);
    if (MTOriginalServiceInitializer == NULL) {
        MTInstalledInvalidator = nil;
        MTIconServiceInvalidatorSetError(error, 3,
            @"Hook backend did not return the service initializer IMP.");
        return NO;
    }
    atomic_store_explicit(
        &MTIconServiceStoreInvalidatorRuntimeObservation.installed,
        1, memory_order_release);
    return YES;
}

- (void)captureLiveService:(id)service {
    if (service == nil) return;
    os_unfair_lock_lock(&_lock);
    self.liveService = service;
    os_unfair_lock_unlock(&_lock);
    atomic_fetch_add_explicit(
        &MTIconServiceStoreInvalidatorRuntimeObservation.capturedServices,
        1, memory_order_relaxed);
}

- (void)recordGeneratedContext:(MTIconServiceRequestContext *)context {
    if (context == nil) return;
    [self recordTargetForBundleIdentifier:context.bundleIdentifier
                               iconDigest:context.iconDigest
                         descriptorDigest:context.descriptorDigest];
}

- (BOOL)recordTargetForBundleIdentifier:(NSString *)bundleIdentifier
                              iconDigest:(NSUUID *)iconDigest
                        descriptorDigest:(NSUUID *)descriptorDigest {
    @try {
        MTIconServiceStoreTarget *target =
            [[MTIconServiceStoreTarget alloc]
                initWithBundleIdentifier:bundleIdentifier
                               iconDigest:iconDigest
                         descriptorDigest:descriptorDigest];
        if (target == nil) return NO;
        BOOL inserted = NO;
        os_unfair_lock_lock(&_lock);
        @try {
            NSMutableDictionary<NSString *, MTIconServiceStoreTarget *>
                *targets = self.targetsByBundle[target.bundleIdentifier];
            if (targets == nil) {
                targets = [NSMutableDictionary dictionary];
                self.targetsByBundle[target.bundleIdentifier] = targets;
            }
            inserted = targets[target.mappingKey] == nil;
            targets[target.mappingKey] = target;
        } @finally {
            os_unfair_lock_unlock(&_lock);
        }
        if (inserted) {
            atomic_fetch_add_explicit(
                &MTIconServiceStoreInvalidatorRuntimeObservation
                    .recordedMappings,
                1, memory_order_relaxed);
        }
        return YES;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

- (NSDictionary<NSString *, NSSet<NSUUID *> *> *)observedDigestsByBundle {
    os_unfair_lock_lock(&_lock);
    NSMutableDictionary<NSString *, NSSet<NSUUID *> *> *copy = nil;
    @try {
        copy = [NSMutableDictionary
            dictionaryWithCapacity:self.targetsByBundle.count];
        [self.targetsByBundle enumerateKeysAndObjectsUsingBlock:
            ^(NSString *bundle,
              NSMutableDictionary<NSString *, MTIconServiceStoreTarget *>
                  *targets,
              BOOL *stop) {
                (void)stop;
                NSMutableSet<NSUUID *> *digests = [NSMutableSet set];
                for (MTIconServiceStoreTarget *target in targets.allValues) {
                    [digests addObject:target.iconDigest];
                }
                copy[bundle] = [digests copy];
            }];
    } @finally {
        os_unfair_lock_unlock(&_lock);
    }
    return [copy copy];
}

- (void)forgetTargets:(NSArray<MTIconServiceStoreTarget *> *)targets {
    if (targets.count == 0) return;
    os_unfair_lock_lock(&_lock);
    @try {
        for (MTIconServiceStoreTarget *target in targets) {
            NSMutableDictionary<NSString *, MTIconServiceStoreTarget *>
                *bundleTargets = self.targetsByBundle[target.bundleIdentifier];
            [bundleTargets removeObjectForKey:target.mappingKey];
            if (bundleTargets.count == 0) {
                [self.targetsByBundle
                    removeObjectForKey:target.bundleIdentifier];
            }
        }
    } @finally {
        os_unfair_lock_unlock(&_lock);
    }
}

- (void)finishWithVerified:(BOOL)verified
      requiresBroadFallback:(BOOL)requiresBroadFallback
                 bundleCount:(NSUInteger)bundleCount
                 digestCount:(NSUInteger)digestCount
                mappingCount:(NSUInteger)mappingCount
           removedValueCount:(NSUInteger)removedValueCount
                     outcome:(NSString *)outcome
                  completion:
    (MTIconServiceStoreInvalidationCompletion)completion {
    MTIconServiceStoreInvalidationResult *result =
        [[MTIconServiceStoreInvalidationResult alloc]
            initWithVerified:verified
            requiresBroadFallback:requiresBroadFallback
            bundleCount:bundleCount
            digestCount:digestCount
            mappingCount:mappingCount
            removedValueCount:removedValueCount
            outcome:outcome];
    if (verified) {
        atomic_fetch_add_explicit(
            &MTIconServiceStoreInvalidatorRuntimeObservation
                .verifiedTransactions,
            1, memory_order_relaxed);
        atomic_fetch_add_explicit(
            &MTIconServiceStoreInvalidatorRuntimeObservation.removedMappings,
            removedValueCount, memory_order_relaxed);
    } else if (requiresBroadFallback) {
        atomic_fetch_add_explicit(
            &MTIconServiceStoreInvalidatorRuntimeObservation.broadFallbacks,
            1, memory_order_relaxed);
    }
    dispatch_async(self.completionQueue, ^{
        completion(result);
    });
}

static BOOL MTIconServiceReadStoreIndexValue(
    const void *rawValue,
    MTIconServiceStoreIndexValue *valueOut) {
    return MTIconServiceStoreIndexReadValue(
        rawValue, MTIconServiceStoreIndexValueByteCount, valueOut);
}

static BOOL MTIconServiceTargetDescriptorMatchesValue(
    MTIconServiceStoreTarget *target,
    const void *rawValue) {
    MTIconServiceStoreIndexValue value = {0};
    return target != nil &&
        MTIconServiceReadStoreIndexValue(rawValue, &value) &&
        memcmp(value.descriptorDigest,
               target.descriptorDigestData.bytes, 16) == 0;
}

static NSData *MTIconServiceStoreUnitUUIDDataForValue(
    const void *rawValue) {
    MTIconServiceStoreIndexValue value = {0};
    return MTIconServiceReadStoreIndexValue(rawValue, &value)
        ? [NSData dataWithBytes:value.storeUnitUUID length:16]
        : nil;
}

static BOOL MTIconServiceTargetMatchesExactValue(
    MTIconServiceStoreTarget *target,
    NSData *storeUnitUUIDData,
    const void *rawValue) {
    MTIconServiceStoreIndexValue value = {0};
    return target != nil && storeUnitUUIDData.length == 16 &&
        MTIconServiceReadStoreIndexValue(rawValue, &value) &&
        MTIconServiceStoreIndexValueMatches(
            &value, target.descriptorDigestData.bytes,
            storeUnitUUIDData.bytes);
}

static NSUInteger MTIconServiceExactMatchingTargetCount(
    NSArray<MTIconServiceStoreTarget *> *targets,
    NSDictionary<NSString *, NSData *> *storeUnitUUIDs,
    const void *rawValue) {
    NSUInteger count = 0;
    for (MTIconServiceStoreTarget *target in targets) {
        if (MTIconServiceTargetMatchesExactValue(
                target, storeUnitUUIDs[target.mappingKey], rawValue)) {
            count += 1;
        }
    }
    return count;
}

- (void)invalidateBundleIdentifiers:(NSSet<NSString *> *)bundleIdentifiers
                           coverage:(MTIconServiceDigestCoverage)coverage
                         completion:
    (MTIconServiceStoreInvalidationCompletion)completion {
    [self invalidateBundleIdentifiers:bundleIdentifiers
                   matchingIconDigest:nil
             matchingDescriptorDigest:nil
                             coverage:coverage
                           completion:completion];
}

- (void)invalidateObservedMappingsForBundleIdentifier:
    (NSString *)bundleIdentifier
                                             iconDigest:(NSUUID *)iconDigest
                                       descriptorDigest:
    (NSUUID *)descriptorDigest
                                              completion:
    (MTIconServiceStoreInvalidationCompletion)completion {
    if (completion == nil) return;
    if (!MTStaticIconBundleIdentifierIsValid(bundleIdentifier) ||
        ![iconDigest isKindOfClass:NSUUID.class] ||
        ![descriptorDigest isKindOfClass:NSUUID.class]) {
        [self finishWithVerified:NO requiresBroadFallback:YES
            bundleCount:bundleIdentifier.length > 0 ? 1 : 0
            digestCount:0 mappingCount:0 removedValueCount:0
            outcome:@"exact-request-identity-invalid" completion:completion];
        return;
    }
    if (![self recordTargetForBundleIdentifier:bundleIdentifier
                                    iconDigest:iconDigest
                              descriptorDigest:descriptorDigest]) {
        [self finishWithVerified:NO requiresBroadFallback:YES
            bundleCount:1 digestCount:1 mappingCount:0 removedValueCount:0
            outcome:@"exact-request-target-rejected" completion:completion];
        return;
    }
    [self invalidateBundleIdentifiers:
            [NSSet setWithObject:bundleIdentifier]
                   matchingIconDigest:iconDigest
             matchingDescriptorDigest:descriptorDigest
                             coverage:
                                 MTIconServiceDigestCoverageAuthoritative
                           completion:completion];
}

- (void)invalidateBundleIdentifiers:(NSSet<NSString *> *)bundleIdentifiers
                 matchingIconDigest:(NSUUID *)matchingIconDigest
           matchingDescriptorDigest:(NSUUID *)matchingDescriptorDigest
                           coverage:(MTIconServiceDigestCoverage)coverage
                         completion:
    (MTIconServiceStoreInvalidationCompletion)completion {
    if (completion == nil) return;
    atomic_fetch_add_explicit(
        &MTIconServiceStoreInvalidatorRuntimeObservation.transactions,
        1, memory_order_relaxed);
    NSArray<NSString *> *bundles = [[bundleIdentifiers allObjects]
        sortedArrayUsingSelector:@selector(compare:)];
    BOOL bundleSetValid = YES;
    for (NSString *bundle in bundles) {
        if (!MTStaticIconBundleIdentifierIsValid(bundle)) {
            bundleSetValid = NO;
            break;
        }
    }
    if (coverage != MTIconServiceDigestCoverageAuthoritative ||
        bundles.count == 0 || !bundleSetValid) {
        [self finishWithVerified:NO requiresBroadFallback:YES
            bundleCount:bundles.count digestCount:0 mappingCount:0
            removedValueCount:0
            outcome:@"coverage-incomplete" completion:completion];
        return;
    }

    NSMutableArray<MTIconServiceStoreTarget *> *selectedTargets =
        [NSMutableArray array];
    __block id service = nil;
    __block BOOL complete = NO;
    @try {
        os_unfair_lock_lock(&_lock);
        @try {
            service = self.liveService;
            complete = service != nil;
            for (NSString *bundle in bundles) {
                NSDictionary<NSString *, MTIconServiceStoreTarget *>
                    *bundleTargets = self.targetsByBundle[bundle];
                if (bundleTargets.count == 0) {
                    complete = NO;
                    break;
                }
                NSUInteger beforeCount = selectedTargets.count;
                for (MTIconServiceStoreTarget *target in
                        bundleTargets.allValues) {
                    if (matchingIconDigest != nil &&
                        ![target.iconDigest isEqual:matchingIconDigest]) {
                        continue;
                    }
                    if (matchingDescriptorDigest != nil &&
                        ![target.descriptorDigest
                            isEqual:matchingDescriptorDigest]) {
                        continue;
                    }
                    [selectedTargets addObject:target];
                }
                if (selectedTargets.count == beforeCount) {
                    complete = NO;
                    break;
                }
            }
        } @finally {
            os_unfair_lock_unlock(&_lock);
        }
    } @catch (__unused NSException *exception) {
        complete = NO;
    }
    [selectedTargets sortUsingComparator:
        ^NSComparisonResult(MTIconServiceStoreTarget *left,
                            MTIconServiceStoreTarget *right) {
            return [left.mappingKey compare:right.mappingKey];
        }];
    NSMutableDictionary<NSString *,
        NSMutableArray<MTIconServiceStoreTarget *> *> *targetsByDigest =
            [NSMutableDictionary dictionary];
    for (MTIconServiceStoreTarget *target in selectedTargets) {
        NSString *digestKey = target.iconDigest.UUIDString.uppercaseString;
        NSMutableArray<MTIconServiceStoreTarget *> *digestTargets =
            targetsByDigest[digestKey];
        if (digestTargets == nil) {
            digestTargets = [NSMutableArray array];
            targetsByDigest[digestKey] = digestTargets;
        }
        BOOL alreadyPresent = NO;
        for (MTIconServiceStoreTarget *existing in digestTargets) {
            if ([existing.mappingKey isEqualToString:target.mappingKey]) {
                alreadyPresent = YES;
                break;
            }
        }
        if (!alreadyPresent) [digestTargets addObject:target];
    }
    NSArray<NSString *> *digestKeys = [targetsByDigest.allKeys
        sortedArrayUsingSelector:@selector(compare:)];
    if (!complete || selectedTargets.count == 0 || digestKeys.count == 0) {
        [self finishWithVerified:NO requiresBroadFallback:YES
            bundleCount:bundles.count digestCount:digestKeys.count
            mappingCount:selectedTargets.count removedValueCount:0
            outcome:@"observed-mapping-set-incomplete"
            completion:completion];
        return;
    }

    id cache = MTIconServiceObjectGetter(
        service, "iconCache", MTIconServiceExecutablePath);
    id index = MTIconServiceObjectGetter(
        cache, "mutableStoreIndex", MTIconServiceExecutablePath);
    SEL performSelector = sel_registerName(MTPerformSelectorName);
    SEL enumerateSelector = sel_registerName(MTEnumerateSelectorName);
    SEL removeSelector = sel_registerName(MTRemoveSelectorName);
    Method performMethod = class_getInstanceMethod(
        object_getClass(index), performSelector);
    Method enumerateMethod = class_getInstanceMethod(
        object_getClass(index), enumerateSelector);
    Method removeMethod = class_getInstanceMethod(
        object_getClass(index), removeSelector);
    if (index == nil ||
        !MTIconServiceMethodMatches(
            performMethod, MTPerformTypeEncoding, MTIconServicesPath) ||
        !MTIconServiceMethodMatches(
            enumerateMethod, MTEnumerateTypeEncoding, MTIconServicesPath) ||
        !MTIconServiceMethodMatches(
            removeMethod, MTRemoveTypeEncoding, MTIconServicesPath)) {
        [self finishWithVerified:NO requiresBroadFallback:YES
            bundleCount:bundles.count digestCount:digestKeys.count
            mappingCount:selectedTargets.count removedValueCount:0
            outcome:@"mutable-index-abi-mismatch"
            completion:completion];
        return;
    }

    MTPerformBlockFunction perform =
        (MTPerformBlockFunction)method_getImplementation(performMethod);
    MTIndexEnumerationFunction enumerate =
        (MTIndexEnumerationFunction)method_getImplementation(enumerateMethod);
    MTRemoveFunction remove =
        (MTRemoveFunction)method_getImplementation(removeMethod);
    dispatch_block_t operation = ^{
        @autoreleasepool {
            NSUInteger removedValues = 0;
            BOOL verified = YES;
            @try {
                for (NSString *digestKey in digestKeys) {
                    NSArray<MTIconServiceStoreTarget *> *digestTargets =
                        targetsByDigest[digestKey];
                    NSUUID *digest = [[NSUUID alloc]
                        initWithUUIDString:digestKey];
                    if (digest == nil || digestTargets.count == 0) {
                        verified = NO;
                        break;
                    }
                    uint8_t bytes[16] = {0};
                    [digest getUUIDBytes:bytes];
                    __block NSUInteger beforeCount = 0;
                    __block NSUInteger eligibleBefore = 0;
                    NSMutableDictionary<NSString *, NSNumber *>
                        *matchCounts = [NSMutableDictionary dictionary];
                    NSMutableDictionary<NSString *, NSData *>
                        *storeUnitUUIDs = [NSMutableDictionary dictionary];
                    for (MTIconServiceStoreTarget *target in digestTargets) {
                        matchCounts[target.mappingKey] = @0;
                    }
                    enumerate(index, enumerateSelector, bytes,
                        ^(const void *value, BOOL *stop) {
                            (void)stop;
                            beforeCount += 1;
                            for (MTIconServiceStoreTarget *target in
                                    digestTargets) {
                                if (!MTIconServiceTargetDescriptorMatchesValue(
                                        target, value)) {
                                    continue;
                                }
                                NSUInteger count =
                                    [matchCounts[target.mappingKey]
                                        unsignedIntegerValue] + 1;
                                matchCounts[target.mappingKey] = @(count);
                                if (count == 1) {
                                    NSData *storeUnitUUID =
                                        MTIconServiceStoreUnitUUIDDataForValue(
                                            value);
                                    if (storeUnitUUID.length == 16) {
                                        storeUnitUUIDs[target.mappingKey] =
                                            storeUnitUUID;
                                    }
                                }
                                eligibleBefore += 1;
                            }
                        });
                    BOOL ambiguousBefore = NO;
                    for (NSString *mappingKey in matchCounts) {
                        NSUInteger count =
                            matchCounts[mappingKey].unsignedIntegerValue;
                        if (count > 1 ||
                            (count == 1 &&
                             storeUnitUUIDs[mappingKey].length != 16)) {
                            ambiguousBefore = YES;
                            break;
                        }
                    }
                    if (ambiguousBefore) {
                        verified = NO;
                        break;
                    }
                    if (eligibleBefore == 0) continue;
                    __block NSUInteger predicateCalls = 0;
                    __block NSUInteger predicateMatches = 0;
                    BOOL removed = remove(index, removeSelector, bytes,
                        ^BOOL(const void *value) {
                            predicateCalls += 1;
                            BOOL matches =
                                MTIconServiceExactMatchingTargetCount(
                                    digestTargets, storeUnitUUIDs, value) == 1;
                            if (matches) predicateMatches += 1;
                            return matches;
                        });
                    __block NSUInteger afterCount = 0;
                    __block NSUInteger eligibleAfter = 0;
                    enumerate(index, enumerateSelector, bytes,
                        ^(const void *value, BOOL *stop) {
                            (void)stop;
                            afterCount += 1;
                            eligibleAfter +=
                                MTIconServiceExactMatchingTargetCount(
                                    digestTargets, storeUnitUUIDs, value);
                        });
                    if (!removed || predicateCalls != beforeCount ||
                        predicateMatches != eligibleBefore ||
                        eligibleAfter != 0 ||
                        afterCount + eligibleBefore != beforeCount) {
                        verified = NO;
                        break;
                    }
                    removedValues += eligibleBefore;
                }
            } @catch (__unused NSException *exception) {
                verified = NO;
            }
            if (verified) [self forgetTargets:selectedTargets];
            [self finishWithVerified:verified
                requiresBroadFallback:!verified
                bundleCount:bundles.count digestCount:digestKeys.count
                mappingCount:selectedTargets.count
                removedValueCount:removedValues
                outcome:verified ? @"exact-store-index-mappings-invalidated"
                                 : @"exact-store-index-verification-failed"
            completion:completion];
        }
    };
    @try {
        perform(index, performSelector, operation);
    } @catch (__unused NSException *exception) {
        [self finishWithVerified:NO requiresBroadFallback:YES
            bundleCount:bundles.count digestCount:digestKeys.count
            mappingCount:selectedTargets.count removedValueCount:0
            outcome:@"store-index-transaction-rejected"
            completion:completion];
    }
}

@end
