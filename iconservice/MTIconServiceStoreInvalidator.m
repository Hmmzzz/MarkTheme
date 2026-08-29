#import "MTIconServiceStoreInvalidator.h"

#import <CydiaSubstrate/CydiaSubstrate.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <os/lock.h>

#include <stdatomic.h>
#include <string.h>

#import "MTIconServiceABI.h"
#import "MTStaticIconConfiguration.h"

NSString *const MTIconServiceStoreInvalidatorErrorDomain =
    @"com.hmmzzz.marktheme.icon-service-store-invalidator";

static NSString *const MTIconServicesPath =
    @"/System/Library/PrivateFrameworks/IconServices.framework/IconServices";
static NSString *const MTIconServiceExecutablePath =
    @"/System/Library/CoreServices/iconservicesagent";
static const char *const MTServiceClassName = "IconCacheService";
static const char *const MTServiceSelectorName =
    "generateStoreUnitWithRequest:validationToken:";
static const char *const MTServiceTypeEncoding = "@32@0:8@16^@24";
static const char *const MTPerformSelectorName = "performBlock:";
static const char *const MTPerformTypeEncoding = "v24@0:8@?16";
static const char *const MTEnumerateSelectorName =
    "enumerateValuesForUUID:bock:";
static const char *const MTEnumerateTypeEncoding = "v32@0:8[16C]16@?24";
static const char *const MTRemoveSelectorName =
    "removeValueForUUID:passingTest:";
static const char *const MTRemoveTypeEncoding = "B32@0:8[16C]16@?24";

typedef id (*MTServiceGenerationFunction)(
    id, SEL, id, id __autoreleasing *_Nullable);
typedef id (*MTObjectGetterFunction)(id, SEL);
typedef void (^MTIndexEnumerationBlock)(const void *, BOOL *);
typedef void (*MTIndexEnumerationFunction)(
    id, SEL, const uint8_t *, MTIndexEnumerationBlock);
typedef void (*MTPerformBlockFunction)(id, SEL, dispatch_block_t);
typedef BOOL (^MTRemovePredicateBlock)(const void *);
typedef BOOL (*MTRemoveFunction)(
    id, SEL, const uint8_t *, MTRemovePredicateBlock);

static MTServiceGenerationFunction MTOriginalServiceGeneration;
static __weak MTIconServiceStoreInvalidator *MTInstalledInvalidator;

@interface MTIconServiceStoreInvalidationResult ()
@property(nonatomic, assign, readwrite, getter=isVerified) BOOL verified;
@property(nonatomic, assign, readwrite) BOOL requiresBroadFallback;
@property(nonatomic, assign, readwrite) NSUInteger bundleCount;
@property(nonatomic, assign, readwrite) NSUInteger digestCount;
@property(nonatomic, assign, readwrite) NSUInteger removedValueCount;
@property(nonatomic, copy, readwrite) NSString *outcome;
- (instancetype)initWithVerified:(BOOL)verified
           requiresBroadFallback:(BOOL)requiresBroadFallback
                      bundleCount:(NSUInteger)bundleCount
                      digestCount:(NSUInteger)digestCount
                removedValueCount:(NSUInteger)removedValueCount
                          outcome:(NSString *)outcome;
@end

@implementation MTIconServiceStoreInvalidationResult

- (instancetype)initWithVerified:(BOOL)verified
           requiresBroadFallback:(BOOL)requiresBroadFallback
                      bundleCount:(NSUInteger)bundleCount
                      digestCount:(NSUInteger)digestCount
                removedValueCount:(NSUInteger)removedValueCount
                          outcome:(NSString *)outcome {
    self = [super init];
    if (self == nil) return nil;
    _verified = verified;
    _requiresBroadFallback = requiresBroadFallback;
    _bundleCount = bundleCount;
    _digestCount = digestCount;
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

static id MTIconServiceObjectGetter(id object, const char *selectorName) {
    if (object == nil || selectorName == NULL) return nil;
    SEL selector = sel_registerName(selectorName);
    Method method = class_getInstanceMethod(object_getClass(object), selector);
    if (!MTIconServiceMethodMatches(
            method, "@16@0:8", MTIconServiceExecutablePath)) return nil;
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
@property(nonatomic, strong, nullable) id liveService;
@property(nonatomic, strong)
    NSMutableDictionary<NSString *, NSMutableSet<NSUUID *> *> *digestsByBundle;
@property(nonatomic, strong) dispatch_queue_t completionQueue;
- (void)recordCompletedRequest:(id)request service:(id)service;
@end

static id MTIconServiceHookedServiceGeneration(
    id self,
    SEL selector,
    id request,
    id __autoreleasing *validationTokenOut) {
    id result = MTOriginalServiceGeneration(
        self, selector, request, validationTokenOut);
    if (result != nil) {
        [MTInstalledInvalidator recordCompletedRequest:request service:self];
    }
    return result;
}

@implementation MTIconServiceStoreInvalidator

- (instancetype)init {
    self = [super init];
    if (self == nil) return nil;
    _lock = OS_UNFAIR_LOCK_INIT;
    _digestsByBundle = [NSMutableDictionary dictionary];
    _completionQueue = dispatch_queue_create(
        "com.hmmzzz.marktheme.icon-service-invalidation-completion",
        DISPATCH_QUEUE_SERIAL);
    return self;
}

- (BOOL)installWithError:(NSError **)error {
    if (error != NULL) *error = nil;
    if (MTInstalledInvalidator != nil) {
        MTIconServiceInvalidatorSetError(error, 1,
            @"Icon service control Hook is already installed.");
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
            @"IconCacheService generation ABI changed.");
        return NO;
    }
    MTInstalledInvalidator = self;
    MTOriginalServiceGeneration = NULL;
    MSHookMessageEx(serviceClass, selector,
        (IMP)MTIconServiceHookedServiceGeneration,
        (IMP *)&MTOriginalServiceGeneration);
    if (MTOriginalServiceGeneration == NULL) {
        MTInstalledInvalidator = nil;
        MTIconServiceInvalidatorSetError(error, 3,
            @"Hook backend did not return the service generation IMP.");
        return NO;
    }
    return YES;
}

- (void)recordCompletedRequest:(id)request service:(id)service {
    @try {
        MTIconServiceRequestContext *context =
            MTIconServiceABIContextForRequest(request, NULL);
        if (context == nil || service == nil) return;
        os_unfair_lock_lock(&_lock);
        @try {
            self.liveService = service;
            NSMutableSet<NSUUID *> *digests =
                self.digestsByBundle[context.bundleIdentifier];
            if (digests == nil) {
                digests = [NSMutableSet set];
                self.digestsByBundle[context.bundleIdentifier] = digests;
            }
            [digests addObject:context.iconDigest];
        } @finally {
            os_unfair_lock_unlock(&_lock);
        }
    } @catch (__unused NSException *exception) {
    }
}

- (NSDictionary<NSString *, NSSet<NSUUID *> *> *)observedDigestsByBundle {
    os_unfair_lock_lock(&_lock);
    NSMutableDictionary<NSString *, NSSet<NSUUID *> *> *copy = nil;
    @try {
        copy = [NSMutableDictionary
            dictionaryWithCapacity:self.digestsByBundle.count];
        [self.digestsByBundle enumerateKeysAndObjectsUsingBlock:
            ^(NSString *bundle, NSMutableSet<NSUUID *> *digests, BOOL *stop) {
                (void)stop;
                copy[bundle] = [digests copy];
            }];
    } @finally {
        os_unfair_lock_unlock(&_lock);
    }
    return [copy copy];
}

- (void)finishWithVerified:(BOOL)verified
      requiresBroadFallback:(BOOL)requiresBroadFallback
                 bundleCount:(NSUInteger)bundleCount
                 digestCount:(NSUInteger)digestCount
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
            removedValueCount:removedValueCount
            outcome:outcome];
    dispatch_async(self.completionQueue, ^{
        completion(result);
    });
}

- (void)invalidateBundleIdentifiers:(NSSet<NSString *> *)bundleIdentifiers
                           coverage:(MTIconServiceDigestCoverage)coverage
                         completion:
    (MTIconServiceStoreInvalidationCompletion)completion {
    if (completion == nil) return;
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
            bundleCount:bundles.count digestCount:0 removedValueCount:0
            outcome:@"coverage-incomplete" completion:completion];
        return;
    }

    NSMutableSet<NSUUID *> *uniqueDigests = [NSMutableSet set];
    __block id service = nil;
    __block BOOL complete = NO;
    @try {
        os_unfair_lock_lock(&_lock);
        @try {
            service = self.liveService;
            complete = service != nil;
            for (NSString *bundle in bundles) {
                NSSet<NSUUID *> *bundleDigests = self.digestsByBundle[bundle];
                if (bundleDigests.count == 0) {
                    complete = NO;
                    break;
                }
                [uniqueDigests unionSet:bundleDigests];
            }
        } @finally {
            os_unfair_lock_unlock(&_lock);
        }
    } @catch (__unused NSException *exception) {
        complete = NO;
    }
    NSArray<NSUUID *> *digests = [uniqueDigests.allObjects
        sortedArrayUsingComparator:
            ^NSComparisonResult(NSUUID *left, NSUUID *right) {
                return [left.UUIDString compare:right.UUIDString];
            }];
    if (!complete || digests.count == 0) {
        [self finishWithVerified:NO requiresBroadFallback:YES
            bundleCount:bundles.count digestCount:digests.count
            removedValueCount:0 outcome:@"observed-digest-set-incomplete"
            completion:completion];
        return;
    }

    id cache = MTIconServiceObjectGetter(service, "iconCache");
    id index = MTIconServiceObjectGetter(cache, "mutableStoreIndex");
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
            bundleCount:bundles.count digestCount:digests.count
            removedValueCount:0 outcome:@"mutable-index-abi-mismatch"
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
                for (NSUUID *digest in digests) {
                    uint8_t bytes[16] = {0};
                    [digest getUUIDBytes:bytes];
                    __block NSUInteger beforeCount = 0;
                    enumerate(index, enumerateSelector, bytes,
                        ^(const void *value, BOOL *stop) {
                            (void)value;
                            (void)stop;
                            beforeCount += 1;
                        });
                    if (beforeCount == 0) continue;
                    __block NSUInteger predicateCalls = 0;
                    BOOL removed = remove(index, removeSelector, bytes,
                        ^BOOL(const void *value) {
                            (void)value;
                            predicateCalls += 1;
                            return YES;
                        });
                    __block NSUInteger afterCount = 0;
                    enumerate(index, enumerateSelector, bytes,
                        ^(const void *value, BOOL *stop) {
                            (void)value;
                            (void)stop;
                            afterCount += 1;
                        });
                    if (!removed || predicateCalls != beforeCount ||
                        afterCount != 0) {
                        verified = NO;
                        break;
                    }
                    removedValues += beforeCount;
                }
            } @catch (__unused NSException *exception) {
                verified = NO;
            }
            [self finishWithVerified:verified
                requiresBroadFallback:!verified
                bundleCount:bundles.count digestCount:digests.count
                removedValueCount:removedValues
                outcome:verified ? @"targeted-store-index-invalidated"
                                 : @"targeted-store-index-verification-failed"
            completion:completion];
        }
    };
    @try {
        perform(index, performSelector, operation);
    } @catch (__unused NSException *exception) {
        [self finishWithVerified:NO requiresBroadFallback:YES
            bundleCount:bundles.count digestCount:digests.count
            removedValueCount:0 outcome:@"store-index-transaction-rejected"
            completion:completion];
    }
}

@end
