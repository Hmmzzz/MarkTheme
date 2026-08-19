#import <Foundation/Foundation.h>

@class MTDiagnostic;
@class MTSourceInventory;
@class MTThemeResource;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTUIResourcesImporterErrorDomain;

// True when this importer already assigns a meaning to a Bundles/<id>
// directory, so other importers leave that bundle alone.
FOUNDATION_EXPORT BOOL MTUIResourceBundleIsSupported(
    NSString *bundleIdentifier);

// A format adapter, not a process adapter. It recognizes the SnowBoard
// Settings bundle layout and emits process-neutral semantic resources.
@interface MTUIResourcesImportResult : NSObject

@property(nonatomic, copy, readonly) NSArray<MTThemeResource *> *resources;
@property(nonatomic, copy, readonly) NSArray<MTDiagnostic *> *diagnostics;
@property(nonatomic, assign, readonly) NSUInteger recognizedFileCount;
@property(nonatomic, assign, readonly) NSUInteger rejectedFileCount;

@end

@interface MTUIResourcesImporter : NSObject

- (nullable MTUIResourcesImportResult *)importSourceInventory:
    (MTSourceInventory *)inventory
                                                     error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
