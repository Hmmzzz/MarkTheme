#import "MTGenerationIndexCodec.h"

#import <string.h>

#import "MTResourceKey.h"

NSString *const MTGenerationIndexErrorDomain =
    @"com.hmmzzz.marktheme.generation-index";
NSUInteger const MTGenerationIndexFormatVersion = 1;
NSUInteger const MTGenerationIndexMaximumRecordCount = 100000;
uint64_t const MTGenerationIndexMaximumByteCount = 128ULL * 1024ULL * 1024ULL;

static const uint8_t MTGenerationIndexMagic[8] = {
    'M', 'T', 'G', 'I', 'D', 'X', 0, 0,
};
static const uint64_t MTGenerationIndexHeaderByteCount = 80;
static const uint32_t MTGenerationIndexRecordByteCount = 64;
static const uint64_t MTGenerationIndexMaximumKeyByteCount = 2048;

static BOOL MTGenerationIndexSetError(NSError **error,
                                      MTGenerationIndexErrorCode code,
                                      NSString *description) {
    if (error != NULL) {
        *error = [NSError errorWithDomain:MTGenerationIndexErrorDomain
                                     code:code
                                 userInfo:@{
            NSLocalizedDescriptionKey : description,
        }];
    }
    return NO;
}

static void MTWriteLittleEndian32(uint8_t *bytes, uint32_t value) {
    bytes[0] = (uint8_t)(value & 0xffU);
    bytes[1] = (uint8_t)((value >> 8) & 0xffU);
    bytes[2] = (uint8_t)((value >> 16) & 0xffU);
    bytes[3] = (uint8_t)((value >> 24) & 0xffU);
}

static void MTWriteLittleEndian64(uint8_t *bytes, uint64_t value) {
    for (NSUInteger index = 0; index < 8; index++) {
        bytes[index] = (uint8_t)((value >> (index * 8)) & 0xffULL);
    }
}

static uint32_t MTReadLittleEndian32(const uint8_t *bytes) {
    return (uint32_t)bytes[0] |
        ((uint32_t)bytes[1] << 8) |
        ((uint32_t)bytes[2] << 16) |
        ((uint32_t)bytes[3] << 24);
}

static uint64_t MTReadLittleEndian64(const uint8_t *bytes) {
    uint64_t value = 0;
    for (NSUInteger index = 0; index < 8; index++) {
        value |= ((uint64_t)bytes[index]) << (index * 8);
    }
    return value;
}

static BOOL MTAddUnsigned64(uint64_t left,
                            uint64_t right,
                            uint64_t *result) {
    if (UINT64_MAX - left < right) return NO;
    *result = left + right;
    return YES;
}

static BOOL MTMultiplyUnsigned64(uint64_t left,
                                 uint64_t right,
                                 uint64_t *result) {
    if (left != 0 && right > UINT64_MAX / left) return NO;
    *result = left * right;
    return YES;
}

static BOOL MTDigestStringIsCanonical(NSString *digest) {
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

static uint8_t MTHexNibble(unichar character) {
    return character <= '9' ? (uint8_t)(character - '0')
                            : (uint8_t)(character - 'a' + 10);
}

static NSData *MTDigestBytes(NSString *digest) {
    uint8_t bytes[32];
    for (NSUInteger index = 0; index < 32; index++) {
        bytes[index] = (uint8_t)((MTHexNibble([digest characterAtIndex:index * 2])
                                 << 4) |
                                MTHexNibble([digest characterAtIndex:index * 2 + 1]));
    }
    return [NSData dataWithBytes:bytes length:sizeof(bytes)];
}

static NSString *MTHexString(const uint8_t *bytes, NSUInteger length) {
    static const char digits[] = "0123456789abcdef";
    NSMutableData *characters = [NSMutableData dataWithLength:length * 2];
    char *output = characters.mutableBytes;
    for (NSUInteger index = 0; index < length; index++) {
        output[index * 2] = digits[(bytes[index] >> 4) & 0xf];
        output[index * 2 + 1] = digits[bytes[index] & 0xf];
    }
    return [[NSString alloc] initWithBytes:characters.bytes
                                    length:characters.length
                                  encoding:NSASCIIStringEncoding];
}

static BOOL MTParseLength(const uint8_t *bytes,
                          NSUInteger length,
                          NSUInteger *cursor,
                          uint64_t *value) {
    NSUInteger start = *cursor;
    uint64_t parsed = 0;
    while (*cursor < length && bytes[*cursor] >= '0' &&
           bytes[*cursor] <= '9') {
        uint8_t digit = (uint8_t)(bytes[*cursor] - '0');
        if (parsed > (UINT64_MAX - digit) / 10) return NO;
        parsed = parsed * 10 + digit;
        (*cursor)++;
    }
    NSUInteger digitCount = *cursor - start;
    if (digitCount == 0 || *cursor >= length || bytes[*cursor] != ':' ||
        (digitCount > 1 && bytes[start] == '0')) {
        return NO;
    }
    (*cursor)++;
    *value = parsed;
    return YES;
}

static NSString *_Nullable MTParseKeyComponent(const uint8_t *bytes,
                                                NSUInteger length,
                                                NSUInteger *cursor,
                                                BOOL expectsSeparator) {
    uint64_t componentLength = 0;
    if (!MTParseLength(bytes, length, cursor, &componentLength) ||
        componentLength == 0 || componentLength > MTGenerationIndexMaximumKeyByteCount ||
        componentLength > (uint64_t)(length - *cursor)) {
        return nil;
    }
    NSUInteger safeLength = (NSUInteger)componentLength;
    NSString *component = [[NSString alloc]
        initWithBytes:bytes + *cursor
               length:safeLength
             encoding:NSUTF8StringEncoding];
    if (component == nil ||
        ![[component dataUsingEncoding:NSUTF8StringEncoding]
            isEqualToData:[NSData dataWithBytes:bytes + *cursor
                                         length:safeLength]]) {
        return nil;
    }
    *cursor += safeLength;
    if (expectsSeparator) {
        if (*cursor >= length || bytes[*cursor] != '|') return nil;
        (*cursor)++;
    } else if (*cursor != length) {
        return nil;
    }
    return component;
}

static BOOL MTCanonicalResourceKeyDataIsValid(NSData *data,
                                               NSString **stringOutput) {
    if (![data isKindOfClass:NSData.class] || data.length == 0 ||
        data.length > MTGenerationIndexMaximumKeyByteCount) {
        return NO;
    }
    const uint8_t *bytes = data.bytes;
    static const uint8_t prefix[] = {'m', 't', 'k', '1', '|'};
    if (data.length <= sizeof(prefix) ||
        memcmp(bytes, prefix, sizeof(prefix)) != 0) {
        return NO;
    }
    NSUInteger cursor = sizeof(prefix);
    NSString *moduleID = MTParseKeyComponent(bytes, data.length, &cursor, YES);
    NSString *surface = MTParseKeyComponent(bytes, data.length, &cursor, YES);
    NSString *subject = MTParseKeyComponent(bytes, data.length, &cursor, YES);
    NSString *variant = MTParseKeyComponent(bytes, data.length, &cursor, YES);
    if (moduleID == nil || surface == nil || subject == nil || variant == nil ||
        cursor >= data.length || bytes[cursor] < '0' || bytes[cursor] > '3') {
        return NO;
    }
    NSUInteger scale = (NSUInteger)(bytes[cursor] - '0');
    cursor++;
    if (cursor >= data.length || bytes[cursor] != '|') return NO;
    cursor++;
    NSString *trait = MTParseKeyComponent(bytes, data.length, &cursor, NO);
    if (trait == nil) return NO;

    NSError *keyError = nil;
    MTResourceKey *key = [[MTResourceKey alloc] initWithModuleID:moduleID
                                                        surface:surface
                                                        subject:subject
                                                        variant:variant
                                                          scale:scale
                                                          trait:trait
                                                          error:&keyError];
    NSData *canonicalData =
        [key.canonicalString dataUsingEncoding:NSUTF8StringEncoding];
    if (key == nil || keyError != nil || ![canonicalData isEqualToData:data]) {
        return NO;
    }
    if (stringOutput != NULL) *stringOutput = key.canonicalString;
    return YES;
}

static NSData *_Nullable MTCanonicalResourceKeyData(NSString *key,
                                                     NSError **error) {
    if (![key isKindOfClass:NSString.class]) {
        MTGenerationIndexSetError(error, MTGenerationIndexErrorInvalidRecord,
                                  @"Generation resource key must be a string.");
        return nil;
    }
    NSData *data = [key dataUsingEncoding:NSUTF8StringEncoding];
    if (!MTCanonicalResourceKeyDataIsValid(data, NULL)) {
        MTGenerationIndexSetError(error, MTGenerationIndexErrorInvalidRecord,
                                  @"Generation resource key is not canonical.");
        return nil;
    }
    return data;
}

static NSComparisonResult MTCompareBytes(NSData *left, NSData *right) {
    NSUInteger commonLength = MIN(left.length, right.length);
    int comparison = memcmp(left.bytes, right.bytes, commonLength);
    if (comparison < 0) return NSOrderedAscending;
    if (comparison > 0) return NSOrderedDescending;
    if (left.length < right.length) return NSOrderedAscending;
    if (left.length > right.length) return NSOrderedDescending;
    return NSOrderedSame;
}

@implementation MTGenerationIndexRecord

- (instancetype)initWithCanonicalResourceKey:(NSString *)canonicalResourceKey
                                contentSHA256:(NSString *)contentSHA256
                                assetByteCount:(uint64_t)assetByteCount
                                         error:(NSError **)error {
    if (MTCanonicalResourceKeyData(canonicalResourceKey, error) == nil ||
        !MTDigestStringIsCanonical(contentSHA256) || assetByteCount == 0) {
        if (error != NULL && *error == nil) {
            MTGenerationIndexSetError(error,
                MTGenerationIndexErrorInvalidRecord,
                @"Generation index record digest or byte count is invalid.");
        }
        return nil;
    }
    self = [super init];
    if (self == nil) return nil;
    _canonicalResourceKey = [canonicalResourceKey copy];
    _contentSHA256 = [contentSHA256 copy];
    _assetByteCount = assetByteCount;
    return self;
}

@end

@interface MTGenerationIndex ()

@property(nonatomic, copy, readwrite) NSData *encodedData;
@property(nonatomic, assign, readwrite) NSUInteger recordCount;

@end

@implementation MTGenerationIndex

+ (NSData *)encodedDataWithRecords:(NSArray<MTGenerationIndexRecord *> *)records
                              error:(NSError **)error {
    if (![records isKindOfClass:NSArray.class] ||
        records.count > MTGenerationIndexMaximumRecordCount) {
        MTGenerationIndexSetError(error, MTGenerationIndexErrorLimitExceeded,
                                  @"Generation index record count exceeds its limit.");
        return nil;
    }

    NSMutableArray<NSDictionary<NSString *, id> *> *validated =
        [NSMutableArray arrayWithCapacity:records.count];
    uint64_t stringByteCount = 0;
    for (id candidate in records) {
        if (![candidate isKindOfClass:MTGenerationIndexRecord.class]) {
            MTGenerationIndexSetError(error, MTGenerationIndexErrorInvalidRecord,
                                      @"Generation index contains an invalid record object.");
            return nil;
        }
        MTGenerationIndexRecord *record = candidate;
        NSError *recordError = nil;
        MTGenerationIndexRecord *copy = [[MTGenerationIndexRecord alloc]
            initWithCanonicalResourceKey:record.canonicalResourceKey
                           contentSHA256:record.contentSHA256
                           assetByteCount:record.assetByteCount
                                    error:&recordError];
        NSData *keyData = MTCanonicalResourceKeyData(copy.canonicalResourceKey,
                                                     &recordError);
        if (copy == nil || keyData == nil ||
            !MTAddUnsigned64(stringByteCount, keyData.length,
                             &stringByteCount)) {
            if (error != NULL) {
                *error = recordError ?: [NSError
                    errorWithDomain:MTGenerationIndexErrorDomain
                               code:MTGenerationIndexErrorLimitExceeded
                           userInfo:@{
                    NSLocalizedDescriptionKey :
                        @"Generation index string table size overflowed."
                }];
            }
            return nil;
        }
        [validated addObject:@{
            @"record" : copy,
            @"keyData" : keyData,
        }];
    }
    [validated sortUsingComparator:^NSComparisonResult(NSDictionary *left,
                                                        NSDictionary *right) {
        return MTCompareBytes(left[@"keyData"], right[@"keyData"]);
    }];
    for (NSUInteger index = 1; index < validated.count; index++) {
        if (MTCompareBytes(validated[index - 1][@"keyData"],
                           validated[index][@"keyData"]) == NSOrderedSame) {
            MTGenerationIndexSetError(error,
                MTGenerationIndexErrorInvalidRecord,
                @"Generation index contains a duplicate resource key.");
            return nil;
        }
    }

    uint64_t entryByteCount = 0;
    uint64_t stringsOffset = 0;
    uint64_t totalByteCount = 0;
    if (!MTMultiplyUnsigned64(validated.count,
                              MTGenerationIndexRecordByteCount,
                              &entryByteCount) ||
        !MTAddUnsigned64(MTGenerationIndexHeaderByteCount,
                         entryByteCount,
                         &stringsOffset) ||
        !MTAddUnsigned64(stringsOffset, stringByteCount, &totalByteCount) ||
        totalByteCount > MTGenerationIndexMaximumByteCount ||
        totalByteCount > NSUIntegerMax) {
        MTGenerationIndexSetError(error, MTGenerationIndexErrorLimitExceeded,
                                  @"Generation index byte size exceeds its limit.");
        return nil;
    }

    NSMutableData *output = [NSMutableData dataWithLength:(NSUInteger)totalByteCount];
    uint8_t *bytes = output.mutableBytes;
    memcpy(bytes, MTGenerationIndexMagic, sizeof(MTGenerationIndexMagic));
    MTWriteLittleEndian32(bytes + 8, (uint32_t)MTGenerationIndexFormatVersion);
    MTWriteLittleEndian32(bytes + 12,
                          (uint32_t)MTGenerationIndexHeaderByteCount);
    MTWriteLittleEndian64(bytes + 16, totalByteCount);
    MTWriteLittleEndian64(bytes + 24, validated.count);
    MTWriteLittleEndian32(bytes + 32, MTGenerationIndexRecordByteCount);
    MTWriteLittleEndian32(bytes + 36, 0);
    MTWriteLittleEndian64(bytes + 40, MTGenerationIndexHeaderByteCount);
    MTWriteLittleEndian64(bytes + 48, entryByteCount);
    MTWriteLittleEndian64(bytes + 56, stringsOffset);
    MTWriteLittleEndian64(bytes + 64, stringByteCount);
    MTWriteLittleEndian64(bytes + 72, 0);

    uint64_t nextStringOffset = stringsOffset;
    for (NSUInteger index = 0; index < validated.count; index++) {
        NSDictionary *item = validated[index];
        MTGenerationIndexRecord *record = item[@"record"];
        NSData *keyData = item[@"keyData"];
        uint8_t *entry = bytes + MTGenerationIndexHeaderByteCount +
            index * MTGenerationIndexRecordByteCount;
        MTWriteLittleEndian64(entry, nextStringOffset);
        MTWriteLittleEndian32(entry + 8, (uint32_t)keyData.length);
        MTWriteLittleEndian32(entry + 12, 0);
        NSData *digestData = MTDigestBytes(record.contentSHA256);
        memcpy(entry + 16, digestData.bytes, digestData.length);
        MTWriteLittleEndian64(entry + 48, record.assetByteCount);
        MTWriteLittleEndian64(entry + 56, 0);
        memcpy(bytes + nextStringOffset, keyData.bytes, keyData.length);
        nextStringOffset += keyData.length;
    }
    return [output copy];
}

- (instancetype)initWithEncodedData:(NSData *)encodedData
                               error:(NSError **)error {
    if (![encodedData isKindOfClass:NSData.class] ||
        encodedData.length < MTGenerationIndexHeaderByteCount ||
        encodedData.length > MTGenerationIndexMaximumByteCount) {
        MTGenerationIndexSetError(error, MTGenerationIndexErrorMalformedData,
                                  @"Generation index size is invalid.");
        return nil;
    }
    const uint8_t *bytes = encodedData.bytes;
    if (memcmp(bytes, MTGenerationIndexMagic,
               sizeof(MTGenerationIndexMagic)) != 0) {
        MTGenerationIndexSetError(error, MTGenerationIndexErrorMalformedData,
                                  @"Generation index magic is invalid.");
        return nil;
    }
    uint32_t version = MTReadLittleEndian32(bytes + 8);
    if (version != MTGenerationIndexFormatVersion) {
        MTGenerationIndexSetError(error,
                                  MTGenerationIndexErrorUnsupportedVersion,
                                  @"Generation index version is unsupported.");
        return nil;
    }

    uint32_t headerByteCount = MTReadLittleEndian32(bytes + 12);
    uint64_t totalByteCount = MTReadLittleEndian64(bytes + 16);
    uint64_t recordCount = MTReadLittleEndian64(bytes + 24);
    uint32_t recordByteCount = MTReadLittleEndian32(bytes + 32);
    uint32_t flags = MTReadLittleEndian32(bytes + 36);
    uint64_t recordsOffset = MTReadLittleEndian64(bytes + 40);
    uint64_t recordsByteCount = MTReadLittleEndian64(bytes + 48);
    uint64_t stringsOffset = MTReadLittleEndian64(bytes + 56);
    uint64_t stringsByteCount = MTReadLittleEndian64(bytes + 64);
    uint64_t reserved = MTReadLittleEndian64(bytes + 72);
    uint64_t expectedRecordsByteCount = 0;
    uint64_t expectedStringsOffset = 0;
    uint64_t expectedTotalByteCount = 0;
    BOOL headerValid =
        headerByteCount == MTGenerationIndexHeaderByteCount &&
        totalByteCount == encodedData.length &&
        recordCount <= MTGenerationIndexMaximumRecordCount &&
        recordCount <= NSUIntegerMax &&
        recordByteCount == MTGenerationIndexRecordByteCount &&
        flags == 0 && reserved == 0 &&
        recordsOffset == MTGenerationIndexHeaderByteCount &&
        MTMultiplyUnsigned64(recordCount, recordByteCount,
                             &expectedRecordsByteCount) &&
        recordsByteCount == expectedRecordsByteCount &&
        MTAddUnsigned64(recordsOffset, recordsByteCount,
                        &expectedStringsOffset) &&
        stringsOffset == expectedStringsOffset &&
        MTAddUnsigned64(stringsOffset, stringsByteCount,
                        &expectedTotalByteCount) &&
        expectedTotalByteCount == totalByteCount;
    if (!headerValid) {
        MTGenerationIndexSetError(error, MTGenerationIndexErrorMalformedData,
                                  @"Generation index header is inconsistent.");
        return nil;
    }

    NSData *previousKey = nil;
    uint64_t expectedKeyOffset = stringsOffset;
    for (uint64_t index = 0; index < recordCount; index++) {
        const uint8_t *entry = bytes + recordsOffset +
            index * MTGenerationIndexRecordByteCount;
        uint64_t keyOffset = MTReadLittleEndian64(entry);
        uint32_t keyLength = MTReadLittleEndian32(entry + 8);
        uint32_t entryFlags = MTReadLittleEndian32(entry + 12);
        uint64_t assetByteCount = MTReadLittleEndian64(entry + 48);
        uint64_t entryReserved = MTReadLittleEndian64(entry + 56);
        uint64_t keyEnd = 0;
        if (keyOffset != expectedKeyOffset || keyLength == 0 ||
            keyLength > MTGenerationIndexMaximumKeyByteCount ||
            entryFlags != 0 || entryReserved != 0 || assetByteCount == 0 ||
            !MTAddUnsigned64(keyOffset, keyLength, &keyEnd) ||
            keyOffset < stringsOffset || keyEnd > totalByteCount) {
            MTGenerationIndexSetError(error,
                MTGenerationIndexErrorMalformedData,
                @"Generation index record layout is invalid.");
            return nil;
        }
        NSData *keyData = [NSData dataWithBytes:bytes + keyOffset
                                         length:keyLength];
        if (!MTCanonicalResourceKeyDataIsValid(keyData, NULL) ||
            (previousKey != nil &&
             MTCompareBytes(previousKey, keyData) != NSOrderedAscending)) {
            MTGenerationIndexSetError(error,
                MTGenerationIndexErrorMalformedData,
                @"Generation index resource keys are invalid or unsorted.");
            return nil;
        }
        previousKey = keyData;
        expectedKeyOffset = keyEnd;
    }
    if (expectedKeyOffset != totalByteCount) {
        MTGenerationIndexSetError(error, MTGenerationIndexErrorMalformedData,
                                  @"Generation index string table is not minimal.");
        return nil;
    }

    self = [super init];
    if (self == nil) return nil;
    _encodedData = [encodedData copy];
    _recordCount = (NSUInteger)recordCount;
    return self;
}

- (MTGenerationIndexRecord *)recordAtIndex:(NSUInteger)index {
    if (index >= self.recordCount) return nil;
    const uint8_t *bytes = self.encodedData.bytes;
    const uint8_t *entry = bytes + MTGenerationIndexHeaderByteCount +
        index * MTGenerationIndexRecordByteCount;
    uint64_t keyOffset = MTReadLittleEndian64(entry);
    uint32_t keyLength = MTReadLittleEndian32(entry + 8);
    NSData *keyData = [NSData dataWithBytes:bytes + keyOffset length:keyLength];
    NSString *key = nil;
    if (!MTCanonicalResourceKeyDataIsValid(keyData, &key)) return nil;
    NSString *digest = MTHexString(entry + 16, 32);
    uint64_t assetByteCount = MTReadLittleEndian64(entry + 48);
    return [[MTGenerationIndexRecord alloc]
        initWithCanonicalResourceKey:key
                       contentSHA256:digest
                       assetByteCount:assetByteCount
                                error:NULL];
}

- (MTGenerationIndexRecord *)recordForCanonicalResourceKey:
    (NSString *)canonicalResourceKey
                                                      error:(NSError **)error {
    NSData *query = MTCanonicalResourceKeyData(canonicalResourceKey, error);
    if (query == nil) return nil;
    NSUInteger lower = 0;
    NSUInteger upper = self.recordCount;
    const uint8_t *bytes = self.encodedData.bytes;
    while (lower < upper) {
        NSUInteger middle = lower + (upper - lower) / 2;
        const uint8_t *entry = bytes + MTGenerationIndexHeaderByteCount +
            middle * MTGenerationIndexRecordByteCount;
        uint64_t keyOffset = MTReadLittleEndian64(entry);
        uint32_t keyLength = MTReadLittleEndian32(entry + 8);
        NSData *candidate = [NSData dataWithBytes:bytes + keyOffset
                                           length:keyLength];
        NSComparisonResult comparison = MTCompareBytes(candidate, query);
        if (comparison == NSOrderedAscending) {
            lower = middle + 1;
        } else if (comparison == NSOrderedDescending) {
            upper = middle;
        } else {
            return [self recordAtIndex:middle];
        }
    }
    return nil;
}

@end
