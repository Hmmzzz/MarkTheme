#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Logical paths produced by MTThemeSourceRoot keep the primary .theme at the
// root and place related SnowBoard components below Components/<name>. This
// value object gives importers one parser for both layouts.
@interface MTThemeComponentPath : NSObject

@property(nonatomic, copy, readonly) NSString *relativePath;
@property(nonatomic, copy, readonly, nullable) NSString *componentName;
@property(nonatomic, copy, readonly) NSString *componentIdentifier;

+ (nullable instancetype)pathWithLogicalRelativePath:(NSString *)logicalPath;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

// Theme packages are authored on case-insensitive filesystems, so directory
// names such as IconBundles/ reach us in many spellings. Importers compare
// directory segments through these helpers instead of a literal hasPrefix:
// so that "iconbundles/" and "ICONBUNDLES/" are the same directory.
FOUNDATION_EXPORT BOOL MTThemePathHasDirectoryPrefix(NSString *path,
                                                     NSString *directoryPrefix);
FOUNDATION_EXPORT NSString *_Nullable MTThemePathRemainderAfterDirectoryPrefix(
    NSString *path,
    NSString *directoryPrefix);

NS_ASSUME_NONNULL_END
