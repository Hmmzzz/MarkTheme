#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>

#import "MTSafeImageInspector.h"

@class MTImportCancellationToken;

NS_ASSUME_NONNULL_BEGIN

// Private synchronous composition point shared by the metadata inspector and
// pixel decoder. The ImageIO source and inspection are valid only while the
// consumer runs; the descriptor, provider, and source never escape ingestion.
typedef id _Nullable (^MTSafeValidatedPNGConsumer)(
    CGImageSourceRef source,
    MTSafeImageInspection *inspection,
    NSError **error);

FOUNDATION_EXPORT id _Nullable MTSafeImageProcessOwnedPNGFile(
    NSURL *fileURL,
    MTSafeImageLimits *limits,
    BOOL validateRasterData,
    MTImportCancellationToken *_Nullable cancellationToken,
    MTSafeValidatedPNGConsumer _Nullable consumer,
    NSError **error);

NS_ASSUME_NONNULL_END
