#import "MTRuntimeProfile.h"

#import <errno.h>
#import <sys/sysctl.h>

#import "MTRuntimeProfiles.generated.h"

NSString *const MTRuntimeProfileErrorDomain =
    @"com.hmmzzz.marktheme.runtime-profile";

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
@property(nonatomic, copy, readwrite) NSString *osBuild;
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

    size_t buildSize = 0;
    if (sysctlbyname("kern.osversion", NULL, &buildSize, NULL, 0) != 0 ||
        buildSize < 2 || buildSize > 256) {
        int savedError = errno;
        MTRuntimeProfileSetError(error,
            MTRuntimeProfileErrorSystemBuildUnavailable,
            @"The current OS build could not be read.",
            [NSError errorWithDomain:NSPOSIXErrorDomain
                                code:savedError
                            userInfo:nil]);
        return nil;
    }
    NSMutableData *buildData = [NSMutableData dataWithLength:buildSize];
    if (sysctlbyname("kern.osversion", buildData.mutableBytes, &buildSize,
                     NULL, 0) != 0) {
        int savedError = errno;
        MTRuntimeProfileSetError(error,
            MTRuntimeProfileErrorSystemBuildUnavailable,
            @"The current OS build could not be read.",
            [NSError errorWithDomain:NSPOSIXErrorDomain
                                code:savedError
                            userInfo:nil]);
        return nil;
    }
    NSString *osBuild = [[NSString alloc]
        initWithUTF8String:buildData.bytes];
    if (osBuild.length == 0) {
        MTRuntimeProfileSetError(error,
            MTRuntimeProfileErrorSystemBuildUnavailable,
            @"The current OS build is not valid UTF-8.", nil);
        return nil;
    }
    return [[self alloc] initWithBundleIdentifier:bundleIdentifier
                                  executableName:executableName
                                         osBuild:osBuild];
}

- (instancetype)initWithBundleIdentifier:(NSString *)bundleIdentifier
                           executableName:(NSString *)executableName
                                  osBuild:(NSString *)osBuild {
    NSParameterAssert(bundleIdentifier.length > 0);
    NSParameterAssert(executableName.length > 0);
    NSParameterAssert(osBuild.length > 0);
    self = [super init];
    if (self == nil) return nil;
    _bundleIdentifier = [bundleIdentifier copy];
    _executableName = [executableName copy];
    _osBuild = [osBuild copy];
    return self;
}

@end

@interface MTRuntimeProfile ()
@property(nonatomic, copy, readwrite) NSString *imageID;
@property(nonatomic, copy, readwrite) NSString *profileID;
@property(nonatomic, assign, readwrite) MTRuntimeProfileMode mode;
@property(nonatomic, copy, readwrite) NSString *bundleIdentifier;
@property(nonatomic, copy, readwrite) NSString *executableName;
@property(nonatomic, copy, readwrite) NSString *osBuild;
@property(nonatomic, copy, readwrite) NSArray<NSString *> *adapterIDs;
@property(nonatomic, copy, readwrite) NSArray<NSString *> *moduleIDs;
@end

@implementation MTRuntimeProfile

- (instancetype)initWithImageID:(NSString *)imageID
                       profileID:(NSString *)profileID
                            mode:(MTRuntimeProfileMode)mode
                bundleIdentifier:(NSString *)bundleIdentifier
                  executableName:(NSString *)executableName
                         osBuild:(NSString *)osBuild
                      adapterIDs:(NSArray<NSString *> *)adapterIDs
                       moduleIDs:(NSArray<NSString *> *)moduleIDs {
    NSParameterAssert(imageID.length > 0);
    NSParameterAssert(profileID.length > 0);
    NSParameterAssert(mode == MTRuntimeProfileModeKernelOnly ||
                      mode == MTRuntimeProfileModeProcessAdapters);
    NSParameterAssert(bundleIdentifier.length > 0);
    NSParameterAssert(executableName.length > 0);
    NSParameterAssert(osBuild.length > 0);
    NSParameterAssert(adapterIDs != nil);
    NSParameterAssert(moduleIDs != nil);
    self = [super init];
    if (self == nil) return nil;
    _imageID = [imageID copy];
    _profileID = [profileID copy];
    _mode = mode;
    _bundleIdentifier = [bundleIdentifier copy];
    _executableName = [executableName copy];
    _osBuild = [osBuild copy];
    _adapterIDs = [adapterIDs copy];
    _moduleIDs = [moduleIDs copy];
    return self;
}

- (BOOL)matchesIdentity:(MTRuntimeProcessIdentity *)identity {
    return [self.bundleIdentifier isEqualToString:identity.bundleIdentifier] &&
        [self.executableName isEqualToString:identity.executableName] &&
        [self.osBuild isEqualToString:identity.osBuild];
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
    return match;
}
