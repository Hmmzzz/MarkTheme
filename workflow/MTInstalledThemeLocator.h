#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTInstalledThemeLocatorErrorDomain;

// One theme already present on the filesystem, typically installed from a
// package manager. The directory is owned by the package manager, so it is
// only ever read: import copies it into a private snapshot first.
@interface MTInstalledTheme : NSObject

@property(nonatomic, copy, readonly) NSString *displayName;
@property(nonatomic, copy, readonly) NSURL *directoryURL;
// The search root this theme was found under, for grouping in the UI.
@property(nonatomic, copy, readonly) NSString *searchRootPath;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

// Finds .theme bundles that a package manager has already installed, so a
// theme delivered as a .deb can be imported without going through the file
// picker. This only locates candidates; every safety rule still applies when
// the located directory is imported.
@interface MTInstalledThemeLocator : NSObject

// Default search roots, resolved through the active bootstrap so that
// rootless and RootHide installs are found at their real locations.
@property(nonatomic, copy, readonly) NSArray<NSString *> *searchRootPaths;

- (instancetype)init;
- (instancetype)initWithSearchRootPaths:(NSArray<NSString *> *)searchRootPaths
    NS_DESIGNATED_INITIALIZER;

// Returns installed themes sorted by display name. An unreadable or missing
// search root is skipped rather than failing the scan, because a device
// legitimately may not have every location.
- (NSArray<MTInstalledTheme *> *)locateInstalledThemes;

@end

NS_ASSUME_NONNULL_END
