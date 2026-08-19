#import "MTAuditedZIPEntryStreamer.h"

#import <CommonCrypto/CommonDigest.h>
#import <errno.h>
#import <unistd.h>
#import <zlib.h>

#import "MTImportSession.h"

static void MTAuditedZIPSetError(
    NSError **error,
    MTAuditedSourceErrorCode code,
    NSString *description,
    NSString *_Nullable relativePath,
    NSError *_Nullable underlyingError) {
    if (error == NULL) return;
    NSMutableDictionary *userInfo = [NSMutableDictionary
        dictionaryWithObject:description forKey:NSLocalizedDescriptionKey];
    if (relativePath.length > 0) {
        userInfo[@"relativePath"] = relativePath;
    }
    if (underlyingError != nil) {
        userInfo[NSUnderlyingErrorKey] = underlyingError;
    }
    *error = [NSError errorWithDomain:MTAuditedSourceErrorDomain
                                 code:code
                             userInfo:userInfo];
}

static NSError *MTAuditedZIPPOSIXError(int code) {
    return [NSError errorWithDomain:NSPOSIXErrorDomain
                               code:code
                           userInfo:nil];
}

static NSString *MTAuditedZIPHexDigest(const unsigned char *digest) {
    static const char digits[] = "0123456789abcdef";
    char output[CC_SHA256_DIGEST_LENGTH * 2 + 1] = {0};
    for (NSUInteger index = 0; index < CC_SHA256_DIGEST_LENGTH; index++) {
        output[index * 2] = digits[(digest[index] >> 4) & 0x0f];
        output[index * 2 + 1] = digits[digest[index] & 0x0f];
    }
    return [NSString stringWithUTF8String:output];
}

static BOOL MTAuditedZIPReadExactly(int descriptor,
                                    void *buffer,
                                    size_t length,
                                    uint64_t offset,
                                    NSString *relativePath,
                                    NSError **error) {
    unsigned char *cursor = buffer;
    size_t remaining = length;
    while (remaining > 0) {
        ssize_t count = pread(descriptor, cursor, remaining, (off_t)offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) {
            MTAuditedZIPSetError(error,
                count == 0 ? MTAuditedSourceErrorCorruptSource
                           : MTAuditedSourceErrorIO,
                count == 0
                    ? @"The audited ZIP entry ended before its planned boundary."
                    : @"The audited ZIP entry could not be read.",
                relativePath,
                count == 0 ? nil : MTAuditedZIPPOSIXError(errno));
            return NO;
        }
        cursor += (size_t)count;
        remaining -= (size_t)count;
        offset += (uint64_t)count;
    }
    return YES;
}

static BOOL MTAuditedZIPConsume(
    const void *bytes,
    NSUInteger length,
    uint64_t expandedByteCount,
    uint64_t maximumByteCount,
    uint64_t *actualByteCount,
    uLong *checksum,
    CC_SHA256_CTX *digestContext,
    MTAuditedSourceByteConsumer byteConsumer,
    NSString *relativePath,
    NSError **error) {
    if (*actualByteCount > expandedByteCount ||
        length > expandedByteCount - *actualByteCount ||
        *actualByteCount > maximumByteCount ||
        length > maximumByteCount - *actualByteCount) {
        MTAuditedZIPSetError(error,
            MTAuditedSourceErrorLimitExceeded,
            @"Decoded ZIP data exceeded its audited read limit.",
            relativePath, nil);
        return NO;
    }
    NSError *consumerError = nil;
    if (!byteConsumer(bytes, length, &consumerError)) {
        if (consumerError != nil && error != NULL) {
            *error = consumerError;
        } else {
            MTAuditedZIPSetError(error, MTAuditedSourceErrorIO,
                @"The byte consumer rejected audited ZIP data.",
                relativePath, nil);
        }
        return NO;
    }
    *checksum = crc32(*checksum, bytes, (uInt)length);
    CC_SHA256_Update(digestContext, bytes, (CC_LONG)length);
    *actualByteCount += length;
    return YES;
}

static BOOL MTAuditedZIPStreamStored(
    int descriptor,
    NSString *relativePath,
    uint64_t compressedByteCount,
    uint64_t expandedByteCount,
    uint64_t compressedDataOffset,
    uint64_t maximumByteCount,
    MTImportCancellationToken *_Nullable cancellationToken,
    MTAuditedSourceByteConsumer byteConsumer,
    CC_SHA256_CTX *digestContext,
    uLong *checksum,
    uint64_t *actualByteCount,
    NSError **error) {
    uint64_t remaining = compressedByteCount;
    uint64_t offset = compressedDataOffset;
    unsigned char buffer[64 * 1024];
    while (remaining > 0) {
        if (cancellationToken.isCancelled) {
            MTAuditedZIPSetError(error, MTAuditedSourceErrorCancelled,
                @"The audited source stream was cancelled while reading stored data.",
                relativePath, nil);
            return NO;
        }
        size_t count = (size_t)MIN(remaining, (uint64_t)sizeof(buffer));
        if (!MTAuditedZIPReadExactly(descriptor, buffer, count, offset,
                relativePath, error) ||
            !MTAuditedZIPConsume(buffer, count, expandedByteCount,
                maximumByteCount, actualByteCount, checksum, digestContext,
                byteConsumer, relativePath, error)) {
            return NO;
        }
        offset += count;
        remaining -= count;
    }
    return YES;
}

static BOOL MTAuditedZIPStreamDeflated(
    int descriptor,
    NSString *relativePath,
    uint64_t compressedByteCount,
    uint64_t expandedByteCount,
    uint64_t compressedDataOffset,
    uint64_t maximumByteCount,
    MTImportCancellationToken *_Nullable cancellationToken,
    MTAuditedSourceByteConsumer byteConsumer,
    CC_SHA256_CTX *digestContext,
    uLong *checksum,
    uint64_t *actualByteCount,
    NSError **error) {
    z_stream stream = {0};
    if (inflateInit2(&stream, -MAX_WBITS) != Z_OK) {
        MTAuditedZIPSetError(error, MTAuditedSourceErrorIO,
            @"The audited ZIP inflater could not be initialized.",
            relativePath, nil);
        return NO;
    }

    unsigned char input[64 * 1024];
    unsigned char output[64 * 1024];
    uint64_t compressedRemaining = compressedByteCount;
    uint64_t compressedOffset = compressedDataOffset;
    BOOL success = YES;
    BOOL reachedEnd = NO;
    while (success && !reachedEnd) {
        if (cancellationToken.isCancelled) {
            MTAuditedZIPSetError(error, MTAuditedSourceErrorCancelled,
                @"The audited source stream was cancelled while inflating data.",
                relativePath, nil);
            success = NO;
            break;
        }
        if (stream.avail_in == 0 && compressedRemaining > 0) {
            size_t inputCount = (size_t)MIN(
                compressedRemaining, (uint64_t)sizeof(input));
            if (!MTAuditedZIPReadExactly(descriptor, input, inputCount,
                    compressedOffset, relativePath, error)) {
                success = NO;
                break;
            }
            stream.next_in = input;
            stream.avail_in = (uInt)inputCount;
            compressedOffset += inputCount;
            compressedRemaining -= inputCount;
        }
        stream.next_out = output;
        stream.avail_out = (uInt)sizeof(output);
        uLong priorInput = stream.total_in;
        uLong priorOutput = stream.total_out;
        int status = inflate(&stream, Z_NO_FLUSH);
        NSUInteger produced = sizeof(output) - stream.avail_out;
        if (produced > 0 &&
            !MTAuditedZIPConsume(output, produced, expandedByteCount,
                maximumByteCount, actualByteCount, checksum, digestContext,
                byteConsumer, relativePath, error)) {
            success = NO;
            break;
        }
        if (status == Z_STREAM_END) {
            reachedEnd = YES;
            break;
        }
        if (status != Z_OK ||
            (stream.total_in == priorInput &&
             stream.total_out == priorOutput)) {
            MTAuditedZIPSetError(error,
                MTAuditedSourceErrorCorruptSource,
                @"The audited deflate stream is corrupt, truncated, or stalled.",
                relativePath, nil);
            success = NO;
            break;
        }
    }
    if (success &&
        (!reachedEnd || compressedRemaining != 0 || stream.avail_in != 0 ||
         stream.total_in != compressedByteCount ||
         stream.total_out != expandedByteCount)) {
        MTAuditedZIPSetError(error,
            MTAuditedSourceErrorCorruptSource,
            @"The audited deflate stream did not end at its exact planned boundary.",
            relativePath, nil);
        success = NO;
    }
    int endStatus = inflateEnd(&stream);
    if (success && endStatus != Z_OK) {
        MTAuditedZIPSetError(error, MTAuditedSourceErrorIO,
            @"The audited ZIP inflater could not release its state.",
            relativePath, nil);
        success = NO;
    }
    return success;
}

BOOL MTAuditedZIPStreamEntry(
    int descriptor,
    NSString *relativePath,
    MTAuditedZIPCompressionMethod compressionMethod,
    uint32_t expectedCRC32,
    uint64_t compressedByteCount,
    uint64_t expandedByteCount,
    uint64_t compressedDataOffset,
    NSString *expectedSHA256,
    uint64_t maximumByteCount,
    MTImportCancellationToken *_Nullable cancellationToken,
    MTAuditedSourceByteConsumer byteConsumer,
    NSError **error) {
    if (descriptor < 0 || relativePath.length == 0 ||
        expectedSHA256.length != CC_SHA256_DIGEST_LENGTH * 2 ||
        byteConsumer == nil || expandedByteCount > maximumByteCount ||
        compressedDataOffset > UINT64_MAX - compressedByteCount ||
        (compressionMethod != MTAuditedZIPCompressionMethodStored &&
         compressionMethod != MTAuditedZIPCompressionMethodDeflate) ||
        (compressionMethod == MTAuditedZIPCompressionMethodStored &&
         compressedByteCount != expandedByteCount)) {
        MTAuditedZIPSetError(error, MTAuditedSourceErrorCorruptSource,
            @"The audited ZIP entry plan is invalid.",
            relativePath, nil);
        return NO;
    }
    if (cancellationToken.isCancelled) {
        MTAuditedZIPSetError(error, MTAuditedSourceErrorCancelled,
            @"The audited source stream was cancelled before reading its entry.",
            relativePath, nil);
        return NO;
    }

    CC_SHA256_CTX digestContext;
    CC_SHA256_Init(&digestContext);
    uLong checksum = crc32(0L, Z_NULL, 0);
    uint64_t actualByteCount = 0;
    BOOL success =
        compressionMethod == MTAuditedZIPCompressionMethodStored
        ? MTAuditedZIPStreamStored(descriptor, relativePath,
            compressedByteCount, expandedByteCount, compressedDataOffset,
            maximumByteCount, cancellationToken, byteConsumer,
            &digestContext, &checksum, &actualByteCount, error)
        : MTAuditedZIPStreamDeflated(descriptor, relativePath,
            compressedByteCount, expandedByteCount, compressedDataOffset,
            maximumByteCount, cancellationToken, byteConsumer,
            &digestContext, &checksum, &actualByteCount, error);
    if (!success) return NO;
    if (actualByteCount != expandedByteCount ||
        (uint32_t)checksum != expectedCRC32) {
        MTAuditedZIPSetError(error,
            MTAuditedSourceErrorCorruptSource,
            @"The audited ZIP entry no longer matches its size or CRC.",
            relativePath, nil);
        return NO;
    }
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &digestContext);
    if (![MTAuditedZIPHexDigest(digest)
            isEqualToString:expectedSHA256]) {
        MTAuditedZIPSetError(error,
            MTAuditedSourceErrorSourceChanged,
            @"Decoded ZIP data no longer matches its inventory digest.",
            relativePath, nil);
        return NO;
    }
    return YES;
}
