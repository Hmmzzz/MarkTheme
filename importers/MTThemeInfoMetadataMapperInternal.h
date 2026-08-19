#import "MTThemeInfoMetadataMapper.h"

NS_ASSUME_NONNULL_BEGIN

// Import-composition seam kept out of the public mapper contract. The mapper
// remains the sole owner of source-name normalization and metadata creation.
@interface MTThemeInfoMetadataMapper (ImportComposition)

- (MTThemeImportMetadata *)
    fallbackMetadataForSourceName:(NSString *)sourceName
                       diagnostics:(NSArray<MTDiagnostic *> *)diagnostics;

- (MTThemeImportMetadata *)metadataByMergingPrimaryMetadata:
    (MTThemeImportMetadata *)primaryMetadata
                                      componentMetadata:
    (NSArray<MTThemeImportMetadata *> *)componentMetadata;

@end

NS_ASSUME_NONNULL_END
