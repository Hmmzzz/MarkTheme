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
enum {
    MTGenerationIndexMaximumKeyByteCount = 2048,
    MTGenerationIndexMaximumIdentifierByteCount = 128,
    MTGenerationIndexMaximumSubjectByteCount = 255,
};

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

static BOOL MTParseKeyComponentRange(const uint8_t *bytes,
                                     NSUInteger length,
                                     NSUInteger *cursor,
                                     BOOL expectsSeparator,
                                     const uint8_t **componentBytes,
                                     NSUInteger *componentLength) {
    uint64_t parsedLength = 0;
    if (!MTParseLength(bytes, length, cursor, &parsedLength) ||
        parsedLength == 0 ||
        parsedLength > MTGenerationIndexMaximumKeyByteCount ||
        parsedLength > (uint64_t)(length - *cursor)) {
        return NO;
    }
    NSUInteger safeLength = (NSUInteger)parsedLength;
    const uint8_t *start = bytes + *cursor;
    *cursor += safeLength;
    if (expectsSeparator) {
        if (*cursor >= length || bytes[*cursor] != '|') return NO;
        (*cursor)++;
    } else if (*cursor != length) {
        return NO;
    }
    *componentBytes = start;
    *componentLength = safeLength;
    return YES;
}

static BOOL MTIdentifierBytesAreCanonical(const uint8_t *bytes,
                                          NSUInteger length) {
    if (length == 0 ||
        length > MTGenerationIndexMaximumIdentifierByteCount) {
        return NO;
    }
    BOOL previousWasSeparator = NO;
    for (NSUInteger index = 0; index < length; index++) {
        uint8_t character = bytes[index];
        BOOL alphanumeric =
            (character >= 'a' && character <= 'z') ||
            (character >= '0' && character <= '9');
        if (alphanumeric) {
            previousWasSeparator = NO;
            continue;
        }
        BOOL separator =
            character == '.' || character == '-' || character == '_';
        if (!separator || previousWasSeparator || index == 0 ||
            index + 1 == length) {
            return NO;
        }
        previousWasSeparator = YES;
    }
    return YES;
}

static BOOL MTSubjectBytesAreCanonical(const uint8_t *bytes,
                                       NSUInteger length) {
    if (length == 0 || length > MTGenerationIndexMaximumSubjectByteCount) {
        return NO;
    }
    BOOL containsNonASCII = NO;
    for (NSUInteger index = 0; index < length; index++) {
        uint8_t character = bytes[index];
        if (character >= 0x80) {
            containsNonASCII = YES;
        } else if (character == 0 || character == '/' ||
                   character == '\\' || character < 0x20 ||
                   character == 0x7f) {
            return NO;
        }
    }
    if (!containsNonASCII) return YES;

    NSString *subject = [[NSString alloc]
        initWithBytes:bytes length:length encoding:NSUTF8StringEncoding];
    if (subject == nil ||
        ![subject isEqualToString:
            [subject precomposedStringWithCanonicalMapping]]) {
        return NO;
    }
    for (NSUInteger index = 0; index < subject.length; index++) {
        unichar character = [subject characterAtIndex:index];
        if (character == 0 || character == '/' || character == '\\' ||
            character < 0x20 || character == 0x7f) {
            return NO;
        }
    }
    NSUInteger encodedLength =
        [subject lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    if (encodedLength != length) return NO;
    uint8_t encoded[MTGenerationIndexMaximumSubjectByteCount];
    NSUInteger usedLength = 0;
    BOOL encodedExactly = [subject
        getBytes:encoded
        maxLength:sizeof(encoded)
        usedLength:&usedLength
        encoding:NSUTF8StringEncoding
        options:0
        range:NSMakeRange(0, subject.length)
        remainingRange:NULL];
    return encodedExactly && usedLength == length &&
        memcmp(encoded, bytes, length) == 0;
}

static BOOL MTCanonicalResourceKeyBytesAreValid(const uint8_t *bytes,
                                                NSUInteger length) {
    if (bytes == NULL || length == 0 ||
        length > MTGenerationIndexMaximumKeyByteCount) {
        return NO;
    }
    static const uint8_t prefix[] = {'m', 't', 'k', '1', '|'};
    if (length <= sizeof(prefix) ||
        memcmp(bytes, prefix, sizeof(prefix)) != 0) {
        return NO;
    }

    const uint8_t *moduleID = NULL;
    const uint8_t *surface = NULL;
    const uint8_t *subject = NULL;
    const uint8_t *variant = NULL;
    const uint8_t *trait = NULL;
    NSUInteger moduleIDLength = 0;
    NSUInteger surfaceLength = 0;
    NSUInteger subjectLength = 0;
    NSUInteger variantLength = 0;
    NSUInteger traitLength = 0;
    NSUInteger cursor = sizeof(prefix);
    if (!MTParseKeyComponentRange(bytes, length, &cursor, YES,
            &moduleID, &moduleIDLength) ||
        !MTParseKeyComponentRange(bytes, length, &cursor, YES,
            &surface, &surfaceLength) ||
        !MTParseKeyComponentRange(bytes, length, &cursor, YES,
            &subject, &subjectLength) ||
        !MTParseKeyComponentRange(bytes, length, &cursor, YES,
            &variant, &variantLength) ||
        cursor >= length || bytes[cursor] < '0' || bytes[cursor] > '3') {
        return NO;
    }
    cursor++;
    if (cursor >= length || bytes[cursor] != '|') return NO;
    cursor++;
    if (!MTParseKeyComponentRange(bytes, length, &cursor, NO,
            &trait, &traitLength)) {
        return NO;
    }
    return MTIdentifierBytesAreCanonical(moduleID, moduleIDLength) &&
        MTIdentifierBytesAreCanonical(surface, surfaceLength) &&
        MTSubjectBytesAreCanonical(subject, subjectLength) &&
        MTIdentifierBytesAreCanonical(variant, variantLength) &&
        MTIdentifierBytesAreCanonical(trait, traitLength);
}

static BOOL MTCanonicalResourceKeyGetBytes(
    NSString *key,
    uint8_t bytes[MTGenerationIndexMaximumKeyByteCount],
    NSUInteger *length,
    NSError **error) {
    if (![key isKindOfClass:NSString.class]) {
        MTGenerationIndexSetError(error, MTGenerationIndexErrorInvalidRecord,
                                  @"Generation resource key must be a string.");
        return NO;
    }
    NSUInteger byteCount =
        [key lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    if (byteCount == 0 ||
        byteCount > MTGenerationIndexMaximumKeyByteCount) {
        MTGenerationIndexSetError(error, MTGenerationIndexErrorInvalidRecord,
                                  @"Generation resource key is not canonical.");
        return NO;
    }
    NSUInteger usedLength = 0;
    NSRange remaining = NSMakeRange(0, 0);
    BOOL encoded = [key
        getBytes:bytes
        maxLength:MTGenerationIndexMaximumKeyByteCount
        usedLength:&usedLength
        encoding:NSUTF8StringEncoding
        options:0
        range:NSMakeRange(0, key.length)
        remainingRange:&remaining];
    if (!encoded || usedLength != byteCount || remaining.length != 0 ||
        !MTCanonicalResourceKeyBytesAreValid(bytes, usedLength)) {
        MTGenerationIndexSetError(error, MTGenerationIndexErrorInvalidRecord,
                                  @"Generation resource key is not canonical.");
        return NO;
    }
    *length = usedLength;
    return YES;
}

static NSData *_Nullable MTCanonicalResourceKeyData(NSString *key,
                                                     NSError **error) {
    uint8_t bytes[MTGenerationIndexMaximumKeyByteCount];
    NSUInteger length = 0;
    if (!MTCanonicalResourceKeyGetBytes(key, bytes, &length, error)) return nil;
    return [NSData dataWithBytes:bytes length:length];
}

static NSComparisonResult MTCompareByteRanges(const uint8_t *left,
                                              NSUInteger leftLength,
                                              const uint8_t *right,
                                              NSUInteger rightLength) {
    NSUInteger commonLength = MIN(leftLength, rightLength);
    int comparison = memcmp(left, right, commonLength);
    if (comparison < 0) return NSOrderedAscending;
    if (comparison > 0) return NSOrderedDescending;
    if (leftLength < rightLength) return NSOrderedAscending;
    if (leftLength > rightLength) return NSOrderedDescending;
    return NSOrderedSame;
}

static NSComparisonResult MTCompareBytes(NSData *left, NSData *right) {
    return MTCompareByteRanges(left.bytes, left.length,
                               right.bytes, right.length);
}

@interface MTGenerationIndexRecord ()
- (instancetype)initWithValidatedCanonicalResourceKey:
    (NSString *)canonicalResourceKey
                                contentSHA256:(NSString *)contentSHA256
                                assetByteCount:(uint64_t)assetByteCount
    NS_DESIGNATED_INITIALIZER;
@end

@implementation MTGenerationIndexRecord

- (instancetype)initWithCanonicalResourceKey:(NSString *)canonicalResourceKey
                                contentSHA256:(NSString *)contentSHA256
                                assetByteCount:(uint64_t)assetByteCount
                                         error:(NSError **)error {
    uint8_t keyBytes[MTGenerationIndexMaximumKeyByteCount];
    NSUInteger keyLength = 0;
    if (!MTCanonicalResourceKeyGetBytes(
            canonicalResourceKey, keyBytes, &keyLength, error) ||
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

- (instancetype)initWithValidatedCanonicalResourceKey:
    (NSString *)canonicalResourceKey
                                contentSHA256:(NSString *)contentSHA256
                                assetByteCount:(uint64_t)assetByteCount {
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

    const uint8_t *previousKey = NULL;
    NSUInteger previousKeyLength = 0;
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
        const uint8_t *keyBytes = bytes + keyOffset;
        if (!MTCanonicalResourceKeyBytesAreValid(keyBytes, keyLength) ||
            (previousKey != NULL &&
             MTCompareByteRanges(previousKey, previousKeyLength,
                                 keyBytes, keyLength) != NSOrderedAscending)) {
            MTGenerationIndexSetError(error,
                MTGenerationIndexErrorMalformedData,
                @"Generation index resource keys are invalid or unsorted.");
            return nil;
        }
        previousKey = keyBytes;
        previousKeyLength = keyLength;
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
    NSString *key = [[NSString alloc]
        initWithBytes:bytes + keyOffset
               length:keyLength
             encoding:NSUTF8StringEncoding];
    if (key == nil) return nil;
    NSString *digest = MTHexString(entry + 16, 32);
    uint64_t assetByteCount = MTReadLittleEndian64(entry + 48);
    return [[MTGenerationIndexRecord alloc]
        initWithValidatedCanonicalResourceKey:key
        contentSHA256:digest
        assetByteCount:assetByteCount];
}

- (MTGenerationIndexRecord *)recordForCanonicalResourceKey:
    (NSString *)canonicalResourceKey
                                                      error:(NSError **)error {
    uint8_t query[MTGenerationIndexMaximumKeyByteCount];
    NSUInteger queryLength = 0;
    if (!MTCanonicalResourceKeyGetBytes(
            canonicalResourceKey, query, &queryLength, error)) {
        return nil;
    }
    NSUInteger lower = 0;
    NSUInteger upper = self.recordCount;
    const uint8_t *bytes = self.encodedData.bytes;
    while (lower < upper) {
        NSUInteger middle = lower + (upper - lower) / 2;
        const uint8_t *entry = bytes + MTGenerationIndexHeaderByteCount +
            middle * MTGenerationIndexRecordByteCount;
        uint64_t keyOffset = MTReadLittleEndian64(entry);
        uint32_t keyLength = MTReadLittleEndian32(entry + 8);
        NSComparisonResult comparison = MTCompareByteRanges(
            bytes + keyOffset, keyLength, query, queryLength);
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
