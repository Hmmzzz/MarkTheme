#import "MTInstalledThemeLocator.h"

#import <sys/stat.h>

#import "MTBootstrapPaths.h"

NSString *const MTInstalledThemeLocatorErrorDomain =
    @"com.hmmzzz.marktheme.installed-theme-locator";

// Package-managed theme locations are logical jailbreak paths. The resolver
// maps these into the active RootHide/rootless namespace; no physical prefix
// is embedded in the application.
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
    return [self initWithBootstrapResolver:
        MTBootstrapPathResolver.currentResolver];
}

- (instancetype)initWithBootstrapResolver:
        (nullable MTBootstrapPathResolver *)resolver {
    NSMutableArray<NSString *> *roots = [NSMutableArray array];
    for (NSString *logicalPath in MTInstalledThemeLogicalRoots()) {
        NSString *resolved = resolver == nil ? nil
            : [resolver resolvedPathForLogicalPath:logicalPath error:NULL];
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

static BOOL MTInstalledThemeDirectoryIsReadable(NSString *path) {
    struct stat status = {0};
    if (lstat(path.fileSystemRepresentation, &status) != 0) return NO;
    return S_ISDIR(status.st_mode);
}

static NSString *_Nullable MTInstalledThemeIdentity(NSString *path) {
    struct stat status = {0};
    if (stat(path.fileSystemRepresentation, &status) != 0) return nil;
    return [NSString stringWithFormat:@"%llu:%llu",
        (unsigned long long)status.st_dev, (unsigned long long)status.st_ino];
}

- (NSArray<MTInstalledTheme *> *)locateInstalledThemes {
    NSFileManager *manager = NSFileManager.defaultManager;
    NSMutableArray<MTInstalledTheme *> *themes = [NSMutableArray array];
    NSMutableSet<NSString *> *seenPaths = [NSMutableSet set];
    NSMutableSet<NSString *> *seenRoots = [NSMutableSet set];
    for (NSString *rootPath in self.searchRootPaths) {
        if (!MTInstalledThemeDirectoryIsReadable(rootPath)) continue;
        NSString *rootIdentity = MTInstalledThemeIdentity(rootPath);
        if (rootIdentity != nil) {
            if ([seenRoots containsObject:rootIdentity]) continue;
            [seenRoots addObject:rootIdentity];
        }
        NSArray<NSString *> *names = [manager
            contentsOfDirectoryAtPath:rootPath error:NULL];
        for (NSString *name in names) {
            if (![name.lowercaseString hasSuffix:@".theme"] ||
                name.length <= 6 || [name hasPrefix:@"."]) {
                continue;
            }
            NSString *path = [rootPath stringByAppendingPathComponent:name];
            if (!MTInstalledThemeDirectoryIsReadable(path)) continue;
            NSString *identity = MTInstalledThemeIdentity(path) ?: path;
            if ([seenPaths containsObject:identity]) continue;
            [seenPaths addObject:identity];
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
