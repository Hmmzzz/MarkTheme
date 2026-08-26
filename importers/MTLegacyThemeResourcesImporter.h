#import <Foundation/Foundation.h>

@class MTDiagnostic;
@class MTSourceInventory;
@class MTThemeResource;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTLegacyThemeResourcesImporterErrorDomain;

// Returns a high-confidence SnowBoard-compatible path when the filename
// itself uniquely identifies one supported resource family. Ambiguous names
// such as dialer digits and Settings artwork intentionally return nil.
FOUNDATION_EXPORT NSString *_Nullable
MTLegacySuggestedRelativePathForLooseFilename(NSString *filename);

@interface MTLegacyThemeResourcesImportResult : NSObject

@property(nonatomic, copy, readonly) NSArray<MTThemeResource *> *resources;
@property(nonatomic, copy, readonly) NSArray<MTDiagnostic *> *diagnostics;
@property(nonatomic, assign, readonly) NSUInteger recognizedFileCount;
@property(nonatomic, assign, readonly) NSUInteger rejectedFileCount;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

// Imports exact SnowBoard resource families that are commonly shipped as
// sibling .theme components. Runtime adapters are deliberately separate from
// this data contract, so unsupported surfaces can be represented honestly in
// the Library and activated later without another import migration.
@interface MTLegacyThemeResourcesImporter : NSObject

- (nullable MTLegacyThemeResourcesImportResult *)
    importSourceInventory:(MTSourceInventory *)inventory
                    error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
