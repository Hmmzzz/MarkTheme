#import <Foundation/Foundation.h>

@class MTDiagnostic;
@class MTSourceInventory;
@class MTThemeResource;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTLegacyThemeResourcesImporterErrorDomain;

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
