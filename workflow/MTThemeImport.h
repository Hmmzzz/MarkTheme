#import <Foundation/Foundation.h>

@class MTDiagnostic;
@class MTImportCancellationToken;
@class MTImportLimits;
@class MTSafeImageDecodeResult;
@class MTSafeImageDecoder;
@class MTThemeLibraryRevision;
@class MTThemeManifest;
@class MTThemeResource;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTThemeImportErrorDomain;

typedef NS_ENUM(NSInteger, MTThemeImportErrorCode) {
    MTThemeImportErrorInvalidRequest = 1,
    MTThemeImportErrorCancelled = 2,
    MTThemeImportErrorAcquisition = 3,
    MTThemeImportErrorArchiveAudit = 4,
    MTThemeImportErrorMetadata = 5,
    MTThemeImportErrorImporter = 6,
    MTThemeImportErrorAssetStaging = 7,
    MTThemeImportErrorImageValidation = 8,
    MTThemeImportErrorCleanup = 9,
    MTThemeImportErrorLibraryCommit = 10,
    MTThemeImportErrorInvalidState = 11,
    MTThemeImportErrorDirectorySnapshot = 12,
};

typedef NS_ENUM(NSUInteger, MTThemeImportStage) {
    MTThemeImportStageAcquiring = 1,
    MTThemeImportStageAuditing = 2,
    MTThemeImportStageParsing = 3,
    MTThemeImportStageStaging = 4,
    MTThemeImportStageValidating = 5,
    MTThemeImportStageCommitting = 6,
};

typedef void (^MTThemeImportProgressHandler)(MTThemeImportStage stage,
                                              NSUInteger completedUnitCount,
                                              NSUInteger totalUnitCount);

// One bounded raw preview retained for Import Review. The full-resolution
// image has already been decoded and released by MTSafeImageDecoder.
@interface MTThemeImportPreviewArtifact : NSObject

@property(nonatomic, strong, readonly) MTThemeResource *resource;
@property(nonatomic, strong, readonly) MTSafeImageDecodeResult *decodeResult;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

// Immutable review data plus the private provisional asset ownership needed
// for an explicit later commit. Deallocation or -discard removes uncommitted
// assets; no external picker URL survives preparation.
@interface MTPreparedThemeImport : NSObject

@property(nonatomic, strong, readonly) MTThemeManifest *manifest;
@property(nonatomic, copy, readonly) NSArray<MTDiagnostic *> *diagnostics;
@property(nonatomic, copy, readonly)
    NSArray<MTThemeImportPreviewArtifact *> *previewArtifacts;
@property(nonatomic, assign, readonly) NSUInteger sourceFileCount;
@property(nonatomic, assign, readonly) NSUInteger recognizedFileCount;
@property(nonatomic, assign, readonly) NSUInteger ignoredFileCount;
@property(nonatomic, assign, readonly) NSUInteger rejectedFileCount;
@property(nonatomic, assign, readonly) NSUInteger uniqueAssetCount;
@property(nonatomic, assign, readonly) uint64_t assetByteCount;
@property(nonatomic, assign, readonly, getter=isActive) BOOL active;

- (BOOL)discard:(NSError **)error;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

// One policy owner prevents acquisition, archive, staging, and Library limits
// from silently drifting across independently constructed default objects.
@interface MTThemeImportConfiguration : NSObject

@property(nonatomic, strong, readonly) MTImportLimits *limits;
@property(nonatomic, copy, readonly) NSURL *importSessionsRootURL;
@property(nonatomic, copy, readonly) NSURL *assetSessionsRootURL;
@property(nonatomic, copy, readonly) NSURL *libraryRootURL;
@property(nonatomic, assign, readonly) uint64_t libraryFreeSpaceReserveBytes;
@property(nonatomic, strong, readonly) MTSafeImageDecoder *imageDecoder;
@property(nonatomic, assign, readonly) NSUInteger maximumPreviewCount;
@property(nonatomic, assign, readonly) uint32_t previewMaximumDimension;

+ (instancetype)defaultConfiguration;
- (instancetype)initWithLimits:(MTImportLimits *)limits
          importSessionsRootURL:(NSURL *)importSessionsRootURL
           assetSessionsRootURL:(NSURL *)assetSessionsRootURL
                 libraryRootURL:(NSURL *)libraryRootURL
   libraryFreeSpaceReserveBytes:(uint64_t)libraryFreeSpaceReserveBytes
                   imageDecoder:(MTSafeImageDecoder *)imageDecoder
            maximumPreviewCount:(NSUInteger)maximumPreviewCount
        previewMaximumDimension:(uint32_t)previewMaximumDimension
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

// Synchronous control-plane pipeline. Callers must run it on a bounded worker
// queue. UIKit and target-process code do not belong in this component.
@interface MTThemeImportPipeline : NSObject

@property(nonatomic, strong, readonly) MTThemeImportConfiguration *configuration;

- (instancetype)initWithConfiguration:
    (MTThemeImportConfiguration *)configuration NS_DESIGNATED_INITIALIZER;
- (instancetype)init;

- (nullable MTPreparedThemeImport *)
    prepareZIPThemeAtURL:(NSURL *)archiveURL
              sourceName:(NSString *)sourceName
       cancellationToken:
           (nullable MTImportCancellationToken *)cancellationToken
         progressHandler:
             (nullable MTThemeImportProgressHandler)progressHandler
                   error:(NSError **)error;

// Unified file-container entry point. ZIP keeps its two-pass reader; Debian
// packages and tar/gzip/xz/zstd containers expand into one private audited
// directory before the same theme-root/import pipeline runs.
- (nullable MTPreparedThemeImport *)
    prepareArchiveThemeAtURL:(NSURL *)archiveURL
                  sourceName:(NSString *)sourceName
           cancellationToken:
               (nullable MTImportCancellationToken *)cancellationToken
             progressHandler:
                 (nullable MTThemeImportProgressHandler)progressHandler
                       error:(NSError **)error;

// Bottom-level directory entry point. It takes an App-owned snapshot before
// parsing and releases both the external scope and private snapshot before
// returning Review data.
- (nullable MTPreparedThemeImport *)
    prepareDirectoryThemeAtURL:(NSURL *)directoryURL
                     sourceName:(NSString *)sourceName
              cancellationToken:
                  (nullable MTImportCancellationToken *)cancellationToken
                progressHandler:
                    (nullable MTThemeImportProgressHandler)progressHandler
                          error:(NSError **)error;

- (nullable MTThemeLibraryRevision *)
    commitPreparedImport:(MTPreparedThemeImport *)preparedImport
       cancellationToken:
           (nullable MTImportCancellationToken *)cancellationToken
         progressHandler:
             (nullable MTThemeImportProgressHandler)progressHandler
                   error:(NSError **)error;

// Startup-only. No workflow or Library mutation may be active while this
// exact-root sweep removes import sessions and completes Library transactions.
+ (BOOL)recoverAbandonedStateWithConfiguration:
            (MTThemeImportConfiguration *)configuration
                                             error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
