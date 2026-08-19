#import <Foundation/Foundation.h>

@class MTAssetStagingSession;
@class MTImportCancellationToken;
@class MTImportLimits;
@class MTThemeManifest;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTThemeLibraryStoreErrorDomain;

typedef NS_ENUM(NSInteger, MTThemeLibraryStoreErrorCode) {
    MTThemeLibraryStoreErrorInvalidRequest = 1,
    MTThemeLibraryStoreErrorStorage = 2,
    MTThemeLibraryStoreErrorVerification = 3,
    MTThemeLibraryStoreErrorBusy = 4,
    MTThemeLibraryStoreErrorCancelled = 5,
    MTThemeLibraryStoreErrorLimitExceeded = 6,
    MTThemeLibraryStoreErrorInsufficientSpace = 7,
    MTThemeLibraryStoreErrorRecovery = 8,
    MTThemeLibraryStoreErrorNotFound = 9,
    MTThemeLibraryStoreErrorAssetSetMismatch = 10,
    MTThemeLibraryStoreErrorCurrentRevision = 11,
    MTThemeLibraryStoreErrorUnsupportedVersion = 12,
};

// Immutable policy shared by the formal commit and read paths. The reserve is
// kept free in addition to the complete logical revision size; it is an
// admission check, not a promise that later filesystem writes cannot fail.
@interface MTThemeLibraryConfiguration : NSObject

@property(nonatomic, copy, readonly) NSURL *rootURL;
@property(nonatomic, strong, readonly) MTImportLimits *limits;
@property(nonatomic, assign, readonly) uint64_t minimumFreeSpaceReserveBytes;

+ (instancetype)defaultConfiguration;
- (instancetype)initWithRootURL:(NSURL *)rootURL
                          limits:(MTImportLimits *)limits
    minimumFreeSpaceReserveBytes:(uint64_t)minimumFreeSpaceReserveBytes
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

// A fully validated, immutable App-owned revision. Asset URLs are derived
// only from content digests. Consumers must still use a no-follow open when
// they retain a URL beyond the lifetime of the operation that loaded it.
@interface MTThemeLibraryRevision : NSObject

@property(nonatomic, copy, readonly) NSString *revisionIdentifier;
@property(nonatomic, copy, readonly) NSString *manifestDigest;
@property(nonatomic, strong, readonly) MTThemeManifest *manifest;
@property(nonatomic, copy, readonly)
    NSDictionary<NSString *, NSURL *> *assetURLsByContentSHA256;
@property(nonatomic, copy, readonly)
    NSDictionary<NSString *, NSNumber *> *assetByteCountsByContentSHA256;
@property(nonatomic, assign, readonly) NSUInteger assetCount;
@property(nonatomic, assign, readonly) uint64_t assetByteCount;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

@interface MTThemeLibraryStore : NSObject

@property(nonatomic, copy, readonly) NSURL *rootURL;
@property(nonatomic, strong, readonly) MTThemeLibraryConfiguration *configuration;

- (instancetype)initWithRootURL:(NSURL *)rootURL;
- (instancetype)initWithConfiguration:
    (MTThemeLibraryConfiguration *)configuration NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

// Compatibility-only M1-A primitive. It persists a manifest-only schema-one
// revision and must not be presented as a completed import. New code uses the
// formal commit below.
- (nullable NSString *)saveManifestRevision:(MTThemeManifest *)manifest
                                       error:(NSError **)error;
- (nullable MTThemeManifest *)loadCurrentManifestForThemeID:(NSString *)themeID
                                                       error:(NSError **)error;

@end

@interface MTThemeLibraryStore (FormalTransaction)

// Commits exactly the unique content digests referenced by the manifest. The
// provisional session is locked against stage/discard for the complete copy,
// consumed only after current.json reaches its atomic linearization point,
// and remains retryable when publication fails before that point.
- (nullable MTThemeLibraryRevision *)
    commitManifest:(MTThemeManifest *)manifest
    fromAssetStagingSession:(MTAssetStagingSession *)assetStagingSession
    cancellationToken:(nullable MTImportCancellationToken *)cancellationToken
    error:(NSError **)error;

// Full validation walks the exact revision tree and independently hashes every
// asset before returning URLs. The manifest-only loader above also accepts a
// formal schema-two current pointer for compatibility with metadata callers.
- (nullable MTThemeLibraryRevision *)
    loadCurrentRevisionForThemeID:(NSString *)themeID
                            error:(NSError **)error;

// Apply uses this form so a full asset hash walk remains cancellable. The
// compatibility selector above is equivalent to a nil cancellation token.
- (nullable MTThemeLibraryRevision *)
    loadCurrentRevisionForThemeID:(NSString *)themeID
                cancellationToken:
                    (nullable MTImportCancellationToken *)cancellationToken
                            error:(NSError **)error;

// UI previews already hold a metadata-validated catalog summary. This bounded
// read verifies only the requested current-revision assets instead of hashing
// every object in a potentially large theme. Authoritative consumers such as
// Apply and revision switching must continue to use loadCurrentRevision... .
- (nullable NSDictionary<NSString *, NSData *> *)
    loadPreviewAssetDataForThemeID:(NSString *)themeID
        expectedRevisionIdentifier:(NSString *)revisionIdentifier
                  expectedManifest:(MTThemeManifest *)manifest
             contentSHA256Digests:(NSArray<NSString *> *)contentSHA256Digests
                              error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
