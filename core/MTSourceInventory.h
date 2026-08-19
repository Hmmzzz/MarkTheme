#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTSourceInventoryErrorDomain;

// Immutable, storage-neutral description of one validated source file. The
// ingestion layer owns bytes; importers consume only this semantic inventory.
@interface MTSourceFile : NSObject

@property(nonatomic, copy, readonly) NSString *relativePath;
@property(nonatomic, assign, readonly) uint64_t byteCount;
@property(nonatomic, copy, readonly) NSString *contentSHA256;
@property(nonatomic, copy, readonly) NSData *prefixData;

- (instancetype)initWithRelativePath:(NSString *)relativePath
                            byteCount:(uint64_t)byteCount
                        contentSHA256:(NSString *)contentSHA256
                           prefixData:(NSData *)prefixData
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

// Canonical source inventory shared by directory and archive acquisition. The
// factory sorts paths and derives the fingerprint solely from path/hash/size,
// so packaging order and container format cannot affect importer identity.
@interface MTSourceInventory : NSObject

@property(nonatomic, copy, readonly) NSArray<MTSourceFile *> *files;
@property(nonatomic, assign, readonly) uint64_t totalBytes;
@property(nonatomic, copy, readonly) NSString *sourceFingerprint;

+ (nullable instancetype)inventoryWithFiles:(NSArray<MTSourceFile *> *)files
                                       error:(NSError **)error;
- (nullable MTSourceFile *)fileAtRelativePath:(NSString *)relativePath;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
