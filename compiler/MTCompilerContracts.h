#import <Foundation/Foundation.h>

@class MTDiagnostic;

NS_ASSUME_NONNULL_BEGIN

// M0 defines the compile-time module boundary only. No generation writer is
// shipped until M2 selects and validates the snapshot format.
@protocol MTCompilerContributor <NSObject>

@property(nonatomic, copy, readonly) NSString *moduleID;

- (NSArray<MTDiagnostic *> *)validateCanonicalResources:
    (NSArray<NSDictionary<NSString *, id> *> *)resources;

@end

NS_ASSUME_NONNULL_END
