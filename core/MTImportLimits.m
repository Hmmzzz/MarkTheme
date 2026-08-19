#import "MTImportLimits.h"

@implementation MTImportLimits

+ (instancetype)defaultLimits {
    return [[self alloc] initWithMaximumRegularFiles:20000
                              maximumArchiveEntries:25000
                                 maximumSourceBytes:512ULL * 1024ULL * 1024ULL
                               maximumExpandedBytes:1024ULL * 1024ULL * 1024ULL
                             maximumSingleFileBytes:128ULL * 1024ULL * 1024ULL
                       maximumArchiveExpansionRatio:100
                                   maximumPathDepth:32
                               maximumPathUTF8Bytes:1024];
}

- (instancetype)initWithMaximumRegularFiles:(NSUInteger)maximumRegularFiles
                        maximumExpandedBytes:(uint64_t)maximumExpandedBytes
                      maximumSingleFileBytes:(uint64_t)maximumSingleFileBytes
                            maximumPathDepth:(NSUInteger)maximumPathDepth
                        maximumPathUTF8Bytes:(NSUInteger)maximumPathUTF8Bytes {
    return [self initWithMaximumRegularFiles:maximumRegularFiles
                       maximumArchiveEntries:maximumRegularFiles
                          maximumSourceBytes:maximumSingleFileBytes
                        maximumExpandedBytes:maximumExpandedBytes
                      maximumSingleFileBytes:maximumSingleFileBytes
                maximumArchiveExpansionRatio:100
                            maximumPathDepth:maximumPathDepth
                        maximumPathUTF8Bytes:maximumPathUTF8Bytes];
}

- (instancetype)initWithMaximumRegularFiles:(NSUInteger)maximumRegularFiles
                       maximumArchiveEntries:(NSUInteger)maximumArchiveEntries
                          maximumSourceBytes:(uint64_t)maximumSourceBytes
                        maximumExpandedBytes:(uint64_t)maximumExpandedBytes
                      maximumSingleFileBytes:(uint64_t)maximumSingleFileBytes
                maximumArchiveExpansionRatio:
                    (uint64_t)maximumArchiveExpansionRatio
                            maximumPathDepth:(NSUInteger)maximumPathDepth
                        maximumPathUTF8Bytes:(NSUInteger)maximumPathUTF8Bytes {
    NSParameterAssert(maximumRegularFiles > 0);
    NSParameterAssert(maximumArchiveEntries >= maximumRegularFiles);
    NSParameterAssert(maximumSourceBytes > 0);
    NSParameterAssert(maximumExpandedBytes > 0);
    NSParameterAssert(maximumSingleFileBytes > 0);
    NSParameterAssert(maximumSingleFileBytes <= maximumExpandedBytes);
    NSParameterAssert(maximumArchiveExpansionRatio > 0);
    NSParameterAssert(maximumPathDepth > 0);
    NSParameterAssert(maximumPathUTF8Bytes > 0);
    self = [super init];
    if (self == nil) return nil;
    _maximumRegularFiles = maximumRegularFiles;
    _maximumArchiveEntries = maximumArchiveEntries;
    _maximumSourceBytes = maximumSourceBytes;
    _maximumExpandedBytes = maximumExpandedBytes;
    _maximumSingleFileBytes = maximumSingleFileBytes;
    _maximumArchiveExpansionRatio = maximumArchiveExpansionRatio;
    _maximumPathDepth = maximumPathDepth;
    _maximumPathUTF8Bytes = maximumPathUTF8Bytes;
    return self;
}

@end
