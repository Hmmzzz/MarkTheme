#import "MTDigest.h"

#import <CommonCrypto/CommonDigest.h>
#import <errno.h>
#import <unistd.h>

NSString *const MTDigestErrorDomain = @"com.hmmzzz.marktheme64e.digest";

static NSString *MTHexString(const unsigned char *bytes, NSUInteger length) {
    static const char digits[] = "0123456789abcdef";
    char output[CC_SHA256_DIGEST_LENGTH * 2 + 1] = {0};
    NSCAssert(length <= CC_SHA256_DIGEST_LENGTH, @"Digest buffer is too small");
    for (NSUInteger index = 0; index < length; index++) {
        output[index * 2] = digits[(bytes[index] >> 4) & 0x0f];
        output[index * 2 + 1] = digits[bytes[index] & 0x0f];
    }
    return [NSString stringWithUTF8String:output];
}

NSString *MTSHA256HexDigestForData(NSData *data) {
    CC_SHA256_CTX context;
    CC_SHA256_Init(&context);
    const unsigned char *bytes = data.bytes;
    NSUInteger offset = 0;
    while (offset < data.length) {
        NSUInteger count = MIN((NSUInteger)(64 * 1024), data.length - offset);
        CC_SHA256_Update(&context, bytes + offset, (CC_LONG)count);
        offset += count;
    }
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &context);
    return MTHexString(digest, sizeof(digest));
}

NSString *MTSHA256HexDigestForFileDescriptor(int fileDescriptor,
                                             uint64_t maximumBytes,
                                             uint64_t *bytesRead,
                                             NSError **error) {
    if (fileDescriptor < 0 || maximumBytes == 0) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:MTDigestErrorDomain
                                         code:1
                                     userInfo:@{
                NSLocalizedDescriptionKey : @"Digest input is invalid."
            }];
        }
        return nil;
    }
    if (lseek(fileDescriptor, 0, SEEK_SET) < 0) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                         code:errno
                                     userInfo:nil];
        }
        return nil;
    }

    CC_SHA256_CTX context;
    CC_SHA256_Init(&context);
    unsigned char buffer[64 * 1024];
    uint64_t total = 0;
    while (YES) {
        ssize_t count = read(fileDescriptor, buffer, sizeof(buffer));
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) {
            if (error != NULL) {
                *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                             code:errno
                                         userInfo:nil];
            }
            return nil;
        }
        if (count == 0) break;
        if ((uint64_t)count > maximumBytes - total) {
            if (error != NULL) {
                *error = [NSError errorWithDomain:MTDigestErrorDomain
                                             code:2
                                         userInfo:@{
                    NSLocalizedDescriptionKey :
                        @"File exceeds the digest byte limit."
                }];
            }
            return nil;
        }
        total += (uint64_t)count;
        CC_SHA256_Update(&context, buffer, (CC_LONG)count);
    }
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &context);
    if (bytesRead != NULL) *bytesRead = total;
    return MTHexString(digest, sizeof(digest));
}

BOOL MTStringIsLowercaseSHA256Digest(NSString *value) {
    if (![value isKindOfClass:NSString.class] || value.length != 64) return NO;
    for (NSUInteger index = 0; index < value.length; index++) {
        unichar character = [value characterAtIndex:index];
        if (!((character >= '0' && character <= '9') ||
              (character >= 'a' && character <= 'f'))) {
            return NO;
        }
    }
    return YES;
}
