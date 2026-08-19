#import <Foundation/Foundation.h>

@class MTResourceKey;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTThemeManifestErrorDomain;
FOUNDATION_EXPORT NSUInteger const MTThemeManifestMaximumDisplayNameUTF8Bytes;
FOUNDATION_EXPORT NSUInteger const MTThemeManifestMaximumAuthorUTF8Bytes;
FOUNDATION_EXPORT NSUInteger const MTThemeManifestMaximumVersionUTF8Bytes;

@interface MTThemeResource : NSObject

@property(nonatomic, strong, readonly) MTResourceKey *resourceKey;
@property(nonatomic, copy, readonly) NSString *relativeAssetPath;
@property(nonatomic, copy, readonly) NSString *contentSHA256;
@property(nonatomic, copy, readonly) NSString *sourceFormat;
@property(nonatomic, assign, readonly) NSUInteger matchRank;

- (nullable instancetype)initWithResourceKey:(MTResourceKey *)resourceKey
                           relativeAssetPath:(NSString *)relativeAssetPath
                               contentSHA256:(NSString *)contentSHA256
                                sourceFormat:(NSString *)sourceFormat
                                   matchRank:(NSUInteger)matchRank
                                       error:(NSError **)error
    NS_DESIGNATED_INITIALIZER;
- (nullable instancetype)initWithDictionary:
    (NSDictionary<NSString *, id> *)dictionary
                                       error:(NSError **)error;
- (NSDictionary<NSString *, id> *)canonicalDictionary;

- (instancetype)init NS_UNAVAILABLE;

@end

@interface MTThemeManifest : NSObject

@property(nonatomic, assign, readonly) NSUInteger schemaVersion;
@property(nonatomic, copy, readonly) NSString *themeID;
@property(nonatomic, copy, readonly) NSString *displayName;
@property(nonatomic, copy, readonly) NSString *author;
@property(nonatomic, copy, readonly) NSString *themeVersion;
@property(nonatomic, copy, readonly) NSString *importerID;
@property(nonatomic, assign, readonly) NSUInteger importerVersion;
@property(nonatomic, copy, readonly) NSString *sourceFingerprint;
@property(nonatomic, copy, readonly) NSArray<NSString *> *capabilities;
@property(nonatomic, copy, readonly)
    NSDictionary<NSString *, NSDictionary<NSString *, id> *> *
        moduleConfigurations;
@property(nonatomic, copy, readonly) NSArray<MTThemeResource *> *resources;

- (nullable instancetype)initWithThemeID:(NSString *)themeID
                              displayName:(NSString *)displayName
                                   author:(NSString *)author
                             themeVersion:(NSString *)themeVersion
                               importerID:(NSString *)importerID
                          importerVersion:(NSUInteger)importerVersion
                        sourceFingerprint:(NSString *)sourceFingerprint
                             capabilities:(NSArray<NSString *> *)capabilities
                                resources:(NSArray<MTThemeResource *> *)resources
                                    error:(NSError **)error;
- (nullable instancetype)initWithThemeID:(NSString *)themeID
                              displayName:(NSString *)displayName
                                   author:(NSString *)author
                             themeVersion:(NSString *)themeVersion
                               importerID:(NSString *)importerID
                          importerVersion:(NSUInteger)importerVersion
                        sourceFingerprint:(NSString *)sourceFingerprint
                             capabilities:(NSArray<NSString *> *)capabilities
                     moduleConfigurations:
    (NSDictionary<NSString *, NSDictionary<NSString *, id> *> *)
        moduleConfigurations
                                resources:(NSArray<MTThemeResource *> *)resources
                                    error:(NSError **)error;
- (nullable instancetype)initWithDictionary:
    (NSDictionary<NSString *, id> *)dictionary
                                       error:(NSError **)error;

- (NSDictionary<NSString *, id> *)canonicalDictionary;
- (nullable NSData *)canonicalDataWithError:(NSError **)error;
- (nullable NSString *)contentDigestWithError:(NSError **)error;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
