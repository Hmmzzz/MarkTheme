#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTGenerationDescriptorErrorDomain;
FOUNDATION_EXPORT NSUInteger const MTGenerationDescriptorSchemaVersion;
FOUNDATION_EXPORT uint64_t const MTGenerationDescriptorMaximumByteCount;

typedef NS_ENUM(NSInteger, MTGenerationDescriptorErrorCode) {
    MTGenerationDescriptorErrorInvalidInput = 1,
    MTGenerationDescriptorErrorMalformedData = 2,
    MTGenerationDescriptorErrorUnsupportedVersion = 3,
    MTGenerationDescriptorErrorLimitExceeded = 4,
};

@interface MTGenerationAssetDescriptor : NSObject

@property(nonatomic, copy, readonly) NSString *contentSHA256;
@property(nonatomic, assign, readonly) uint64_t byteCount;

- (nullable instancetype)initWithContentSHA256:(NSString *)contentSHA256
                                      byteCount:(uint64_t)byteCount
                                          error:(NSError **)error
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

@interface MTGenerationDescriptor : NSObject

@property(nonatomic, assign, readonly) NSUInteger schemaVersion;
@property(nonatomic, copy, readonly) NSString *generationDigest;
@property(nonatomic, copy, readonly) NSString *generationIdentifier;
@property(nonatomic, copy, readonly)
    NSDictionary<NSString *, NSNumber *> *contractVersions;
@property(nonatomic, copy, readonly) NSString *themeID;
@property(nonatomic, copy, readonly) NSString *libraryRevisionIdentifier;
@property(nonatomic, copy, readonly) NSString *manifestDigest;
@property(nonatomic, copy, readonly) NSString *indexSHA256;
@property(nonatomic, assign, readonly) uint64_t indexByteCount;
@property(nonatomic, assign, readonly) NSUInteger indexFormatVersion;
@property(nonatomic, assign, readonly) NSUInteger resourceCount;
@property(nonatomic, copy, readonly)
    NSArray<MTGenerationAssetDescriptor *> *assets;
@property(nonatomic, assign, readonly) NSUInteger assetCount;
@property(nonatomic, assign, readonly) uint64_t assetByteCount;
@property(nonatomic, copy, readonly) NSArray<NSString *> *moduleIDs;
@property(nonatomic, copy, readonly)
    NSDictionary<NSString *, NSDictionary<NSString *, id> *> *
        moduleConfigurations;
@property(nonatomic, copy, readonly) NSData *canonicalData;

- (nullable instancetype)initWithThemeID:(NSString *)themeID
               libraryRevisionIdentifier:(NSString *)libraryRevisionIdentifier
                           manifestDigest:(NSString *)manifestDigest
                              indexSHA256:(NSString *)indexSHA256
                           indexByteCount:(uint64_t)indexByteCount
                       indexFormatVersion:(NSUInteger)indexFormatVersion
                            resourceCount:(NSUInteger)resourceCount
                                   assets:
    (NSArray<MTGenerationAssetDescriptor *> *)assets
                                moduleIDs:(NSArray<NSString *> *)moduleIDs
                                    error:(NSError **)error;

- (nullable instancetype)initWithThemeID:(NSString *)themeID
               libraryRevisionIdentifier:(NSString *)libraryRevisionIdentifier
                           manifestDigest:(NSString *)manifestDigest
                              indexSHA256:(NSString *)indexSHA256
                           indexByteCount:(uint64_t)indexByteCount
                       indexFormatVersion:(NSUInteger)indexFormatVersion
                            resourceCount:(NSUInteger)resourceCount
                                   assets:
    (NSArray<MTGenerationAssetDescriptor *> *)assets
                                moduleIDs:(NSArray<NSString *> *)moduleIDs
                     moduleConfigurations:
    (NSDictionary<NSString *, NSDictionary<NSString *, id> *> *)
        moduleConfigurations
                                    error:(NSError **)error;

- (nullable instancetype)initWithCanonicalData:(NSData *)canonicalData
                                          error:(NSError **)error;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
