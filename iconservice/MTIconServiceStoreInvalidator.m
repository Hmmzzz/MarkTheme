#import "MTIconServiceStoreInvalidator.h"

#import <CydiaSubstrate/CydiaSubstrate.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <os/lock.h>

#include <stdatomic.h>
#include <string.h>

#import "MTIconServiceABI.h"

NSString *const MTIconServiceStoreInvalidatorErrorDomain =
    @"com.hmmzzz.marktheme.icon-service-store-invalidator";

MTIconServiceStoreInvalidatorObservation
    MTIconServiceStoreInvalidatorRuntimeObservation = {
        .schemaVersion = 2,
        .installed = ATOMIC_VAR_INIT(0),
        .capturedServices = ATOMIC_VAR_INIT(0),
        .transactions = ATOMIC_VAR_INIT(0),
        .verifiedTransactions = ATOMIC_VAR_INIT(0),
        .failedTransactions = ATOMIC_VAR_INIT(0),
    };

_Static_assert(sizeof(MTIconServiceStoreInvalidatorObservation) == 40,
    "Icon service invalidator observation ABI changed");

static NSString *const MTIconServiceExecutablePath =
    @"/System/Library/CoreServices/iconservicesagent";
static const char *const MTServiceClassName = "IconCacheService";
static const char *const MTServiceSelectorName = "initWithServiceName:";
static const char *const MTServiceTypeEncoding = "@24@0:8@16";
static const char *const MTScheduleSelectorName = "scheduleCacheOperation:";
static const char *const MTScheduleTypeEncoding = "v24@0:8Q16";
static const NSUInteger MTWholeCacheOperationType = 2;
static const NSTimeInterval MTWholeCacheOperationTimeout = 4.0;
static const char *const MTMutableIconCacheClassName = "ISMutableIconCache";
static const char *const MTClearOperationClassName = "ClearCacheOperation";
static const char *const MTClearOperationRunSelectorName = "run";
static const char *const MTClearOperationRunTypeEncoding = "v16@0:8";
static const char *const MTClearOperationTypeSelectorName = "operation";
static const char *const MTClearOperationTypeTypeEncoding = "Q16@0:8";
static const char *const MTClearOperationCacheSelectorName = "cache";
static const char *const MTClearOperationCacheTypeEncoding = "@16@0:8";

// This IMP is an Objective-C init-family method. Keep its ARC ownership ABI
// exact when forwarding through a C function pointer and from the Hook IMP.
typedef id (*MTServiceInitializerFunction)(
    __attribute__((ns_consumed)) id, SEL, id)
    __attribute__((ns_returns_retained));
typedef id (*MTObjectGetterFunction)(id, SEL);
typedef NSUInteger (*MTUnsignedIntegerGetterFunction)(id, SEL);
typedef void (*MTScheduleCacheOperationFunction)(id, SEL, NSUInteger);
typedef void (*MTClearOperationRunFunction)(id, SEL);

static MTServiceInitializerFunction MTOriginalServiceInitializer;
static MTClearOperationRunFunction MTOriginalClearOperationRun;
static __weak MTIconServiceStoreInvalidator *MTInstalledInvalidator;

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
    if (!MTIconServiceMethodMatches(method, "@16@0:8", imagePath)) return nil;
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

@interface MTIconServiceStoreInvalidationResult ()
@property(nonatomic, assign, readwrite, getter=isVerified) BOOL verified;
@property(nonatomic, copy, readwrite) NSString *outcome;
- (instancetype)initWithVerified:(BOOL)verified outcome:(NSString *)outcome;
@end

@implementation MTIconServiceStoreInvalidationResult

- (instancetype)initWithVerified:(BOOL)verified outcome:(NSString *)outcome {
    self = [super init];
    if (self == nil) return nil;
    _verified = verified;
    _outcome = [outcome copy];
    return self;
}

@end

@interface MTIconServiceStoreInvalidator () {
    os_unfair_lock _lock;
}
@property(nonatomic, weak, nullable) id liveService;
@property(nonatomic, strong) dispatch_queue_t completionQueue;
@property(nonatomic, strong, nullable) id pendingWholeStoreCache;
@property(nonatomic, strong, nullable) NSObject *pendingWholeStoreToken;
@property(nonatomic, copy, nullable)
    MTIconServiceStoreInvalidationCompletion pendingWholeStoreCompletion;
- (void)captureLiveService:(id)service;
- (void)completeNativeWholeStoreClearForCache:(id)cache;
- (void)failNativeWholeStoreClearForToken:(NSObject *)token
                                  outcome:(NSString *)outcome;
- (void)finishWithVerified:(BOOL)verified
                   outcome:(NSString *)outcome
                completion:
    (MTIconServiceStoreInvalidationCompletion)completion;
@end

static id MTIconServiceHookedServiceInitializer(
    __attribute__((ns_consumed)) id self,
    SEL selector,
    id serviceName) __attribute__((ns_returns_retained)) {
    id result = MTOriginalServiceInitializer(self, selector, serviceName);
    if (result != nil) {
        [MTInstalledInvalidator captureLiveService:result];
    }
    return result;
}

static void MTIconServiceHookedClearOperationRun(id self, SEL selector) {
    Method operationMethod = class_getInstanceMethod(
        object_getClass(self),
        sel_registerName(MTClearOperationTypeSelectorName));
    Method cacheMethod = class_getInstanceMethod(
        object_getClass(self),
        sel_registerName(MTClearOperationCacheSelectorName));
    NSUInteger operation = NSNotFound;
    id cache = nil;
    if (MTIconServiceMethodMatches(operationMethod,
            MTClearOperationTypeTypeEncoding,
            MTIconServiceExecutablePath) &&
        MTIconServiceMethodMatches(cacheMethod,
            MTClearOperationCacheTypeEncoding,
            MTIconServiceExecutablePath)) {
        operation = ((MTUnsignedIntegerGetterFunction)
            method_getImplementation(operationMethod))(
                self, method_getName(operationMethod));
        cache = ((MTObjectGetterFunction)
            method_getImplementation(cacheMethod))(
                self, method_getName(cacheMethod));
    }
    BOOL returnedNormally = NO;
    @try {
        MTOriginalClearOperationRun(self, selector);
        returnedNormally = YES;
    } @finally {
        if (returnedNormally && operation == MTWholeCacheOperationType &&
            cache != nil) {
            [MTInstalledInvalidator
                completeNativeWholeStoreClearForCache:cache];
        }
    }
}

@implementation MTIconServiceStoreInvalidator

- (instancetype)init {
    self = [super init];
    if (self == nil) return nil;
    _lock = OS_UNFAIR_LOCK_INIT;
    _completionQueue = dispatch_queue_create(
        "com.hmmzzz.marktheme.icon-service-invalidation-completion",
        DISPATCH_QUEUE_SERIAL);
    return self;
}

- (BOOL)installWithError:(NSError **)error {
    if (error != NULL) *error = nil;
    if (MTInstalledInvalidator != nil) {
        MTIconServiceInvalidatorSetError(error, 1,
            @"Icon service cache-control Hooks are already installed.");
        return NO;
    }
    if (!MTIconServiceABIValidateRuntime(NULL, error)) return NO;

    Class serviceClass = objc_getClass(MTServiceClassName);
    SEL serviceSelector = sel_registerName(MTServiceSelectorName);
    Method serviceMethod = serviceClass == Nil ? NULL :
        class_getInstanceMethod(serviceClass, serviceSelector);
    if (!MTIconServiceMethodMatches(
            serviceMethod, MTServiceTypeEncoding,
            MTIconServiceExecutablePath)) {
        MTIconServiceInvalidatorSetError(error, 2,
            @"IconCacheService initializer ABI changed.");
        return NO;
    }

    Class operationClass = objc_getClass(MTClearOperationClassName);
    SEL runSelector = sel_registerName(MTClearOperationRunSelectorName);
    Method runMethod = operationClass == Nil ? NULL :
        class_getInstanceMethod(operationClass, runSelector);
    Method operationMethod = operationClass == Nil ? NULL :
        class_getInstanceMethod(operationClass,
            sel_registerName(MTClearOperationTypeSelectorName));
    Method cacheMethod = operationClass == Nil ? NULL :
        class_getInstanceMethod(operationClass,
            sel_registerName(MTClearOperationCacheSelectorName));
    if (!MTIconServiceMethodMatches(runMethod,
            MTClearOperationRunTypeEncoding,
            MTIconServiceExecutablePath) ||
        !MTIconServiceMethodMatches(operationMethod,
            MTClearOperationTypeTypeEncoding,
            MTIconServiceExecutablePath) ||
        !MTIconServiceMethodMatches(cacheMethod,
            MTClearOperationCacheTypeEncoding,
            MTIconServiceExecutablePath)) {
        MTIconServiceInvalidatorSetError(error, 3,
            @"ClearCacheOperation ABI changed.");
        return NO;
    }

    MTInstalledInvalidator = self;
    MTOriginalClearOperationRun = NULL;
    MSHookMessageEx(operationClass, runSelector,
        (IMP)MTIconServiceHookedClearOperationRun,
        (IMP *)&MTOriginalClearOperationRun);
    if (MTOriginalClearOperationRun == NULL) {
        MTInstalledInvalidator = nil;
        MTIconServiceInvalidatorSetError(error, 4,
            @"Hook backend did not return the native clear-operation IMP.");
        return NO;
    }

    MTOriginalServiceInitializer = NULL;
    MSHookMessageEx(serviceClass, serviceSelector,
        (IMP)MTIconServiceHookedServiceInitializer,
        (IMP *)&MTOriginalServiceInitializer);
    if (MTOriginalServiceInitializer == NULL) {
        MTInstalledInvalidator = nil;
        MTIconServiceInvalidatorSetError(error, 5,
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

- (void)completeNativeWholeStoreClearForCache:(id)cache {
    if (cache == nil) return;
    MTIconServiceStoreInvalidationCompletion completion = nil;
    os_unfair_lock_lock(&_lock);
    @try {
        if (self.pendingWholeStoreCache == cache) {
            completion = self.pendingWholeStoreCompletion;
            self.pendingWholeStoreCache = nil;
            self.pendingWholeStoreToken = nil;
            self.pendingWholeStoreCompletion = nil;
        }
    } @finally {
        os_unfair_lock_unlock(&_lock);
    }
    if (completion == nil) return;
    [self finishWithVerified:YES
        outcome:@"native-whole-cache-cleared"
        completion:completion];
}

- (void)failNativeWholeStoreClearForToken:(NSObject *)token
                                  outcome:(NSString *)outcome {
    if (token == nil || outcome.length == 0) return;
    MTIconServiceStoreInvalidationCompletion completion = nil;
    os_unfair_lock_lock(&_lock);
    @try {
        if (self.pendingWholeStoreToken == token) {
            completion = self.pendingWholeStoreCompletion;
            self.pendingWholeStoreCache = nil;
            self.pendingWholeStoreToken = nil;
            self.pendingWholeStoreCompletion = nil;
        }
    } @finally {
        os_unfair_lock_unlock(&_lock);
    }
    if (completion == nil) return;
    [self finishWithVerified:NO outcome:outcome completion:completion];
}

- (void)finishWithVerified:(BOOL)verified
                   outcome:(NSString *)outcome
                completion:
    (MTIconServiceStoreInvalidationCompletion)completion {
    MTIconServiceStoreInvalidationResult *result =
        [[MTIconServiceStoreInvalidationResult alloc]
            initWithVerified:verified outcome:outcome];
    atomic_fetch_add_explicit(
        verified
            ? &MTIconServiceStoreInvalidatorRuntimeObservation
                  .verifiedTransactions
            : &MTIconServiceStoreInvalidatorRuntimeObservation
                  .failedTransactions,
        1, memory_order_relaxed);
    dispatch_async(self.completionQueue, ^{
        completion(result);
    });
}

- (void)invalidateWholeStoreWithCompletion:
    (MTIconServiceStoreInvalidationCompletion)completion {
    if (completion == nil) return;
    atomic_fetch_add_explicit(
        &MTIconServiceStoreInvalidatorRuntimeObservation.transactions,
        1, memory_order_relaxed);

    __block id service = nil;
    os_unfair_lock_lock(&_lock);
    @try {
        service = self.liveService;
    } @finally {
        os_unfair_lock_unlock(&_lock);
    }
    id cache = MTIconServiceObjectGetter(
        service, "iconCache", MTIconServiceExecutablePath);
    SEL scheduleSelector = sel_registerName(MTScheduleSelectorName);
    Method scheduleMethod = class_getInstanceMethod(
        object_getClass(service), scheduleSelector);
    if (service == nil || cache == nil ||
        ![cache isKindOfClass:
            objc_getClass(MTMutableIconCacheClassName)] ||
        !MTIconServiceMethodMatches(scheduleMethod,
            MTScheduleTypeEncoding, MTIconServiceExecutablePath)) {
        [self finishWithVerified:NO
            outcome:@"native-clear-abi-mismatch"
            completion:completion];
        return;
    }

    NSObject *token = [[NSObject alloc] init];
    BOOL accepted = NO;
    os_unfair_lock_lock(&_lock);
    @try {
        if (self.pendingWholeStoreCompletion == nil) {
            self.pendingWholeStoreCache = cache;
            self.pendingWholeStoreToken = token;
            self.pendingWholeStoreCompletion = completion;
            accepted = YES;
        }
    } @finally {
        os_unfair_lock_unlock(&_lock);
    }
    if (!accepted) {
        [self finishWithVerified:NO
            outcome:@"native-clear-transaction-busy"
            completion:completion];
        return;
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                       (int64_t)(MTWholeCacheOperationTimeout * NSEC_PER_SEC)),
        self.completionQueue, ^{
            [self failNativeWholeStoreClearForToken:token
                outcome:@"native-clear-completion-timeout"];
        });
    MTScheduleCacheOperationFunction schedule =
        (MTScheduleCacheOperationFunction)
            method_getImplementation(scheduleMethod);
    @try {
        schedule(service, scheduleSelector, MTWholeCacheOperationType);
    } @catch (__unused NSException *exception) {
        [self failNativeWholeStoreClearForToken:token
            outcome:@"native-clear-transaction-rejected"];
    }
}

@end
