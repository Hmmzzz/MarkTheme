#import "MTThemeLibraryStore.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT const uint64_t MTLibraryMaximumManifestBytes;
FOUNDATION_EXPORT const uint64_t MTLibraryMaximumRevisionMetadataBytes;
FOUNDATION_EXPORT const uint64_t MTLibraryMaximumCurrentPointerBytes;

BOOL MTLibraryDictionaryHasExactlyKeys(NSDictionary *dictionary,
                                       NSArray<NSString *> *keys);
BOOL MTLibraryReadUnsignedInteger(id value,
                                  uint64_t maximum,
                                  uint64_t *_Nullable result);
NSDictionary *_Nullable MTLibraryCanonicalDictionaryFromData(
    NSData *data,
    NSError **error);
NSArray<NSString *> *MTLibraryRequiredAssetDigests(MTThemeManifest *manifest);
NSDictionary<NSString *, NSNumber *> *_Nullable
MTLibraryParseRevisionMetadata(
    NSData *data,
    NSString *expectedManifestDigest,
    NSArray<NSString *> *expectedDigests,
    uint64_t *_Nullable totalBytes,
    NSError **error);

// Parses the one supported current-snapshot pointer format.
BOOL MTLibraryParseCurrentPointerData(
    NSData *data,
    NSString *_Nullable *_Nullable revisionIdentifier,
    NSString *_Nullable *_Nullable manifestDigest,
    NSError **error);

@interface MTThemeLibraryRevision ()

- (instancetype)initWithRevisionIdentifier:(NSString *)revisionIdentifier
                             manifestDigest:(NSString *)manifestDigest
                                    manifest:(MTThemeManifest *)manifest
             assetURLsByContentSHA256:
                 (NSDictionary<NSString *, NSURL *> *)assetURLsByContentSHA256
       assetByteCountsByContentSHA256:
           (NSDictionary<NSString *, NSNumber *> *)assetByteCountsByContentSHA256
                    resourcesDirectoryURL:
                        (nullable NSURL *)resourcesDirectoryURL
                             assetByteCount:(uint64_t)assetByteCount
    NS_DESIGNATED_INITIALIZER;

@end

@interface MTThemeLibraryStore ()

@property(nonatomic, strong, readwrite)
    MTThemeLibraryConfiguration *configuration;

@end

typedef struct MTLibraryThemeDirectories MTLibraryThemeDirectories;

NSURL *MTLibraryRevisionURL(MTThemeLibraryStore *store,
                            NSString *storageIdentifier,
                            NSString *revisionIdentifier);
MTThemeLibraryRevision *_Nullable MTLibraryLoadRevision(
    MTThemeLibraryStore *store,
    MTLibraryThemeDirectories *directories,
    NSString *storageIdentifier,
    NSString *requestedThemeID,
    NSString *revisionIdentifier,
    NSString *expectedManifestDigest,
    NSDictionary<NSString *, NSNumber *> *_Nullable expectedByteCounts,
    MTImportCancellationToken *_Nullable cancellationToken,
    NSError **error);

NS_ASSUME_NONNULL_END
