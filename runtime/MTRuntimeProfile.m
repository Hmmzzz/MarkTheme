#import "MTRuntimeProfile.h"

#import "MTRuntimeProfiles.generated.h"

#import <mach-o/dyld.h>

#include <string.h>

NSString *const MTRuntimeProfileErrorDomain =
    @"com.hmmzzz.marktheme.runtime-profile";
static NSString *const MTRuntimeLoadedShareSheetProfileID =
    @"share-sheet.loaded-host.ui-icons";
static const char *const MTRuntimeShareSheetImagePath =
    "/System/Library/PrivateFrameworks/ShareSheet.framework/ShareSheet";

static BOOL MTRuntimeShareSheetImageIsLoaded(void) {
    uint32_t count = _dyld_image_count();
    for (uint32_t index = 0; index < count; index++) {
        const char *name = _dyld_get_image_name(index);
        if (name != NULL &&
            strcmp(name, MTRuntimeShareSheetImagePath) == 0) {
            return YES;
        }
    }
    return NO;
}

static void MTRuntimeProfileSetError(NSError **error,
                                     MTRuntimeProfileErrorCode code,
                                     NSString *description,
                                     NSError *underlying) {
    if (error == NULL) return;
    NSMutableDictionary *userInfo = [NSMutableDictionary
        dictionaryWithObject:description forKey:NSLocalizedDescriptionKey];
    if (underlying != nil) userInfo[NSUnderlyingErrorKey] = underlying;
    *error = [NSError errorWithDomain:MTRuntimeProfileErrorDomain
                                 code:code
                             userInfo:userInfo];
}

@interface MTRuntimeProcessIdentity ()
@property(nonatomic, copy, readwrite) NSString *bundleIdentifier;
@property(nonatomic, copy, readwrite) NSString *executableName;
@end

@implementation MTRuntimeProcessIdentity

+ (instancetype)currentIdentityWithError:(NSError **)error {
    NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier;
    NSString *executableName = NSProcessInfo.processInfo.processName;
    if (bundleIdentifier.length == 0 || executableName.length == 0) {
        MTRuntimeProfileSetError(error, MTRuntimeProfileErrorInvalidIdentity,
            @"The current process has no exact bundle or executable identity.",
            nil);
        return nil;
    }

    return [[self alloc] initWithBundleIdentifier:bundleIdentifier
                                  executableName:executableName];
}

- (instancetype)initWithBundleIdentifier:(NSString *)bundleIdentifier
                           executableName:(NSString *)executableName {
    NSParameterAssert(bundleIdentifier.length > 0);
    NSParameterAssert(executableName.length > 0);
    self = [super init];
    if (self == nil) return nil;
    _bundleIdentifier = [bundleIdentifier copy];
    _executableName = [executableName copy];
    return self;
}

@end

@interface MTRuntimeProfile ()
@property(nonatomic, copy, readwrite) NSString *imageID;
@property(nonatomic, copy, readwrite) NSString *profileID;
@property(nonatomic, assign, readwrite) MTRuntimeProfileMode mode;
@property(nonatomic, copy, readwrite) NSString *bundleIdentifier;
@property(nonatomic, copy, readwrite) NSString *executableName;
@property(nonatomic, copy, readwrite) NSArray<NSString *> *adapterIDs;
@property(nonatomic, copy, readwrite) NSArray<NSString *> *moduleIDs;
@end

@implementation MTRuntimeProfile

- (instancetype)initWithImageID:(NSString *)imageID
                       profileID:(NSString *)profileID
                            mode:(MTRuntimeProfileMode)mode
                bundleIdentifier:(NSString *)bundleIdentifier
                  executableName:(NSString *)executableName
                      adapterIDs:(NSArray<NSString *> *)adapterIDs
                       moduleIDs:(NSArray<NSString *> *)moduleIDs {
    NSParameterAssert(imageID.length > 0);
    NSParameterAssert(profileID.length > 0);
    NSParameterAssert(mode == MTRuntimeProfileModeKernelOnly ||
                      mode == MTRuntimeProfileModeProcessAdapters);
    NSParameterAssert(bundleIdentifier.length > 0);
    NSParameterAssert(executableName.length > 0);
    NSParameterAssert(adapterIDs != nil);
    NSParameterAssert(moduleIDs != nil);
    self = [super init];
    if (self == nil) return nil;
    _imageID = [imageID copy];
    _profileID = [profileID copy];
    _mode = mode;
    _bundleIdentifier = [bundleIdentifier copy];
    _executableName = [executableName copy];
    _adapterIDs = [adapterIDs copy];
    _moduleIDs = [moduleIDs copy];
    return self;
}

- (BOOL)matchesIdentity:(MTRuntimeProcessIdentity *)identity {
    return [self.bundleIdentifier isEqualToString:identity.bundleIdentifier] &&
        [self.executableName isEqualToString:identity.executableName];
}

@end

MTRuntimeProfile *MTRuntimeResolveProfile(
    MTRuntimeProcessIdentity *identity,
    NSString *imageID,
    NSError **error) {
    if (![identity isKindOfClass:MTRuntimeProcessIdentity.class] ||
        imageID.length == 0) {
        MTRuntimeProfileSetError(error, MTRuntimeProfileErrorInvalidIdentity,
            @"Runtime profile resolution requires one exact process identity and image.",
            nil);
        return nil;
    }
    MTRuntimeProfile *match = nil;
    for (MTRuntimeProfile *profile in MTRuntimeGeneratedProfiles()) {
        if (![profile.imageID isEqualToString:imageID] ||
            ![profile matchesIdentity:identity]) {
            continue;
        }
        if (match != nil) {
            MTRuntimeProfileSetError(error,
                MTRuntimeProfileErrorAmbiguousMatch,
                @"More than one Runtime profile matched the exact process identity.",
                nil);
            return nil;
        }
        match = profile;
    }
    if (match != nil || !MTRuntimeShareSheetImageIsLoaded()) return match;

    // iOS 16 presents UIActivityViewController inside the initiating App.
    // The injection filter is therefore tied to the loaded ShareSheet
    // framework, while this second pass selects its narrow adapter profile
    // only after the exact Apple image is present. Exact process profiles
    // above always win for Photos, sharingd, and dedicated service hosts.
    for (MTRuntimeProfile *profile in MTRuntimeGeneratedProfiles()) {
        if ([profile.imageID isEqualToString:imageID] &&
            [profile.profileID
                isEqualToString:MTRuntimeLoadedShareSheetProfileID]) {
            return profile;
        }
    }
    return nil;
}
