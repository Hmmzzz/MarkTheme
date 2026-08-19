#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTRuntimeProfileErrorDomain;

typedef NS_ENUM(NSInteger, MTRuntimeProfileErrorCode) {
    MTRuntimeProfileErrorInvalidIdentity = 1,
    MTRuntimeProfileErrorAmbiguousMatch = 2,
    MTRuntimeProfileErrorSystemBuildUnavailable = 3,
};

typedef NS_ENUM(NSUInteger, MTRuntimeProfileMode) {
    // Load and validate the Runtime data plane, but register no Hook.
    MTRuntimeProfileModeKernelOnly = 1,
    // Load the Kernel and one or more profile-selected ProcessAdapters. A
    // ModuleRuntime may supply the stable resolver without adding an image.
    MTRuntimeProfileModeProcessAdapters = 2,
};

@interface MTRuntimeProcessIdentity : NSObject

@property(nonatomic, copy, readonly) NSString *bundleIdentifier;
@property(nonatomic, copy, readonly) NSString *executableName;
@property(nonatomic, copy, readonly) NSString *osBuild;

+ (nullable instancetype)currentIdentityWithError:(NSError **)error;
- (instancetype)initWithBundleIdentifier:(NSString *)bundleIdentifier
                           executableName:(NSString *)executableName
                                  osBuild:(NSString *)osBuild
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

@interface MTRuntimeProfile : NSObject

@property(nonatomic, copy, readonly) NSString *imageID;
@property(nonatomic, copy, readonly) NSString *profileID;
@property(nonatomic, assign, readonly) MTRuntimeProfileMode mode;
@property(nonatomic, copy, readonly) NSString *bundleIdentifier;
@property(nonatomic, copy, readonly) NSString *executableName;
@property(nonatomic, copy, readonly) NSString *osBuild;
@property(nonatomic, copy, readonly) NSArray<NSString *> *adapterIDs;
@property(nonatomic, copy, readonly) NSArray<NSString *> *moduleIDs;

- (instancetype)initWithImageID:(NSString *)imageID
                       profileID:(NSString *)profileID
                            mode:(MTRuntimeProfileMode)mode
                bundleIdentifier:(NSString *)bundleIdentifier
                  executableName:(NSString *)executableName
                         osBuild:(NSString *)osBuild
                      adapterIDs:(NSArray<NSString *> *)adapterIDs
                       moduleIDs:(NSArray<NSString *> *)moduleIDs
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (BOOL)matchesIdentity:(MTRuntimeProcessIdentity *)identity;

@end

// Unsupported processes/builds are a normal no-op and return nil without an
// error. An error is reserved for a malformed identity or ambiguous table.
FOUNDATION_EXPORT MTRuntimeProfile * _Nullable MTRuntimeResolveProfile(
    MTRuntimeProcessIdentity *identity,
    NSString *imageID,
    NSError **error);

NS_ASSUME_NONNULL_END
