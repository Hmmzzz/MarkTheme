#import "MTInstalledThemeLocator.h"

#import <sys/stat.h>

#import "MTBootstrapPaths.h"

NSString *const MTInstalledThemeLocatorErrorDomain =
    @"com.hmmzzz.marktheme.installed-theme-locator";

// Where package managers place theme bundles. These are logical paths: the
// bootstrap resolver maps them onto the real rootless or RootHide prefix.
static NSArray<NSString *> *MTInstalledThemeLogicalRoots(void) {
    return @[
        @"/Library/Themes",
        @"/var/mobile/Library/Themes",
    ];
}

@interface MTInstalledTheme ()
- (instancetype)initWithDisplayName:(NSString *)displayName
                        directoryURL:(NSURL *)directoryURL
                      searchRootPath:(NSString *)searchRootPath;
@end

@implementation MTInstalledTheme

- (instancetype)initWithDisplayName:(NSString *)displayName
                        directoryURL:(NSURL *)directoryURL
                      searchRootPath:(NSString *)searchRootPath {
    self = [super init];
    if (self == nil) return nil;
    _displayName = [displayName copy];
    _directoryURL = [directoryURL copy];
    _searchRootPath = [searchRootPath copy];
    return self;
}

@end

@implementation MTInstalledThemeLocator

- (instancetype)init {
    NSMutableArray<NSString *> *roots = [NSMutableArray array];
    MTBootstrapPathResolver *resolver = MTBootstrapPathResolver.currentResolver;
    for (NSString *logicalPath in MTInstalledThemeLogicalRoots()) {
        NSString *resolved = [resolver resolvedPathForLogicalPath:logicalPath
                                                            error:NULL];
        if (resolved.length > 0 && ![roots containsObject:resolved]) {
            [roots addObject:resolved];
        }
    }
    return [self initWithSearchRootPaths:roots];
}

- (instancetype)initWithSearchRootPaths:(NSArray<NSString *> *)searchRootPaths {
    NSParameterAssert(searchRootPaths != nil);
    self = [super init];
    if (self == nil) return nil;
    _searchRootPaths = [searchRootPaths copy];
    return self;
}

// A theme directory must be a real directory, not a symlink pointing outside
// the search root. The package manager owns these paths, so this is a
// consistency check on what is read, not a trust boundary.
static BOOL MTInstalledThemeDirectoryIsReadable(NSString *path) {
    struct stat status = {0};
    if (lstat(path.fileSystemRepresentation, &status) != 0) return NO;
    return S_ISDIR(status.st_mode);
}

- (NSArray<MTInstalledTheme *> *)locateInstalledThemes {
    NSFileManager *manager = NSFileManager.defaultManager;
    NSMutableArray<MTInstalledTheme *> *themes = [NSMutableArray array];
    NSMutableSet<NSString *> *seenPaths = [NSMutableSet set];
    for (NSString *rootPath in self.searchRootPaths) {
        if (!MTInstalledThemeDirectoryIsReadable(rootPath)) continue;
        NSArray<NSString *> *names = [manager
            contentsOfDirectoryAtPath:rootPath error:NULL];
        for (NSString *name in names) {
            if (![name.lowercaseString hasSuffix:@".theme"] ||
                name.length <= 6 || [name hasPrefix:@"."]) {
                continue;
            }
            NSString *path = [rootPath stringByAppendingPathComponent:name];
            if (!MTInstalledThemeDirectoryIsReadable(path) ||
                [seenPaths containsObject:path]) {
                continue;
            }
            [seenPaths addObject:path];
            [themes addObject:[[MTInstalledTheme alloc]
                initWithDisplayName:[name substringToIndex:name.length - 6]
                       directoryURL:[NSURL fileURLWithPath:path
                                               isDirectory:YES]
                     searchRootPath:rootPath]];
        }
    }
    return [themes sortedArrayUsingComparator:
        ^NSComparisonResult(MTInstalledTheme *left, MTInstalledTheme *right) {
            NSComparisonResult byName = [left.displayName
                localizedCaseInsensitiveCompare:right.displayName];
            if (byName != NSOrderedSame) return byName;
            return [left.directoryURL.path compare:right.directoryURL.path
                                            options:NSLiteralSearch];
        }];
}

@end
