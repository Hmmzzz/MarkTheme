#import "MTIconServicesClientCacheInvalidation.h"

#import <objc/message.h>
#import <objc/runtime.h>
#import <os/lock.h>

#include <stddef.h>
#include <stdint.h>
#include <string.h>

#import "MTRuntimeImageABI.h"
#import "MTSpringBoardHomeABI.h"

static const char *const MTIconServicesImagePath =
    "/System/Library/PrivateFrameworks/"
    "IconServices.framework/IconServices";
static const char *const MTObjectGetterTypeEncoding = "@16@0:8";
static const char *const MTUnfairLockCompactTypeEncoding =
    "{os_unfair_lock_s=I}";
static const char *const MTUnfairLockNamedFieldTypeEncoding =
    "{os_unfair_lock_s=\"_os_unfair_lock_opaque\"I}";
static const NSUInteger MTMaximumRegisteredIconCount = 4096;
static const NSUInteger MTMaximumDescriptorBagCount = 65536;

typedef NS_OPTIONS(uint32_t, MTIconServicesClientCacheABIChecks) {
    MTIconServicesClientCacheABICheckManagerClass = 1u << 0,
    MTIconServicesClientCacheABICheckConcreteIconClass = 1u << 1,
    MTIconServicesClientCacheABICheckImageCacheClass = 1u << 2,
    MTIconServicesClientCacheABICheckSharedInstance = 1u << 3,
    MTIconServicesClientCacheABICheckIconRegistry = 1u << 4,
    MTIconServicesClientCacheABICheckImageCache = 1u << 5,
    MTIconServicesClientCacheABICheckManagerLock = 1u << 6,
    MTIconServicesClientCacheABICheckRegistryIvar = 1u << 7,
    MTIconServicesClientCacheABICheckImageCacheLock = 1u << 8,
    MTIconServicesClientCacheABICheckDescriptorBagsIvar = 1u << 9,
};

typedef id (*MTObjectGetterFunction)(id, SEL);

static BOOL MTMethodMatches(Class runtimeClass,
                            SEL selector,
                            BOOL classMethod) {
    Method method = classMethod
        ? class_getClassMethod(runtimeClass, selector)
        : class_getInstanceMethod(runtimeClass, selector);
    const char *encoding = method == NULL
        ? NULL : method_getTypeEncoding(method);
    return encoding != NULL &&
        strcmp(encoding, MTObjectGetterTypeEncoding) == 0 &&
        MTRuntimeImplementationResolves(method_getImplementation(method));
}

static BOOL MTIvarBoundsMatch(Ivar ivar,
                              size_t valueSize,
                              Class instanceClass) {
    if (ivar == NULL || instanceClass == Nil) {
        return NO;
    }
    ptrdiff_t offset = ivar_getOffset(ivar);
    size_t instanceSize = class_getInstanceSize(instanceClass);
    return offset >= (ptrdiff_t)sizeof(void *) &&
        (size_t)offset <= instanceSize &&
        valueSize <= instanceSize - (size_t)offset;
}

static BOOL MTUnfairLockIvarMatches(Ivar ivar, Class instanceClass) {
    const char *actual = ivar == NULL ? NULL : ivar_getTypeEncoding(ivar);
    BOOL encodingMatches = actual != NULL &&
        (strcmp(actual, MTUnfairLockCompactTypeEncoding) == 0 ||
         strcmp(actual, MTUnfairLockNamedFieldTypeEncoding) == 0);
    return encodingMatches &&
        MTIvarBoundsMatch(ivar, sizeof(os_unfair_lock), instanceClass);
}

static BOOL MTObjectIvarMatches(Ivar ivar, Class instanceClass) {
    const char *actual = ivar == NULL ? NULL : ivar_getTypeEncoding(ivar);
    if (actual == NULL || actual[0] != '@') return NO;
    // The Objective-C runtime may retain the declared class name in an object
    // ivar encoding (for example @"NSHashTable"). Both that form and bare @
    // describe the same strong object-pointer storage; reject blocks (@?).
    BOOL objectEncoding = actual[1] == '\0' ||
        (actual[1] == '"' && actual[strlen(actual) - 1] == '"');
    return objectEncoding &&
        MTIvarBoundsMatch(ivar, sizeof(id), instanceClass);
}

static os_unfair_lock *MTLockForObject(id object, Ivar lockIvar) {
    uintptr_t base = (uintptr_t)(__bridge void *)object;
    return (os_unfair_lock *)(base + (uintptr_t)ivar_getOffset(lockIvar));
}

BOOL MTIconServicesInvalidateClientImageCaches(
    MTIconServicesClientCacheInvalidationResult *result) {
    MTIconServicesClientCacheInvalidationResult local = {0};
    Class managerClass = objc_getClass("ISIconManager");
    if (managerClass == Nil) {
        if (result != NULL) *result = local;
        return YES;
    }
    local.iconServicesLoaded = YES;

    Class concreteIconClass = objc_getClass("ISConcreteIcon");
    Class imageCacheClass = objc_getClass("ISImageCache");
    BOOL managerClassMatches = MTRuntimeClassMatchesImagePath(
        managerClass, MTIconServicesImagePath);
    BOOL concreteIconClassMatches = concreteIconClass != Nil &&
        MTRuntimeClassMatchesImagePath(
            concreteIconClass, MTIconServicesImagePath);
    BOOL imageCacheClassMatches = imageCacheClass != Nil &&
        MTRuntimeClassMatchesImagePath(
            imageCacheClass, MTIconServicesImagePath);
    if (managerClassMatches) {
        local.abiChecks |= MTIconServicesClientCacheABICheckManagerClass;
    }
    if (concreteIconClassMatches) {
        local.abiChecks |=
            MTIconServicesClientCacheABICheckConcreteIconClass;
    }
    if (imageCacheClassMatches) {
        local.abiChecks |= MTIconServicesClientCacheABICheckImageCacheClass;
    }
    if (!managerClassMatches || !concreteIconClassMatches ||
        !imageCacheClassMatches) {
        local.outcome =
            MTIconServicesClientCacheInvalidationOutcomeClassABIRejected;
        if (result != NULL) *result = local;
        return NO;
    }

    SEL sharedSelector = sel_registerName("sharedInstance");
    SEL registrySelector = sel_registerName("iconRegistry");
    SEL imageCacheSelector = sel_registerName("imageCache");
    BOOL sharedMethodMatches =
        MTMethodMatches(managerClass, sharedSelector, YES);
    BOOL registryMethodMatches =
        MTMethodMatches(managerClass, registrySelector, NO);
    BOOL imageCacheMethodMatches =
        MTMethodMatches(concreteIconClass, imageCacheSelector, NO);
    if (sharedMethodMatches) {
        local.abiChecks |= MTIconServicesClientCacheABICheckSharedInstance;
    }
    if (registryMethodMatches) {
        local.abiChecks |= MTIconServicesClientCacheABICheckIconRegistry;
    }
    if (imageCacheMethodMatches) {
        local.abiChecks |= MTIconServicesClientCacheABICheckImageCache;
    }
    if (!sharedMethodMatches || !registryMethodMatches ||
        !imageCacheMethodMatches) {
        local.outcome =
            MTIconServicesClientCacheInvalidationOutcomeMethodABIRejected;
        if (result != NULL) *result = local;
        return NO;
    }

    Ivar managerLockIvar = class_getInstanceVariable(managerClass, "_lock");
    Ivar registryIvar = class_getInstanceVariable(
        managerClass, "_iconRegistry");
    Ivar imageCacheLockIvar = class_getInstanceVariable(
        imageCacheClass, "_lock");
    Ivar descriptorBagsIvar = class_getInstanceVariable(
        imageCacheClass, "_imageBagsByDescriptor");
    BOOL managerLockMatches =
        MTUnfairLockIvarMatches(managerLockIvar, managerClass);
    BOOL registryIvarMatches =
        MTObjectIvarMatches(registryIvar, managerClass);
    BOOL imageCacheLockMatches =
        MTUnfairLockIvarMatches(imageCacheLockIvar, imageCacheClass);
    BOOL descriptorBagsIvarMatches =
        MTObjectIvarMatches(descriptorBagsIvar, imageCacheClass);
    if (managerLockMatches) {
        local.abiChecks |= MTIconServicesClientCacheABICheckManagerLock;
    }
    if (registryIvarMatches) {
        local.abiChecks |= MTIconServicesClientCacheABICheckRegistryIvar;
    }
    if (imageCacheLockMatches) {
        local.abiChecks |= MTIconServicesClientCacheABICheckImageCacheLock;
    }
    if (descriptorBagsIvarMatches) {
        local.abiChecks |=
            MTIconServicesClientCacheABICheckDescriptorBagsIvar;
    }
    if (!managerLockMatches || !registryIvarMatches ||
        !imageCacheLockMatches || !descriptorBagsIvarMatches) {
        local.outcome =
            MTIconServicesClientCacheInvalidationOutcomeIvarABIRejected;
        if (result != NULL) *result = local;
        return NO;
    }

    id manager = ((MTObjectGetterFunction)objc_msgSend)(
        managerClass, sharedSelector);
    if (!MTRuntimeClassIsSubclassOfClass(
            object_getClass(manager), managerClass)) {
        local.outcome =
            MTIconServicesClientCacheInvalidationOutcomeManagerRejected;
        if (result != NULL) *result = local;
        return NO;
    }

    __block NSArray *registeredIcons = nil;
    __block BOOL registryValid = YES;
    os_unfair_lock *managerLock = MTLockForObject(manager, managerLockIvar);
    BOOL managerLocked = NO;
    @try {
        os_unfair_lock_lock(managerLock);
        managerLocked = YES;
        id registry = object_getIvar(manager, registryIvar);
        if (registry == nil ||
            ![registry respondsToSelector:@selector(allObjects)] ||
            ![registry respondsToSelector:@selector(removeAllObjects)]) {
            registryValid = NO;
        } else {
            id objects = [registry allObjects];
            if (![objects isKindOfClass:NSArray.class] ||
                [(NSArray *)objects count] > MTMaximumRegisteredIconCount) {
                registryValid = NO;
            } else {
                registeredIcons = [objects copy];
                [registry removeAllObjects];
            }
        }
    } @catch (__unused NSException *exception) {
        registryValid = NO;
    } @finally {
        if (managerLocked) os_unfair_lock_unlock(managerLock);
    }
    if (!registryValid || registeredIcons == nil) {
        local.outcome =
            MTIconServicesClientCacheInvalidationOutcomeRegistryRejected;
        if (result != NULL) *result = local;
        return NO;
    }

    local.registeredIcons = registeredIcons.count;
    local.registryEntriesRemoved = registeredIcons.count;
    NSHashTable *seenCaches = [[NSHashTable alloc]
        initWithOptions:NSPointerFunctionsStrongMemory |
                        NSPointerFunctionsObjectPointerPersonality
              capacity:registeredIcons.count];
    BOOL verified = YES;
    for (id icon in registeredIcons) {
        if (!MTRuntimeClassIsSubclassOfClass(
                object_getClass(icon), concreteIconClass)) {
            continue;
        }
        local.concreteIcons += 1;
        id cache = ((MTObjectGetterFunction)objc_msgSend)(
            icon, imageCacheSelector);
        if (!MTRuntimeClassIsSubclassOfClass(
                object_getClass(cache), imageCacheClass)) {
            verified = NO;
            continue;
        }
        if ([seenCaches containsObject:cache]) continue;
        [seenCaches addObject:cache];

        os_unfair_lock *cacheLock =
            MTLockForObject(cache, imageCacheLockIvar);
        __block BOOL cacheValid = YES;
        BOOL cacheLocked = NO;
        @try {
            os_unfair_lock_lock(cacheLock);
            cacheLocked = YES;
            id bags = object_getIvar(cache, descriptorBagsIvar);
            if (bags == nil ||
                ![bags respondsToSelector:@selector(count)] ||
                ![bags respondsToSelector:@selector(removeAllObjects)]) {
                cacheValid = NO;
            } else {
                NSUInteger bagCount = [bags count];
                if (bagCount > MTMaximumDescriptorBagCount) {
                    cacheValid = NO;
                } else {
                    [bags removeAllObjects];
                    local.descriptorBagsCleared += bagCount;
                }
            }
        } @catch (__unused NSException *exception) {
            cacheValid = NO;
        } @finally {
            if (cacheLocked) os_unfair_lock_unlock(cacheLock);
        }
        if (cacheValid) local.imageCachesCleared += 1;
        else verified = NO;
    }

    local.outcome = verified
        ? MTIconServicesClientCacheInvalidationOutcomeVerified
        : MTIconServicesClientCacheInvalidationOutcomeImageCacheRejected;
    if (result != NULL) *result = local;
    return verified;
}
