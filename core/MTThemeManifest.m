#import "MTThemeManifest.h"

#import <CoreFoundation/CoreFoundation.h>

#import "MTCanonicalJSON.h"
#import "MTDigest.h"
#import "MTIdentifier.h"
#import "MTModuleConfiguration.h"
#import "MTResourceKey.h"
#import "MTVersionContracts.h"

NSString *const MTThemeManifestErrorDomain =
    @"com.hmmzzz.marktheme.theme-manifest";
NSUInteger const MTThemeManifestMaximumDisplayNameUTF8Bytes = 256;
NSUInteger const MTThemeManifestMaximumAuthorUTF8Bytes = 256;
NSUInteger const MTThemeManifestMaximumVersionUTF8Bytes = 128;

static BOOL MTManifestSetError(NSError **error,
                               NSInteger code,
                               NSString *description) {
    if (error != NULL) {
        *error = [NSError errorWithDomain:MTThemeManifestErrorDomain
                                     code:code
                                 userInfo:@{
            NSLocalizedDescriptionKey : description
        }];
    }
    return NO;
}

static NSString *_Nullable MTNormalizeMetadataString(NSString *value,
                                                       BOOL mayBeEmpty,
                                                       NSUInteger maximumBytes) {
    if (![value isKindOfClass:NSString.class]) return nil;
    NSString *trimmed = [value
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *normalized = [trimmed precomposedStringWithCanonicalMapping];
    NSData *utf8 = [normalized dataUsingEncoding:NSUTF8StringEncoding
                            allowLossyConversion:NO];
    if (utf8 == nil) return nil;
    NSUInteger length = utf8.length;
    if ((!mayBeEmpty && length == 0) || length > maximumBytes) return nil;
    for (NSUInteger index = 0; index < normalized.length; index++) {
        unichar character = [normalized characterAtIndex:index];
        if (character == 0 || character < 0x20 || character == 0x7f) return nil;
    }
    return normalized;
}

static BOOL MTRelativeManifestPathIsSafe(NSString *path) {
    if (![path isKindOfClass:NSString.class] || path.length == 0 ||
        [path hasPrefix:@"/"] || [path hasSuffix:@"/"] ||
        [path containsString:@"\\"] ||
        [path lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 1024) {
        return NO;
    }
    for (NSString *component in [path componentsSeparatedByString:@"/"]) {
        if (component.length == 0 || [component isEqualToString:@"."] ||
            [component isEqualToString:@".."]) {
            return NO;
        }
        for (NSUInteger index = 0; index < component.length; index++) {
            unichar character = [component characterAtIndex:index];
            if (character == 0 || character < 0x20 || character == 0x7f) {
                return NO;
            }
        }
    }
    return YES;
}

static BOOL MTDictionaryHasExactlyKeys(NSDictionary *dictionary,
                                       NSArray<NSString *> *keys) {
    return dictionary.count == keys.count &&
        [[NSSet setWithArray:dictionary.allKeys]
            isEqualToSet:[NSSet setWithArray:keys]];
}

static BOOL MTReadUnsignedInteger(id value,
                                  NSUInteger maximum,
                                  NSUInteger *result) {
    if (![value isKindOfClass:NSNumber.class] ||
        CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) {
        return NO;
    }
    NSNumber *number = value;
    double doubleValue = number.doubleValue;
    NSUInteger integerValue = number.unsignedIntegerValue;
    if (doubleValue < 0 || doubleValue != (double)integerValue ||
        integerValue > maximum) {
        return NO;
    }
    if (result != NULL) *result = integerValue;
    return YES;
}

@implementation MTThemeResource

- (instancetype)initWithResourceKey:(MTResourceKey *)resourceKey
                   relativeAssetPath:(NSString *)relativeAssetPath
                       contentSHA256:(NSString *)contentSHA256
                        sourceFormat:(NSString *)sourceFormat
                           matchRank:(NSUInteger)matchRank
                               error:(NSError **)error {
    NSString *normalizedPath =
        [relativeAssetPath precomposedStringWithCanonicalMapping];
    NSString *normalizedSourceFormat = MTNormalizeIdentifier(sourceFormat, NULL);
    if (![resourceKey isKindOfClass:MTResourceKey.class] ||
        !MTRelativeManifestPathIsSafe(normalizedPath) ||
        !MTStringIsLowercaseSHA256Digest(contentSHA256) ||
        normalizedSourceFormat == nil || matchRank > UINT16_MAX) {
        MTManifestSetError(error, 1, @"Theme resource is invalid.");
        return nil;
    }
    self = [super init];
    if (self == nil) return nil;
    _resourceKey = resourceKey;
    _relativeAssetPath = [normalizedPath copy];
    _contentSHA256 = [contentSHA256 copy];
    _sourceFormat = [normalizedSourceFormat copy];
    _matchRank = matchRank;
    return self;
}

- (instancetype)initWithDictionary:(NSDictionary<NSString *,id> *)dictionary
                               error:(NSError **)error {
    if (![dictionary isKindOfClass:NSDictionary.class] ||
        !MTDictionaryHasExactlyKeys(dictionary,
            @[@"asset", @"contentSHA256", @"key", @"matchRank", @"sourceFormat"]) ||
        ![dictionary[@"key"] isKindOfClass:NSDictionary.class]) {
        MTManifestSetError(error, 2, @"Theme resource dictionary is malformed.");
        return nil;
    }
    NSDictionary *keyDictionary = dictionary[@"key"];
    if (!MTDictionaryHasExactlyKeys(keyDictionary,
        @[@"moduleID", @"scale", @"subject", @"surface", @"trait", @"variant"])) {
        MTManifestSetError(error, 2, @"Theme resource key is malformed.");
        return nil;
    }
    NSUInteger scale = 0;
    NSUInteger matchRank = 0;
    if (!MTReadUnsignedInteger(keyDictionary[@"scale"], 3, &scale) ||
        !MTReadUnsignedInteger(dictionary[@"matchRank"], UINT16_MAX,
                               &matchRank)) {
        MTManifestSetError(error, 2, @"Theme resource number is malformed.");
        return nil;
    }
    NSError *keyError = nil;
    MTResourceKey *key = [[MTResourceKey alloc]
        initWithModuleID:keyDictionary[@"moduleID"]
                 surface:keyDictionary[@"surface"]
                 subject:keyDictionary[@"subject"]
                 variant:keyDictionary[@"variant"]
                   scale:scale
                   trait:keyDictionary[@"trait"]
                   error:&keyError];
    if (key == nil) {
        if (error != NULL) *error = keyError;
        return nil;
    }
    return [self initWithResourceKey:key
                   relativeAssetPath:dictionary[@"asset"]
                       contentSHA256:dictionary[@"contentSHA256"]
                        sourceFormat:dictionary[@"sourceFormat"]
                           matchRank:matchRank
                               error:error];
}

- (NSDictionary<NSString *,id> *)canonicalDictionary {
    return @{
        @"asset" : self.relativeAssetPath,
        @"contentSHA256" : self.contentSHA256,
        @"key" : @{
            @"moduleID" : self.resourceKey.moduleID,
            @"scale" : @(self.resourceKey.scale),
            @"subject" : self.resourceKey.subject,
            @"surface" : self.resourceKey.surface,
            @"trait" : self.resourceKey.trait,
            @"variant" : self.resourceKey.variant,
        },
        @"matchRank" : @(self.matchRank),
        @"sourceFormat" : self.sourceFormat,
    };
}

@end

static NSArray<NSString *> *_Nullable MTNormalizeCapabilities(
    NSArray<NSString *> *capabilities) {
    if (![capabilities isKindOfClass:NSArray.class] || capabilities.count == 0) {
        return nil;
    }
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    NSMutableArray<NSString *> *normalized = [NSMutableArray array];
    for (id value in capabilities) {
        NSString *identifier = MTNormalizeIdentifier(value, NULL);
        if (identifier == nil || [seen containsObject:identifier]) return nil;
        [seen addObject:identifier];
        [normalized addObject:identifier];
    }
    return [normalized sortedArrayUsingComparator:^NSComparisonResult(
        NSString *left, NSString *right) {
        return [left compare:right options:NSLiteralSearch];
    }];
}

static NSComparisonResult MTCompareThemeResources(MTThemeResource *left,
                                                   MTThemeResource *right) {
    NSComparisonResult result = [left.resourceKey.canonicalString
        compare:right.resourceKey.canonicalString options:NSLiteralSearch];
    if (result != NSOrderedSame) return result;
    if (left.matchRank != right.matchRank) {
        return left.matchRank < right.matchRank
            ? NSOrderedAscending : NSOrderedDescending;
    }
    result = [left.relativeAssetPath compare:right.relativeAssetPath
                                      options:NSLiteralSearch];
    if (result != NSOrderedSame) return result;
    result = [left.sourceFormat compare:right.sourceFormat options:NSLiteralSearch];
    if (result != NSOrderedSame) return result;
    return [left.contentSHA256 compare:right.contentSHA256 options:NSLiteralSearch];
}

@implementation MTThemeManifest

- (instancetype)initWithThemeID:(NSString *)themeID
                      displayName:(NSString *)displayName
                           author:(NSString *)author
                     themeVersion:(NSString *)themeVersion
                       importerID:(NSString *)importerID
                  importerVersion:(NSUInteger)importerVersion
                sourceFingerprint:(NSString *)sourceFingerprint
                     capabilities:(NSArray<NSString *> *)capabilities
                        resources:(NSArray<MTThemeResource *> *)resources
                            error:(NSError **)error {
    return [self initWithThemeID:themeID
                     displayName:displayName
                          author:author
                    themeVersion:themeVersion
                      importerID:importerID
                 importerVersion:importerVersion
               sourceFingerprint:sourceFingerprint
                    capabilities:capabilities
            moduleConfigurations:@{}
                       resources:resources
                           error:error];
}

- (instancetype)initWithThemeID:(NSString *)themeID
                      displayName:(NSString *)displayName
                           author:(NSString *)author
                     themeVersion:(NSString *)themeVersion
                       importerID:(NSString *)importerID
                  importerVersion:(NSUInteger)importerVersion
                sourceFingerprint:(NSString *)sourceFingerprint
                     capabilities:(NSArray<NSString *> *)capabilities
             moduleConfigurations:
    (NSDictionary<NSString *,NSDictionary<NSString *,id> *> *)
        moduleConfigurations
                        resources:(NSArray<MTThemeResource *> *)resources
                            error:(NSError **)error {
    NSString *normalizedThemeID = MTNormalizeIdentifier(themeID, NULL);
    NSString *normalizedName = MTNormalizeMetadataString(
        displayName, NO, MTThemeManifestMaximumDisplayNameUTF8Bytes);
    NSString *normalizedAuthor = MTNormalizeMetadataString(
        author, YES, MTThemeManifestMaximumAuthorUTF8Bytes);
    NSString *normalizedThemeVersion =
        MTNormalizeMetadataString(themeVersion, YES,
                                  MTThemeManifestMaximumVersionUTF8Bytes);
    NSString *normalizedImporter = MTNormalizeIdentifier(importerID, NULL);
    NSArray<NSString *> *normalizedCapabilities =
        MTNormalizeCapabilities(capabilities);
    NSError *configurationError = nil;
    NSDictionary *normalizedConfigurations = normalizedCapabilities == nil
        ? nil
        : MTNormalizeModuleConfigurations(moduleConfigurations,
                                          normalizedCapabilities,
                                          &configurationError);
    if (normalizedThemeID == nil || normalizedName == nil ||
        normalizedAuthor == nil || normalizedThemeVersion == nil ||
        normalizedImporter == nil || importerVersion == 0 ||
        !MTStringIsLowercaseSHA256Digest(sourceFingerprint) ||
        normalizedCapabilities == nil || normalizedConfigurations == nil ||
        ![resources isKindOfClass:NSArray.class] || resources.count == 0) {
        if (error != NULL && configurationError != nil) {
            *error = configurationError;
        } else {
            MTManifestSetError(error, 3, @"Theme manifest fields are invalid.");
        }
        return nil;
    }

    NSMutableSet<NSString *> *resourceIdentities = [NSMutableSet set];
    for (id object in resources) {
        if (![object isKindOfClass:MTThemeResource.class]) {
            MTManifestSetError(error, 3,
                @"Theme manifest contains an invalid resource.");
            return nil;
        }
        MTThemeResource *resource = object;
        if (![normalizedCapabilities containsObject:resource.resourceKey.moduleID]) {
            MTManifestSetError(error, 3,
                @"Theme resource module is not declared as a capability.");
            return nil;
        }
        NSString *identity = [NSString stringWithFormat:@"%@\x1f%lu\x1f%@",
            resource.resourceKey.canonicalString,
            (unsigned long)resource.matchRank,
            resource.relativeAssetPath];
        if ([resourceIdentities containsObject:identity]) {
            MTManifestSetError(error, 3,
                @"Theme manifest contains a duplicate resource entry.");
            return nil;
        }
        [resourceIdentities addObject:identity];
    }

    self = [super init];
    if (self == nil) return nil;
    _schemaVersion = MTThemeManifestVersion;
    _themeID = [normalizedThemeID copy];
    _displayName = [normalizedName copy];
    _author = [normalizedAuthor copy];
    _themeVersion = [normalizedThemeVersion copy];
    _importerID = [normalizedImporter copy];
    _importerVersion = importerVersion;
    _sourceFingerprint = [sourceFingerprint copy];
    _capabilities = [normalizedCapabilities copy];
    _moduleConfigurations = [normalizedConfigurations copy];
    _resources = [[resources sortedArrayUsingComparator:
        ^NSComparisonResult(MTThemeResource *left, MTThemeResource *right) {
            return MTCompareThemeResources(left, right);
        }] copy];
    return self;
}

- (instancetype)initWithDictionary:(NSDictionary<NSString *,id> *)dictionary
                               error:(NSError **)error {
    NSUInteger schemaVersion = 0;
    if (![dictionary isKindOfClass:NSDictionary.class] ||
        !MTReadUnsignedInteger(dictionary[@"schemaVersion"], NSUIntegerMax,
                               &schemaVersion) ||
        schemaVersion != MTThemeManifestVersion) {
        MTManifestSetError(error, 4,
            @"Theme manifest version is unsupported.");
        return nil;
    }
    if (!MTDictionaryHasExactlyKeys(dictionary,
            @[@"capabilities", @"display", @"importer",
              @"moduleConfigurations", @"resources", @"schemaVersion",
              @"sourceFingerprint", @"themeID"]) ||
        ![dictionary[@"display"] isKindOfClass:NSDictionary.class] ||
        ![dictionary[@"importer"] isKindOfClass:NSDictionary.class] ||
        ![dictionary[@"resources"] isKindOfClass:NSArray.class] ||
        ![dictionary[@"moduleConfigurations"] isKindOfClass:NSDictionary.class]) {
        MTManifestSetError(error, 4, @"Theme manifest dictionary is malformed.");
        return nil;
    }
    NSDictionary *display = dictionary[@"display"];
    NSDictionary *importer = dictionary[@"importer"];
    if (!MTDictionaryHasExactlyKeys(display,
            @[@"author", @"name", @"version"]) ||
        !MTDictionaryHasExactlyKeys(importer, @[@"id", @"version"])) {
        MTManifestSetError(error, 4,
            @"Theme manifest metadata dictionary is malformed.");
        return nil;
    }
    NSUInteger importerVersion = 0;
    if (!MTReadUnsignedInteger(importer[@"version"], UINT32_MAX,
                               &importerVersion) || importerVersion == 0) {
        MTManifestSetError(error, 4,
            @"Theme manifest version is unsupported.");
        return nil;
    }

    NSMutableArray<MTThemeResource *> *resources = [NSMutableArray array];
    for (id object in dictionary[@"resources"]) {
        if (![object isKindOfClass:NSDictionary.class]) {
            MTManifestSetError(error, 4,
                @"Theme manifest resource is malformed.");
            return nil;
        }
        MTThemeResource *resource = [[MTThemeResource alloc]
            initWithDictionary:object error:error];
        if (resource == nil) return nil;
        [resources addObject:resource];
    }
    return [self initWithThemeID:dictionary[@"themeID"]
                      displayName:display[@"name"]
                           author:display[@"author"]
                     themeVersion:display[@"version"]
                       importerID:importer[@"id"]
                  importerVersion:importerVersion
                sourceFingerprint:dictionary[@"sourceFingerprint"]
                     capabilities:dictionary[@"capabilities"]
             moduleConfigurations:dictionary[@"moduleConfigurations"]
                        resources:resources
                            error:error];
}

- (NSDictionary<NSString *,id> *)canonicalDictionary {
    NSMutableArray<NSDictionary<NSString *, id> *> *resources =
        [NSMutableArray arrayWithCapacity:self.resources.count];
    for (MTThemeResource *resource in self.resources) {
        [resources addObject:resource.canonicalDictionary];
    }
    return @{
        @"capabilities" : self.capabilities,
        @"display" : @{
            @"author" : self.author,
            @"name" : self.displayName,
            @"version" : self.themeVersion,
        },
        @"importer" : @{
            @"id" : self.importerID,
            @"version" : @(self.importerVersion),
        },
        @"moduleConfigurations" : self.moduleConfigurations,
        @"resources" : resources,
        @"schemaVersion" : @(self.schemaVersion),
        @"sourceFingerprint" : self.sourceFingerprint,
        @"themeID" : self.themeID,
    };
}

- (NSData *)canonicalDataWithError:(NSError **)error {
    return MTCanonicalJSONData(self.canonicalDictionary, error);
}

- (NSString *)contentDigestWithError:(NSError **)error {
    NSData *data = [self canonicalDataWithError:error];
    return data != nil ? MTSHA256HexDigestForData(data) : nil;
}

@end
