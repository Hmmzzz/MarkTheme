#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTRuntimeProfileErrorDomain;

typedef NS_ENUM(NSInteger, MTRuntimeProfileErrorCode) {
    MTRuntimeProfileErrorInvalidIdentity = 1,
    MTRuntimeProfileErrorAmbiguousMatch = 2,
};

typedef NS_ENUM(NSUInteger, MTRuntimeProfileMode) {
    // Load the Kernel and one or more profile-selected ProcessAdapters. A
    // ModuleRuntime may supply the stable resolver without adding an image.
    MTRuntimeProfileModeProcessAdapters = 1,
};

@interface MTRuntimeProcessIdentity : NSObject

@property(nonatomic, copy, readonly) NSString *bundleIdentifier;
@property(nonatomic, copy, readonly) NSString *executableName;

+ (nullable instancetype)currentIdentityWithError:(NSError **)error;
- (instancetype)initWithBundleIdentifier:(NSString *)bundleIdentifier
                           executableName:(NSString *)executableName
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

@interface MTRuntimeProfile : NSObject

@property(nonatomic, copy, readonly) NSString *imageID;
@property(nonatomic, copy, readonly) NSString *profileID;
@property(nonatomic, assign, readonly) MTRuntimeProfileMode mode;
@property(nonatomic, copy, readonly) NSString *bundleIdentifier;
@property(nonatomic, copy, readonly) NSString *executableName;
@property(nonatomic, copy, readonly) NSArray<NSString *> *adapterIDs;
@property(nonatomic, copy, readonly) NSArray<NSString *> *moduleIDs;

- (instancetype)initWithImageID:(NSString *)imageID
                       profileID:(NSString *)profileID
                            mode:(MTRuntimeProfileMode)mode
                bundleIdentifier:(NSString *)bundleIdentifier
                  executableName:(NSString *)executableName
                      adapterIDs:(NSArray<NSString *> *)adapterIDs
                       moduleIDs:(NSArray<NSString *> *)moduleIDs
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (BOOL)matchesIdentity:(MTRuntimeProcessIdentity *)identity;

@end

// Unsupported processes are a normal no-op and return nil without an error.
// Private ABI compatibility is probed by the selected adapters before Hook
// installation; it is deliberately not inferred from an OS build number.
FOUNDATION_EXPORT MTRuntimeProfile * _Nullable MTRuntimeResolveProfile(
    MTRuntimeProcessIdentity *identity,
    NSString *imageID,
    NSError **error);

NS_ASSUME_NONNULL_END
