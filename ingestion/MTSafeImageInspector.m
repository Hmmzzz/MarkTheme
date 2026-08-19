#import "MTSafeImageValidationInternal.h"

#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <errno.h>
#import <fcntl.h>
#import <stdatomic.h>
#import <string.h>
#import <sys/stat.h>
#import <sys/types.h>
#import <unistd.h>
#import <zlib.h>

#import "MTImportSession.h"

NSString *const MTSafeImageInspectorErrorDomain =
    @"com.hmmzzz.marktheme.safe-image-inspector";

static const uint8_t MTPNGSignature[8] = {
    0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a,
};
enum { MTImageReadBufferSize = 32 * 1024 };

typedef struct {
    uint32_t width;
    uint32_t height;
    uint8_t bitDepth;
    uint8_t colorType;
    BOOL interlaced;
    BOOL hasTransparencyChunk;
    uint64_t pixelCount;
    uint64_t decodedByteEstimate;
} MTPNGPreflightInfo;

typedef struct {
    int descriptor;
    off_t byteCount;
    struct stat baseline;
    __unsafe_unretained MTImportCancellationToken *cancellationToken;
    atomic_bool sourceChanged;
    atomic_bool cancelled;
    atomic_int ioError;
} MTImageDataProviderInfo;

@interface MTSafeImageInspection ()

- (instancetype)initWithTypeIdentifier:(NSString *)typeIdentifier
                       encodedByteCount:(uint64_t)encodedByteCount
                             pixelWidth:(uint32_t)pixelWidth
                            pixelHeight:(uint32_t)pixelHeight
                             pixelCount:(uint64_t)pixelCount
                    decodedByteEstimate:(uint64_t)decodedByteEstimate
                             frameCount:(NSUInteger)frameCount
                               hasAlpha:(BOOL)hasAlpha
                            orientation:(NSUInteger)orientation
                               bitDepth:(uint8_t)bitDepth
                              colorType:(uint8_t)colorType
                             interlaced:(BOOL)interlaced;

@end

@implementation MTSafeImageLimits

+ (instancetype)defaultLimits {
    return [[self alloc]
        initWithMaximumEncodedBytes:32ULL * 1024ULL * 1024ULL
             maximumDimensionPixels:16384
                  maximumPixelCount:64ULL * 1024ULL * 1024ULL
                maximumDecodedBytes:256ULL * 1024ULL * 1024ULL
                   maximumChunkCount:4096
              maximumAncillaryBytes:4ULL * 1024ULL * 1024ULL];
}

- (instancetype)initWithMaximumEncodedBytes:(uint64_t)maximumEncodedBytes
                     maximumDimensionPixels:(uint32_t)maximumDimensionPixels
                          maximumPixelCount:(uint64_t)maximumPixelCount
                        maximumDecodedBytes:(uint64_t)maximumDecodedBytes
                           maximumChunkCount:(NSUInteger)maximumChunkCount
                      maximumAncillaryBytes:(uint64_t)maximumAncillaryBytes {
    NSParameterAssert(maximumEncodedBytes > 0);
    NSParameterAssert(maximumDimensionPixels > 0);
    NSParameterAssert(maximumPixelCount > 0);
    NSParameterAssert(maximumPixelCount <= UINT64_MAX / 4ULL);
    NSParameterAssert(maximumDecodedBytes > 0);
    NSParameterAssert(maximumChunkCount > 0);
    NSParameterAssert(maximumAncillaryBytes > 0);
    self = [super init];
    if (self == nil) return nil;
    _maximumEncodedBytes = maximumEncodedBytes;
    _maximumDimensionPixels = maximumDimensionPixels;
    _maximumPixelCount = maximumPixelCount;
    _maximumDecodedBytes = maximumDecodedBytes;
    _maximumChunkCount = maximumChunkCount;
    _maximumAncillaryBytes = maximumAncillaryBytes;
    return self;
}

@end

@implementation MTSafeImageInspection

- (instancetype)initWithTypeIdentifier:(NSString *)typeIdentifier
                       encodedByteCount:(uint64_t)encodedByteCount
                             pixelWidth:(uint32_t)pixelWidth
                            pixelHeight:(uint32_t)pixelHeight
                             pixelCount:(uint64_t)pixelCount
                    decodedByteEstimate:(uint64_t)decodedByteEstimate
                             frameCount:(NSUInteger)frameCount
                               hasAlpha:(BOOL)hasAlpha
                            orientation:(NSUInteger)orientation
                               bitDepth:(uint8_t)bitDepth
                              colorType:(uint8_t)colorType
                             interlaced:(BOOL)interlaced {
    self = [super init];
    if (self == nil) return nil;
    _typeIdentifier = [typeIdentifier copy];
    _encodedByteCount = encodedByteCount;
    _pixelWidth = pixelWidth;
    _pixelHeight = pixelHeight;
    _pixelCount = pixelCount;
    _decodedByteEstimate = decodedByteEstimate;
    _frameCount = frameCount;
    _hasAlpha = hasAlpha;
    _orientation = orientation;
    _bitDepth = bitDepth;
    _colorType = colorType;
    _interlaced = interlaced;
    return self;
}

@end

static NSError *MTImagePOSIXError(int value) {
    return [NSError errorWithDomain:NSPOSIXErrorDomain code:value userInfo:nil];
}

static BOOL MTImageSetError(NSError **error,
                            MTSafeImageInspectorErrorCode code,
                            NSString *description,
                            NSError *_Nullable underlying) {
    if (error != NULL) {
        NSMutableDictionary *userInfo = [NSMutableDictionary
            dictionaryWithObject:description forKey:NSLocalizedDescriptionKey];
        if (underlying != nil) userInfo[NSUnderlyingErrorKey] = underlying;
        *error = [NSError errorWithDomain:MTSafeImageInspectorErrorDomain
                                     code:code
                                 userInfo:userInfo];
    }
    return NO;
}

typedef struct {
    uint64_t rowDataBytes;
    uint32_t rowCount;
} MTPNGRasterPass;

@interface MTPNGRasterValidator : NSObject {
    z_stream _stream;
    BOOL _streamInitialized;
    BOOL _streamEnded;
    MTPNGRasterPass _passes[7];
    NSUInteger _passCount;
    NSUInteger _passIndex;
    uint32_t _rowIndex;
    uint64_t _positionInRow;
    uint64_t _expectedBytes;
    uint64_t _producedBytes;
}

- (nullable instancetype)initWithWidth:(uint32_t)width
                                 height:(uint32_t)height
                               bitDepth:(uint8_t)bitDepth
                              colorType:(uint8_t)colorType
                             interlaced:(BOOL)interlaced
                                  error:(NSError **)error;
- (BOOL)consumeCompressedBytes:(const void *)bytes
                        length:(NSUInteger)length
                         error:(NSError **)error;
- (BOOL)finish:(NSError **)error;

@end

static uint32_t MTPNGRasterPassDimension(uint32_t fullDimension,
                                         uint8_t start,
                                         uint8_t step) {
    if (fullDimension <= start) return 0;
    return (fullDimension - start + step - 1U) / step;
}

@implementation MTPNGRasterValidator

- (instancetype)initWithWidth:(uint32_t)width
                         height:(uint32_t)height
                       bitDepth:(uint8_t)bitDepth
                      colorType:(uint8_t)colorType
                     interlaced:(BOOL)interlaced
                          error:(NSError **)error {
    self = [super init];
    if (self == nil) return nil;
    uint8_t channels = colorType == 6 ? 4 :
        (colorType == 4 ? 2 : (colorType == 2 ? 3 : 1));
    uint64_t bitsPerPixel = (uint64_t)channels * bitDepth;
    static const uint8_t xStart[7] = {0, 4, 0, 2, 0, 1, 0};
    static const uint8_t yStart[7] = {0, 0, 4, 0, 2, 0, 1};
    static const uint8_t xStep[7] = {8, 8, 4, 4, 2, 2, 1};
    static const uint8_t yStep[7] = {8, 8, 8, 4, 4, 2, 2};
    NSUInteger candidateCount = interlaced ? 7 : 1;
    for (NSUInteger index = 0; index < candidateCount; index++) {
        uint32_t passWidth = interlaced
            ? MTPNGRasterPassDimension(width, xStart[index], xStep[index])
            : width;
        uint32_t passHeight = interlaced
            ? MTPNGRasterPassDimension(height, yStart[index], yStep[index])
            : height;
        if (passWidth == 0 || passHeight == 0) continue;
        uint64_t rowBits = (uint64_t)passWidth * bitsPerPixel;
        uint64_t rowDataBytes = (rowBits + 7ULL) / 8ULL;
        if (rowDataBytes == 0 ||
            rowDataBytes == UINT64_MAX ||
            (rowDataBytes + 1ULL) >
                (UINT64_MAX - _expectedBytes) / passHeight) {
            MTImageSetError(error, MTSafeImageInspectorErrorLimitExceeded,
                @"The PNG raster byte layout overflows its validation budget.",
                nil);
            return nil;
        }
        _passes[_passCount++] = (MTPNGRasterPass){
            .rowDataBytes = rowDataBytes,
            .rowCount = passHeight,
        };
        _expectedBytes += (rowDataBytes + 1ULL) * passHeight;
    }
    if (_passCount == 0 || _expectedBytes == 0) {
        MTImageSetError(error, MTSafeImageInspectorErrorCorruptPixelData,
            @"The PNG raster has no decodable scanlines.", nil);
        return nil;
    }
    memset(&_stream, 0, sizeof(_stream));
    int result = inflateInit(&_stream);
    if (result != Z_OK) {
        MTImageSetError(error, MTSafeImageInspectorErrorImageIO,
            @"Unable to initialize bounded PNG raster validation.", nil);
        return nil;
    }
    _streamInitialized = YES;
    return self;
}

- (void)dealloc {
    if (_streamInitialized) inflateEnd(&_stream);
}

- (BOOL)consumeInflatedBytes:(const uint8_t *)bytes
                       length:(NSUInteger)length
                        error:(NSError **)error {
    NSUInteger cursor = 0;
    while (cursor < length) {
        if (_producedBytes >= _expectedBytes || _passIndex >= _passCount) {
            return MTImageSetError(error,
                MTSafeImageInspectorErrorCorruptPixelData,
                @"The PNG raster expands beyond its declared scanline layout.",
                nil);
        }
        if (_positionInRow == 0) {
            if (bytes[cursor] > 4) {
                return MTImageSetError(error,
                    MTSafeImageInspectorErrorCorruptPixelData,
                    @"The PNG raster contains an invalid scanline filter.", nil);
            }
            _positionInRow = 1;
            _producedBytes++;
            cursor++;
            continue;
        }

        uint64_t completeRowBytes =
            _passes[_passIndex].rowDataBytes + 1ULL;
        uint64_t rowBytesRemaining = completeRowBytes - _positionInRow;
        NSUInteger available = length - cursor;
        NSUInteger consumed = rowBytesRemaining > available
            ? available : (NSUInteger)rowBytesRemaining;
        _positionInRow += consumed;
        _producedBytes += consumed;
        cursor += consumed;
        if (_positionInRow == completeRowBytes) {
            _positionInRow = 0;
            _rowIndex++;
            if (_rowIndex == _passes[_passIndex].rowCount) {
                _passIndex++;
                _rowIndex = 0;
            }
        }
    }
    return YES;
}

- (BOOL)consumeCompressedBytes:(const void *)bytes
                        length:(NSUInteger)length
                         error:(NSError **)error {
    if (length == 0) return YES;
    if (_streamEnded || length > UINT_MAX) {
        return MTImageSetError(error,
            MTSafeImageInspectorErrorCorruptPixelData,
            @"The PNG contains bytes after its compressed raster stream.", nil);
    }
    _stream.next_in = (Bytef *)bytes;
    _stream.avail_in = (uInt)length;
    uint8_t output[MTImageReadBufferSize];
    while (_stream.avail_in > 0) {
        _stream.next_out = output;
        _stream.avail_out = sizeof(output);
        uInt inputBefore = _stream.avail_in;
        int result = inflate(&_stream, Z_NO_FLUSH);
        NSUInteger produced = sizeof(output) - _stream.avail_out;
        if (produced > 0 &&
            ![self consumeInflatedBytes:output length:produced error:error]) {
            return NO;
        }
        if (result == Z_STREAM_END) {
            _streamEnded = YES;
            if (_stream.avail_in != 0) {
                return MTImageSetError(error,
                    MTSafeImageInspectorErrorCorruptPixelData,
                    @"The PNG has trailing bytes inside its IDAT stream.", nil);
            }
            break;
        }
        if (result != Z_OK ||
            (produced == 0 && _stream.avail_in == inputBefore)) {
            return MTImageSetError(error,
                MTSafeImageInspectorErrorCorruptPixelData,
                @"The PNG IDAT zlib stream is corrupt or stalled.", nil);
        }
    }
    return YES;
}

- (BOOL)finish:(NSError **)error {
    while (!_streamEnded) {
        uint8_t output[MTImageReadBufferSize];
        _stream.next_in = Z_NULL;
        _stream.avail_in = 0;
        _stream.next_out = output;
        _stream.avail_out = sizeof(output);
        int result = inflate(&_stream, Z_FINISH);
        NSUInteger produced = sizeof(output) - _stream.avail_out;
        if (produced > 0 &&
            ![self consumeInflatedBytes:output length:produced error:error]) {
            return NO;
        }
        if (result == Z_STREAM_END) {
            _streamEnded = YES;
            break;
        }
        if ((result != Z_OK && result != Z_BUF_ERROR) || produced == 0) {
            break;
        }
    }
    if (!_streamEnded || _producedBytes != _expectedBytes ||
        _passIndex != _passCount || _rowIndex != 0 || _positionInRow != 0) {
        return MTImageSetError(error,
            MTSafeImageInspectorErrorCorruptPixelData,
            @"The PNG raster does not contain every declared scanline.", nil);
    }
    return YES;
}

@end

static BOOL MTImageStatIsStable(const struct stat *before,
                                const struct stat *after) {
    return before->st_dev == after->st_dev &&
        before->st_ino == after->st_ino &&
        before->st_mode == after->st_mode &&
        before->st_nlink == after->st_nlink &&
        before->st_uid == after->st_uid &&
        before->st_size == after->st_size &&
        before->st_mtimespec.tv_sec == after->st_mtimespec.tv_sec &&
        before->st_mtimespec.tv_nsec == after->st_mtimespec.tv_nsec &&
        before->st_ctimespec.tv_sec == after->st_ctimespec.tv_sec &&
        before->st_ctimespec.tv_nsec == after->st_ctimespec.tv_nsec;
}

static uint32_t MTImageReadBE32(const uint8_t *bytes) {
    return ((uint32_t)bytes[0] << 24) |
        ((uint32_t)bytes[1] << 16) |
        ((uint32_t)bytes[2] << 8) |
        (uint32_t)bytes[3];
}

static BOOL MTImageChunkTypeByteIsASCIIAlpha(uint8_t value) {
    return (value >= 'A' && value <= 'Z') ||
        (value >= 'a' && value <= 'z');
}

static BOOL MTImageReadExactly(
    int descriptor,
    off_t offset,
    void *output,
    size_t byteCount,
    MTImportCancellationToken *_Nullable cancellationToken,
    NSError **error) {
    uint8_t *cursor = output;
    size_t completed = 0;
    while (completed < byteCount) {
        if (cancellationToken.isCancelled) {
            return MTImageSetError(error, MTSafeImageInspectorErrorCancelled,
                @"Image inspection was cancelled.", nil);
        }
        size_t request = MIN(byteCount - completed, MTImageReadBufferSize);
        ssize_t result = pread(descriptor, cursor + completed, request,
                               offset + (off_t)completed);
        if (result < 0 && errno == EINTR) continue;
        if (result < 0) {
            return MTImageSetError(error, MTSafeImageInspectorErrorIO,
                @"Unable to read the image staging file.",
                MTImagePOSIXError(errno));
        }
        if (result == 0) {
            return MTImageSetError(error,
                MTSafeImageInspectorErrorCorruptData,
                @"The PNG data ended before its declared structure.", nil);
        }
        completed += (size_t)result;
    }
    return YES;
}

static BOOL MTImageColorTypeAndDepthAreValid(uint8_t colorType,
                                             uint8_t bitDepth) {
    switch (colorType) {
        case 0:
            return bitDepth == 1 || bitDepth == 2 || bitDepth == 4 ||
                bitDepth == 8 || bitDepth == 16;
        case 2:
        case 4:
        case 6:
            return bitDepth == 8 || bitDepth == 16;
        case 3:
            return bitDepth == 1 || bitDepth == 2 || bitDepth == 4 ||
                bitDepth == 8;
        default:
            return NO;
    }
}

static BOOL MTImageChunkUsesCompressedTextMetadata(uint32_t chunkType) {
    return chunkType == 0x7a545874;  // zTXt
}

static NSUInteger MTImageIndexOfNUL(const uint8_t *bytes,
                                    NSUInteger start,
                                    NSUInteger length) {
    for (NSUInteger index = start; index < length; index++) {
        if (bytes[index] == 0) return index;
    }
    return NSNotFound;
}

static BOOL MTImagePNGKeywordIsValid(const uint8_t *bytes,
                                     NSUInteger length) {
    if (length == 0 || length > 79 || bytes[0] == 0x20 ||
        bytes[length - 1] == 0x20) {
        return NO;
    }
    BOOL priorSpace = NO;
    for (NSUInteger index = 0; index < length; index++) {
        uint8_t byte = bytes[index];
        BOOL admitted = (byte >= 32 && byte <= 126) || byte >= 161;
        if (!admitted || (byte == 0x20 && priorSpace)) return NO;
        priorSpace = byte == 0x20;
    }
    return YES;
}

static BOOL MTImageUTF8FieldIsValid(const uint8_t *bytes,
                                    NSUInteger length) {
    if (length == 0) return YES;
    if (memchr(bytes, 0, length) != NULL) return NO;
    NSData *data = [NSData dataWithBytesNoCopy:(void *)bytes
                                        length:length
                                  freeWhenDone:NO];
    return [[NSString alloc] initWithData:data
                                 encoding:NSUTF8StringEncoding] != nil;
}

static BOOL MTImageValidateInternationalText(NSData *data,
                                             NSError **error) {
    const uint8_t *bytes = data.bytes;
    NSUInteger length = data.length;
    NSUInteger keywordEnd = MTImageIndexOfNUL(bytes, 0, length);
    if (keywordEnd == NSNotFound ||
        !MTImagePNGKeywordIsValid(bytes, keywordEnd) ||
        keywordEnd > length - MIN(length, 5U)) {
        return MTImageSetError(error,
            MTSafeImageInspectorErrorCorruptData,
            @"The PNG international-text metadata is malformed.", nil);
    }
    NSUInteger cursor = keywordEnd + 1;
    uint8_t compressionFlag = bytes[cursor++];
    uint8_t compressionMethod = bytes[cursor++];
    if (compressionFlag > 1 || compressionMethod != 0) {
        return MTImageSetError(error,
            MTSafeImageInspectorErrorCorruptData,
            @"The PNG international-text compression fields are invalid.", nil);
    }
    if (compressionFlag == 1) {
        return MTImageSetError(error,
            MTSafeImageInspectorErrorUnsupportedFormat,
            @"Compressed PNG text metadata is not admitted.", nil);
    }
    NSUInteger languageEnd = MTImageIndexOfNUL(bytes, cursor, length);
    if (languageEnd == NSNotFound) {
        return MTImageSetError(error,
            MTSafeImageInspectorErrorCorruptData,
            @"The PNG international-text language field is malformed.", nil);
    }
    for (NSUInteger index = cursor; index < languageEnd; index++) {
        uint8_t byte = bytes[index];
        BOOL admitted = (byte >= 'A' && byte <= 'Z') ||
            (byte >= 'a' && byte <= 'z') ||
            (byte >= '0' && byte <= '9') || byte == '-';
        if (!admitted) {
            return MTImageSetError(error,
                MTSafeImageInspectorErrorCorruptData,
                @"The PNG international-text language tag is invalid.", nil);
        }
    }
    cursor = languageEnd + 1;
    NSUInteger translatedEnd = MTImageIndexOfNUL(bytes, cursor, length);
    if (translatedEnd == NSNotFound ||
        !MTImageUTF8FieldIsValid(bytes + cursor, translatedEnd - cursor)) {
        return MTImageSetError(error,
            MTSafeImageInspectorErrorCorruptData,
            @"The PNG translated keyword is not valid UTF-8.", nil);
    }
    cursor = translatedEnd + 1;
    if (!MTImageUTF8FieldIsValid(bytes + cursor, length - cursor)) {
        return MTImageSetError(error,
            MTSafeImageInspectorErrorCorruptData,
            @"The PNG international text is not valid UTF-8.", nil);
    }
    return YES;
}

static BOOL MTImageValidateICCProfile(
    NSData *data,
    uint64_t maximumExpandedBytes,
    MTImportCancellationToken *_Nullable cancellationToken,
    NSError **error) {
    const uint8_t *bytes = data.bytes;
    NSUInteger length = data.length;
    NSUInteger nameEnd = MTImageIndexOfNUL(bytes, 0, length);
    if (nameEnd == NSNotFound ||
        !MTImagePNGKeywordIsValid(bytes, nameEnd) ||
        nameEnd > length - MIN(length, 3U) ||
        bytes[nameEnd + 1] != 0) {
        return MTImageSetError(error,
            MTSafeImageInspectorErrorCorruptData,
            @"The PNG ICC profile fields are malformed.", nil);
    }

    NSUInteger compressedOffset = nameEnd + 2;
    if (compressedOffset >= length ||
        length - compressedOffset > UINT_MAX) {
        return MTImageSetError(error,
            MTSafeImageInspectorErrorCorruptData,
            @"The PNG ICC profile payload is malformed.", nil);
    }
    z_stream stream = {0};
    stream.next_in = (Bytef *)(bytes + compressedOffset);
    stream.avail_in = (uInt)(length - compressedOffset);
    if (inflateInit(&stream) != Z_OK) {
        return MTImageSetError(error,
            MTSafeImageInspectorErrorCorruptData,
            @"The PNG ICC profile decompressor could not initialize.", nil);
    }

    BOOL valid = YES;
    BOOL complete = NO;
    uint64_t expandedBytes = 0;
    uint8_t output[MTImageReadBufferSize];
    while (valid && !complete) {
        if (cancellationToken.isCancelled) {
            valid = MTImageSetError(error,
                MTSafeImageInspectorErrorCancelled,
                @"Image inspection was cancelled while validating an ICC profile.",
                nil);
            break;
        }
        stream.next_out = output;
        stream.avail_out = sizeof(output);
        int result = inflate(&stream, Z_NO_FLUSH);
        uint64_t produced = sizeof(output) - stream.avail_out;
        if (produced > maximumExpandedBytes -
                MIN(expandedBytes, maximumExpandedBytes)) {
            valid = MTImageSetError(error,
                MTSafeImageInspectorErrorLimitExceeded,
                @"The expanded PNG ICC profile exceeds the metadata budget.",
                nil);
            break;
        }
        expandedBytes += produced;
        if (result == Z_STREAM_END) {
            complete = stream.avail_in == 0;
            if (!complete) {
                valid = MTImageSetError(error,
                    MTSafeImageInspectorErrorCorruptData,
                    @"The PNG ICC profile contains trailing compressed data.",
                    nil);
            }
        } else if (result != Z_OK ||
                   (produced == 0 && stream.avail_in == 0)) {
            valid = MTImageSetError(error,
                MTSafeImageInspectorErrorCorruptData,
                @"The PNG ICC profile has an invalid compressed payload.", nil);
        }
    }
    inflateEnd(&stream);
    if (valid && complete && expandedBytes == 0) {
        return MTImageSetError(error,
            MTSafeImageInspectorErrorCorruptData,
            @"The PNG ICC profile expands to an empty payload.", nil);
    }
    return valid && complete;
}

static uint32_t MTImageReadLE32(const uint8_t *bytes) {
    return (uint32_t)bytes[0] |
        ((uint32_t)bytes[1] << 8) |
        ((uint32_t)bytes[2] << 16) |
        ((uint32_t)bytes[3] << 24);
}

static BOOL MTImageValidateExif(NSData *data, NSError **error) {
    const uint8_t *bytes = data.bytes;
    if (data.length < 10) {
        return MTImageSetError(error,
            MTSafeImageInspectorErrorCorruptData,
            @"The PNG Exif payload is truncated.", nil);
    }
    BOOL littleEndian = bytes[0] == 'I' && bytes[1] == 'I' &&
        bytes[2] == 0x2a && bytes[3] == 0;
    BOOL bigEndian = bytes[0] == 'M' && bytes[1] == 'M' &&
        bytes[2] == 0 && bytes[3] == 0x2a;
    if (!littleEndian && !bigEndian) {
        return MTImageSetError(error,
            MTSafeImageInspectorErrorCorruptData,
            @"The PNG Exif payload lacks a valid TIFF header.", nil);
    }
    uint32_t firstDirectoryOffset = littleEndian
        ? MTImageReadLE32(bytes + 4) : MTImageReadBE32(bytes + 4);
    if (firstDirectoryOffset < 8 ||
        firstDirectoryOffset > data.length - 2) {
        return MTImageSetError(error,
            MTSafeImageInspectorErrorCorruptData,
            @"The PNG Exif directory offset is outside its bounded payload.",
            nil);
    }
    return YES;
}

static BOOL MTImagePreflightPNG(
    int descriptor,
    uint64_t encodedByteCount,
    MTSafeImageLimits *limits,
    BOOL validateRasterData,
    MTImportCancellationToken *_Nullable cancellationToken,
    MTPNGPreflightInfo *output,
    NSError **error) {
    if (encodedByteCount < 8) {
        return MTImageSetError(error,
            MTSafeImageInspectorErrorUnsupportedFormat,
            @"The image is not a PNG file.", nil);
    }
    uint8_t signature[sizeof(MTPNGSignature)] = {0};
    if (!MTImageReadExactly(descriptor, 0, signature, sizeof(signature),
                            cancellationToken, error)) {
        return NO;
    }
    if (memcmp(signature, MTPNGSignature, sizeof(signature)) != 0) {
        return MTImageSetError(error,
            MTSafeImageInspectorErrorUnsupportedFormat,
            @"Only static PNG images are admitted by this import stage.", nil);
    }

    uint64_t cursor = sizeof(MTPNGSignature);
    NSUInteger chunkCount = 0;
    uint64_t ancillaryByteCount = 0;
    BOOL seenHeader = NO;
    BOOL seenPalette = NO;
    BOOL seenImageData = NO;
    BOOL imageDataSequenceEnded = NO;
    BOOL seenEnd = NO;
    BOOL seenTransparency = NO;
    uint32_t paletteEntries = 0;
    uint64_t imageDataByteCount = 0;
    MTPNGPreflightInfo info = {0};
    MTPNGRasterValidator *rasterValidator = nil;

    while (cursor < encodedByteCount) {
        if (chunkCount >= limits.maximumChunkCount) {
            return MTImageSetError(error,
                MTSafeImageInspectorErrorLimitExceeded,
                @"The PNG contains too many chunks.", nil);
        }
        if (encodedByteCount - cursor < 12) {
            return MTImageSetError(error,
                MTSafeImageInspectorErrorCorruptData,
                @"The PNG has a truncated chunk header.", nil);
        }
        uint8_t header[8] = {0};
        if (!MTImageReadExactly(descriptor, (off_t)cursor, header,
                                sizeof(header), cancellationToken, error)) {
            return NO;
        }
        uint32_t dataLength = MTImageReadBE32(header);
        uint8_t *typeBytes = header + 4;
        for (NSUInteger index = 0; index < 4; index++) {
            if (!MTImageChunkTypeByteIsASCIIAlpha(typeBytes[index])) {
                return MTImageSetError(error,
                    MTSafeImageInspectorErrorCorruptData,
                    @"The PNG contains an invalid chunk type.", nil);
            }
        }
        if ((typeBytes[2] & 0x20) != 0) {
            return MTImageSetError(error,
                MTSafeImageInspectorErrorCorruptData,
                @"The PNG uses the reserved chunk type bit.", nil);
        }
        uint32_t chunkType = MTImageReadBE32(typeBytes);
        uint64_t completeChunkBytes = 12ULL + (uint64_t)dataLength;
        if (completeChunkBytes > encodedByteCount - cursor) {
            return MTImageSetError(error,
                MTSafeImageInspectorErrorCorruptData,
                @"A PNG chunk exceeds the encoded file boundary.", nil);
        }
        BOOL ancillary = (typeBytes[0] & 0x20) != 0;
        if (ancillary) {
            if ((uint64_t)dataLength > limits.maximumAncillaryBytes -
                    MIN(ancillaryByteCount, limits.maximumAncillaryBytes)) {
                return MTImageSetError(error,
                    MTSafeImageInspectorErrorLimitExceeded,
                    @"The PNG ancillary metadata budget was exceeded.", nil);
            }
            ancillaryByteCount += dataLength;
        }

        if (chunkCount == 0 && chunkType != 0x49484452) {
            return MTImageSetError(error,
                MTSafeImageInspectorErrorCorruptData,
                @"IHDR must be the first PNG chunk.", nil);
        }
        if (chunkType == 0x6163544c || chunkType == 0x6663544c ||
            chunkType == 0x66644154) {  // acTL, fcTL, fdAT
            return MTImageSetError(error,
                MTSafeImageInspectorErrorAnimatedImage,
                @"Animated PNG images are not supported.", nil);
        }
        if (MTImageChunkUsesCompressedTextMetadata(chunkType)) {
            return MTImageSetError(error,
                MTSafeImageInspectorErrorUnsupportedFormat,
                @"Compressed PNG text metadata is not admitted.", nil);
        }
        if (!ancillary && chunkType != 0x49484452 &&
            chunkType != 0x504c5445 && chunkType != 0x49444154 &&
            chunkType != 0x49454e44) {
            return MTImageSetError(error,
                MTSafeImageInspectorErrorUnsupportedFormat,
                @"The PNG contains an unknown critical chunk.", nil);
        }

        uint8_t smallData[13] = {0};
        BOOL needsSmallData = chunkType == 0x49484452;
        // iCCP, iTXt, eXIf
        BOOL needsMetadataData = chunkType == 0x69434350 ||
            chunkType == 0x69545874 || chunkType == 0x65584966;
        NSMutableData *metadataData = needsMetadataData
            ? [NSMutableData dataWithLength:dataLength] : nil;
        if (needsSmallData && dataLength != sizeof(smallData)) {
            return MTImageSetError(error,
                MTSafeImageInspectorErrorCorruptData,
                @"The PNG IHDR length is invalid.", nil);
        }
        uLong calculatedCRC = crc32(0L, Z_NULL, 0);
        calculatedCRC = crc32(calculatedCRC, typeBytes, 4);
        uint8_t readBuffer[MTImageReadBufferSize];
        uint64_t dataOffset = cursor + 8;
        uint32_t completed = 0;
        while (completed < dataLength) {
            size_t request = MIN((size_t)(dataLength - completed),
                                 sizeof(readBuffer));
            if (!MTImageReadExactly(descriptor,
                                    (off_t)(dataOffset + completed),
                                    readBuffer, request,
                                    cancellationToken, error)) {
                return NO;
            }
            if (needsSmallData) {
                memcpy(smallData + completed, readBuffer, request);
            }
            if (needsMetadataData) {
                memcpy((uint8_t *)metadataData.mutableBytes + completed,
                       readBuffer, request);
            }
            calculatedCRC = crc32(calculatedCRC, readBuffer, (uInt)request);
            if (validateRasterData && chunkType == 0x49444154 &&
                ![rasterValidator consumeCompressedBytes:readBuffer
                                                     length:request
                                                      error:error]) {
                return NO;
            }
            completed += (uint32_t)request;
        }
        uint8_t storedCRCBytes[4] = {0};
        if (!MTImageReadExactly(descriptor,
                                (off_t)(dataOffset + dataLength),
                                storedCRCBytes, sizeof(storedCRCBytes),
                                cancellationToken, error)) {
            return NO;
        }
        if ((uint32_t)calculatedCRC != MTImageReadBE32(storedCRCBytes)) {
            return MTImageSetError(error,
                MTSafeImageInspectorErrorCorruptData,
                @"A PNG chunk CRC is invalid.", nil);
        }
        if (chunkType == 0x69545874 &&
            !MTImageValidateInternationalText(metadataData, error)) {
            return NO;
        }
        if (chunkType == 0x69434350 &&
            !MTImageValidateICCProfile(metadataData,
                limits.maximumAncillaryBytes, cancellationToken, error)) {
            return NO;
        }
        if (chunkType == 0x65584966 &&
            !MTImageValidateExif(metadataData, error)) {
            return NO;
        }

        switch (chunkType) {
            case 0x49484452: {  // IHDR
                if (seenHeader) {
                    return MTImageSetError(error,
                        MTSafeImageInspectorErrorCorruptData,
                        @"The PNG contains more than one IHDR chunk.", nil);
                }
                info.width = MTImageReadBE32(smallData);
                info.height = MTImageReadBE32(smallData + 4);
                info.bitDepth = smallData[8];
                info.colorType = smallData[9];
                if (info.width == 0 || info.height == 0 || smallData[10] != 0 ||
                    smallData[11] != 0 || smallData[12] > 1 ||
                    !MTImageColorTypeAndDepthAreValid(info.colorType,
                                                      info.bitDepth)) {
                    return MTImageSetError(error,
                        MTSafeImageInspectorErrorCorruptData,
                        @"The PNG IHDR fields are invalid.", nil);
                }
                if (info.bitDepth > 8) {
                    return MTImageSetError(error,
                        MTSafeImageInspectorErrorUnsupportedFormat,
                        @"16-bit PNG assets are not admitted yet.", nil);
                }
                if (info.width > limits.maximumDimensionPixels ||
                    info.height > limits.maximumDimensionPixels) {
                    return MTImageSetError(error,
                        MTSafeImageInspectorErrorLimitExceeded,
                        @"A PNG dimension exceeds the image limit.", nil);
                }
                info.pixelCount = (uint64_t)info.width * info.height;
                if (info.pixelCount > limits.maximumPixelCount) {
                    return MTImageSetError(error,
                        MTSafeImageInspectorErrorLimitExceeded,
                        @"The PNG pixel count exceeds the image limit.", nil);
                }
                info.decodedByteEstimate = info.pixelCount * 4ULL;
                if (info.decodedByteEstimate > limits.maximumDecodedBytes) {
                    return MTImageSetError(error,
                        MTSafeImageInspectorErrorLimitExceeded,
                        @"The estimated RGBA pixel buffer exceeds the limit.",
                        nil);
                }
                info.interlaced = smallData[12] == 1;
                if (validateRasterData) {
                    rasterValidator = [[MTPNGRasterValidator alloc]
                        initWithWidth:info.width
                               height:info.height
                             bitDepth:info.bitDepth
                            colorType:info.colorType
                           interlaced:info.interlaced
                                error:error];
                    if (rasterValidator == nil) return NO;
                }
                seenHeader = YES;
                break;
            }
            case 0x504c5445:  // PLTE
                if (!seenHeader || seenPalette || seenImageData ||
                    dataLength == 0 || dataLength > 768 ||
                    dataLength % 3 != 0 || info.colorType == 0 ||
                    info.colorType == 4) {
                    return MTImageSetError(error,
                        MTSafeImageInspectorErrorCorruptData,
                        @"The PNG palette is invalid or out of order.", nil);
                }
                paletteEntries = dataLength / 3;
                if (info.colorType == 3 &&
                    paletteEntries > (1U << info.bitDepth)) {
                    return MTImageSetError(error,
                        MTSafeImageInspectorErrorCorruptData,
                        @"The indexed PNG palette exceeds its bit depth.", nil);
                }
                seenPalette = YES;
                break;
            case 0x49444154:  // IDAT
                if (!seenHeader || imageDataSequenceEnded ||
                    (info.colorType == 3 && !seenPalette)) {
                    return MTImageSetError(error,
                        MTSafeImageInspectorErrorCorruptData,
                        @"The PNG image-data chunks are invalid or out of order.",
                        nil);
                }
                seenImageData = YES;
                imageDataByteCount += dataLength;
                break;
            case 0x49454e44:  // IEND
                if (!seenHeader || !seenImageData ||
                    imageDataByteCount == 0 || seenEnd ||
                    dataLength != 0) {
                    return MTImageSetError(error,
                        MTSafeImageInspectorErrorCorruptData,
                        @"The PNG end chunk is invalid.", nil);
                }
                if (validateRasterData &&
                    ![rasterValidator finish:error]) {
                    return NO;
                }
                seenEnd = YES;
                break;
            case 0x74524e53: {  // tRNS
                BOOL validLength =
                    (info.colorType == 0 && dataLength == 2) ||
                    (info.colorType == 2 && dataLength == 6) ||
                    (info.colorType == 3 && seenPalette && dataLength > 0 &&
                     dataLength <= paletteEntries);
                if (!seenHeader || seenTransparency || seenImageData ||
                    !validLength) {
                    return MTImageSetError(error,
                        MTSafeImageInspectorErrorCorruptData,
                        @"The PNG transparency chunk is invalid or out of order.",
                        nil);
                }
                seenTransparency = YES;
                info.hasTransparencyChunk = YES;
                break;
            }
            default:
                break;
        }

        chunkCount++;
        cursor += completeChunkBytes;
        if (seenEnd) break;
        if (seenImageData && chunkType != 0x49444154) {
            imageDataSequenceEnded = YES;
        }
    }
    if (!seenEnd || cursor != encodedByteCount) {
        return MTImageSetError(error,
            MTSafeImageInspectorErrorCorruptData,
            @"The PNG is missing IEND or contains trailing data.", nil);
    }
    *output = info;
    return YES;
}

static size_t MTImageProviderReadAtPosition(void *rawInfo,
                                            void *buffer,
                                            off_t position,
                                            size_t byteCount) {
    MTImageDataProviderInfo *info = rawInfo;
    if (info == NULL || position < 0 || position >= info->byteCount ||
        atomic_load(&info->sourceChanged) || atomic_load(&info->ioError) != 0) {
        return 0;
    }
    if (info->cancellationToken.isCancelled) {
        atomic_store(&info->cancelled, true);
        return 0;
    }
    struct stat before = {0};
    if (fstat(info->descriptor, &before) != 0) {
        atomic_store(&info->ioError, errno);
        return 0;
    }
    if (!MTImageStatIsStable(&info->baseline, &before)) {
        atomic_store(&info->sourceChanged, true);
        return 0;
    }
    uint64_t available = (uint64_t)(info->byteCount - position);
    size_t target = byteCount;
    if ((uint64_t)target > available) target = (size_t)available;
    size_t completed = 0;
    while (completed < target) {
        if (info->cancellationToken.isCancelled) {
            atomic_store(&info->cancelled, true);
            return 0;
        }
        ssize_t result = pread(info->descriptor,
                               (uint8_t *)buffer + completed,
                               target - completed,
                               position + (off_t)completed);
        if (result < 0 && errno == EINTR) continue;
        if (result < 0) {
            atomic_store(&info->ioError, errno);
            break;
        }
        if (result == 0) {
            atomic_store(&info->ioError, EIO);
            break;
        }
        completed += (size_t)result;
    }
    struct stat after = {0};
    if (fstat(info->descriptor, &after) != 0) {
        atomic_store(&info->ioError, errno);
        return 0;
    }
    if (!MTImageStatIsStable(&info->baseline, &after)) {
        atomic_store(&info->sourceChanged, true);
        return 0;
    }
    if (completed != target) return 0;
    return completed;
}

static id _Nullable MTImageInspectProperties(
    int descriptor,
    uint64_t encodedByteCount,
    const struct stat *baseline,
    const MTPNGPreflightInfo *preflight,
    MTImportCancellationToken *_Nullable cancellationToken,
    MTSafeValidatedPNGConsumer _Nullable consumer,
    NSError **error) {
    if (cancellationToken.isCancelled) {
        MTImageSetError(error, MTSafeImageInspectorErrorCancelled,
            @"Image inspection was cancelled before metadata validation.", nil);
        return nil;
    }
    MTImageDataProviderInfo providerInfo = {
        .descriptor = descriptor,
        .byteCount = (off_t)encodedByteCount,
        .baseline = *baseline,
        .cancellationToken = cancellationToken,
    };
    atomic_init(&providerInfo.sourceChanged, false);
    atomic_init(&providerInfo.cancelled, false);
    atomic_init(&providerInfo.ioError, 0);
    const CGDataProviderDirectCallbacks callbacks = {
        .version = 0,
        .getBytePointer = NULL,
        .releaseBytePointer = NULL,
        .getBytesAtPosition = MTImageProviderReadAtPosition,
        .releaseInfo = NULL,
    };
    CGDataProviderRef provider = CGDataProviderCreateDirect(
        &providerInfo, providerInfo.byteCount, &callbacks);
    if (provider == NULL) {
        MTImageSetError(error, MTSafeImageInspectorErrorImageIO,
            @"Unable to create a bounded ImageIO data provider.", nil);
        return nil;
    }
    NSDictionary *sourceOptions = @{
        (__bridge NSString *)kCGImageSourceTypeIdentifierHint : @"public.png",
    };
    CGImageSourceRef source = CGImageSourceCreateWithDataProvider(
        provider, (__bridge CFDictionaryRef)sourceOptions);
    CGDataProviderRelease(provider);
    if (source == NULL) {
        if (atomic_load(&providerInfo.sourceChanged)) {
            MTImageSetError(error, MTSafeImageInspectorErrorSourceChanged,
                @"The image staging file changed while ImageIO opened it.", nil);
        } else {
            int providerError = atomic_load(&providerInfo.ioError);
            if (providerError != 0) {
                MTImageSetError(error, MTSafeImageInspectorErrorIO,
                    @"ImageIO could not open the complete staging file safely.",
                    MTImagePOSIXError(providerError));
            } else if (atomic_load(&providerInfo.cancelled)) {
                MTImageSetError(error, MTSafeImageInspectorErrorCancelled,
                    @"Image inspection was cancelled while ImageIO opened the source.",
                    nil);
            } else {
                MTImageSetError(error, MTSafeImageInspectorErrorImageIO,
                    @"ImageIO rejected the PNG source.", nil);
            }
        }
        return nil;
    }

    MTSafeImageInspection *inspection = nil;
    CFStringRef sourceType = CGImageSourceGetType(source);
    if (sourceType == NULL ||
        ![(__bridge NSString *)sourceType isEqualToString:@"public.png"]) {
        MTImageSetError(error,
            MTSafeImageInspectorErrorUnsupportedFormat,
            @"ImageIO did not identify the source as PNG.", nil);
    } else {
        size_t frameCount = CGImageSourceGetCount(source);
        if (frameCount != 1) {
            MTImageSetError(error,
                MTSafeImageInspectorErrorAnimatedImage,
                @"Only a single static image frame is supported.", nil);
        } else {
            NSDictionary *propertyOptions = @{
                (__bridge NSString *)kCGImageSourceShouldCache : @NO,
                (__bridge NSString *)kCGImageSourceShouldCacheImmediately : @NO,
                (__bridge NSString *)kCGImageSourceShouldAllowFloat : @NO,
            };
            CFDictionaryRef copiedProperties =
                CGImageSourceCopyPropertiesAtIndex(
                    source, 0, (__bridge CFDictionaryRef)propertyOptions);
            NSDictionary *properties = CFBridgingRelease(copiedProperties);
            NSNumber *width = properties[
                (__bridge NSString *)kCGImagePropertyPixelWidth];
            NSNumber *height = properties[
                (__bridge NSString *)kCGImagePropertyPixelHeight];
            NSNumber *hasAlpha = properties[
                (__bridge NSString *)kCGImagePropertyHasAlpha];
            NSNumber *orientation = properties[
                (__bridge NSString *)kCGImagePropertyOrientation];
            uint64_t imageIOWidth = width.unsignedLongLongValue;
            uint64_t imageIOHeight = height.unsignedLongLongValue;
            NSUInteger imageOrientation = orientation == nil
                ? 1 : orientation.unsignedIntegerValue;
            BOOL headerHasAlpha = preflight->colorType == 4 ||
                preflight->colorType == 6 ||
                preflight->hasTransparencyChunk;
            BOOL alphaPropertyMatches = hasAlpha == nil ||
                ([hasAlpha isKindOfClass:NSNumber.class] &&
                 hasAlpha.boolValue == headerHasAlpha);
            BOOL validProperties =
                [properties isKindOfClass:NSDictionary.class] &&
                [width isKindOfClass:NSNumber.class] &&
                [height isKindOfClass:NSNumber.class] &&
                imageIOWidth == preflight->width &&
                imageIOHeight == preflight->height &&
                imageOrientation >= 1 && imageOrientation <= 8 &&
                alphaPropertyMatches;
            BOOL statusesAreComplete =
                CGImageSourceGetStatus(source) == kCGImageStatusComplete &&
                CGImageSourceGetStatusAtIndex(source, 0) ==
                    kCGImageStatusComplete;
            if (!validProperties || !statusesAreComplete) {
                MTImageSetError(error,
                    MTSafeImageInspectorErrorImageIO,
                    @"ImageIO metadata does not match the validated PNG header.",
                    nil);
            } else if (cancellationToken.isCancelled) {
                MTImageSetError(error,
                    MTSafeImageInspectorErrorCancelled,
                    @"Image inspection was cancelled during metadata validation.",
                    nil);
            } else {
                inspection = [[MTSafeImageInspection alloc]
                    initWithTypeIdentifier:@"public.png"
                         encodedByteCount:encodedByteCount
                               pixelWidth:preflight->width
                              pixelHeight:preflight->height
                               pixelCount:preflight->pixelCount
                      decodedByteEstimate:preflight->decodedByteEstimate
                               frameCount:(NSUInteger)frameCount
                                 hasAlpha:headerHasAlpha
                              orientation:imageOrientation
                                 bitDepth:preflight->bitDepth
                                colorType:preflight->colorType
                               interlaced:preflight->interlaced];
            }
        }
    }
    id result = inspection;
    if (inspection != nil && consumer != nil &&
        !atomic_load(&providerInfo.sourceChanged) &&
        atomic_load(&providerInfo.ioError) == 0 &&
        !atomic_load(&providerInfo.cancelled)) {
        result = consumer(source, inspection, error);
    }
    CFRelease(source);
    if (atomic_load(&providerInfo.sourceChanged)) {
        result = nil;
        MTImageSetError(error, MTSafeImageInspectorErrorSourceChanged,
            @"The image staging file changed while ImageIO processed it.", nil);
    } else {
        int providerError = atomic_load(&providerInfo.ioError);
        if (providerError != 0) {
            result = nil;
            MTImageSetError(error, MTSafeImageInspectorErrorIO,
                @"ImageIO could not read the complete staging file safely.",
                MTImagePOSIXError(providerError));
        } else if (atomic_load(&providerInfo.cancelled)) {
            result = nil;
            MTImageSetError(error, MTSafeImageInspectorErrorCancelled,
                @"Image processing was cancelled while ImageIO read pixels.",
                nil);
        }
    }
    return result;
}

id _Nullable MTSafeImageProcessOwnedPNGFile(
    NSURL *fileURL,
    MTSafeImageLimits *limits,
    BOOL validateRasterData,
    MTImportCancellationToken *_Nullable cancellationToken,
    MTSafeValidatedPNGConsumer _Nullable consumer,
    NSError **error) {
    if (error != NULL) *error = nil;
    NSString *path = fileURL.path;
    if (![fileURL isKindOfClass:NSURL.class] || !fileURL.isFileURL ||
        ![limits isKindOfClass:MTSafeImageLimits.class] ||
        path.length == 0 || !path.isAbsolutePath ||
        ![path.stringByStandardizingPath isEqualToString:path]) {
        MTImageSetError(error, MTSafeImageInspectorErrorInvalidRequest,
            @"Image processing requires a canonical local file URL and limits.",
            nil);
        return nil;
    }
    if (cancellationToken.isCancelled) {
        MTImageSetError(error, MTSafeImageInspectorErrorCancelled,
            @"Image processing was cancelled before opening the source.", nil);
        return nil;
    }

    struct stat pathBefore = {0};
    if (lstat(path.fileSystemRepresentation, &pathBefore) != 0) {
        MTImageSetError(error, MTSafeImageInspectorErrorUnsafeSource,
            @"The image staging file is unavailable or unsafe.",
            MTImagePOSIXError(errno));
        return nil;
    }
    mode_t unsafePermissions = S_IXUSR | S_IXGRP | S_IXOTH |
        S_IWGRP | S_IWOTH;
    if (!S_ISREG(pathBefore.st_mode) || pathBefore.st_nlink != 1 ||
        pathBefore.st_uid != geteuid() || pathBefore.st_size <= 0 ||
        (pathBefore.st_mode & unsafePermissions) != 0) {
        MTImageSetError(error, MTSafeImageInspectorErrorUnsafeSource,
            @"The image staging file has an unsafe type, owner, link count, or mode.",
            nil);
        return nil;
    }
    if ((uint64_t)pathBefore.st_size > limits.maximumEncodedBytes) {
        MTImageSetError(error, MTSafeImageInspectorErrorLimitExceeded,
            @"The encoded PNG exceeds the image byte limit.", nil);
        return nil;
    }

    int descriptor = open(path.fileSystemRepresentation,
        O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW);
    if (descriptor < 0) {
        MTImageSetError(error, MTSafeImageInspectorErrorUnsafeSource,
            @"Unable to open the image staging file without following links.",
            MTImagePOSIXError(errno));
        return nil;
    }
    struct stat openedStatus = {0};
    if (fstat(descriptor, &openedStatus) != 0 ||
        !MTImageStatIsStable(&pathBefore, &openedStatus)) {
        int savedError = errno;
        close(descriptor);
        MTImageSetError(error, MTSafeImageInspectorErrorSourceChanged,
            @"The image staging file changed while it was opened.",
            savedError == 0 ? nil : MTImagePOSIXError(savedError));
        return nil;
    }

    MTPNGPreflightInfo preflight = {0};
    id result = nil;
    BOOL preflightPassed = MTImagePreflightPNG(
        descriptor, (uint64_t)openedStatus.st_size, limits,
        validateRasterData,
        cancellationToken, &preflight, error);
    if (preflightPassed) {
        struct stat descriptorAfterPreflight = {0};
        struct stat pathAfterPreflight = {0};
        BOOL stableBeforeImageIO =
            fstat(descriptor, &descriptorAfterPreflight) == 0 &&
            MTImageStatIsStable(&openedStatus, &descriptorAfterPreflight) &&
            lstat(path.fileSystemRepresentation, &pathAfterPreflight) == 0 &&
            MTImageStatIsStable(&openedStatus, &pathAfterPreflight);
        if (!stableBeforeImageIO) {
            MTImageSetError(error, MTSafeImageInspectorErrorSourceChanged,
                @"The image staging file changed during PNG preflight.", nil);
        } else {
            result = MTImageInspectProperties(
                descriptor, (uint64_t)openedStatus.st_size, &openedStatus,
                &preflight, cancellationToken, consumer, error);
        }
    }

    struct stat descriptorAfter = {0};
    struct stat pathAfter = {0};
    BOOL descriptorStable = fstat(descriptor, &descriptorAfter) == 0 &&
        MTImageStatIsStable(&openedStatus, &descriptorAfter);
    BOOL pathStable = lstat(path.fileSystemRepresentation, &pathAfter) == 0 &&
        MTImageStatIsStable(&openedStatus, &pathAfter);
    close(descriptor);
    if (!descriptorStable || !pathStable) {
        MTImageSetError(error, MTSafeImageInspectorErrorSourceChanged,
            @"The image staging file changed during processing.", nil);
        return nil;
    }
    return result;
}

@implementation MTSafeImageInspector

+ (instancetype)defaultInspector {
    return [[self alloc] initWithLimits:MTSafeImageLimits.defaultLimits];
}

- (instancetype)initWithLimits:(MTSafeImageLimits *)limits {
    NSParameterAssert(limits != nil);
    self = [super init];
    if (self == nil) return nil;
    _limits = limits;
    return self;
}

- (MTSafeImageInspection *)
    inspectOwnedPNGFileAtURL:(NSURL *)fileURL
          cancellationToken:(MTImportCancellationToken *)cancellationToken
                       error:(NSError **)error {
    return MTSafeImageProcessOwnedPNGFile(
        fileURL, self.limits, NO, cancellationToken, nil, error);
}

@end
