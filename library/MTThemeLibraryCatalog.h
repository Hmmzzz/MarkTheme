#import <Foundation/Foundation.h>

#import "MTThemeLibraryStore.h"

NS_ASSUME_NONNULL_BEGIN

// Metadata-only projection used by catalog views. Asset file metadata and the
// exact asset set are checked, but bytes are deliberately not hashed here.
@interface MTThemeLibraryRevisionSummary : NSObject

@property(nonatomic, copy, readonly) NSString *revisionIdentifier;
@property(nonatomic, copy, readonly) NSString *manifestDigest;
@property(nonatomic, strong, readonly) MTThemeManifest *manifest;
@property(nonatomic, assign, readonly) NSUInteger assetCount;
@property(nonatomic, assign, readonly) uint64_t assetByteCount;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

@interface MTThemeLibraryThemeSummary : NSObject

@property(nonatomic, copy, readonly) NSString *themeID;
@property(nonatomic, strong, readonly)
    MTThemeLibraryRevisionSummary *currentRevision;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

@interface MTThemeLibraryStore (Catalog)

// Returns a stable, theme-ID-sorted derived view. This does not create or trust
// an index file; each theme's current pointer and canonical metadata remain the
// source of truth.
- (nullable NSArray<MTThemeLibraryThemeSummary *> *)
    loadThemeCatalogWithCancellationToken:
        (nullable MTImportCancellationToken *)cancellationToken
    error:(NSError **)error;

// Removes an entire theme. The theme directory is atomically quarantined first, so an
// interruption leaves recoverable state rather than a half-deleted theme.
// Applying a theme is a separate concern: this only removes Library storage.
- (BOOL)removeThemeWithID:(NSString *)themeID
        cancellationToken:(nullable MTImportCancellationToken *)cancellationToken
                    error:(NSError **)error;

// Completes abandoned import/deletion transactions and removes superseded
// snapshots under each per-theme exclusive lock. Safe to call repeatedly
// during Manager startup.
- (BOOL)recoverAbandonedLibraryOperationsWithError:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
