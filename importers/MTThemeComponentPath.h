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

NS_ASSUME_NONNULL_END
