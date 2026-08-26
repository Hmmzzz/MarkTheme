#import <Foundation/Foundation.h>

@class MTDiagnostic;
@class MTSourceInventory;
@class MTThemeImportMetadata;
@class MTThemeManifest;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTIconBundlesImporterErrorDomain;

// Used by the input-layout adapter when a package contains confirmed
// IconBundles files without an IconBundles/ wrapper. This checks only the
// filename grammar; the normal importer and image gate still validate it.
FOUNDATION_EXPORT BOOL MTIconBundlesFilenameIsSupported(NSString *filename);
FOUNDATION_EXPORT NSString *_Nullable
MTIconBundlesSuggestedRelativePathForLooseFilename(NSString *filename);
FOUNDATION_EXPORT NSString *_Nullable
MTIconBundlesSuggestedBundleRelativePath(NSString *bundleIdentifier,
                                         NSString *filename);

@interface MTIconBundlesImportResult : NSObject

@property(nonatomic, strong, readonly) MTThemeManifest *manifest;
@property(nonatomic, copy, readonly) NSArray<MTDiagnostic *> *diagnostics;
@property(nonatomic, assign, readonly) NSUInteger recognizedFileCount;
@property(nonatomic, assign, readonly) NSUInteger ignoredFileCount;
@property(nonatomic, assign, readonly) NSUInteger rejectedFileCount;

@end

@interface MTIconBundlesImporter : NSObject

// Parses only the filename forms confirmed by the pinned IconBundles source.
// It maps metadata into canonical resources; it does not decode images, copy
// assets, compile a generation or imply runtime/device compatibility.
- (nullable MTIconBundlesImportResult *)importSourceInventory:
    (MTSourceInventory *)inventory
                                                sourceName:(NSString *)sourceName
                                                     error:(NSError **)error;

// Optional validated Info.plist metadata may add bounded module configuration
// only when the module's required imported resource is also present.
- (nullable MTIconBundlesImportResult *)importSourceInventory:
    (MTSourceInventory *)inventory
                                                sourceName:(NSString *)sourceName
                                            importMetadata:
                                               (nullable MTThemeImportMetadata *)importMetadata
                                                     error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
