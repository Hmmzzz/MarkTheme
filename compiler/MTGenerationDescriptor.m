#import "MTGenerationDescriptor.h"

#import <CoreFoundation/CoreFoundation.h>

#import "MTCanonicalJSON.h"
#import "MTDigest.h"
#import "MTGenerationIndexCodec.h"
#import "MTIdentifier.h"
#import "MTModuleConfiguration.h"
#import "MTVersionContracts.h"

NSString *const MTGenerationDescriptorErrorDomain =
    @"com.hmmzzz.marktheme64e.generation-descriptor";
NSUInteger const MTGenerationDescriptorSchemaVersion = 2;
uint64_t const MTGenerationDescriptorMaximumByteCount = 1024ULL * 1024ULL;

static NSString *const MTGenerationIndexFilename = @"index.mtg";
static const NSUInteger MTGenerationMaximumModuleCount = 128;

static BOOL MTGenerationDescriptorSetError(
    NSError **error,
    MTGenerationDescriptorErrorCode code,
    NSString *description,
    NSError *_Nullable underlying) {
    if (error != NULL) {
        NSMutableDictionary *userInfo = [NSMutableDictionary dictionaryWithObject:
            description
            forKey:NSLocalizedDescriptionKey];
        if (underlying != nil) userInfo[NSUnderlyingErrorKey] = underlying;
        *error = [NSError errorWithDomain:MTGenerationDescriptorErrorDomain
                                     code:code
                                 userInfo:userInfo];
    }
    return NO;
}

static BOOL MTGenerationDigestIsCanonical(NSString *digest) {
    if (![digest isKindOfClass:NSString.class] || digest.length != 64) {
        return NO;
    }
    for (NSUInteger index = 0; index < digest.length; index++) {
        unichar character = [digest characterAtIndex:index];
        if (!((character >= '0' && character <= '9') ||
              (character >= 'a' && character <= 'f'))) {
            return NO;
        }
    }
    return YES;
}

static BOOL MTGenerationRevisionIdentifierMatchesDigest(
    NSString *identifier,
    NSString *manifestDigest) {
    return [identifier isKindOfClass:NSString.class] &&
        [identifier isEqualToString:
            [@"r1-" stringByAppendingString:manifestDigest]];
}

static BOOL MTGenerationDictionaryHasExactKeys(NSDictionary *dictionary,
                                               NSArray<NSString *> *keys) {
    if (![dictionary isKindOfClass:NSDictionary.class] ||
        dictionary.count != keys.count) {
        return NO;
    }
    NSSet *expected = [NSSet setWithArray:keys];
    return [[NSSet setWithArray:dictionary.allKeys] isEqualToSet:expected];
}

static BOOL MTGenerationUnsignedInteger(id value,
                                        uint64_t maximum,
                                        uint64_t *output) {
    if (![value isKindOfClass:NSNumber.class] ||
        CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) {
        return NO;
    }
    NSNumber *number = value;
    const char *type = number.objCType;
    if (type == NULL || type[0] == 'f' || type[0] == 'd') return NO;
    NSString *string = number.stringValue;
    if (string.length == 0 || [string characterAtIndex:0] == '-') return NO;
    uint64_t parsed = 0;
    for (NSUInteger index = 0; index < string.length; index++) {
        unichar character = [string characterAtIndex:index];
        if (character < '0' || character > '9') return NO;
        uint64_t digit = (uint64_t)(character - '0');
        if (parsed > (UINT64_MAX - digit) / 10) return NO;
        parsed = parsed * 10 + digit;
    }
    if (parsed > maximum) return NO;
    *output = parsed;
    return YES;
}

static NSComparisonResult MTGenerationLiteralCompare(NSString *left,
                                                      NSString *right) {
    NSData *leftData = [left dataUsingEncoding:NSUTF8StringEncoding];
    NSData *rightData = [right dataUsingEncoding:NSUTF8StringEncoding];
    NSUInteger common = MIN(leftData.length, rightData.length);
    int result = memcmp(leftData.bytes, rightData.bytes, common);
    if (result < 0) return NSOrderedAscending;
    if (result > 0) return NSOrderedDescending;
    if (leftData.length < rightData.length) return NSOrderedAscending;
    if (leftData.length > rightData.length) return NSOrderedDescending;
    return NSOrderedSame;
}

static NSDictionary<NSString *, id> *MTGenerationAssetDictionary(
    MTGenerationAssetDescriptor *asset) {
    return @{
        @"byteCount" : @(asset.byteCount),
        @"sha256" : asset.contentSHA256,
    };
}

static NSDictionary<NSString *, id> *MTGenerationBaseDictionary(
    NSString *themeID,
    NSString *revisionIdentifier,
    NSString *manifestDigest,
    NSString *indexSHA256,
    uint64_t indexByteCount,
    NSUInteger indexFormatVersion,
    NSUInteger resourceCount,
    NSArray<MTGenerationAssetDescriptor *> *assets,
    uint64_t assetByteCount,
    NSArray<NSString *> *moduleIDs,
    NSDictionary<NSString *, NSDictionary<NSString *, id> *> *
        moduleConfigurations) {
    NSMutableArray<NSDictionary<NSString *, id> *> *assetObjects =
        [NSMutableArray arrayWithCapacity:assets.count];
    for (MTGenerationAssetDescriptor *asset in assets) {
        [assetObjects addObject:MTGenerationAssetDictionary(asset)];
    }
    return @{
        @"assetByteCount" : @(assetByteCount),
        @"assetCount" : @(assets.count),
        @"assets" : assetObjects,
        @"contractVersions" : MTCurrentContractVersions(),
        @"index" : @{
            @"byteCount" : @(indexByteCount),
            @"filename" : MTGenerationIndexFilename,
            @"formatVersion" : @(indexFormatVersion),
            @"resourceCount" : @(resourceCount),
            @"sha256" : indexSHA256,
        },
        @"libraryRevisionIdentifier" : revisionIdentifier,
        @"manifestDigest" : manifestDigest,
        @"moduleConfigurations" : moduleConfigurations,
        @"moduleIDs" : moduleIDs,
        @"schemaVersion" : @(MTGenerationDescriptorSchemaVersion),
        @"themeID" : themeID,
    };
}

@implementation MTGenerationAssetDescriptor

- (instancetype)initWithContentSHA256:(NSString *)contentSHA256
                              byteCount:(uint64_t)byteCount
                                  error:(NSError **)error {
    if (!MTGenerationDigestIsCanonical(contentSHA256) || byteCount == 0) {
        MTGenerationDescriptorSetError(error,
            MTGenerationDescriptorErrorInvalidInput,
            @"Generation asset descriptor is invalid.", nil);
        return nil;
    }
    self = [super init];
    if (self == nil) return nil;
    _contentSHA256 = [contentSHA256 copy];
    _byteCount = byteCount;
    return self;
}

@end

@interface MTGenerationDescriptor ()

@property(nonatomic, assign, readwrite) NSUInteger schemaVersion;
@property(nonatomic, copy, readwrite) NSString *generationDigest;
@property(nonatomic, copy, readwrite) NSString *generationIdentifier;
@property(nonatomic, copy, readwrite)
    NSDictionary<NSString *, NSNumber *> *contractVersions;
@property(nonatomic, copy, readwrite) NSString *themeID;
@property(nonatomic, copy, readwrite) NSString *libraryRevisionIdentifier;
@property(nonatomic, copy, readwrite) NSString *manifestDigest;
@property(nonatomic, copy, readwrite) NSString *indexSHA256;
@property(nonatomic, assign, readwrite) uint64_t indexByteCount;
@property(nonatomic, assign, readwrite) NSUInteger indexFormatVersion;
@property(nonatomic, assign, readwrite) NSUInteger resourceCount;
@property(nonatomic, copy, readwrite)
    NSArray<MTGenerationAssetDescriptor *> *assets;
@property(nonatomic, assign, readwrite) NSUInteger assetCount;
@property(nonatomic, assign, readwrite) uint64_t assetByteCount;
@property(nonatomic, copy, readwrite) NSArray<NSString *> *moduleIDs;
@property(nonatomic, copy, readwrite)
    NSDictionary<NSString *, NSDictionary<NSString *, id> *> *
        moduleConfigurations;
@property(nonatomic, copy, readwrite) NSData *canonicalData;

@end

@implementation MTGenerationDescriptor

- (instancetype)initWithThemeID:(NSString *)themeID
       libraryRevisionIdentifier:(NSString *)libraryRevisionIdentifier
                   manifestDigest:(NSString *)manifestDigest
                      indexSHA256:(NSString *)indexSHA256
                   indexByteCount:(uint64_t)indexByteCount
               indexFormatVersion:(NSUInteger)indexFormatVersion
                    resourceCount:(NSUInteger)resourceCount
                           assets:(NSArray<MTGenerationAssetDescriptor *> *)assets
                        moduleIDs:(NSArray<NSString *> *)moduleIDs
                            error:(NSError **)error {
    return [self initWithThemeID:themeID
       libraryRevisionIdentifier:libraryRevisionIdentifier
                   manifestDigest:manifestDigest
                      indexSHA256:indexSHA256
                   indexByteCount:indexByteCount
               indexFormatVersion:indexFormatVersion
                    resourceCount:resourceCount
                           assets:assets
                        moduleIDs:moduleIDs
             moduleConfigurations:@{}
                            error:error];
}

- (instancetype)initWithThemeID:(NSString *)themeID
       libraryRevisionIdentifier:(NSString *)libraryRevisionIdentifier
                   manifestDigest:(NSString *)manifestDigest
                      indexSHA256:(NSString *)indexSHA256
                   indexByteCount:(uint64_t)indexByteCount
               indexFormatVersion:(NSUInteger)indexFormatVersion
                    resourceCount:(NSUInteger)resourceCount
                           assets:(NSArray<MTGenerationAssetDescriptor *> *)assets
                        moduleIDs:(NSArray<NSString *> *)moduleIDs
             moduleConfigurations:
    (NSDictionary<NSString *,NSDictionary<NSString *,id> *> *)
                        moduleConfigurations
                            error:(NSError **)error {
    if (!MTIdentifierIsValid(themeID) ||
        !MTGenerationDigestIsCanonical(manifestDigest) ||
        !MTGenerationRevisionIdentifierMatchesDigest(libraryRevisionIdentifier,
                                                     manifestDigest) ||
        !MTGenerationDigestIsCanonical(indexSHA256) ||
        indexByteCount < 80 ||
        indexByteCount > MTGenerationIndexMaximumByteCount ||
        indexFormatVersion != MTGenerationIndexFormatVersion ||
        resourceCount > MTGenerationIndexMaximumRecordCount ||
        ![assets isKindOfClass:NSArray.class] ||
        ![moduleIDs isKindOfClass:NSArray.class] ||
        assets.count > MTGenerationIndexMaximumRecordCount ||
        moduleIDs.count > MTGenerationMaximumModuleCount ||
        assets.count > resourceCount ||
        ((resourceCount == 0) != (assets.count == 0)) ||
        (resourceCount > 0 && moduleIDs.count == 0)) {
        MTGenerationDescriptorSetError(error,
            MTGenerationDescriptorErrorInvalidInput,
            @"Generation descriptor identity, index, or collection limits are invalid.",
            nil);
        return nil;
    }

    NSMutableArray<MTGenerationAssetDescriptor *> *validatedAssets =
        [NSMutableArray arrayWithCapacity:assets.count];
    uint64_t totalAssetBytes = 0;
    for (id candidate in assets) {
        if (![candidate isKindOfClass:MTGenerationAssetDescriptor.class]) {
            MTGenerationDescriptorSetError(error,
                MTGenerationDescriptorErrorInvalidInput,
                @"Generation assets contain an invalid object.", nil);
            return nil;
        }
        MTGenerationAssetDescriptor *asset = candidate;
        NSError *assetError = nil;
        MTGenerationAssetDescriptor *copy = [[MTGenerationAssetDescriptor alloc]
            initWithContentSHA256:asset.contentSHA256
                        byteCount:asset.byteCount
                            error:&assetError];
        if (copy == nil || UINT64_MAX - totalAssetBytes < copy.byteCount) {
            MTGenerationDescriptorSetError(error,
                MTGenerationDescriptorErrorLimitExceeded,
                @"Generation asset metadata exceeds its byte limit.", assetError);
            return nil;
        }
        totalAssetBytes += copy.byteCount;
        [validatedAssets addObject:copy];
    }
    [validatedAssets sortUsingComparator:
        ^NSComparisonResult(MTGenerationAssetDescriptor *left,
                            MTGenerationAssetDescriptor *right) {
        return MTGenerationLiteralCompare(left.contentSHA256,
                                          right.contentSHA256);
    }];
    for (NSUInteger index = 1; index < validatedAssets.count; index++) {
        if ([validatedAssets[index - 1].contentSHA256
                isEqualToString:validatedAssets[index].contentSHA256]) {
            MTGenerationDescriptorSetError(error,
                MTGenerationDescriptorErrorInvalidInput,
                @"Generation assets contain a duplicate digest.", nil);
            return nil;
        }
    }

    NSMutableArray<NSString *> *validatedModules =
        [NSMutableArray arrayWithCapacity:moduleIDs.count];
    for (id candidate in moduleIDs) {
        if (![candidate isKindOfClass:NSString.class] ||
            !MTIdentifierIsValid(candidate)) {
            MTGenerationDescriptorSetError(error,
                MTGenerationDescriptorErrorInvalidInput,
                @"Generation module identifier is invalid.", nil);
            return nil;
        }
        [validatedModules addObject:[candidate copy]];
    }
    [validatedModules sortUsingComparator:^NSComparisonResult(NSString *left,
                                                               NSString *right) {
        return MTGenerationLiteralCompare(left, right);
    }];
    for (NSUInteger index = 1; index < validatedModules.count; index++) {
        if ([validatedModules[index - 1]
                isEqualToString:validatedModules[index]]) {
            MTGenerationDescriptorSetError(error,
                MTGenerationDescriptorErrorInvalidInput,
                @"Generation module identifiers must be unique.", nil);
            return nil;
        }
    }

    NSError *configurationError = nil;
    NSDictionary *validatedConfigurations = MTNormalizeModuleConfigurations(
        moduleConfigurations, validatedModules, &configurationError);
    if (validatedConfigurations == nil) {
        MTGenerationDescriptorSetError(error,
            MTGenerationDescriptorErrorInvalidInput,
            @"Generation module configurations are invalid.",
            configurationError);
        return nil;
    }

    NSDictionary *base = MTGenerationBaseDictionary(
        themeID, libraryRevisionIdentifier, manifestDigest, indexSHA256,
        indexByteCount, indexFormatVersion, resourceCount, validatedAssets,
        totalAssetBytes, validatedModules, validatedConfigurations);
    NSError *canonicalError = nil;
    NSData *baseData = MTCanonicalJSONData(base, &canonicalError);
    NSString *generationDigest = baseData == nil
        ? nil
        : MTSHA256HexDigestForData(baseData);
    NSString *generationIdentifier = generationDigest == nil
        ? nil
        : [@"g1-" stringByAppendingString:generationDigest];
    NSMutableDictionary *complete = [base mutableCopy];
    if (generationDigest != nil && generationIdentifier != nil) {
        complete[@"generationDigest"] = generationDigest;
        complete[@"generationIdentifier"] = generationIdentifier;
    }
    NSData *canonicalData = generationDigest == nil
        ? nil
        : MTCanonicalJSONData(complete, &canonicalError);
    if (canonicalData == nil ||
        canonicalData.length > MTGenerationDescriptorMaximumByteCount) {
        MTGenerationDescriptorSetError(error,
            MTGenerationDescriptorErrorLimitExceeded,
            @"Generation descriptor could not be canonically encoded within its limit.",
            canonicalError);
        return nil;
    }

    self = [super init];
    if (self == nil) return nil;
    _schemaVersion = MTGenerationDescriptorSchemaVersion;
    _generationDigest = [generationDigest copy];
    _generationIdentifier = [generationIdentifier copy];
    _contractVersions = [MTCurrentContractVersions() copy];
    _themeID = [themeID copy];
    _libraryRevisionIdentifier = [libraryRevisionIdentifier copy];
    _manifestDigest = [manifestDigest copy];
    _indexSHA256 = [indexSHA256 copy];
    _indexByteCount = indexByteCount;
    _indexFormatVersion = indexFormatVersion;
    _resourceCount = resourceCount;
    _assets = [validatedAssets copy];
    _assetCount = validatedAssets.count;
    _assetByteCount = totalAssetBytes;
    _moduleIDs = [validatedModules copy];
    _moduleConfigurations = [validatedConfigurations copy];
    _canonicalData = [canonicalData copy];
    return self;
}

- (instancetype)initWithCanonicalData:(NSData *)canonicalData
                                 error:(NSError **)error {
    if (![canonicalData isKindOfClass:NSData.class] ||
        canonicalData.length == 0 ||
        canonicalData.length > MTGenerationDescriptorMaximumByteCount) {
        MTGenerationDescriptorSetError(error,
            MTGenerationDescriptorErrorLimitExceeded,
            @"Generation descriptor byte size is invalid.", nil);
        return nil;
    }
    NSError *parseError = nil;
    id object = [NSJSONSerialization JSONObjectWithData:canonicalData
                                                options:0
                                                  error:&parseError];
    NSData *roundTrip = object == nil
        ? nil
        : MTCanonicalJSONData(object, &parseError);
    if (![object isKindOfClass:NSDictionary.class] || roundTrip == nil ||
        ![roundTrip isEqualToData:canonicalData]) {
        MTGenerationDescriptorSetError(error,
            MTGenerationDescriptorErrorMalformedData,
            @"Generation completion marker is not canonical JSON.", parseError);
        return nil;
    }
    NSDictionary *root = object;
    uint64_t schemaVersion = 0;
    if (!MTGenerationUnsignedInteger(root[@"schemaVersion"], NSUIntegerMax,
                                     &schemaVersion) ||
        schemaVersion != MTGenerationDescriptorSchemaVersion) {
        MTGenerationDescriptorSetError(error,
            MTGenerationDescriptorErrorUnsupportedVersion,
            @"Generation descriptor schema version is unsupported.", nil);
        return nil;
    }
    NSArray *rootKeys = @[
        @"assetByteCount", @"assetCount", @"assets", @"contractVersions",
        @"generationDigest", @"generationIdentifier", @"index",
        @"libraryRevisionIdentifier", @"manifestDigest",
        @"moduleConfigurations", @"moduleIDs", @"schemaVersion", @"themeID",
    ];
    if (!MTGenerationDictionaryHasExactKeys(root, rootKeys)) {
        MTGenerationDescriptorSetError(error,
            MTGenerationDescriptorErrorMalformedData,
            @"Generation completion marker has unknown or missing fields.", nil);
        return nil;
    }
    NSDictionary *contracts = root[@"contractVersions"];
    if (!MTGenerationDictionaryHasExactKeys(contracts,
            MTCurrentContractVersions().allKeys) ||
        ![contracts isEqualToDictionary:MTCurrentContractVersions()]) {
        MTGenerationDescriptorSetError(error,
            MTGenerationDescriptorErrorUnsupportedVersion,
            @"Generation contract versions are unsupported.", nil);
        return nil;
    }
    NSDictionary *index = root[@"index"];
    if (!MTGenerationDictionaryHasExactKeys(index, @[
            @"byteCount", @"filename", @"formatVersion", @"resourceCount",
            @"sha256",
        ]) ||
        ![index[@"filename"] isEqual:MTGenerationIndexFilename]) {
        MTGenerationDescriptorSetError(error,
            MTGenerationDescriptorErrorMalformedData,
            @"Generation index descriptor is malformed.", nil);
        return nil;
    }
    uint64_t indexByteCount = 0;
    uint64_t indexFormatVersion = 0;
    uint64_t resourceCount = 0;
    uint64_t declaredAssetCount = 0;
    uint64_t declaredAssetBytes = 0;
    if (!MTGenerationUnsignedInteger(index[@"byteCount"], UINT64_MAX,
                                     &indexByteCount) ||
        !MTGenerationUnsignedInteger(index[@"formatVersion"], NSUIntegerMax,
                                     &indexFormatVersion) ||
        !MTGenerationUnsignedInteger(index[@"resourceCount"], NSUIntegerMax,
                                     &resourceCount) ||
        !MTGenerationUnsignedInteger(root[@"assetCount"], NSUIntegerMax,
                                     &declaredAssetCount) ||
        !MTGenerationUnsignedInteger(root[@"assetByteCount"], UINT64_MAX,
                                     &declaredAssetBytes)) {
        MTGenerationDescriptorSetError(error,
            MTGenerationDescriptorErrorMalformedData,
            @"Generation descriptor numeric fields are invalid.", nil);
        return nil;
    }
    NSArray *assetObjects = root[@"assets"];
    if (![assetObjects isKindOfClass:NSArray.class] ||
        assetObjects.count > MTGenerationIndexMaximumRecordCount) {
        MTGenerationDescriptorSetError(error,
            MTGenerationDescriptorErrorLimitExceeded,
            @"Generation asset descriptor count is invalid.", nil);
        return nil;
    }
    NSMutableArray<MTGenerationAssetDescriptor *> *assets =
        [NSMutableArray arrayWithCapacity:assetObjects.count];
    for (id candidate in assetObjects) {
        if (!MTGenerationDictionaryHasExactKeys(candidate,
                                                @[@"byteCount", @"sha256"])) {
            MTGenerationDescriptorSetError(error,
                MTGenerationDescriptorErrorMalformedData,
                @"Generation asset entry is malformed.", nil);
            return nil;
        }
        uint64_t byteCount = 0;
        if (!MTGenerationUnsignedInteger(candidate[@"byteCount"], UINT64_MAX,
                                         &byteCount)) {
            MTGenerationDescriptorSetError(error,
                MTGenerationDescriptorErrorMalformedData,
                @"Generation asset byte count is invalid.", nil);
            return nil;
        }
        NSError *assetError = nil;
        MTGenerationAssetDescriptor *asset = [[MTGenerationAssetDescriptor alloc]
            initWithContentSHA256:candidate[@"sha256"]
                        byteCount:byteCount
                            error:&assetError];
        if (asset == nil) {
            MTGenerationDescriptorSetError(error,
                MTGenerationDescriptorErrorMalformedData,
                @"Generation asset entry is invalid.", assetError);
            return nil;
        }
        [assets addObject:asset];
    }
    NSArray *modules = root[@"moduleIDs"];
    if (![modules isKindOfClass:NSArray.class]) {
        MTGenerationDescriptorSetError(error,
            MTGenerationDescriptorErrorMalformedData,
            @"Generation module list is malformed.", nil);
        return nil;
    }

    NSError *generatedError = nil;
    MTGenerationDescriptor *generated = [self
        initWithThemeID:root[@"themeID"]
        libraryRevisionIdentifier:root[@"libraryRevisionIdentifier"]
        manifestDigest:root[@"manifestDigest"]
        indexSHA256:index[@"sha256"]
        indexByteCount:indexByteCount
        indexFormatVersion:(NSUInteger)indexFormatVersion
        resourceCount:(NSUInteger)resourceCount
        assets:assets
        moduleIDs:modules
        moduleConfigurations:root[@"moduleConfigurations"]
        error:&generatedError];
    BOOL declaredCountsMatch =
        generated != nil && declaredAssetCount == generated.assetCount &&
        declaredAssetBytes == generated.assetByteCount;
    BOOL identityMatches = declaredCountsMatch &&
        [root[@"generationDigest"]
            isEqualToString:generated.generationDigest] &&
        [root[@"generationIdentifier"]
            isEqualToString:generated.generationIdentifier];
    if (!identityMatches ||
        ![generated.canonicalData isEqualToData:canonicalData]) {
        MTGenerationDescriptorSetError(error,
            MTGenerationDescriptorErrorMalformedData,
            @"Generation descriptor identity or canonical ordering is invalid.",
            generatedError);
        return nil;
    }
    return generated;
}

@end
