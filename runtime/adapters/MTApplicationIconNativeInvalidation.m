#import "MTApplicationIconNativeInvalidation.h"

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

#include <string.h>

#import "MTRuntimeABIReport.h"
#import "MTIconServicesClientCacheInvalidation.h"
#import "MTStaticIconConfiguration.h"

static NSString *const MTNativeInvalidationAdapterID =
    @"application-icon.native-invalidation";
static NSString *const MTLaunchServicesIconChangedNotificationName =
    @"com.apple.LaunchServices.applicationIconChanged";
static NSString *const MTLaunchServicesBundleIdentifierKey =
    @"CFBundleIdentifier";

MTApplicationIconNativeInvalidationObservation
    MTRuntimeApplicationIconNativeInvalidationObservation = {
        .schemaVersion = 3,
        .reserved = 0,
        .requests = ATOMIC_VAR_INIT(0),
        .verifiedRequests = ATOMIC_VAR_INIT(0),
        .launchServicesSignals = ATOMIC_VAR_INIT(0),
        .notificationCacheClears = ATOMIC_VAR_INIT(0),
        .preferencesReloads = ATOMIC_VAR_INIT(0),
        .shareSheetCacheClears = ATOMIC_VAR_INIT(0),
        .shareSheetReloads = ATOMIC_VAR_INIT(0),
        .failures = ATOMIC_VAR_INIT(0),
        .clientCacheInvalidations = ATOMIC_VAR_INIT(0),
        .clientRegisteredIcons = ATOMIC_VAR_INIT(0),
        .clientRegistryEntriesRemoved = ATOMIC_VAR_INIT(0),
        .clientImageCachesCleared = ATOMIC_VAR_INIT(0),
        .clientDescriptorBagsCleared = ATOMIC_VAR_INIT(0),
        .shareSheetProvidersTracked = ATOMIC_VAR_INIT(0),
    };

_Static_assert(sizeof(MTApplicationIconNativeInvalidationObservation) == 120,
    "Native application-icon invalidation observation ABI changed");

static MTApplicationIconNativeInvalidationOwners MTConfiguredOwners;
static BOOL MTNativeInvalidationConfigured;

static NSHashTable *MTTrackedShareImageProviders(void) {
    static NSHashTable *providers;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        providers = [NSHashTable weakObjectsHashTable];
    });
    return providers;
}

void MTApplicationIconNativeInvalidationTrackShareImageProvider(id provider) {
    if (provider == nil) return;
    NSHashTable *providers = MTTrackedShareImageProviders();
    @synchronized (providers) {
        [providers addObject:provider];
    }
    atomic_fetch_add_explicit(
        &MTRuntimeApplicationIconNativeInvalidationObservation
             .shareSheetProvidersTracked,
        1, memory_order_relaxed);
}

static BOOL MTMethodHasType(Class cls,
                            SEL selector,
                            const char *typeEncoding,
                            BOOL classMethod) {
    if (cls == Nil || selector == NULL || typeEncoding == NULL) return NO;
    Method method = classMethod
        ? class_getClassMethod(cls, selector)
        : class_getInstanceMethod(cls, selector);
    const char *actual = method == NULL ? NULL : method_getTypeEncoding(method);
    return actual != NULL && strcmp(actual, typeEncoding) == 0;
}

static void MTCollectReachableControllers(
    UIViewController *controller,
    NSHashTable<UIViewController *> *visited,
    NSMutableArray<UIViewController *> *result) {
    if (controller == nil || [visited containsObject:controller]) return;
    [visited addObject:controller];
    [result addObject:controller];
    MTCollectReachableControllers(
        controller.presentedViewController, visited, result);
    for (UIViewController *child in controller.childViewControllers) {
        MTCollectReachableControllers(child, visited, result);
    }
    // UIKit container membership is the stable owner of already-loaded
    // Settings lists. A controller below the visible navigation entry may no
    // longer be present in the live child array even though its cells still
    // retain the previous generation's lazy icon. Traverse each public stack
    // explicitly, without loading a view or reaching into Preferences pixels.
    NSArray<UIViewController *> *stack = nil;
    if ([controller isKindOfClass:UINavigationController.class]) {
        stack = ((UINavigationController *)controller).viewControllers;
    } else if ([controller isKindOfClass:UITabBarController.class]) {
        stack = ((UITabBarController *)controller).viewControllers;
    } else if ([controller isKindOfClass:UISplitViewController.class]) {
        stack = ((UISplitViewController *)controller).viewControllers;
    }
    for (UIViewController *child in stack) {
        MTCollectReachableControllers(child, visited, result);
    }
}

static NSArray<UIViewController *> *MTReachableViewControllers(void) {
    UIApplication *application = UIApplication.sharedApplication;
    if (application == nil) return @[];
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    for (UIScene *scene in application.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class]) {
            [windows addObjectsFromArray:((UIWindowScene *)scene).windows];
        }
    }
    NSHashTable<UIViewController *> *visited =
        [NSHashTable weakObjectsHashTable];
    NSMutableArray<UIViewController *> *controllers =
        [NSMutableArray array];
    for (UIWindow *window in windows) {
        MTCollectReachableControllers(
            window.rootViewController, visited, controllers);
    }
    return [controllers copy];
}

NSSet<NSString *> *
MTApplicationIconNativeInvalidationInstalledBundleIdentifiers(void) {
    Class workspaceClass = objc_getClass("LSApplicationWorkspace");
    SEL defaultSelector = sel_registerName("defaultWorkspace");
    SEL installedSelector = sel_registerName("allInstalledApplications");
    SEL bundleSelector = sel_registerName("bundleIdentifier");
    if (!MTMethodHasType(
            workspaceClass, defaultSelector, "@16@0:8", YES)) {
        return nil;
    }
    id workspace = ((id (*)(id, SEL))objc_msgSend)(
        workspaceClass, defaultSelector);
    Class concreteWorkspaceClass = object_getClass(workspace);
    if (workspace == nil ||
        !MTMethodHasType(
            concreteWorkspaceClass, installedSelector, "@16@0:8", NO)) {
        return nil;
    }
    id rawApplications = ((id (*)(id, SEL))objc_msgSend)(
        workspace, installedSelector);
    if (![rawApplications isKindOfClass:NSArray.class] ||
        [(NSArray *)rawApplications count] > 4096) {
        return nil;
    }
    NSMutableSet<NSString *> *identifiers = [NSMutableSet set];
    for (id proxy in (NSArray *)rawApplications) {
        Class proxyClass = object_getClass(proxy);
        if (!MTMethodHasType(
                proxyClass, bundleSelector, "@16@0:8", NO)) {
            continue;
        }
        id value = ((id (*)(id, SEL))objc_msgSend)(proxy, bundleSelector);
        if (MTStaticIconBundleIdentifierIsValid(value)) {
            [identifiers addObject:value];
        }
    }
    return identifiers.count == 0 ? nil : [identifiers copy];
}

static BOOL MTClearNotificationImageCache(void) {
    Class cacheClass = objc_getClass("NCUIMappedImageCache");
    if (cacheClass == Nil) return YES;
    SEL sharedSelector = sel_registerName("sharedCache");
    SEL clearSelector = sel_registerName("removeAllObjects");
    if (!MTMethodHasType(cacheClass, sharedSelector, "@16@0:8", YES)) {
        return NO;
    }
    id cache = ((id (*)(id, SEL))objc_msgSend)(cacheClass, sharedSelector);
    Class concreteClass = object_getClass(cache);
    if (cache == nil ||
        !MTMethodHasType(concreteClass, clearSelector, "v16@0:8", NO)) {
        return NO;
    }
    ((void (*)(id, SEL))objc_msgSend)(cache, clearSelector);
    atomic_fetch_add_explicit(
        &MTRuntimeApplicationIconNativeInvalidationObservation
            .notificationCacheClears,
        1, memory_order_relaxed);
    return YES;
}

static BOOL MTPostLaunchServicesApplicationIconSignals(
    NSSet<NSString *> *requestedIdentifiers,
    NSUInteger *signalCount) {
    if (signalCount != NULL) *signalCount = 0;
    NSSet<NSString *> *identifiers = requestedIdentifiers ?:
        MTApplicationIconNativeInvalidationInstalledBundleIdentifiers();
    if (identifiers == nil || identifiers.count > 4096) return NO;
    if (identifiers.count == 0) return YES;
    for (NSString *identifier in identifiers) {
        if (!MTStaticIconBundleIdentifierIsValid(identifier)) return NO;
    }
    NSArray<NSString *> *ordered = [identifiers.allObjects
        sortedArrayUsingSelector:@selector(compare:)];
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    for (NSString *identifier in ordered) {
        [center postNotificationName:
                    MTLaunchServicesIconChangedNotificationName
                              object:nil
                            userInfo:@{
            MTLaunchServicesBundleIdentifierKey : identifier,
        }];
    }
    atomic_fetch_add_explicit(
        &MTRuntimeApplicationIconNativeInvalidationObservation
            .launchServicesSignals,
        ordered.count, memory_order_relaxed);
    if (signalCount != NULL) *signalCount = ordered.count;
    return YES;
}

static BOOL MTReloadAttachedPreferencesControllers(
    NSArray<UIViewController *> *controllers,
    NSUInteger *reloadCount) {
    if (reloadCount != NULL) *reloadCount = 0;
    Class listClass = objc_getClass("PSListController");
    if (listClass == Nil) return YES;
    SEL reloadSelector = sel_registerName("reloadSpecifiers");
    if (!MTMethodHasType(listClass, reloadSelector, "v16@0:8", NO)) {
        return NO;
    }
    NSUInteger count = 0;
    for (UIViewController *controller in controllers) {
        if (![controller isKindOfClass:listClass] ||
            controller.viewIfLoaded == nil) {
            continue;
        }
        ((void (*)(id, SEL))objc_msgSend)(controller, reloadSelector);
        count += 1;
    }
    atomic_fetch_add_explicit(
        &MTRuntimeApplicationIconNativeInvalidationObservation
            .preferencesReloads,
        count, memory_order_relaxed);
    if (reloadCount != NULL) *reloadCount = count;
    return YES;
}

static BOOL MTReloadAttachedShareSheetControllers(
    NSArray<UIViewController *> *controllers,
    NSUInteger *cacheClearCount,
    NSUInteger *reloadCount) {
    if (cacheClearCount != NULL) *cacheClearCount = 0;
    if (reloadCount != NULL) *reloadCount = 0;
    Class contentClass = objc_getClass("UIActivityContentViewController");
    SEL providerSelector = sel_registerName("activityImageProvider");
    SEL cacheSelector = sel_registerName("imageCache");
    SEL clearSelector = sel_registerName("removeAllObjects");
    SEL reloadSelector = sel_registerName("reloadContent");
    NSHashTable *seenProviders = [[NSHashTable alloc]
        initWithOptions:NSPointerFunctionsStrongMemory |
                        NSPointerFunctionsObjectPointerPersonality
              capacity:16];
    NSHashTable *tracked = MTTrackedShareImageProviders();
    @synchronized (tracked) {
        for (id provider in tracked.allObjects) {
            if (provider != nil) [seenProviders addObject:provider];
        }
    }
    NSMutableArray<UIViewController *> *contentControllers =
        [NSMutableArray array];
    NSUInteger cleared = 0;
    NSUInteger reloaded = 0;
    for (UIViewController *controller in controllers) {
        if (contentClass == Nil ||
            ![controller isKindOfClass:contentClass] ||
            controller.viewIfLoaded.window == nil) {
            continue;
        }
        Class controllerClass = object_getClass(controller);
        if (!MTMethodHasType(
                controllerClass, providerSelector, "@16@0:8", NO) ||
            !MTMethodHasType(
                controllerClass, reloadSelector, "v16@0:8", NO)) {
            return NO;
        }
        id provider = ((id (*)(id, SEL))objc_msgSend)(
            controller, providerSelector);
        if (provider == nil) return NO;
        [seenProviders addObject:provider];
        [contentControllers addObject:controller];
    }
    for (id provider in seenProviders) {
        Class providerClass = object_getClass(provider);
        if (!MTMethodHasType(
                providerClass, cacheSelector, "@16@0:8", NO)) {
            return NO;
        }
        id cache = ((id (*)(id, SEL))objc_msgSend)(
            provider, cacheSelector);
        Class cacheClass = object_getClass(cache);
        if (cache == nil ||
            !MTMethodHasType(
                cacheClass, clearSelector, "v16@0:8", NO)) {
            return NO;
        }
        ((void (*)(id, SEL))objc_msgSend)(cache, clearSelector);
        cleared += 1;
    }
    for (UIViewController *controller in contentControllers) {
        ((void (*)(id, SEL))objc_msgSend)(controller, reloadSelector);
        reloaded += 1;
    }
    atomic_fetch_add_explicit(
        &MTRuntimeApplicationIconNativeInvalidationObservation
            .shareSheetCacheClears,
        cleared, memory_order_relaxed);
    atomic_fetch_add_explicit(
        &MTRuntimeApplicationIconNativeInvalidationObservation
            .shareSheetReloads,
        reloaded, memory_order_relaxed);
    if (cacheClearCount != NULL) *cacheClearCount = cleared;
    if (reloadCount != NULL) *reloadCount = reloaded;
    return YES;
}

BOOL MTApplicationIconNativeInvalidationConfigure(
    MTApplicationIconNativeInvalidationOwners owners,
    NSError **error) {
    if (error != NULL) *error = nil;
    MTApplicationIconNativeInvalidationOwners allOwners =
        MTApplicationIconNativeInvalidationOwnerLaunchServices |
        MTApplicationIconNativeInvalidationOwnerNotificationImages |
        MTApplicationIconNativeInvalidationOwnerPreferences |
        MTApplicationIconNativeInvalidationOwnerShareSheet;
    if (owners == 0 || (owners & ~allOwners) != 0) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:
                @"com.hmmzzz.marktheme.native-icon-invalidation"
                                         code:1
                                     userInfo:@{
                NSLocalizedDescriptionKey :
                    @"Native icon invalidation owners are invalid.",
            }];
        }
        return NO;
    }
    @synchronized (NSProcessInfo.processInfo) {
        if (MTNativeInvalidationConfigured &&
            MTConfiguredOwners != owners) {
            return NO;
        }
        MTConfiguredOwners = owners;
        MTNativeInvalidationConfigured = YES;
    }
    MTRuntimeABIReportRecordAdapterState(
        MTNativeInvalidationAdapterID, (uint32_t)owners, @"Configured");
    return YES;
}

void MTApplicationIconNativeInvalidationRefresh(
    MTApplicationIconNativeInvalidationCompletion completion) {
    MTApplicationIconNativeInvalidationRefreshBundleIdentifiers(
        nil, completion);
}

void MTApplicationIconNativeInvalidationRefreshBundleIdentifiers(
    NSSet<NSString *> *bundleIdentifiers,
    MTApplicationIconNativeInvalidationCompletion completion) {
    if (completion == nil) return;
    atomic_fetch_add_explicit(
        &MTRuntimeApplicationIconNativeInvalidationObservation.requests,
        1, memory_order_relaxed);
    dispatch_async(dispatch_get_main_queue(), ^{
        MTApplicationIconNativeInvalidationOwners owners = 0;
        @synchronized (NSProcessInfo.processInfo) {
            if (MTNativeInvalidationConfigured) {
                owners = MTConfiguredOwners;
            }
        }
        BOOL verified = owners != 0;
        MTIconServicesClientCacheInvalidationResult clientResult = {0};
        NSUInteger signalCount = 0;
        NSUInteger preferencesReloads = 0;
        NSUInteger shareCacheClears = 0;
        NSUInteger shareReloads = 0;
        NSArray<UIViewController *> *controllers = nil;
        if (verified) {
            verified = MTIconServicesInvalidateClientImageCaches(
                &clientResult);
            atomic_fetch_add_explicit(
                &MTRuntimeApplicationIconNativeInvalidationObservation
                     .clientCacheInvalidations,
                1, memory_order_relaxed);
            atomic_fetch_add_explicit(
                &MTRuntimeApplicationIconNativeInvalidationObservation
                     .clientRegisteredIcons,
                clientResult.registeredIcons, memory_order_relaxed);
            atomic_fetch_add_explicit(
                &MTRuntimeApplicationIconNativeInvalidationObservation
                     .clientRegistryEntriesRemoved,
                clientResult.registryEntriesRemoved,
                memory_order_relaxed);
            atomic_fetch_add_explicit(
                &MTRuntimeApplicationIconNativeInvalidationObservation
                     .clientImageCachesCleared,
                clientResult.imageCachesCleared, memory_order_relaxed);
            atomic_fetch_add_explicit(
                &MTRuntimeApplicationIconNativeInvalidationObservation
                     .clientDescriptorBagsCleared,
                clientResult.descriptorBagsCleared,
                memory_order_relaxed);
        }
        if (verified &&
            (owners &
             MTApplicationIconNativeInvalidationOwnerNotificationImages)) {
            verified = MTClearNotificationImageCache();
        }
        if (verified &&
            (owners & MTApplicationIconNativeInvalidationOwnerLaunchServices)) {
            verified = MTPostLaunchServicesApplicationIconSignals(
                bundleIdentifiers, &signalCount);
        }
        if (verified &&
            (owners & (MTApplicationIconNativeInvalidationOwnerPreferences |
                       MTApplicationIconNativeInvalidationOwnerShareSheet))) {
            controllers = MTReachableViewControllers();
        }
        if (verified &&
            (owners & MTApplicationIconNativeInvalidationOwnerPreferences)) {
            verified = MTReloadAttachedPreferencesControllers(
                controllers, &preferencesReloads);
        }
        if (verified &&
            (owners & MTApplicationIconNativeInvalidationOwnerShareSheet)) {
            verified = MTReloadAttachedShareSheetControllers(
                controllers, &shareCacheClears, &shareReloads);
        }
        atomic_fetch_add_explicit(
            verified
                ? &MTRuntimeApplicationIconNativeInvalidationObservation
                       .verifiedRequests
                : &MTRuntimeApplicationIconNativeInvalidationObservation
                       .failures,
            1, memory_order_relaxed);
        MTRuntimeABIReportRecordSample(
            @"application-icon.native-invalidation", @{
                @"owners" : @((NSUInteger)owners),
                @"verified" : @(verified),
                @"launchServicesSignals" : @(signalCount),
                @"preferencesReloads" : @(preferencesReloads),
                @"shareSheetCacheClears" : @(shareCacheClears),
                @"shareSheetReloads" : @(shareReloads),
                @"iconServicesLoaded" : @(clientResult.iconServicesLoaded),
                @"clientCacheOutcome" : @(clientResult.outcome),
                @"clientCacheABIChecks" : @(clientResult.abiChecks),
                @"clientRegisteredIcons" :
                    @(clientResult.registeredIcons),
                @"clientRegistryEntriesRemoved" :
                    @(clientResult.registryEntriesRemoved),
                @"clientImageCachesCleared" :
                    @(clientResult.imageCachesCleared),
                @"clientDescriptorBagsCleared" :
                    @(clientResult.descriptorBagsCleared),
            });
        completion(verified);
    });
}
