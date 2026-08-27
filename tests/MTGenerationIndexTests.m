#import "MTGenerationIndexTests.h"

#import <stdlib.h>

#import "MTDigest.h"
#import "MTGenerationIndexCodec.h"
#import "MTResourceKey.h"

static NSUInteger MTGenerationAssertionCount = 0;

static void MTGenerationAssert(BOOL condition, NSString *message) {
    MTGenerationAssertionCount++;
    if (condition) return;
    fprintf(stderr, "FAIL: %s\n", message.UTF8String);
    exit(1);
}

static NSString *MTGenerationDigest(NSUInteger value) {
    return [NSString stringWithFormat:@"%064llx",
                                      (unsigned long long)value];
}

static MTGenerationIndexRecord *MTGenerationRecord(NSString *subject,
                                                    NSUInteger digestValue,
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
    MTGenerationAssert(key != nil && error == nil,
                       @"generation fixture key must be canonical");
    MTGenerationIndexRecord *record = [[MTGenerationIndexRecord alloc]
        initWithCanonicalResourceKey:key.canonicalString
                       contentSHA256:MTGenerationDigest(digestValue)
                       assetByteCount:byteCount
                                error:&error];
    MTGenerationAssert(record != nil && error == nil,
                       @"generation fixture record must be valid");
    return record;
}

static void MTGenerationWriteLE32(NSMutableData *data,
                                  NSUInteger offset,
                                  uint32_t value) {
    uint8_t *bytes = data.mutableBytes;
    bytes[offset] = (uint8_t)(value & 0xffU);
    bytes[offset + 1] = (uint8_t)((value >> 8) & 0xffU);
    bytes[offset + 2] = (uint8_t)((value >> 16) & 0xffU);
    bytes[offset + 3] = (uint8_t)((value >> 24) & 0xffU);
}

static void MTGenerationWriteLE64(NSMutableData *data,
                                  NSUInteger offset,
                                  uint64_t value) {
    uint8_t *bytes = data.mutableBytes;
    for (NSUInteger index = 0; index < 8; index++) {
        bytes[offset + index] =
            (uint8_t)((value >> (index * 8)) & 0xffULL);
    }
}

static void MTGenerationAssertMalformed(NSData *data, NSString *message) {
    NSError *error = nil;
    MTGenerationIndex *index = [[MTGenerationIndex alloc]
        initWithEncodedData:data
                      error:&error];
    MTGenerationAssert(index == nil && error != nil, message);
}

NSUInteger MTRunGenerationIndexCodecTests(void) {
    MTGenerationAssertionCount = 0;
    MTGenerationIndexRecord *zulu =
        MTGenerationRecord(@"com.example.zulu", 3, 303);
    MTGenerationIndexRecord *alpha =
        MTGenerationRecord(@"com.example.alpha", 1, 101);
    MTGenerationIndexRecord *cafe =
        MTGenerationRecord(@"com.example.caf\u00e9", 2, 202);
    NSArray *input = @[zulu, cafe, alpha];

    NSError *error = nil;
    NSData *encoded = [MTGenerationIndex encodedDataWithRecords:input
                                                           error:&error];
    MTGenerationAssert(encoded != nil && error == nil,
                       @"valid generation records must encode");
    NSData *reordered = [MTGenerationIndex encodedDataWithRecords:
        @[alpha, zulu, cafe]
                                                                error:&error];
    MTGenerationAssert([encoded isEqualToData:reordered] && error == nil,
                       @"generation index encoding must ignore insertion order");
    MTGenerationAssert(encoded.length > 80,
                       @"non-empty generation index must contain records and strings");
    NSString *golden = MTSHA256HexDigestForData(encoded);
    MTGenerationAssert([golden isEqualToString:
        @"b8b3648fa21b975d4539f3f74d8e4a004d09264f5bf9c9672b9fb87176b76195"],
        [NSString stringWithFormat:@"generation index golden changed: %@", golden]);

    MTGenerationIndex *index = [[MTGenerationIndex alloc]
        initWithEncodedData:encoded
                      error:&error];
    MTGenerationAssert(index != nil && error == nil && index.recordCount == 3,
                       @"encoded generation index must fully validate");
    NSArray *sortedRecords = @[
        [index recordAtIndex:0],
        [index recordAtIndex:1],
        [index recordAtIndex:2],
    ];
    for (NSUInteger recordIndex = 1;
         recordIndex < sortedRecords.count;
         recordIndex++) {
        MTGenerationIndexRecord *previous = sortedRecords[recordIndex - 1];
        MTGenerationIndexRecord *current = sortedRecords[recordIndex];
        MTGenerationAssert([previous.canonicalResourceKey
            compare:current.canonicalResourceKey
            options:NSLiteralSearch] == NSOrderedAscending,
            @"generation records must be stored in canonical key order");
    }
    for (MTGenerationIndexRecord *expected in input) {
        error = nil;
        MTGenerationIndexRecord *found = [index
            recordForCanonicalResourceKey:expected.canonicalResourceKey
                                     error:&error];
        MTGenerationAssert(found != nil && error == nil &&
                           [found.contentSHA256
                               isEqualToString:expected.contentSHA256] &&
                           found.assetByteCount == expected.assetByteCount,
                           @"binary lookup must return the exact generation record");
    }
    MTGenerationIndexRecord *missing = MTGenerationRecord(
        @"com.example.missing", 9, 909);
    error = nil;
    MTGenerationAssert([index recordForCanonicalResourceKey:
                            missing.canonicalResourceKey
                                                        error:&error] == nil &&
                       error == nil,
                       @"a canonical generation lookup miss must not be an error");
    error = nil;
    MTGenerationAssert([index recordForCanonicalResourceKey:@"not-canonical"
                                                        error:&error] == nil &&
                       error.code == MTGenerationIndexErrorInvalidRecord,
                       @"an alternate resource key encoding must be rejected");
    error = nil;
    NSString *uppercaseModule = [alpha.canonicalResourceKey
        stringByReplacingOccurrencesOfString:@"icons.static"
                                  withString:@"Icons.static"];
    MTGenerationAssert([index
        recordForCanonicalResourceKey:uppercaseModule error:&error] == nil &&
        error.code == MTGenerationIndexErrorInvalidRecord,
        @"a non-lowercase identifier must be rejected by fast lookup validation");
    error = nil;
    NSString *decomposedSubject =
        @"mtk1|12:icons.static|16:springboard.icon|18:com.example.cafe\u0301|7:default|3|3:any";
    MTGenerationAssert([index
        recordForCanonicalResourceKey:decomposedSubject error:&error] == nil &&
        error.code == MTGenerationIndexErrorInvalidRecord,
        @"a non-NFC subject must be rejected by fast lookup validation");
    error = nil;
    NSString *unsafeSubject =
        @"mtk1|12:icons.static|16:springboard.icon|3:a/b|7:default|3|3:any";
    MTGenerationAssert([index
        recordForCanonicalResourceKey:unsafeSubject error:&error] == nil &&
        error.code == MTGenerationIndexErrorInvalidRecord,
        @"an unsafe subject must be rejected by fast lookup validation");
    MTGenerationAssert([index recordAtIndex:3] == nil,
                       @"generation record access must reject an out-of-range index");

    error = nil;
    NSString *uppercaseDigest = [@"A" stringByAppendingString:
        [alpha.contentSHA256 substringFromIndex:1]];
    MTGenerationIndexRecord *uppercase = [[MTGenerationIndexRecord alloc]
        initWithCanonicalResourceKey:alpha.canonicalResourceKey
                       contentSHA256:uppercaseDigest
                       assetByteCount:1
                                error:&error];
    MTGenerationAssert(uppercase == nil &&
                       error.code == MTGenerationIndexErrorInvalidRecord,
                       @"generation asset digests must be lowercase canonical hex");
    error = nil;
    MTGenerationIndexRecord *emptyAsset = [[MTGenerationIndexRecord alloc]
        initWithCanonicalResourceKey:alpha.canonicalResourceKey
                       contentSHA256:alpha.contentSHA256
                       assetByteCount:0
                                error:&error];
    MTGenerationAssert(emptyAsset == nil &&
                       error.code == MTGenerationIndexErrorInvalidRecord,
                       @"generation assets must have a non-zero byte count");
    error = nil;
    MTGenerationAssert([MTGenerationIndex encodedDataWithRecords:@[alpha, alpha]
                                                           error:&error] == nil &&
                       error.code == MTGenerationIndexErrorInvalidRecord,
                       @"duplicate generation resource keys must be rejected");

    error = nil;
    NSData *emptyData = [MTGenerationIndex encodedDataWithRecords:@[]
                                                             error:&error];
    MTGenerationIndex *emptyIndex = [[MTGenerationIndex alloc]
        initWithEncodedData:emptyData
                      error:&error];
    MTGenerationAssert(emptyData.length == 80 && emptyIndex.recordCount == 0 &&
                       error == nil,
                       @"the zero-resource generation index must be canonical");

    NSMutableData *badMagic = [encoded mutableCopy];
    ((uint8_t *)badMagic.mutableBytes)[0] ^= 0xff;
    MTGenerationAssertMalformed(badMagic,
        @"generation index magic corruption must be rejected");
    NSMutableData *badVersion = [encoded mutableCopy];
    MTGenerationWriteLE32(badVersion, 8, 2);
    MTGenerationAssertMalformed(badVersion,
        @"an unknown generation index version must be rejected");
    NSMutableData *badHeaderFlags = [encoded mutableCopy];
    MTGenerationWriteLE32(badHeaderFlags, 36, 1);
    MTGenerationAssertMalformed(badHeaderFlags,
        @"generation index header flags must be zero in v1");
    NSMutableData *badRecordFlags = [encoded mutableCopy];
    MTGenerationWriteLE32(badRecordFlags, 80 + 12, 1);
    MTGenerationAssertMalformed(badRecordFlags,
        @"generation index record flags must be zero in v1");
    NSMutableData *zeroAssetBytes = [encoded mutableCopy];
    MTGenerationWriteLE64(zeroAssetBytes, 80 + 48, 0);
    MTGenerationAssertMalformed(zeroAssetBytes,
        @"generation index zero-byte asset metadata must be rejected");
    NSMutableData *zeroKey = [encoded mutableCopy];
    MTGenerationWriteLE32(zeroKey, 80 + 8, 0);
    MTGenerationAssertMalformed(zeroKey,
        @"generation index zero-length keys must be rejected");
    NSMutableData *trailing = [encoded mutableCopy];
    uint8_t byte = 0;
    [trailing appendBytes:&byte length:1];
    MTGenerationAssertMalformed(trailing,
        @"generation index trailing bytes must be rejected");
    NSMutableData *truncated = [encoded mutableCopy];
    truncated.length -= 1;
    MTGenerationAssertMalformed(truncated,
        @"generation index truncation must be rejected");

    return MTGenerationAssertionCount;
}
