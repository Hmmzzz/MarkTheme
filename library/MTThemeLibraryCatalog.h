#import <Foundation/Foundation.h>

#import "MTThemeLibraryStore.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, MTThemeLibraryRevisionFormat) {
    // Self-contained revision with canonical manifest, revision metadata and
    // content-addressed assets.
    MTThemeLibraryRevisionFormatFormalV1 = 1,

    // Compatibility-only schema-one revision containing a manifest but no
    // Library-owned assets. It must be reimported before compile/apply.
    MTThemeLibraryRevisionFormatLegacyManifestOnly = 2,
};

// Metadata-only projection used by catalog and history views. Formal asset
// file metadata and the exact asset set are checked, but bytes are deliberately
// not hashed here. switch/load APIs perform full content verification.
@interface MTThemeLibraryRevisionSummary : NSObject

@property(nonatomic, copy, readonly) NSString *revisionIdentifier;
@property(nonatomic, copy, readonly) NSString *manifestDigest;
@property(nonatomic, strong, readonly) MTThemeManifest *manifest;
@property(nonatomic, assign, readonly) NSUInteger assetCount;
@property(nonatomic, assign, readonly) uint64_t assetByteCount;
@property(nonatomic, assign, readonly) MTThemeLibraryRevisionFormat format;
@property(nonatomic, assign, readonly, getter=isCurrent) BOOL current;
@property(nonatomic, assign, readonly) BOOL requiresReimport;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

@interface MTThemeLibraryThemeSummary : NSObject

@property(nonatomic, copy, readonly) NSString *themeID;
@property(nonatomic, strong, readonly)
    MTThemeLibraryRevisionSummary *currentRevision;
@property(nonatomic, copy, readonly)
    NSArray<MTThemeLibraryRevisionSummary *> *revisionHistory;
@property(nonatomic, assign, readonly) NSUInteger revisionCount;
@property(nonatomic, assign, readonly) NSUInteger formalRevisionCount;
@property(nonatomic, assign, readonly) NSUInteger legacyRevisionCount;
@property(nonatomic, assign, readonly) BOOL requiresReimport;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

@interface MTThemeLibraryStore (Catalog)

// Returns a stable, theme-ID-sorted derived view. This does not create or trust
// an index file; revision directories and canonical metadata remain the source
// of truth.
- (nullable NSArray<MTThemeLibraryThemeSummary *> *)
    loadThemeCatalogWithCancellationToken:
        (nullable MTImportCancellationToken *)cancellationToken
    error:(NSError **)error;

// Current is first; remaining revisions are ordered by canonical identifier.
- (nullable NSArray<MTThemeLibraryRevisionSummary *> *)
    loadRevisionHistoryForThemeID:(NSString *)themeID
    cancellationToken:(nullable MTImportCancellationToken *)cancellationToken
    error:(NSError **)error;

// Fully hashes the selected formal revision before atomically replacing
// current.json. This is Library rollback only; it does not apply a theme.
- (nullable MTThemeLibraryRevision *)
    switchCurrentRevisionForThemeID:(NSString *)themeID
    revisionIdentifier:(NSString *)revisionIdentifier
    cancellationToken:(nullable MTImportCancellationToken *)cancellationToken
    error:(NSError **)error;

// Removes only a non-current formal revision. Once its atomic quarantine rename
// succeeds cancellation is intentionally ignored so bounded cleanup can finish.
- (BOOL)removeRevisionForThemeID:(NSString *)themeID
    revisionIdentifier:(NSString *)revisionIdentifier
    cancellationToken:(nullable MTImportCancellationToken *)cancellationToken
    error:(NSError **)error;

// Removes an entire theme, including its current revision and every stored
// revision. The theme directory is atomically quarantined first, so an
// interruption leaves recoverable state rather than a half-deleted theme.
// Applying a theme is a separate concern: this only removes Library storage.
- (BOOL)removeThemeWithID:(NSString *)themeID
        cancellationToken:(nullable MTImportCancellationToken *)cancellationToken
                    error:(NSError **)error;

// Completes abandoned import/deletion transactions under each per-theme
// exclusive lock. Safe to call repeatedly during Manager startup.
- (BOOL)recoverAbandonedLibraryOperationsWithError:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
