#import "MTThemeComponentPath.h"

BOOL MTThemePathHasDirectoryPrefix(NSString *path, NSString *directoryPrefix) {
    return MTThemePathRemainderAfterDirectoryPrefix(path, directoryPrefix) !=
        nil;
}

NSString *_Nullable MTThemePathRemainderAfterDirectoryPrefix(
    NSString *path,
    NSString *directoryPrefix) {
    if (![path isKindOfClass:NSString.class] ||
        directoryPrefix.length == 0 || path.length <= directoryPrefix.length) {
        return nil;
    }
    NSRange range = NSMakeRange(0, directoryPrefix.length);
    if ([path compare:directoryPrefix
              options:NSCaseInsensitiveSearch
                range:range] != NSOrderedSame) {
        return nil;
    }
    return [path substringFromIndex:directoryPrefix.length];
}

static NSString *MTThemeComponentIdentifier(NSString *_Nullable name) {
    if (name.length == 0) return @"primary";
    NSString *stem = name;
    if ([stem.lowercaseString hasSuffix:@".theme"] && stem.length > 6) {
        stem = [stem substringToIndex:stem.length - 6];
    }
    NSString *lowercase = [stem lowercaseStringWithLocale:
        [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"]];
    NSMutableString *result = [NSMutableString string];
    BOOL pendingSeparator = NO;
    for (NSUInteger index = 0; index < lowercase.length; index++) {
        unichar character = [lowercase characterAtIndex:index];
        BOOL alphanumeric =
            (character >= 'a' && character <= 'z') ||
            (character >= '0' && character <= '9');
        if (!alphanumeric) {
            pendingSeparator = result.length > 0;
            continue;
        }
        if (pendingSeparator && result.length < 95) [result appendString:@"-"];
        pendingSeparator = NO;
        if (result.length < 96) [result appendFormat:@"%C", character];
    }
    return result.length > 0 ? result : @"component";
}

@interface MTThemeComponentPath ()
@property(nonatomic, copy, readwrite) NSString *relativePath;
@property(nonatomic, copy, readwrite, nullable) NSString *componentName;
@property(nonatomic, copy, readwrite) NSString *componentIdentifier;
- (instancetype)initPrivate;
@end

@implementation MTThemeComponentPath

+ (instancetype)pathWithLogicalRelativePath:(NSString *)logicalPath {
    if (![logicalPath isKindOfClass:NSString.class] ||
        logicalPath.length == 0) {
        return nil;
    }
    NSString *componentName = nil;
    NSString *relativePath = logicalPath;
    static NSString *const prefix = @"Components/";
    if ([logicalPath hasPrefix:prefix]) {
        NSString *remainder = [logicalPath substringFromIndex:prefix.length];
        NSRange separator = [remainder rangeOfString:@"/"];
        if (separator.location == NSNotFound || separator.location == 0 ||
            NSMaxRange(separator) >= remainder.length) {
            return nil;
        }
        componentName = [remainder substringToIndex:separator.location];
        relativePath = [remainder substringFromIndex:NSMaxRange(separator)];
    }
    MTThemeComponentPath *path = [[self alloc] initPrivate];
    path.relativePath = [relativePath copy];
    path.componentName = [componentName copy];
    path.componentIdentifier = MTThemeComponentIdentifier(componentName);
    return path;
}

- (instancetype)initPrivate {
    return [super init];
}

@end
