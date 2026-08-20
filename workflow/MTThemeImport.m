#import "MTThemeImport.h"

#import "MTAssetStagingSession.h"
#import "MTAssetStagingSessionInternal.h"
#import "MTBadgeConfiguration.h"
#import "MTBadgesModule.h"
#import "MTCalendarIconsModule.h"
#import "MTClockIconsModule.h"
#import "MTDirectorySnapshotSession.h"
#import "MTExpandedArchiveSession.h"
#import "MTDiagnostic.h"
#import "MTIconBundlesImporter.h"
#import "MTImportLimits.h"
#import "MTImportSession.h"
#import "MTResourceKey.h"
#import "MTSafeDirectoryScanner.h"
#import "MTSafeImageDecoder.h"
#import "MTSafeZIPArchiveReader.h"
#import "MTSourceInventory.h"
#import "MTStaticIconConfiguration.h"
#import "MTThemeInfoMetadataImporter.h"
#import "MTThemeInfoMetadataMapper.h"
#import "MTThemeLibraryStore.h"
#import "MTThemeLibraryCatalog.h"
#import "MTThemeManifest.h"
#import "MTThemeSourceRoot.h"

NSString *const MTThemeImportErrorDomain =
    @"com.hmmzzz.marktheme.theme-import";

// Files arriving through a share sheet or a rename often lose their
// extension, and the picker cannot filter undeclared types precisely. Reading
// the leading magic bytes lets a correct package import on its content rather
// than on its name. The extension still wins when it is present and known.
typedef NS_ENUM(NSUInteger, MTThemeImportSniffedFormat) {
    MTThemeImportSniffedFormatUnknown = 0,
    MTThemeImportSniffedFormatZIP,
    MTThemeImportSniffedFormatDebianPackage,
    MTThemeImportSniffedFormatTar,
};

static MTThemeImportSniffedFormat MTThemeImportSniffFormat(NSURL *archiveURL) {
    // A URL handed over by the share sheet or a document picker is only
    // readable inside a security scope. Opening it without one fails, the
    // format comes back unknown, and a perfectly ordinary theme is refused
    // with "the theme couldn't be added" -- so the scope is taken here even
    // though the copy that follows takes its own.
    BOOL scoped = [archiveURL startAccessingSecurityScopedResource];
    NSFileHandle *handle =
        [NSFileHandle fileHandleForReadingFromURL:archiveURL error:NULL];
    NSData *prefix = nil;
    if (handle != nil) {
        prefix = [handle readDataOfLength:8];
        [handle closeFile];
    }
    if (scoped) [archiveURL stopAccessingSecurityScopedResource];
    if (prefix == nil) return MTThemeImportSniffedFormatUnknown;
    const unsigned char *bytes = prefix.bytes;
    if (prefix.length >= 8 && memcmp(bytes, "!<arch>\n", 8) == 0) {
        return MTThemeImportSniffedFormatDebianPackage;
    }
    if (prefix.length >= 4 && bytes[0] == 0x50 && bytes[1] == 0x4b &&
        ((bytes[2] == 0x03 && bytes[3] == 0x04) ||
         (bytes[2] == 0x05 && bytes[3] == 0x06))) {
        return MTThemeImportSniffedFormatZIP;
    }
    // Compressed tar wrappers: gzip, bzip2, xz, and zstd.
    if (prefix.length >= 3 && bytes[0] == 0x1f && bytes[1] == 0x8b &&
        bytes[2] == 0x08) {
        return MTThemeImportSniffedFormatTar;
    }
    if (prefix.length >= 3 && memcmp(bytes, "BZh", 3) == 0) {
        return MTThemeImportSniffedFormatTar;
    }
    static const unsigned char xz[] = {0xfd, '7', 'z', 'X', 'Z', 0x00};
    if (prefix.length >= sizeof(xz) && memcmp(bytes, xz, sizeof(xz)) == 0) {
        return MTThemeImportSniffedFormatTar;
    }
    static const unsigned char zstd[] = {0x28, 0xb5, 0x2f, 0xfd};
    if (prefix.length >= sizeof(zstd) &&
        memcmp(bytes, zstd, sizeof(zstd)) == 0) {
        return MTThemeImportSniffedFormatTar;
    }
    return MTThemeImportSniffedFormatUnknown;
}

static NSError *MTThemeImportError(MTThemeImportErrorCode code,
                                   NSString *description,
                                   NSError *_Nullable underlying) {
    NSMutableDictionary *userInfo = [NSMutableDictionary
        dictionaryWithObject:description forKey:NSLocalizedDescriptionKey];
    if (underlying != nil) userInfo[NSUnderlyingErrorKey] = underlying;
    return [NSError errorWithDomain:MTThemeImportErrorDomain
                               code:code
                           userInfo:userInfo];
}

static BOOL MTThemeImportSetError(NSError **error,
                                  MTThemeImportErrorCode code,
                                  NSString *description,
                                  NSError *_Nullable underlying) {
    if (error != NULL) {
        *error = MTThemeImportError(code, description, underlying);
    }
    return NO;
}

static BOOL MTThemeImportIsCancelled(
    MTImportCancellationToken *_Nullable token) {
    return token != nil && token.isCancelled;
}

static MTThemeManifest *_Nullable MTThemeImportManifestByRemovingDigests(
    MTThemeManifest *manifest,
    NSSet<NSString *> *removedDigests,
    NSError **error) {
    NSMutableArray<MTThemeResource *> *resources = [NSMutableArray array];
    for (MTThemeResource *resource in manifest.resources) {
        if (![removedDigests containsObject:resource.contentSHA256]) {
            [resources addObject:resource];
        }
    }
    BOOL hasStatic = NO;
    for (MTThemeResource *resource in resources) {
        if ([resource.resourceKey.moduleID isEqualToString:@"icons.static"]) {
            hasStatic = YES;
            break;
        }
    }
    if (!hasStatic) {
        NSIndexSet *dependentResources = [resources
            indexesOfObjectsPassingTest:^BOOL(MTThemeResource *resource,
                                               __unused NSUInteger index,
                                               __unused BOOL *stop) {
            return [resource.resourceKey.moduleID
                isEqualToString:MTClockIconsModuleID];
        }];
        [resources removeObjectsAtIndexes:dependentResources];
    }
    if (resources.count == 0) {
        if (error != NULL) {
            *error = MTThemeImportError(MTThemeImportErrorImageValidation,
                @"No usable resources remain after image validation.", nil);
        }
        return nil;
    }

    NSMutableSet<NSString *> *capabilitySet = [NSMutableSet set];
    for (MTThemeResource *resource in resources) {
        [capabilitySet addObject:resource.resourceKey.moduleID];
    }
    BOOL hasCalendarBackground = NO;
    for (MTThemeResource *resource in resources) {
        MTResourceKey *key = resource.resourceKey;
        if ([key.moduleID isEqualToString:@"icons.static"] &&
            [key.surface isEqualToString:@"springboard.home"] &&
            [key.subject isEqualToString:@"com.apple.mobilecal"] &&
            MTStaticIconSourceVariantIsSupported(key.variant)) {
            hasCalendarBackground = YES;
            break;
        }
    }
    NSMutableDictionary<NSString *, NSDictionary<NSString *, id> *> *configs =
        [NSMutableDictionary dictionary];
    for (NSString *moduleID in manifest.moduleConfigurations) {
        if ([capabilitySet containsObject:moduleID] &&
            ![moduleID isEqualToString:MTBadgesModuleID]) {
            configs[moduleID] = manifest.moduleConfigurations[moduleID];
        }
    }
    NSDictionary *calendar =
        manifest.moduleConfigurations[MTCalendarIconsModuleID];
    if (hasStatic && hasCalendarBackground && calendar != nil) {
        [capabilitySet addObject:MTCalendarIconsModuleID];
        configs[MTCalendarIconsModuleID] = calendar;
    }
    if ([capabilitySet containsObject:MTBadgesModuleID]) {
        NSMutableSet<NSString *> *variants = [NSMutableSet set];
        for (MTThemeResource *resource in resources) {
            if ([resource.resourceKey.moduleID
                    isEqualToString:MTBadgesModuleID]) {
                [variants addObject:resource.resourceKey.variant];
            }
        }
        MTBadgeConfiguration *previous = [[MTBadgeConfiguration alloc]
            initWithDictionary:
                manifest.moduleConfigurations[MTBadgesModuleID]
            error:NULL];
        NSString *defaultVariant = [variants containsObject:
                previous.defaultVariant]
            ? previous.defaultVariant
            : [[variants.allObjects sortedArrayUsingSelector:
                @selector(compare:)] firstObject];
        MTBadgeConfiguration *badge = [MTBadgeConfiguration
            configurationWithDefaultVariant:defaultVariant];
        if (badge == nil) {
            if (error != NULL) {
                *error = MTThemeImportError(
                    MTThemeImportErrorImageValidation,
                    @"No complete badge style remains after image validation.",
                    nil);
            }
            return nil;
        }
        configs[MTBadgesModuleID] = badge.canonicalDictionary;
    }
    return [[MTThemeManifest alloc]
        initWithThemeID:manifest.themeID
        displayName:manifest.displayName
        author:manifest.author
        themeVersion:manifest.themeVersion
        importerID:manifest.importerID
        importerVersion:manifest.importerVersion
        sourceFingerprint:manifest.sourceFingerprint
        capabilities:capabilitySet.allObjects
        moduleConfigurations:configs
        resources:resources
        error:error];
}

@interface MTThemeImportPreviewArtifact ()
- (instancetype)initWithResource:(MTThemeResource *)resource
                     decodeResult:(MTSafeImageDecodeResult *)decodeResult;
@end

@implementation MTThemeImportPreviewArtifact

- (instancetype)initWithResource:(MTThemeResource *)resource
                     decodeResult:(MTSafeImageDecodeResult *)decodeResult {
    NSParameterAssert(resource != nil);
    NSParameterAssert(decodeResult != nil);
    self = [super init];
    if (self == nil) return nil;
    _resource = resource;
    _decodeResult = decodeResult;
    return self;
}

@end

typedef NS_ENUM(NSUInteger, MTPreparedThemeImportState) {
    MTPreparedThemeImportStateReady = 1,
    MTPreparedThemeImportStateCommitting = 2,
    MTPreparedThemeImportStateCommitted = 3,
    MTPreparedThemeImportStateDiscarded = 4,
    MTPreparedThemeImportStateDiscarding = 5,
};

@interface MTPreparedThemeImport ()
@property(nonatomic, strong) MTAssetStagingSession *assetStagingSession;
@property(nonatomic, assign) MTPreparedThemeImportState internalState;
- (instancetype)initWithManifest:(MTThemeManifest *)manifest
                       diagnostics:(NSArray<MTDiagnostic *> *)diagnostics
                 previewArtifacts:
                     (NSArray<MTThemeImportPreviewArtifact *> *)previewArtifacts
                   sourceFileCount:(NSUInteger)sourceFileCount
               recognizedFileCount:(NSUInteger)recognizedFileCount
                  ignoredFileCount:(NSUInteger)ignoredFileCount
                 rejectedFileCount:(NSUInteger)rejectedFileCount
                  uniqueAssetCount:(NSUInteger)uniqueAssetCount
                     assetByteCount:(uint64_t)assetByteCount
               assetStagingSession:
                   (MTAssetStagingSession *)assetStagingSession;
- (nullable MTAssetStagingSession *)beginCommit:(NSError **)error;
- (void)finishCommitWithRevision:(nullable MTThemeLibraryRevision *)revision;
@end

@implementation MTPreparedThemeImport

- (instancetype)initWithManifest:(MTThemeManifest *)manifest
                       diagnostics:(NSArray<MTDiagnostic *> *)diagnostics
                 previewArtifacts:
                     (NSArray<MTThemeImportPreviewArtifact *> *)previewArtifacts
                   sourceFileCount:(NSUInteger)sourceFileCount
               recognizedFileCount:(NSUInteger)recognizedFileCount
                  ignoredFileCount:(NSUInteger)ignoredFileCount
                 rejectedFileCount:(NSUInteger)rejectedFileCount
                  uniqueAssetCount:(NSUInteger)uniqueAssetCount
                     assetByteCount:(uint64_t)assetByteCount
               assetStagingSession:
                   (MTAssetStagingSession *)assetStagingSession {
    NSParameterAssert(manifest != nil);
    NSParameterAssert(assetStagingSession != nil);
    self = [super init];
    if (self == nil) return nil;
    _manifest = manifest;
    _diagnostics = [diagnostics copy];
    _previewArtifacts = [previewArtifacts copy];
    _sourceFileCount = sourceFileCount;
    _recognizedFileCount = recognizedFileCount;
    _ignoredFileCount = ignoredFileCount;
    _rejectedFileCount = rejectedFileCount;
    _uniqueAssetCount = uniqueAssetCount;
    _assetByteCount = assetByteCount;
    _assetStagingSession = assetStagingSession;
    _internalState = MTPreparedThemeImportStateReady;
    return self;
}

- (BOOL)isActive {
    @synchronized (self) {
        return (self.internalState == MTPreparedThemeImportStateReady ||
                self.internalState == MTPreparedThemeImportStateCommitting) &&
            self.assetStagingSession.isActive;
    }
}

- (MTAssetStagingSession *)beginCommit:(NSError **)error {
    @synchronized (self) {
        if (self.internalState != MTPreparedThemeImportStateReady ||
            !self.assetStagingSession.isActive) {
            MTThemeImportSetError(error, MTThemeImportErrorInvalidState,
                @"Only an active reviewed import can be committed.", nil);
            return nil;
        }
        self.internalState = MTPreparedThemeImportStateCommitting;
        return self.assetStagingSession;
    }
}

- (void)finishCommitWithRevision:(MTThemeLibraryRevision *)revision {
    @synchronized (self) {
        if (revision != nil) {
            self.internalState = MTPreparedThemeImportStateCommitted;
            self.assetStagingSession = nil;
        } else if (self.assetStagingSession.isActive) {
            self.internalState = MTPreparedThemeImportStateReady;
        } else {
            self.internalState = MTPreparedThemeImportStateDiscarded;
            self.assetStagingSession = nil;
        }
    }
}

- (BOOL)discard:(NSError **)error {
    MTAssetStagingSession *session = nil;
    @synchronized (self) {
        if (self.internalState == MTPreparedThemeImportStateCommitted ||
            self.internalState == MTPreparedThemeImportStateDiscarded) {
            return YES;
        }
        if (self.internalState == MTPreparedThemeImportStateCommitting) {
            return MTThemeImportSetError(error,
                MTThemeImportErrorInvalidState,
                @"A Library commit cannot be discarded concurrently.", nil);
        }
        session = self.assetStagingSession;
        self.internalState = MTPreparedThemeImportStateDiscarding;
    }
    NSError *discardError = nil;
    BOOL success = [session discard:&discardError];
    if (!success) {
        @synchronized (self) {
            if (self.internalState == MTPreparedThemeImportStateDiscarding) {
                self.internalState = session.isActive
                    ? MTPreparedThemeImportStateReady
                    : MTPreparedThemeImportStateDiscarded;
                if (!session.isActive) self.assetStagingSession = nil;
            }
        }
        return MTThemeImportSetError(error, MTThemeImportErrorCleanup,
            @"Unable to remove the provisional import safely.",
            discardError);
    }
    @synchronized (self) {
        self.internalState = MTPreparedThemeImportStateDiscarded;
        self.assetStagingSession = nil;
    }
    return YES;
}

- (void)dealloc {
    [self discard:NULL];
}

@end

@implementation MTThemeImportConfiguration

+ (instancetype)defaultConfiguration {
    MTImportLimits *limits = MTImportLimits.defaultLimits;
    MTImportSessionConfiguration *importConfiguration =
        MTImportSessionConfiguration.defaultConfiguration;
    MTAssetStagingConfiguration *assetConfiguration =
        MTAssetStagingConfiguration.defaultConfiguration;
    MTThemeLibraryConfiguration *libraryConfiguration =
        MTThemeLibraryConfiguration.defaultConfiguration;
    return [[self alloc]
        initWithLimits:limits
        importSessionsRootURL:importConfiguration.sessionsRootURL
        assetSessionsRootURL:assetConfiguration.sessionsRootURL
        libraryRootURL:libraryConfiguration.rootURL
        libraryFreeSpaceReserveBytes:
            libraryConfiguration.minimumFreeSpaceReserveBytes
        imageDecoder:MTSafeImageDecoder.defaultDecoder
        maximumPreviewCount:4
        previewMaximumDimension:160];
}

- (instancetype)initWithLimits:(MTImportLimits *)limits
          importSessionsRootURL:(NSURL *)importSessionsRootURL
           assetSessionsRootURL:(NSURL *)assetSessionsRootURL
                 libraryRootURL:(NSURL *)libraryRootURL
   libraryFreeSpaceReserveBytes:(uint64_t)libraryFreeSpaceReserveBytes
                   imageDecoder:(MTSafeImageDecoder *)imageDecoder
            maximumPreviewCount:(NSUInteger)maximumPreviewCount
        previewMaximumDimension:(uint32_t)previewMaximumDimension {
    NSParameterAssert(limits != nil);
    NSParameterAssert(importSessionsRootURL.isFileURL);
    NSParameterAssert(assetSessionsRootURL.isFileURL);
    NSParameterAssert(libraryRootURL.isFileURL);
    NSParameterAssert(imageDecoder != nil);
    NSParameterAssert(maximumPreviewCount > 0 && maximumPreviewCount <= 16);
    NSParameterAssert(previewMaximumDimension > 0 &&
        previewMaximumDimension <=
            imageDecoder.decodeLimits.maximumThumbnailDimensionPixels);
    NSString *importPath = importSessionsRootURL.path.stringByStandardizingPath;
    NSString *assetPath = assetSessionsRootURL.path.stringByStandardizingPath;
    NSString *libraryPath = libraryRootURL.path.stringByStandardizingPath;
    NSArray<NSString *> *paths = @[importPath, assetPath, libraryPath];
    for (NSUInteger left = 0; left < paths.count; left++) {
        for (NSUInteger right = left + 1; right < paths.count; right++) {
            NSString *leftPrefix = [paths[left]
                stringByAppendingString:@"/"];
            NSString *rightPrefix = [paths[right]
                stringByAppendingString:@"/"];
            NSParameterAssert(![paths[left] isEqualToString:paths[right]] &&
                ![paths[left] hasPrefix:rightPrefix] &&
                ![paths[right] hasPrefix:leftPrefix]);
        }
    }
    self = [super init];
    if (self == nil) return nil;
    _limits = limits;
    _importSessionsRootURL = [importSessionsRootURL copy];
    _assetSessionsRootURL = [assetSessionsRootURL copy];
    _libraryRootURL = [libraryRootURL copy];
    _libraryFreeSpaceReserveBytes = libraryFreeSpaceReserveBytes;
    _imageDecoder = imageDecoder;
    _maximumPreviewCount = maximumPreviewCount;
    _previewMaximumDimension = previewMaximumDimension;
    return self;
}

@end

typedef BOOL (^MTThemeImportSourceDiscarder)(NSError **error);

@interface MTThemeImportPipeline ()
@property(nonatomic, strong) MTThemeLibraryStore *libraryStore;
- (nullable MTPreparedThemeImport *)
    prepareAuditedThemeSource:(id<MTAuditedSource>)source
                    sourceName:(NSString *)sourceName
               sourceDiscarder:(MTThemeImportSourceDiscarder)sourceDiscarder
             cancellationToken:
                 (nullable MTImportCancellationToken *)cancellationToken
               progressHandler:
                   (nullable MTThemeImportProgressHandler)progressHandler
                         error:(NSError **)error;
@end

@implementation MTThemeImportPipeline

- (instancetype)init {
    return [self initWithConfiguration:
        MTThemeImportConfiguration.defaultConfiguration];
}

- (instancetype)initWithConfiguration:
        (MTThemeImportConfiguration *)configuration {
    NSParameterAssert(configuration != nil);
    self = [super init];
    if (self == nil) return nil;
    _configuration = configuration;
    MTThemeLibraryConfiguration *libraryConfiguration =
        [[MTThemeLibraryConfiguration alloc]
            initWithRootURL:configuration.libraryRootURL
                     limits:configuration.limits
       minimumFreeSpaceReserveBytes:
           configuration.libraryFreeSpaceReserveBytes];
    _libraryStore = [[MTThemeLibraryStore alloc]
        initWithConfiguration:libraryConfiguration];
    return self;
}

static void MTThemeImportReport(MTThemeImportProgressHandler handler,
                                MTThemeImportStage stage,
                                NSUInteger completed,
                                NSUInteger total) {
    if (handler != nil) handler(stage, completed, total);
}

static MTThemeImportErrorCode MTThemeImportCodeForCancellation(
    MTImportCancellationToken *_Nullable token,
    MTThemeImportErrorCode fallback) {
    return MTThemeImportIsCancelled(token)
        ? MTThemeImportErrorCancelled : fallback;
}

static NSString *MTThemeImportDescriptionForCancellation(
    MTImportCancellationToken *_Nullable token,
    NSString *fallback) {
    return MTThemeImportIsCancelled(token)
        ? @"Theme import was cancelled." : fallback;
}

- (MTPreparedThemeImport *)
    prepareZIPThemeAtURL:(NSURL *)archiveURL
              sourceName:(NSString *)sourceName
       cancellationToken:(MTImportCancellationToken *)cancellationToken
         progressHandler:(MTThemeImportProgressHandler)progressHandler
                   error:(NSError **)error {
    if (![archiveURL isKindOfClass:NSURL.class] || !archiveURL.isFileURL ||
        archiveURL.path.length == 0 ||
        ![sourceName isKindOfClass:NSString.class] || sourceName.length == 0) {
        MTThemeImportSetError(error, MTThemeImportErrorInvalidRequest,
            @"A local ZIP URL and display name are required.", nil);
        return nil;
    }
    if (MTThemeImportIsCancelled(cancellationToken)) {
        MTThemeImportSetError(error, MTThemeImportErrorCancelled,
            @"Theme import was cancelled before acquisition.", nil);
        return nil;
    }

    NSError *operationError = nil;
    MTThemeImportReport(progressHandler, MTThemeImportStageAcquiring, 0, 1);
    MTImportSessionConfiguration *importConfiguration =
        [[MTImportSessionConfiguration alloc]
        initWithSessionsRootURL:self.configuration.importSessionsRootURL
                         limits:self.configuration.limits];
    MTImportSession *importSession = [MTImportSession
        sessionByImportingFileAtURL:archiveURL
                      configuration:importConfiguration
                  cancellationToken:cancellationToken
                              error:&operationError];
    if (importSession == nil) {
        MTThemeImportSetError(error,
            MTThemeImportCodeForCancellation(cancellationToken,
                MTThemeImportErrorAcquisition),
            MTThemeImportDescriptionForCancellation(cancellationToken,
                @"The selected ZIP could not be copied into private storage."),
            operationError);
        return nil;
    }
    MTThemeImportReport(progressHandler, MTThemeImportStageAcquiring, 1, 1);

    MTThemeImportReport(progressHandler, MTThemeImportStageAuditing, 0, 1);
    MTSafeZIPArchiveReader *archiveReader = [[MTSafeZIPArchiveReader alloc]
        initWithLimits:self.configuration.limits];
    MTSafeZIPArchiveScan *source = [archiveReader
        scanArchiveAtURL:importSession.payloadURL
        cancellationToken:cancellationToken
        error:&operationError];
    if (source == nil) {
        NSError *cleanupError = nil;
        if (![importSession discard:&cleanupError]) {
            MTThemeImportSetError(error, MTThemeImportErrorCleanup,
                @"ZIP audit failed and its private source copy could not be removed safely.",
                cleanupError ?: operationError);
        } else {
            MTThemeImportSetError(error,
                MTThemeImportCodeForCancellation(cancellationToken,
                    MTThemeImportErrorArchiveAudit),
                MTThemeImportDescriptionForCancellation(cancellationToken,
                    @"The selected ZIP did not pass the complete archive audit."),
                operationError);
        }
        return nil;
    }
    MTThemeImportReport(progressHandler, MTThemeImportStageAuditing, 1, 1);

    return [self prepareAuditedThemeSource:source
        sourceName:sourceName
        sourceDiscarder:^BOOL(NSError **cleanupError) {
            return [importSession discard:cleanupError];
        }
        cancellationToken:cancellationToken
        progressHandler:progressHandler error:error];
}

- (MTPreparedThemeImport *)
    prepareArchiveThemeAtURL:(NSURL *)archiveURL
                  sourceName:(NSString *)sourceName
           cancellationToken:(MTImportCancellationToken *)cancellationToken
             progressHandler:(MTThemeImportProgressHandler)progressHandler
                       error:(NSError **)error {
    if (![archiveURL isKindOfClass:NSURL.class] || !archiveURL.isFileURL ||
        archiveURL.path.length == 0 ||
        ![sourceName isKindOfClass:NSString.class] || sourceName.length == 0) {
        MTThemeImportSetError(error, MTThemeImportErrorInvalidRequest,
            @"A supported local theme archive and display name are required.",
            nil);
        return nil;
    }
    NSString *extension = archiveURL.pathExtension.lowercaseString;
    NSSet<NSString *> *tarExtensions = [NSSet setWithArray:@[
        @"tar", @"tgz", @"gz", @"txz", @"xz", @"tzst", @"zst",
        @"zstd", @"tbz", @"tbz2", @"bz2",
    ]];
    BOOL debianPackage = [extension isEqualToString:@"deb"];
    if (![extension isEqualToString:@"zip"] && !debianPackage &&
        ![tarExtensions containsObject:extension]) {
        // The name says nothing useful, so let the content decide.
        switch (MTThemeImportSniffFormat(archiveURL)) {
            case MTThemeImportSniffedFormatZIP:
                extension = @"zip";
                break;
            case MTThemeImportSniffedFormatDebianPackage:
                debianPackage = YES;
                break;
            case MTThemeImportSniffedFormatTar:
                break;
            case MTThemeImportSniffedFormatUnknown:
                MTThemeImportSetError(error,
                    MTThemeImportErrorInvalidRequest,
                    @"A supported local theme archive and display name are required.",
                    nil);
                return nil;
        }
    }
    if ([extension isEqualToString:@"zip"]) {
        return [self prepareZIPThemeAtURL:archiveURL
            sourceName:sourceName cancellationToken:cancellationToken
            progressHandler:progressHandler error:error];
    }
    if (MTThemeImportIsCancelled(cancellationToken)) {
        MTThemeImportSetError(error, MTThemeImportErrorCancelled,
            @"Theme import was cancelled before acquisition.", nil);
        return nil;
    }

    NSError *operationError = nil;
    MTThemeImportReport(progressHandler, MTThemeImportStageAcquiring, 0, 1);
    MTImportSessionConfiguration *importConfiguration =
        [[MTImportSessionConfiguration alloc]
            initWithSessionsRootURL:
                self.configuration.importSessionsRootURL
                             limits:self.configuration.limits];
    MTImportSession *importSession = [MTImportSession
        sessionByImportingFileAtURL:archiveURL
        configuration:importConfiguration
        cancellationToken:cancellationToken
        error:&operationError];
    if (importSession == nil) {
        MTThemeImportSetError(error,
            MTThemeImportCodeForCancellation(cancellationToken,
                MTThemeImportErrorAcquisition),
            MTThemeImportDescriptionForCancellation(cancellationToken,
                @"The selected archive could not be copied into private storage."),
            operationError);
        return nil;
    }
    MTThemeImportReport(progressHandler, MTThemeImportStageAcquiring, 1, 1);
    MTThemeImportReport(progressHandler, MTThemeImportStageAuditing, 0, 1);
    MTSafeDirectoryScanner *scanner = [[MTSafeDirectoryScanner alloc]
        initWithLimits:self.configuration.limits];
    MTExpandedArchiveSession *expanded = [MTExpandedArchiveSession
        sessionByExpandingArchiveAtURL:importSession.payloadURL
        format:debianPackage ? MTExpandedArchiveFormatDebianPackage
                             : MTExpandedArchiveFormatTar
        sessionsRootURL:self.configuration.importSessionsRootURL
        limits:self.configuration.limits
        cancellationToken:cancellationToken
        auditor:^id<MTAuditedSource>(NSURL *directoryURL,
                                     NSError **auditError) {
            return [scanner scanDirectorySourceAtURL:directoryURL
                cancellationToken:cancellationToken error:auditError];
        }
        error:&operationError];
    if (expanded == nil) {
        NSError *cleanupError = nil;
        if (![importSession discard:&cleanupError]) {
            MTThemeImportSetError(error, MTThemeImportErrorCleanup,
                @"Archive expansion failed and its private source copy could not be removed.",
                cleanupError ?: operationError);
        } else {
            MTThemeImportSetError(error,
                MTThemeImportCodeForCancellation(cancellationToken,
                    MTThemeImportErrorArchiveAudit),
                MTThemeImportDescriptionForCancellation(cancellationToken,
                    @"The selected archive did not contain a supported theme tree."),
                operationError);
        }
        return nil;
    }
    MTThemeImportReport(progressHandler, MTThemeImportStageAuditing, 1, 1);

    return [self prepareAuditedThemeSource:expanded.auditedSource
        sourceName:sourceName
        sourceDiscarder:^BOOL(NSError **cleanupError) {
            NSError *expandedError = nil;
            BOOL expandedClean = [expanded discard:&expandedError];
            NSError *importError = nil;
            BOOL importClean = [importSession discard:&importError];
            if ((!expandedClean || !importClean) && cleanupError != NULL) {
                *cleanupError = expandedError ?: importError;
            }
            return expandedClean && importClean;
        }
        cancellationToken:cancellationToken
        progressHandler:progressHandler error:error];
}

- (MTPreparedThemeImport *)
    prepareDirectoryThemeAtURL:(NSURL *)directoryURL
                     sourceName:(NSString *)sourceName
              cancellationToken:
                  (MTImportCancellationToken *)cancellationToken
                progressHandler:
                    (MTThemeImportProgressHandler)progressHandler
                          error:(NSError **)error {
    if (![directoryURL isKindOfClass:NSURL.class] ||
        !directoryURL.isFileURL || directoryURL.path.length == 0 ||
        ![sourceName isKindOfClass:NSString.class] || sourceName.length == 0) {
        MTThemeImportSetError(error, MTThemeImportErrorInvalidRequest,
            @"A local directory URL and display name are required.", nil);
        return nil;
    }
    if (MTThemeImportIsCancelled(cancellationToken)) {
        MTThemeImportSetError(error, MTThemeImportErrorCancelled,
            @"Theme import was cancelled before directory acquisition.", nil);
        return nil;
    }

    MTThemeImportReport(progressHandler, MTThemeImportStageAcquiring, 0, 1);
    MTDirectorySnapshotConfiguration *snapshotConfiguration =
        [[MTDirectorySnapshotConfiguration alloc]
            initWithSessionsRootURL:
                self.configuration.importSessionsRootURL
                             limits:self.configuration.limits
               minimumFreeSpaceReserveBytes:
                   self.configuration.libraryFreeSpaceReserveBytes];
    MTSafeDirectoryScanner *scanner = [[MTSafeDirectoryScanner alloc]
        initWithLimits:self.configuration.limits];
    NSError *operationError = nil;
    MTDirectorySnapshotSession *snapshot =
        [MTDirectorySnapshotSession
            sessionBySnapshottingDirectoryAtURL:directoryURL
            configuration:snapshotConfiguration
            cancellationToken:cancellationToken
            auditor:^id<MTAuditedSource>(NSURL *candidateURL,
                                         NSError **auditError) {
                return [scanner
                    scanDirectorySourceAtURL:candidateURL
                    cancellationToken:cancellationToken
                    error:auditError];
            }
            error:&operationError];
    if (snapshot == nil) {
        MTThemeImportSetError(error,
            MTThemeImportCodeForCancellation(cancellationToken,
                MTThemeImportErrorDirectorySnapshot),
            MTThemeImportDescriptionForCancellation(cancellationToken,
                @"The selected directory could not become a verified private snapshot."),
            operationError);
        return nil;
    }
    MTThemeImportReport(progressHandler, MTThemeImportStageAcquiring, 1, 1);
    MTThemeImportReport(progressHandler, MTThemeImportStageAuditing, 0, 1);
    MTThemeImportReport(progressHandler, MTThemeImportStageAuditing, 1, 1);

    return [self prepareAuditedThemeSource:snapshot.auditedSource
        sourceName:sourceName
        sourceDiscarder:^BOOL(NSError **cleanupError) {
            return [snapshot discard:cleanupError];
        }
        cancellationToken:cancellationToken
        progressHandler:progressHandler error:error];
}

- (MTPreparedThemeImport *)
    prepareAuditedThemeSource:(id<MTAuditedSource>)source
                    sourceName:(NSString *)sourceName
               sourceDiscarder:(MTThemeImportSourceDiscarder)sourceDiscarder
             cancellationToken:
                 (MTImportCancellationToken *)cancellationToken
               progressHandler:
                   (MTThemeImportProgressHandler)progressHandler
                         error:(NSError **)error {
    if (source == nil ||
        ![(id)source conformsToProtocol:@protocol(MTAuditedSource)] ||
        ![sourceName isKindOfClass:NSString.class] || sourceName.length == 0 ||
        sourceDiscarder == nil) {
        NSError *cleanupError = nil;
        BOOL cleaned = sourceDiscarder == nil ||
            sourceDiscarder(&cleanupError);
        MTThemeImportSetError(error,
            cleaned ? MTThemeImportErrorInvalidRequest
                    : MTThemeImportErrorCleanup,
            cleaned
                ? @"A verified audited source and cleanup owner are required."
                : @"An invalid audited source could not be cleaned safely.",
            cleanupError);
        return nil;
    }

    MTAssetStagingSession *assetSession = nil;
    NSError *operationError = nil;
    MTThemeImportErrorCode failureCode = MTThemeImportErrorInvalidRequest;
    NSString *failureDescription = @"Theme import failed.";
    MTThemeImportMetadata *importMetadata = nil;
    MTIconBundlesImportResult *importResult = nil;
    MTThemeManifest *validatedManifest = nil;
    NSMutableArray<MTDiagnostic *> *validatedDiagnostics = nil;
    NSUInteger finalRecognizedFileCount = 0;
    NSUInteger finalIgnoredFileCount = 0;
    NSUInteger finalRejectedFileCount = 0;
    NSMutableDictionary<NSString *, MTThemeResource *> *resourcesByDigest = nil;
    NSArray<NSString *> *sortedDigests = nil;
    uint64_t expectedAssetBytes = 0;
    MTAssetStagingConfiguration *assetConfiguration = nil;
    NSMutableDictionary<NSString *, MTStagedAsset *> *stagedByDigest = nil;
    NSUInteger stagedCount = 0;
    NSMutableArray<MTThemeImportPreviewArtifact *> *previews = nil;
    NSMutableSet<NSString *> *invalidDigests = nil;
    NSMutableDictionary<NSString *, NSError *> *validationErrorsByDigest = nil;
    NSUInteger validatedCount = 0;
    NSError *sourceCleanupError = nil;

    source = [MTThemeSourceRoot sourceByResolvingThemeRootInSource:source
                                                             error:&operationError];
    if (source == nil) {
        failureCode = MTThemeImportErrorImporter;
        failureDescription = @"The selected theme root could not be resolved.";
        goto fail;
    }

    if (MTThemeImportIsCancelled(cancellationToken)) {
        operationError = MTThemeImportError(MTThemeImportErrorCancelled,
            @"Theme import was cancelled before parsing.", nil);
        failureCode = MTThemeImportErrorCancelled;
        failureDescription = @"Theme import was cancelled.";
        goto fail;
    }

    MTThemeImportReport(progressHandler, MTThemeImportStageParsing, 0, 2);
    importMetadata = [[[MTThemeInfoMetadataImporter alloc] init]
            importMetadataFromSource:source
                            sourceName:sourceName
                     cancellationToken:cancellationToken
                                 error:&operationError];
    if (importMetadata == nil) {
        failureCode = MTThemeImportCodeForCancellation(cancellationToken,
            MTThemeImportErrorMetadata);
        failureDescription = MTThemeImportDescriptionForCancellation(
            cancellationToken,
            @"Theme display metadata could not be read safely.");
        goto fail;
    }
    MTThemeImportReport(progressHandler, MTThemeImportStageParsing, 1, 2);
    importResult = [[[MTIconBundlesImporter alloc] init]
            importSourceInventory:source.inventory
                       sourceName:sourceName
                   importMetadata:importMetadata
                            error:&operationError];
    if (importResult == nil) {
        failureCode = MTThemeImportCodeForCancellation(cancellationToken,
            MTThemeImportErrorImporter);
        failureDescription = MTThemeImportDescriptionForCancellation(
            cancellationToken,
            @"No supported static icon resources could be imported.");
        goto fail;
    }
    validatedManifest = importResult.manifest;
    validatedDiagnostics = [importResult.diagnostics mutableCopy];
    finalRecognizedFileCount = importResult.recognizedFileCount;
    finalIgnoredFileCount = importResult.ignoredFileCount;
    finalRejectedFileCount = importResult.rejectedFileCount;
    MTThemeImportReport(progressHandler, MTThemeImportStageParsing, 2, 2);

    resourcesByDigest = [NSMutableDictionary dictionary];
    for (MTThemeResource *resource in importResult.manifest.resources) {
        MTSourceFile *file = [source.inventory
            fileAtRelativePath:resource.relativeAssetPath];
        if (file == nil ||
            ![file.contentSHA256 isEqualToString:resource.contentSHA256]) {
            operationError = MTThemeImportError(
                MTThemeImportErrorImporter,
                @"An imported resource no longer matches the audited inventory.",
                nil);
            failureCode = MTThemeImportErrorImporter;
            failureDescription =
                @"The imported resource map is inconsistent.";
            goto fail;
        }
        MTThemeResource *existing = resourcesByDigest[resource.contentSHA256];
        if (existing == nil || [resource.relativeAssetPath
                compare:existing.relativeAssetPath
               options:NSLiteralSearch] == NSOrderedAscending) {
            resourcesByDigest[resource.contentSHA256] = resource;
        }
    }
    sortedDigests = [resourcesByDigest.allKeys
        sortedArrayUsingSelector:@selector(compare:)];
    if (sortedDigests.count == 0 ||
        sortedDigests.count > self.configuration.limits.maximumRegularFiles) {
        operationError = MTThemeImportError(MTThemeImportErrorImporter,
            @"The imported theme has an invalid unique asset count.", nil);
        failureCode = MTThemeImportErrorImporter;
        failureDescription = @"The imported asset set is invalid.";
        goto fail;
    }
    for (NSString *digest in sortedDigests) {
        MTThemeResource *resource = resourcesByDigest[digest];
        MTSourceFile *file = [source.inventory
            fileAtRelativePath:resource.relativeAssetPath];
        if (file.byteCount > UINT64_MAX - expectedAssetBytes) {
            operationError = MTThemeImportError(
                MTThemeImportErrorAssetStaging,
                @"The unique asset byte total overflows its policy.", nil);
            failureCode = MTThemeImportErrorAssetStaging;
            failureDescription = @"The imported asset total is invalid.";
            goto fail;
        }
        expectedAssetBytes += file.byteCount;
    }

    assetConfiguration = [[MTAssetStagingConfiguration alloc]
        initWithSessionsRootURL:self.configuration.assetSessionsRootURL
                         limits:self.configuration.limits];
    assetSession = [MTAssetStagingSession
        sessionWithConfiguration:assetConfiguration error:&operationError];
    if (assetSession == nil) {
        failureCode = MTThemeImportErrorAssetStaging;
        failureDescription =
            @"A private provisional asset transaction could not be created.";
        goto fail;
    }

    stagedByDigest =
        [NSMutableDictionary dictionaryWithCapacity:sortedDigests.count];
    MTThemeImportReport(progressHandler, MTThemeImportStageStaging, 0,
                        sortedDigests.count);
    for (NSString *digest in sortedDigests) {
        if (MTThemeImportIsCancelled(cancellationToken)) {
            operationError = MTThemeImportError(MTThemeImportErrorCancelled,
                @"Theme import was cancelled during asset staging.", nil);
            failureCode = MTThemeImportErrorCancelled;
            failureDescription = @"Theme import was cancelled.";
            goto fail;
        }
        MTThemeResource *resource = resourcesByDigest[digest];
        MTSourceFile *file = [source.inventory
            fileAtRelativePath:resource.relativeAssetPath];
        MTStagedAsset *asset = [assetSession
            stageAssetAtRelativePath:resource.relativeAssetPath
                          fromSource:source
                    maximumByteCount:file.byteCount
                   cancellationToken:cancellationToken
                               error:&operationError];
        if (asset == nil || ![asset.contentSHA256 isEqualToString:digest]) {
            failureCode = MTThemeImportCodeForCancellation(cancellationToken,
                MTThemeImportErrorAssetStaging);
            failureDescription = MTThemeImportDescriptionForCancellation(
                cancellationToken,
                @"An audited asset could not enter private staging.");
            goto fail;
        }
        stagedByDigest[digest] = asset;
        stagedCount++;
        MTThemeImportReport(progressHandler, MTThemeImportStageStaging,
                            stagedCount, sortedDigests.count);
    }
    if (assetSession.stagedObjectCount != sortedDigests.count ||
        assetSession.stagedByteCount != expectedAssetBytes) {
        operationError = MTThemeImportError(
            MTThemeImportErrorAssetStaging,
            @"The provisional asset totals do not match the import plan.", nil);
        failureCode = MTThemeImportErrorAssetStaging;
        failureDescription = @"The provisional asset set is inconsistent.";
        goto fail;
    }

    previews = [NSMutableArray
        arrayWithCapacity:self.configuration.maximumPreviewCount];
    invalidDigests = [NSMutableSet set];
    validationErrorsByDigest = [NSMutableDictionary dictionary];
    MTThemeImportReport(progressHandler, MTThemeImportStageValidating, 0,
                        sortedDigests.count);
    for (NSString *digest in sortedDigests) {
        @autoreleasepool {
            MTStagedAsset *asset = stagedByDigest[digest];
            uint32_t previewDimension =
                previews.count < self.configuration.maximumPreviewCount
                    ? self.configuration.previewMaximumDimension : 1;
            MTSafeImageDecodeResult *decodeResult =
                [self.configuration.imageDecoder
                    decodeOwnedPNGFileAtURL:asset.ownedFileURL
                    thumbnailMaximumDimension:previewDimension
                    cancellationToken:cancellationToken
                    error:&operationError];
            if (decodeResult == nil) {
                if (MTThemeImportIsCancelled(cancellationToken) ||
                    ([operationError.domain
                        isEqualToString:MTSafeImageDecoderErrorDomain] &&
                     operationError.code ==
                        MTSafeImageDecoderErrorCancelled)) {
                    failureCode = MTThemeImportErrorCancelled;
                    failureDescription = @"Theme import was cancelled.";
                    goto fail;
                }
                [invalidDigests addObject:digest];
                if (operationError != nil) {
                    validationErrorsByDigest[digest] = operationError;
                }
                operationError = nil;
            } else if (previews.count <
                       self.configuration.maximumPreviewCount) {
                MTThemeImportPreviewArtifact *artifact =
                    [[MTThemeImportPreviewArtifact alloc]
                        initWithResource:resourcesByDigest[digest]
                             decodeResult:decodeResult];
                [previews addObject:artifact];
            }
        }
        validatedCount++;
        MTThemeImportReport(progressHandler, MTThemeImportStageValidating,
                            validatedCount, sortedDigests.count);
    }

    if (invalidDigests.count > 0) {
        validatedManifest = MTThemeImportManifestByRemovingDigests(
            importResult.manifest, invalidDigests, &operationError);
        if (validatedManifest == nil) {
            failureCode = MTThemeImportErrorImageValidation;
            failureDescription =
                @"No usable theme resources remain after image validation.";
            goto fail;
        }
        NSMutableSet<NSString *> *requiredDigests = [NSMutableSet set];
        for (MTThemeResource *resource in validatedManifest.resources) {
            [requiredDigests addObject:resource.contentSHA256];
        }
        for (NSString *digest in [sortedDigests copy]) {
            if ([requiredDigests containsObject:digest]) continue;
            if (![assetSession removeStagedAssetWithContentSHA256:digest
                                                            error:&operationError]) {
                failureCode = MTThemeImportErrorAssetStaging;
                failureDescription =
                    @"A rejected resource could not leave private staging.";
                goto fail;
            }
            [stagedByDigest removeObjectForKey:digest];
        }
        NSMutableSet<NSString *> *retainedPaths = [NSMutableSet set];
        for (MTThemeResource *resource in validatedManifest.resources) {
            [retainedPaths addObject:resource.relativeAssetPath];
        }
        NSMutableSet<NSString *> *rejectedPaths = [NSMutableSet set];
        NSMutableSet<NSString *> *dependentSkippedPaths =
            [NSMutableSet set];
        for (MTThemeResource *resource in importResult.manifest.resources) {
            if ([retainedPaths containsObject:resource.relativeAssetPath]) {
                continue;
            }
            BOOL invalidImage = [invalidDigests containsObject:
                resource.contentSHA256];
            NSMutableSet<NSString *> *pathSet = invalidImage
                ? rejectedPaths : dependentSkippedPaths;
            if ([pathSet containsObject:resource.relativeAssetPath]) {
                continue;
            }
            [pathSet addObject:resource.relativeAssetPath];
            NSError *validationError = invalidImage
                ? validationErrorsByDigest[resource.contentSHA256] : nil;
            [validatedDiagnostics addObject:[[MTDiagnostic alloc]
                initWithSeverity:MTDiagnosticSeverityWarning
                            code:invalidImage
                ? @"import.image.invalid-resource-skipped"
                : @"import.image.dependent-resource-skipped"
                         summary:invalidImage
                ? @"One invalid image resource was skipped; the rest of the theme remains importable."
                : @"A valid image whose required companion resource was unavailable was skipped."
                     resourceKey:resource.resourceKey
                         details:@{
                             @"path" : resource.relativeAssetPath,
                             @"reason" : invalidImage
                                ? (validationError.localizedDescription ?:
                                    @"Image decoding failed.")
                                : @"A required companion image did not survive validation.",
                         }
                           error:NULL]];
        }
        NSUInteger removedPathCount = rejectedPaths.count +
            dependentSkippedPaths.count;
        finalRecognizedFileCount = removedPathCount >
                finalRecognizedFileCount
            ? 0 : finalRecognizedFileCount - removedPathCount;
        finalRejectedFileCount += rejectedPaths.count;
        finalIgnoredFileCount += dependentSkippedPaths.count;
        sortedDigests = [requiredDigests.allObjects
            sortedArrayUsingSelector:@selector(compare:)];
        expectedAssetBytes = assetSession.stagedByteCount;
        NSIndexSet *removedPreviews = [previews
            indexesOfObjectsPassingTest:^BOOL(
                MTThemeImportPreviewArtifact *artifact,
                __unused NSUInteger index,
                __unused BOOL *stop) {
            return ![requiredDigests containsObject:
                artifact.resource.contentSHA256];
        }];
        [previews removeObjectsAtIndexes:removedPreviews];
        if (assetSession.stagedObjectCount != sortedDigests.count ||
            sortedDigests.count == 0) {
            operationError = MTThemeImportError(
                MTThemeImportErrorAssetStaging,
                @"The filtered provisional asset set is inconsistent.", nil);
            failureCode = MTThemeImportErrorAssetStaging;
            failureDescription =
                @"The filtered provisional asset set is inconsistent.";
            goto fail;
        }
    }

    if (MTThemeImportIsCancelled(cancellationToken)) {
        operationError = MTThemeImportError(MTThemeImportErrorCancelled,
            @"Theme import was cancelled before review.", nil);
        failureCode = MTThemeImportErrorCancelled;
        failureDescription = @"Theme import was cancelled.";
        goto fail;
    }
    if (!sourceDiscarder(&sourceCleanupError)) {
        operationError = sourceCleanupError;
        failureCode = MTThemeImportErrorCleanup;
        failureDescription =
            @"The private source snapshot could not be removed safely.";
        goto fail;
    }

    return [[MTPreparedThemeImport alloc]
        initWithManifest:validatedManifest
        diagnostics:validatedDiagnostics
        previewArtifacts:previews
        sourceFileCount:source.inventory.files.count
        recognizedFileCount:finalRecognizedFileCount
        ignoredFileCount:finalIgnoredFileCount
        rejectedFileCount:finalRejectedFileCount
        uniqueAssetCount:sortedDigests.count
        assetByteCount:expectedAssetBytes
        assetStagingSession:assetSession];

fail: {
        NSError *cleanupError = nil;
        BOOL assetClean = assetSession == nil || [assetSession discard:&cleanupError];
        NSError *failedSourceCleanupError = nil;
        BOOL sourceClean = sourceDiscarder(&failedSourceCleanupError);
        if (!assetClean || !sourceClean) {
            NSError *underlyingCleanup = cleanupError ?:
                failedSourceCleanupError;
            MTThemeImportSetError(error, MTThemeImportErrorCleanup,
                @"Theme import failed and temporary data could not be removed safely.",
                underlyingCleanup ?: operationError);
        } else {
            MTThemeImportSetError(error, failureCode, failureDescription,
                                  operationError);
        }
        return nil;
    }
}

- (MTThemeLibraryRevision *)
    commitPreparedImport:(MTPreparedThemeImport *)preparedImport
       cancellationToken:(MTImportCancellationToken *)cancellationToken
         progressHandler:(MTThemeImportProgressHandler)progressHandler
                   error:(NSError **)error {
    if (![preparedImport isKindOfClass:MTPreparedThemeImport.class]) {
        MTThemeImportSetError(error, MTThemeImportErrorInvalidRequest,
            @"A valid reviewed import is required.", nil);
        return nil;
    }
    if (MTThemeImportIsCancelled(cancellationToken)) {
        MTThemeImportSetError(error, MTThemeImportErrorCancelled,
            @"Theme import was cancelled before Library commit.", nil);
        return nil;
    }
    NSError *stateError = nil;
    MTAssetStagingSession *assetSession =
        [preparedImport beginCommit:&stateError];
    if (assetSession == nil) {
        if (error != NULL) *error = stateError;
        return nil;
    }
    MTThemeImportReport(progressHandler, MTThemeImportStageCommitting, 0, 1);
    NSError *commitError = nil;
    MTThemeLibraryRevision *revision = [self.libraryStore
        commitManifest:preparedImport.manifest
        fromAssetStagingSession:assetSession
        cancellationToken:cancellationToken
        error:&commitError];
    [preparedImport finishCommitWithRevision:revision];
    if (revision == nil) {
        MTThemeImportErrorCode code = MTThemeImportCodeForCancellation(
            cancellationToken, MTThemeImportErrorLibraryCommit);
        NSString *description = MTThemeImportDescriptionForCancellation(
            cancellationToken,
            @"The reviewed theme could not be committed to the Library.");
        MTThemeImportSetError(error, code, description, commitError);
        return nil;
    }
    MTThemeImportReport(progressHandler, MTThemeImportStageCommitting, 1, 1);
    return revision;
}

+ (BOOL)recoverAbandonedStateWithConfiguration:
            (MTThemeImportConfiguration *)configuration
                                             error:(NSError **)error {
    if (![configuration isKindOfClass:MTThemeImportConfiguration.class]) {
        return MTThemeImportSetError(error,
            MTThemeImportErrorInvalidRequest,
            @"A valid import-workflow configuration is required.", nil);
    }
    NSError *expandedCleanupError = nil;
    if (![MTExpandedArchiveSession
            discardAbandonedSessionsAtRootURL:
                configuration.importSessionsRootURL
            error:&expandedCleanupError]) {
        return MTThemeImportSetError(error, MTThemeImportErrorCleanup,
            @"Abandoned expanded-archive sessions could not be removed safely.",
            expandedCleanupError);
    }
    MTImportSessionConfiguration *importConfiguration =
        [[MTImportSessionConfiguration alloc]
            initWithSessionsRootURL:configuration.importSessionsRootURL
                             limits:configuration.limits];
    NSError *cleanupError = nil;
    if (![MTImportSession
            discardAbandonedSessionsWithConfiguration:importConfiguration
                                                 error:&cleanupError]) {
        return MTThemeImportSetError(error, MTThemeImportErrorCleanup,
            @"Abandoned source sessions could not be removed safely.",
            cleanupError);
    }
    MTDirectorySnapshotConfiguration *snapshotConfiguration =
        [[MTDirectorySnapshotConfiguration alloc]
            initWithSessionsRootURL:configuration.importSessionsRootURL
                             limits:configuration.limits
               minimumFreeSpaceReserveBytes:
                   configuration.libraryFreeSpaceReserveBytes];
    if (![MTDirectorySnapshotSession
            discardAbandonedSessionsWithConfiguration:snapshotConfiguration
                                                 error:&cleanupError]) {
        return MTThemeImportSetError(error, MTThemeImportErrorCleanup,
            @"Abandoned directory snapshots could not be removed safely.",
            cleanupError);
    }
    MTAssetStagingConfiguration *assetConfiguration =
        [[MTAssetStagingConfiguration alloc]
            initWithSessionsRootURL:configuration.assetSessionsRootURL
                             limits:configuration.limits];
    if (![MTAssetStagingSession
            discardAbandonedSessionsWithConfiguration:assetConfiguration
                                                 error:&cleanupError]) {
        return MTThemeImportSetError(error, MTThemeImportErrorCleanup,
            @"Abandoned asset sessions could not be removed safely.",
            cleanupError);
    }
    MTThemeLibraryConfiguration *libraryConfiguration =
        [[MTThemeLibraryConfiguration alloc]
            initWithRootURL:configuration.libraryRootURL
                     limits:configuration.limits
       minimumFreeSpaceReserveBytes:
           configuration.libraryFreeSpaceReserveBytes];
    MTThemeLibraryStore *library = [[MTThemeLibraryStore alloc]
        initWithConfiguration:libraryConfiguration];
    if (![library recoverAbandonedLibraryOperationsWithError:&cleanupError]) {
        return MTThemeImportSetError(error, MTThemeImportErrorCleanup,
            @"Abandoned Library operations could not be recovered safely.",
            cleanupError);
    }
    return YES;
}

@end
