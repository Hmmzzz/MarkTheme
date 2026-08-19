#import "MTGenerationDescriptorTests.h"

#import <stdlib.h>

#import "MTCanonicalJSON.h"
#import "MTDigest.h"
#import "MTGenerationDescriptor.h"
#import "MTGenerationIndexCodec.h"
#import "MTResourceKey.h"

static NSUInteger MTDescriptorAssertionCount = 0;

static void MTDescriptorAssert(BOOL condition, NSString *message) {
    MTDescriptorAssertionCount++;
    if (condition) return;
    fprintf(stderr, "FAIL: %s\n", message.UTF8String);
    exit(1);
}

static NSString *MTDescriptorDigest(unichar character) {
    return [@"" stringByPaddingToLength:64
                              withString:[NSString stringWithCharacters:&character
                                                                 length:1]
                         startingAtIndex:0];
}

static MTGenerationIndexRecord *MTDescriptorIndexRecord(
    NSString *subject,
    NSString *digest,
    uint64_t byteCount) {
    NSError *error = nil;
    MTResourceKey *key = [[MTResourceKey alloc]
        initWithModuleID:@"icons.static"
                 surface:@"springboard.icon"
                 subject:subject
                 variant:@"default"
                   scale:3
                   trait:@"any"
                   error:&error];
    MTDescriptorAssert(key != nil && error == nil,
                       @"descriptor fixture key must be canonical");
    MTGenerationIndexRecord *record = [[MTGenerationIndexRecord alloc]
        initWithCanonicalResourceKey:key.canonicalString
                       contentSHA256:digest
                       assetByteCount:byteCount
                                error:&error];
    MTDescriptorAssert(record != nil && error == nil,
                       @"descriptor fixture index record must be valid");
    return record;
}

static MTGenerationAssetDescriptor *MTDescriptorAsset(NSString *digest,
                                                       uint64_t byteCount) {
    NSError *error = nil;
    MTGenerationAssetDescriptor *asset = [[MTGenerationAssetDescriptor alloc]
        initWithContentSHA256:digest
                    byteCount:byteCount
                        error:&error];
    MTDescriptorAssert(asset != nil && error == nil,
                       @"descriptor fixture asset must be valid");
    return asset;
}

static NSMutableDictionary *MTDescriptorJSONObject(NSData *data) {
    NSError *error = nil;
    id object = [NSJSONSerialization JSONObjectWithData:data
                                                options:NSJSONReadingMutableContainers
                                                  error:&error];
    MTDescriptorAssert([object isKindOfClass:NSMutableDictionary.class] &&
                       error == nil,
                       @"descriptor fixture JSON must be mutable");
    return object;
}

static NSData *MTDescriptorCanonicalData(id object) {
    NSError *error = nil;
    NSData *data = MTCanonicalJSONData(object, &error);
    MTDescriptorAssert(data != nil && error == nil,
                       @"mutated descriptor fixture must remain canonical JSON");
    return data;
}

static void MTDescriptorAssertRejected(NSData *data, NSString *message) {
    NSError *error = nil;
    MTGenerationDescriptor *descriptor = [[MTGenerationDescriptor alloc]
        initWithCanonicalData:data
                        error:&error];
    MTDescriptorAssert(descriptor == nil && error != nil, message);
}

NSUInteger MTRunGenerationDescriptorTests(void) {
    MTDescriptorAssertionCount = 0;
    NSString *manifestDigest = MTDescriptorDigest('1');
    NSString *assetA = MTDescriptorDigest('a');
    NSString *assetB = MTDescriptorDigest('b');
    NSArray *indexRecords = @[
        MTDescriptorIndexRecord(@"com.example.beta", assetB, 202),
        MTDescriptorIndexRecord(@"com.example.alpha", assetA, 101),
    ];
    NSError *error = nil;
    NSData *indexData = [MTGenerationIndex
        encodedDataWithRecords:indexRecords
                         error:&error];
    MTDescriptorAssert(indexData != nil && error == nil,
                       @"descriptor fixture index must encode");
    NSString *indexDigest = MTSHA256HexDigestForData(indexData);
    MTGenerationAssetDescriptor *firstAsset =
        MTDescriptorAsset(assetA, 101);
    MTGenerationAssetDescriptor *secondAsset =
        MTDescriptorAsset(assetB, 202);
    NSString *revisionIdentifier =
        [@"r1-" stringByAppendingString:manifestDigest];

    MTGenerationDescriptor *descriptor = [[MTGenerationDescriptor alloc]
        initWithThemeID:@"com.example.theme"
        libraryRevisionIdentifier:revisionIdentifier
        manifestDigest:manifestDigest
        indexSHA256:indexDigest
        indexByteCount:indexData.length
        indexFormatVersion:MTGenerationIndexFormatVersion
        resourceCount:indexRecords.count
        assets:@[secondAsset, firstAsset]
        moduleIDs:@[@"icons.static"]
        error:&error];
    MTDescriptorAssert(descriptor != nil && error == nil,
                       @"valid generation descriptor must initialize");
    MTDescriptorAssert(descriptor.schemaVersion ==
                           MTGenerationDescriptorSchemaVersion &&
                       descriptor.resourceCount == 2 &&
                       descriptor.assetCount == 2 &&
                       descriptor.assetByteCount == 303,
                       @"generation descriptor must preserve exact counts");
    MTDescriptorAssert([descriptor.assets[0].contentSHA256
                            isEqualToString:assetA] &&
                       [descriptor.assets[1].contentSHA256
                            isEqualToString:assetB],
                       @"generation assets must be digest-sorted");
    MTDescriptorAssert(descriptor.moduleConfigurations.count == 0,
                       @"static-only generation must retain an explicit empty configuration map");
    MTDescriptorAssert([descriptor.generationIdentifier isEqualToString:
        [@"g1-" stringByAppendingString:descriptor.generationDigest]],
        @"generation identifier must be derived from its descriptor digest");
    MTDescriptorAssert([descriptor.generationDigest isEqualToString:
        @"492d575268fa6c870c2a5ed336ea019c76338236b24af92876cb165179fa21ec"],
        [NSString stringWithFormat:@"generation descriptor golden changed: %@",
                                   descriptor.generationDigest]);

    MTGenerationDescriptor *reordered = [[MTGenerationDescriptor alloc]
        initWithThemeID:@"com.example.theme"
        libraryRevisionIdentifier:revisionIdentifier
        manifestDigest:manifestDigest
        indexSHA256:indexDigest
        indexByteCount:indexData.length
        indexFormatVersion:MTGenerationIndexFormatVersion
        resourceCount:indexRecords.count
        assets:@[firstAsset, secondAsset]
        moduleIDs:@[@"icons.static"]
        error:&error];
    MTDescriptorAssert([descriptor.canonicalData
                            isEqualToData:reordered.canonicalData] &&
                       error == nil,
                       @"generation descriptor must ignore asset insertion order");
    MTGenerationDescriptor *decoded = [[MTGenerationDescriptor alloc]
        initWithCanonicalData:descriptor.canonicalData
                        error:&error];
    MTDescriptorAssert(decoded != nil && error == nil &&
                       [decoded.generationIdentifier
                           isEqualToString:descriptor.generationIdentifier] &&
                       [decoded.canonicalData
                           isEqualToData:descriptor.canonicalData],
                       @"canonical generation descriptor must round-trip exactly");

    error = nil;
    MTGenerationDescriptor *empty = [[MTGenerationDescriptor alloc]
        initWithThemeID:@"com.example.empty"
        libraryRevisionIdentifier:revisionIdentifier
        manifestDigest:manifestDigest
        indexSHA256:MTSHA256HexDigestForData(
            [MTGenerationIndex encodedDataWithRecords:@[] error:&error])
        indexByteCount:80
        indexFormatVersion:MTGenerationIndexFormatVersion
        resourceCount:0
        assets:@[]
        moduleIDs:@[]
        error:&error];
    MTDescriptorAssert(empty != nil && empty.assetCount == 0 &&
                       empty.assetByteCount == 0 && error == nil,
                       @"a zero-resource generation descriptor must be valid");

    error = nil;
    MTGenerationDescriptor *missingAsset = [[MTGenerationDescriptor alloc]
        initWithThemeID:@"com.example.theme"
        libraryRevisionIdentifier:revisionIdentifier
        manifestDigest:manifestDigest
        indexSHA256:indexDigest
        indexByteCount:indexData.length
        indexFormatVersion:MTGenerationIndexFormatVersion
        resourceCount:1
        assets:@[]
        moduleIDs:@[@"icons.static"]
        error:&error];
    MTDescriptorAssert(missingAsset == nil && error != nil,
                       @"a resource-bearing generation must own an asset");
    error = nil;
    MTGenerationDescriptor *duplicateAsset = [[MTGenerationDescriptor alloc]
        initWithThemeID:@"com.example.theme"
        libraryRevisionIdentifier:revisionIdentifier
        manifestDigest:manifestDigest
        indexSHA256:indexDigest
        indexByteCount:indexData.length
        indexFormatVersion:MTGenerationIndexFormatVersion
        resourceCount:2
        assets:@[firstAsset, firstAsset]
        moduleIDs:@[@"icons.static"]
        error:&error];
    MTDescriptorAssert(duplicateAsset == nil && error != nil,
                       @"generation assets must have unique digests");
    error = nil;
    MTGenerationDescriptor *duplicateModule = [[MTGenerationDescriptor alloc]
        initWithThemeID:@"com.example.theme"
        libraryRevisionIdentifier:revisionIdentifier
        manifestDigest:manifestDigest
        indexSHA256:indexDigest
        indexByteCount:indexData.length
        indexFormatVersion:MTGenerationIndexFormatVersion
        resourceCount:2
        assets:@[firstAsset, secondAsset]
        moduleIDs:@[@"icons.static", @"icons.static"]
        error:&error];
    MTDescriptorAssert(duplicateModule == nil && error != nil,
                       @"generation module IDs must be unique");
    error = nil;
    MTGenerationDescriptor *wrongRevision = [[MTGenerationDescriptor alloc]
        initWithThemeID:@"com.example.theme"
        libraryRevisionIdentifier:[@"r1-" stringByAppendingString:assetA]
        manifestDigest:manifestDigest
        indexSHA256:indexDigest
        indexByteCount:indexData.length
        indexFormatVersion:MTGenerationIndexFormatVersion
        resourceCount:2
        assets:@[firstAsset, secondAsset]
        moduleIDs:@[@"icons.static"]
        error:&error];
    MTDescriptorAssert(wrongRevision == nil && error != nil,
                       @"generation revision ID must bind its manifest digest");

    NSMutableDictionary *badDigest =
        MTDescriptorJSONObject(descriptor.canonicalData);
    badDigest[@"generationDigest"] = MTDescriptorDigest('0');
    MTDescriptorAssertRejected(MTDescriptorCanonicalData(badDigest),
        @"generation descriptor digest mutation must be rejected");
    NSMutableDictionary *badIdentifier =
        MTDescriptorJSONObject(descriptor.canonicalData);
    badIdentifier[@"generationIdentifier"] =
        [@"g1-" stringByAppendingString:MTDescriptorDigest('0')];
    MTDescriptorAssertRejected(MTDescriptorCanonicalData(badIdentifier),
        @"generation identifier mutation must be rejected");
    NSMutableDictionary *extraField =
        MTDescriptorJSONObject(descriptor.canonicalData);
    extraField[@"unexpected"] = @1;
    MTDescriptorAssertRejected(MTDescriptorCanonicalData(extraField),
        @"unknown generation descriptor fields must be rejected");
    NSMutableDictionary *badSchema =
        MTDescriptorJSONObject(descriptor.canonicalData);
    badSchema[@"schemaVersion"] = @3;
    MTDescriptorAssertRejected(MTDescriptorCanonicalData(badSchema),
        @"unknown generation descriptor schemas must be rejected");
    NSMutableDictionary *badContracts =
        MTDescriptorJSONObject(descriptor.canonicalData);
    NSMutableDictionary *contracts =
        [badContracts[@"contractVersions"] mutableCopy];
    contracts[@"compiler"] = @3;
    badContracts[@"contractVersions"] = contracts;
    MTDescriptorAssertRejected(MTDescriptorCanonicalData(badContracts),
        @"unknown generation contract versions must be rejected");
    NSMutableDictionary *badIndex =
        MTDescriptorJSONObject(descriptor.canonicalData);
    NSMutableDictionary *indexObject = [badIndex[@"index"] mutableCopy];
    indexObject[@"filename"] = @"other.mtg";
    badIndex[@"index"] = indexObject;
    MTDescriptorAssertRejected(MTDescriptorCanonicalData(badIndex),
        @"generation index filename is part of the fixed schema");
    NSMutableDictionary *badAssetCount =
        MTDescriptorJSONObject(descriptor.canonicalData);
    badAssetCount[@"assetCount"] = @1;
    MTDescriptorAssertRejected(MTDescriptorCanonicalData(badAssetCount),
        @"generation asset count mismatch must be rejected");
    NSMutableDictionary *badAssetBytes =
        MTDescriptorJSONObject(descriptor.canonicalData);
    badAssetBytes[@"assetByteCount"] = @304;
    MTDescriptorAssertRejected(MTDescriptorCanonicalData(badAssetBytes),
        @"generation aggregate asset bytes mismatch must be rejected");
    NSMutableDictionary *unsortedAssets =
        MTDescriptorJSONObject(descriptor.canonicalData);
    unsortedAssets[@"assets"] =
        [unsortedAssets[@"assets"] reverseObjectEnumerator].allObjects;
    MTDescriptorAssertRejected(MTDescriptorCanonicalData(unsortedAssets),
        @"generation asset array must use its unique canonical order");
    NSMutableData *noncanonical = [descriptor.canonicalData mutableCopy];
    const uint8_t newline = '\n';
    [noncanonical appendBytes:&newline length:1];
    MTDescriptorAssertRejected(noncanonical,
        @"generation completion marker must not accept trailing whitespace");

    return MTDescriptorAssertionCount;
}
