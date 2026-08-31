#import "MTThemeLibraryStore.h"

#import "MTBootstrapPaths.h"
#import "MTImportLimits.h"
#import "MTThemeLibraryStoreInternal.h"

NSString *const MTThemeLibraryStoreErrorDomain =
    @"com.hmmzzz.marktheme.theme-library-store";

@implementation MTThemeLibraryConfiguration

+ (instancetype)defaultConfiguration {
    NSURL *managerDataRoot = MTDefaultManagerDataRootURL();
    NSAssert(managerDataRoot != nil,
             @"Manager data storage must be available for the theme Library.");
    NSURL *rootURL = [managerDataRoot
        URLByAppendingPathComponent:@"Library" isDirectory:YES];
    return [[self alloc] initWithRootURL:rootURL
                                  limits:MTImportLimits.defaultLimits
            minimumFreeSpaceReserveBytes:64ULL * 1024ULL * 1024ULL];
}

- (instancetype)initWithRootURL:(NSURL *)rootURL
                          limits:(MTImportLimits *)limits
    minimumFreeSpaceReserveBytes:(uint64_t)minimumFreeSpaceReserveBytes {
    NSParameterAssert(rootURL.isFileURL);
    NSParameterAssert(rootURL.path.length > 0);
    NSParameterAssert(limits != nil);
    self = [super init];
    if (self == nil) return nil;
    _rootURL = [rootURL copy];
    _limits = limits;
    _minimumFreeSpaceReserveBytes = minimumFreeSpaceReserveBytes;
    return self;
}

@end

@implementation MTThemeLibraryRevision

- (instancetype)initWithRevisionIdentifier:(NSString *)revisionIdentifier
                             manifestDigest:(NSString *)manifestDigest
                                    manifest:(MTThemeManifest *)manifest
             assetURLsByContentSHA256:
                 (NSDictionary<NSString *,NSURL *> *)assetURLsByContentSHA256
       assetByteCountsByContentSHA256:
           (NSDictionary<NSString *,NSNumber *> *)assetByteCountsByContentSHA256
                    resourcesDirectoryURL:(NSURL *)resourcesDirectoryURL
                             assetByteCount:(uint64_t)assetByteCount {
    self = [super init];
    if (self == nil) return nil;
    _revisionIdentifier = [revisionIdentifier copy];
    _manifestDigest = [manifestDigest copy];
    _manifest = manifest;
    _assetURLsByContentSHA256 = [assetURLsByContentSHA256 copy];
    _assetByteCountsByContentSHA256 =
        [assetByteCountsByContentSHA256 copy];
    _resourcesDirectoryURL = [resourcesDirectoryURL copy];
    _assetCount = _assetURLsByContentSHA256.count;
    _assetByteCount = assetByteCount;
    return self;
}

@end

@implementation MTThemeLibraryStore

- (instancetype)initWithRootURL:(NSURL *)rootURL {
    MTThemeLibraryConfiguration *configuration =
        [[MTThemeLibraryConfiguration alloc]
            initWithRootURL:rootURL
                     limits:MTImportLimits.defaultLimits
       minimumFreeSpaceReserveBytes:64ULL * 1024ULL * 1024ULL];
    return [self initWithConfiguration:configuration];
}

- (instancetype)initWithConfiguration:
        (MTThemeLibraryConfiguration *)configuration {
    NSParameterAssert(configuration != nil);
    self = [super init];
    if (self == nil) return nil;
    _configuration = configuration;
    _rootURL = [configuration.rootURL copy];
    return self;
}

@end
