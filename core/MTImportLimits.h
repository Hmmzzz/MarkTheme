#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Shared resource policy for every stage that acquires, expands, scans, or
// decodes untrusted theme input. A caller may tighten these limits, but a later
// stage must never silently widen the limits accepted by an earlier stage.
@interface MTImportLimits : NSObject

@property(nonatomic, assign, readonly) NSUInteger maximumRegularFiles;
@property(nonatomic, assign, readonly) NSUInteger maximumArchiveEntries;
@property(nonatomic, assign, readonly) uint64_t maximumSourceBytes;
@property(nonatomic, assign, readonly) uint64_t maximumExpandedBytes;
@property(nonatomic, assign, readonly) uint64_t maximumSingleFileBytes;
@property(nonatomic, assign, readonly) uint64_t maximumArchiveExpansionRatio;
@property(nonatomic, assign, readonly) NSUInteger maximumPathDepth;
@property(nonatomic, assign, readonly) NSUInteger maximumPathUTF8Bytes;

+ (instancetype)defaultLimits;
- (instancetype)initWithMaximumRegularFiles:(NSUInteger)maximumRegularFiles
                        maximumExpandedBytes:(uint64_t)maximumExpandedBytes
                      maximumSingleFileBytes:(uint64_t)maximumSingleFileBytes
                            maximumPathDepth:(NSUInteger)maximumPathDepth
                        maximumPathUTF8Bytes:(NSUInteger)maximumPathUTF8Bytes;
- (instancetype)initWithMaximumRegularFiles:(NSUInteger)maximumRegularFiles
                       maximumArchiveEntries:(NSUInteger)maximumArchiveEntries
                          maximumSourceBytes:(uint64_t)maximumSourceBytes
                        maximumExpandedBytes:(uint64_t)maximumExpandedBytes
                      maximumSingleFileBytes:(uint64_t)maximumSingleFileBytes
                maximumArchiveExpansionRatio:
                    (uint64_t)maximumArchiveExpansionRatio
                            maximumPathDepth:(NSUInteger)maximumPathDepth
                        maximumPathUTF8Bytes:(NSUInteger)maximumPathUTF8Bytes
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
