#import "MTSourceInventory.h"

#import "MTCanonicalJSON.h"
#import "MTDigest.h"

NSString *const MTSourceInventoryErrorDomain =
    @"com.hmmzzz.marktheme.source-inventory";

@implementation MTSourceFile

- (instancetype)initWithRelativePath:(NSString *)relativePath
                            byteCount:(uint64_t)byteCount
                        contentSHA256:(NSString *)contentSHA256
                           prefixData:(NSData *)prefixData {
    NSParameterAssert(relativePath.length > 0);
    NSParameterAssert(MTStringIsLowercaseSHA256Digest(contentSHA256));
    NSParameterAssert(prefixData.length <= 16);
    self = [super init];
    if (self == nil) return nil;
    _relativePath = [[relativePath precomposedStringWithCanonicalMapping] copy];
    _byteCount = byteCount;
    _contentSHA256 = [contentSHA256 copy];
    _prefixData = [prefixData copy];
    return self;
}

@end

@interface MTSourceInventory ()
- (instancetype)initWithFiles:(NSArray<MTSourceFile *> *)files
                     totalBytes:(uint64_t)totalBytes
              sourceFingerprint:(NSString *)sourceFingerprint;
@end

@implementation MTSourceInventory {
    NSDictionary<NSString *, MTSourceFile *> *_filesByPath;
}

- (instancetype)initWithFiles:(NSArray<MTSourceFile *> *)files
                     totalBytes:(uint64_t)totalBytes
              sourceFingerprint:(NSString *)sourceFingerprint {
    self = [super init];
    if (self == nil) return nil;
    _files = [files copy];
    _totalBytes = totalBytes;
    _sourceFingerprint = [sourceFingerprint copy];
    NSMutableDictionary<NSString *, MTSourceFile *> *byPath =
        [NSMutableDictionary dictionaryWithCapacity:files.count];
    for (MTSourceFile *file in files) byPath[file.relativePath] = file;
    _filesByPath = [byPath copy];
    return self;
}

+ (instancetype)inventoryWithFiles:(NSArray<MTSourceFile *> *)files
                              error:(NSError **)error {
    if (![files isKindOfClass:NSArray.class]) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:MTSourceInventoryErrorDomain
                                         code:1
                                     userInfo:@{
                NSLocalizedDescriptionKey : @"Source inventory files are invalid."
            }];
        }
        return nil;
    }
    for (id candidate in files) {
        if (![candidate isKindOfClass:MTSourceFile.class]) {
            if (error != NULL) {
                *error = [NSError errorWithDomain:MTSourceInventoryErrorDomain
                                             code:2
                                         userInfo:@{
                    NSLocalizedDescriptionKey :
                        @"Source inventory contains an invalid file object."
                }];
            }
            return nil;
        }
    }
    NSArray<MTSourceFile *> *sorted = [files
        sortedArrayUsingComparator:^NSComparisonResult(MTSourceFile *left,
                                                       MTSourceFile *right) {
            return [left.relativePath compare:right.relativePath
                                       options:NSLiteralSearch];
        }];
    NSMutableArray<NSDictionary<NSString *, id> *> *records =
        [NSMutableArray arrayWithCapacity:sorted.count];
    NSString *previousPath = nil;
    uint64_t totalBytes = 0;
    for (MTSourceFile *file in sorted) {
        if (file.relativePath.length == 0 ||
            !MTStringIsLowercaseSHA256Digest(file.contentSHA256) ||
            file.prefixData.length > 16 ||
            (previousPath != nil &&
             [file.relativePath isEqualToString:previousPath]) ||
            file.byteCount > UINT64_MAX - totalBytes) {
            if (error != NULL) {
                *error = [NSError errorWithDomain:MTSourceInventoryErrorDomain
                                             code:2
                                         userInfo:@{
                    NSLocalizedDescriptionKey :
                        @"Source inventory contains an invalid or duplicate file."
                }];
            }
            return nil;
        }
        totalBytes += file.byteCount;
        previousPath = file.relativePath;
        [records addObject:@{
            @"path" : file.relativePath,
            @"sha256" : file.contentSHA256,
            @"size" : @(file.byteCount),
        }];
    }
    NSError *canonicalError = nil;
    NSData *canonicalData = MTCanonicalJSONData(records, &canonicalError);
    if (canonicalData == nil) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:MTSourceInventoryErrorDomain
                                         code:3
                                     userInfo:@{
                NSLocalizedDescriptionKey :
                    @"Unable to canonicalize the source inventory.",
                NSUnderlyingErrorKey : canonicalError,
            }];
        }
        return nil;
    }
    return [[self alloc]
        initWithFiles:sorted
            totalBytes:totalBytes
     sourceFingerprint:MTSHA256HexDigestForData(canonicalData)];
}

- (MTSourceFile *)fileAtRelativePath:(NSString *)relativePath {
    NSString *normalized = [relativePath precomposedStringWithCanonicalMapping];
    return _filesByPath[normalized];
}

@end
