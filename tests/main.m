#import <Foundation/Foundation.h>

#import <dispatch/dispatch.h>
#import <fcntl.h>
#import <string.h>
#import <sys/file.h>
#import <sys/stat.h>
#import <unistd.h>
#import <zlib.h>

#import "MTBootstrapPaths.h"
#import "MTBadgeConfiguration.h"
#import "MTBadgesModule.h"
#import "MTCanonicalJSON.h"
#import "MTCalendarIconConfiguration.h"
#import "MTCalendarIconsModule.h"
#import "MTClockIconsModule.h"
#import "MTCalendarRuntimeTests.h"
#import "MTAssetStagingSession.h"
#import "MTDiagnostic.h"
#import "MTDialerModule.h"
#import "MTDialerContract.h"
#import "MTDigest.h"
#import "MTDirectorySnapshotSession.h"
#import "MTExpandedArchiveSession.h"
#import "MTGenerationDescriptor.h"
#import "MTGenerationDescriptorTests.h"
#import "MTGenerationIndexCodec.h"
#import "MTGenerationReader.h"
#import "MTGenerationIndexTests.h"
#import "MTGenerationReaderTests.h"
#import "MTGenerationWriter.h"
#import "MTGenerationWriterTests.h"
#import "MTFolderIconContract.h"
#import "MTFolderIconsModule.h"
#import "MTIdentifier.h"
#import "MTIconBundlesImporter.h"
#import "MTIconMaskConfiguration.h"
#import "MTIconServiceRuntimeTests.h"
#import "MTIconMaskContract.h"
#import "MTIconOverlayContract.h"
#import "MTIconMaskModule.h"
#import "MTIconOverlayModule.h"
#import "MTIconShadowConfiguration.h"
#import "MTIconShadowContract.h"
#import "MTIconShadowsModule.h"
#import "MTAuditedSource.h"
#import "MTImportSession.h"
#import "MTImportCoordinator.h"
#import "MTLayerResolver.h"
#import "MTModuleDescriptor.h"
#import "MTModuleRegistry.h"
#import "MTResourceKey.h"
#import "MTRuntimeKernelTests.h"
#import "MTRuntimePublishedImageLoader.h"
#import "MTRuntimeProfileTests.h"
#import "MTRuntimeReplacementTests.h"
#import "MTRuntimeSnapshotResourceTests.h"
#import "MTRuntimeStoreTests.h"
#import "MTRuntimeWeakObjectMapSnapshotTests.h"
#import "MTRuntimeStressFixture.h"
#import "MTSafeDirectoryScanner.h"
#import "MTSafeImageDecoder.h"
#import "MTSafeImageInspector.h"
#import "MTSafePropertyListReader.h"
#import "MTSafeZIPArchiveReader.h"
#import "MTSourceInventory.h"
#import "MTStaticIconsModule.h"
#import "MTStaticIconConfiguration.h"
#import "MTStaticIconCompiler.h"
#import "MTStatusBarContract.h"
#import "MTStatusBarModule.h"
#import "MTThemeCapabilityReport.h"
#import "MTThemeComponentCatalog.h"
#import "MTThemeComponentSelectionStore.h"
#import "MTThemeLibraryStore.h"
#import "MTThemeLibraryCatalog.h"
#import "MTThemeManifest.h"
#import "MTThemeMixSelection.h"
#import "MTThemeInfoMetadataImporter.h"
#import "MTThemeInfoMetadataMapper.h"
#import "MTThemeInfoMetadataMapperInternal.h"
#import "MTThemeImport.h"
#import "MTInstalledThemeLocator.h"
#import "MTThemeSourceRoot.h"
#import "MTThemeApplyServiceTests.h"
#import "MTUIResourcesModule.h"
#import "MTVersionContracts.h"

static NSUInteger MTAssertionCount = 0;
static NSString *MTGoldenManifestDigest = nil;

@interface MTDeterministicCancellationToken : MTImportCancellationToken {
    NSUInteger _readCount;
}
@end

@implementation MTDeterministicCancellationToken
- (BOOL)isCancelled {
    _readCount++;
    return _readCount >= 4;
}
@end

@interface MTThresholdCancellationToken : MTImportCancellationToken {
    NSUInteger _readCount;
    NSUInteger _threshold;
}
@property(nonatomic, assign, readonly) NSUInteger readCount;
- (instancetype)initWithThreshold:(NSUInteger)threshold;
@end

@implementation MTThresholdCancellationToken
- (instancetype)initWithThreshold:(NSUInteger)threshold {
    self = [super init];
    if (self == nil) return nil;
    _threshold = threshold;
    return self;
}
- (BOOL)isCancelled {
    _readCount++;
    return _readCount >= _threshold;
}
- (NSUInteger)readCount {
    return _readCount;
}
@end

@interface MTImageMutationToken : MTImportCancellationToken {
    NSUInteger _readCount;
    NSUInteger _triggerCount;
    NSString *_path;
}
@property(nonatomic, assign, readonly) BOOL mutationSucceeded;
- (instancetype)initWithPath:(NSString *)path
                 triggerCount:(NSUInteger)triggerCount;
@end

@implementation MTImageMutationToken
- (instancetype)initWithPath:(NSString *)path
                 triggerCount:(NSUInteger)triggerCount {
    self = [super init];
    if (self == nil) return nil;
    _path = [path copy];
    _triggerCount = triggerCount;
    return self;
}
- (BOOL)isCancelled {
    _readCount++;
    if (_readCount == _triggerCount) {
        _mutationSucceeded = chmod(_path.fileSystemRepresentation, 0400) == 0;
    }
    return NO;
}
@end

static void MTAssert(BOOL condition, NSString *message) {
    MTAssertionCount++;
    if (condition) return;
    fprintf(stderr, "FAIL: %s\n", message.UTF8String);
    exit(1);
}

static void MTZIPFixtureAppendLE16(NSMutableData *data, uint16_t value) {
    uint8_t bytes[] = {(uint8_t)value, (uint8_t)(value >> 8)};
    [data appendBytes:bytes length:sizeof(bytes)];
}

static void MTZIPFixtureAppendLE32(NSMutableData *data, uint32_t value) {
    uint8_t bytes[] = {
        (uint8_t)value,
        (uint8_t)(value >> 8),
        (uint8_t)(value >> 16),
        (uint8_t)(value >> 24),
    };
    [data appendBytes:bytes length:sizeof(bytes)];
}

static uint32_t MTZIPFixtureCRC32(NSData *data) {
    return (uint32_t)crc32(0, data.bytes, (uInt)data.length);
}

static NSData *MTZIPFixtureRawDeflate(NSData *data) {
    MTAssert(data.length <= UINT32_MAX,
             @"ZIP fixture deflate input must fit zlib counters");
    z_stream stream = {0};
    int result = deflateInit2(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED,
                              -MAX_WBITS, 8, Z_DEFAULT_STRATEGY);
    MTAssert(result == Z_OK, @"ZIP fixture raw deflate must initialize");
    uLong bound = deflateBound(&stream, (uLong)data.length);
    NSMutableData *compressed = [NSMutableData dataWithLength:(NSUInteger)bound];
    stream.next_in = (Bytef *)data.bytes;
    stream.avail_in = (uInt)data.length;
    stream.next_out = compressed.mutableBytes;
    stream.avail_out = (uInt)compressed.length;
    result = deflate(&stream, Z_FINISH);
    MTAssert(result == Z_STREAM_END,
             @"ZIP fixture raw deflate must consume the complete input");
    [compressed setLength:(NSUInteger)stream.total_out];
    MTAssert(deflateEnd(&stream) == Z_OK,
             @"ZIP fixture raw deflate must release state");
    return compressed;
}

// Adapted from MarkFont's proven stored-ZIP host fixture builder, extended
// locally with raw deflate and deliberate metadata mutations for attack tests.
static NSData *MTZIPFixtureData(
    NSArray<NSDictionary<NSString *, id> *> *entries) {
    NSMutableData *archive = [NSMutableData data];
    NSMutableArray<NSDictionary<NSString *, id> *> *centralEntries =
        [NSMutableArray array];
    for (NSDictionary<NSString *, id> *entry in entries) {
        NSData *name = entry[@"nameData"] ?: [entry[@"name"]
            dataUsingEncoding:NSUTF8StringEncoding];
        NSData *localName = entry[@"localNameData"] ?: name;
        NSData *contents = entry[@"data"] ?: NSData.data;
        uint16_t method = [entry[@"method"] unsignedShortValue];
        NSData *payload = method == 8
            ? MTZIPFixtureRawDeflate(contents) : contents;
        uint16_t flags = entry[@"flags"] == nil
            ? 0x0800 : [entry[@"flags"] unsignedShortValue];
        uint32_t crc = entry[@"crc"] == nil
            ? MTZIPFixtureCRC32(contents) : [entry[@"crc"] unsignedIntValue];
        MTAssert(name.length <= UINT16_MAX && localName.length <= UINT16_MAX &&
                 contents.length <= UINT32_MAX && payload.length <= UINT32_MAX &&
                 archive.length <= UINT32_MAX,
                 @"ZIP fixture entry must fit the ZIP32 subset");
        uint32_t localOffset = (uint32_t)archive.length;
        MTZIPFixtureAppendLE32(archive, 0x04034b50);
        MTZIPFixtureAppendLE16(archive, 20);
        MTZIPFixtureAppendLE16(archive, flags);
        MTZIPFixtureAppendLE16(archive, method);
        MTZIPFixtureAppendLE16(archive, 0);
        MTZIPFixtureAppendLE16(archive, 0);
        MTZIPFixtureAppendLE32(archive, crc);
        MTZIPFixtureAppendLE32(archive, (uint32_t)payload.length);
        MTZIPFixtureAppendLE32(archive, (uint32_t)contents.length);
        MTZIPFixtureAppendLE16(archive, (uint16_t)localName.length);
        MTZIPFixtureAppendLE16(archive, 0);
        [archive appendData:localName];
        [archive appendData:payload];
        [centralEntries addObject:@{
            @"name" : name,
            @"contentsLength" : @((uint32_t)contents.length),
            @"payloadLength" : @((uint32_t)payload.length),
            @"crc" : @(crc),
            @"offset" : @(localOffset),
            @"flags" : @(flags),
            @"method" : @(method),
            @"mode" : entry[@"mode"] ?: @(S_IFREG | 0644),
        }];
    }
    uint32_t centralOffset = (uint32_t)archive.length;
    for (NSDictionary<NSString *, id> *entry in centralEntries) {
        NSData *name = entry[@"name"];
        MTZIPFixtureAppendLE32(archive, 0x02014b50);
        MTZIPFixtureAppendLE16(archive, 0x0314);
        MTZIPFixtureAppendLE16(archive, 20);
        MTZIPFixtureAppendLE16(archive,
            [entry[@"flags"] unsignedShortValue]);
        MTZIPFixtureAppendLE16(archive,
            [entry[@"method"] unsignedShortValue]);
        MTZIPFixtureAppendLE16(archive, 0);
        MTZIPFixtureAppendLE16(archive, 0);
        MTZIPFixtureAppendLE32(archive, [entry[@"crc"] unsignedIntValue]);
        MTZIPFixtureAppendLE32(archive,
            [entry[@"payloadLength"] unsignedIntValue]);
        MTZIPFixtureAppendLE32(archive,
            [entry[@"contentsLength"] unsignedIntValue]);
        MTZIPFixtureAppendLE16(archive, (uint16_t)name.length);
        MTZIPFixtureAppendLE16(archive, 0);
        MTZIPFixtureAppendLE16(archive, 0);
        MTZIPFixtureAppendLE16(archive, 0);
        MTZIPFixtureAppendLE16(archive, 0);
        MTZIPFixtureAppendLE32(archive,
            [entry[@"mode"] unsignedIntValue] << 16);
        MTZIPFixtureAppendLE32(archive, [entry[@"offset"] unsignedIntValue]);
        [archive appendData:name];
    }
    uint32_t centralSize = (uint32_t)archive.length - centralOffset;
    MTZIPFixtureAppendLE32(archive, 0x06054b50);
    MTZIPFixtureAppendLE16(archive, 0);
    MTZIPFixtureAppendLE16(archive, 0);
    MTZIPFixtureAppendLE16(archive, (uint16_t)centralEntries.count);
    MTZIPFixtureAppendLE16(archive, (uint16_t)centralEntries.count);
    MTZIPFixtureAppendLE32(archive, centralSize);
    MTZIPFixtureAppendLE32(archive, centralOffset);
    MTZIPFixtureAppendLE16(archive, 0);
    return archive;
}

static void MTPNGFixtureAppendBE32(NSMutableData *data, uint32_t value) {
    uint8_t bytes[] = {
        (uint8_t)(value >> 24),
        (uint8_t)(value >> 16),
        (uint8_t)(value >> 8),
        (uint8_t)value,
    };
    [data appendBytes:bytes length:sizeof(bytes)];
}

static void MTPNGFixtureAppendChunk(NSMutableData *png,
                                    NSString *type,
                                    NSData *contents) {
    NSData *typeData = [type dataUsingEncoding:NSASCIIStringEncoding];
    MTAssert(typeData.length == 4 && contents.length <= UINT32_MAX,
             @"PNG fixture chunk must have a four-byte ASCII type");
    MTPNGFixtureAppendBE32(png, (uint32_t)contents.length);
    [png appendData:typeData];
    [png appendData:contents];
    uLong checksum = crc32(0L, Z_NULL, 0);
    checksum = crc32(checksum, typeData.bytes, (uInt)typeData.length);
    if (contents.length > 0) {
        checksum = crc32(checksum, contents.bytes, (uInt)contents.length);
    }
    MTPNGFixtureAppendBE32(png, (uint32_t)checksum);
}

static NSData *MTPNGFixtureCompressedData(NSData *uncompressed) {
    MTAssert(uncompressed.length <= UINT32_MAX,
             @"PNG fixture raster must fit zlib counters");
    uLongf capacity = compressBound((uLong)uncompressed.length);
    NSMutableData *compressed = [NSMutableData dataWithLength:capacity];
    int result = compress2(compressed.mutableBytes, &capacity,
                           uncompressed.bytes, (uLong)uncompressed.length,
                           Z_BEST_SPEED);
    MTAssert(result == Z_OK, @"PNG fixture raster must compress");
    [compressed setLength:(NSUInteger)capacity];
    return compressed;
}

static NSData *MTPNGFixtureData(
    uint32_t width,
    uint32_t height,
    uint8_t bitDepth,
    uint8_t colorType,
    uint8_t interlace,
    BOOL validRaster,
    NSArray<NSDictionary<NSString *, id> *> *chunksBeforeImageData,
    NSArray<NSDictionary<NSString *, id> *> *chunksAfterImageData) {
    NSMutableData *png = [NSMutableData data];
    const uint8_t signature[] = {
        0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a,
    };
    [png appendBytes:signature length:sizeof(signature)];

    NSMutableData *header = [NSMutableData data];
    MTPNGFixtureAppendBE32(header, width);
    MTPNGFixtureAppendBE32(header, height);
    const uint8_t headerTail[] = {
        bitDepth, colorType, 0, 0, interlace,
    };
    [header appendBytes:headerTail length:sizeof(headerTail)];
    MTPNGFixtureAppendChunk(png, @"IHDR", header);

    for (NSDictionary<NSString *, id> *chunk in chunksBeforeImageData) {
        MTPNGFixtureAppendChunk(png, chunk[@"type"],
                               chunk[@"data"] ?: NSData.data);
    }

    NSMutableData *raster = [NSMutableData data];
    if (validRaster) {
        NSUInteger channels = colorType == 6 ? 4 :
            (colorType == 4 ? 2 : (colorType == 2 ? 3 : 1));
        MTAssert(bitDepth == 8 && interlace <= 1 &&
                 width <= 256 && height <= 256,
                 @"valid PNG host fixture must stay bounded and 8-bit");
        static const uint8_t xStart[7] = {0, 4, 0, 2, 0, 1, 0};
        static const uint8_t yStart[7] = {0, 0, 4, 0, 2, 0, 1};
        static const uint8_t xStep[7] = {8, 8, 4, 4, 2, 2, 1};
        static const uint8_t yStep[7] = {8, 8, 8, 4, 4, 2, 2};
        NSUInteger passCount = interlace == 0 ? 1 : 7;
        for (NSUInteger pass = 0; pass < passCount; pass++) {
            uint8_t startX = interlace == 0 ? 0 : xStart[pass];
            uint8_t startY = interlace == 0 ? 0 : yStart[pass];
            uint8_t stepX = interlace == 0 ? 1 : xStep[pass];
            uint8_t stepY = interlace == 0 ? 1 : yStep[pass];
            if (width <= startX || height <= startY) continue;
            uint32_t passWidth = (width - startX + stepX - 1U) / stepX;
            uint32_t passHeight = (height - startY + stepY - 1U) / stepY;
            for (uint32_t passY = 0; passY < passHeight; passY++) {
                uint8_t filter = 0;
                [raster appendBytes:&filter length:1];
                uint32_t y = startY + passY * stepY;
                for (uint32_t passX = 0; passX < passWidth; passX++) {
                    uint32_t x = startX + passX * stepX;
                    uint8_t pixel[4] = {
                        (uint8_t)(x * 31),
                        (uint8_t)(y * 47),
                        0x7f,
                        0xff,
                    };
                    [raster appendBytes:pixel length:channels];
                }
            }
        }
    } else {
        const uint8_t syntheticRaster[] = {0, 0, 0, 0, 0};
        [raster appendBytes:syntheticRaster length:sizeof(syntheticRaster)];
    }
    MTPNGFixtureAppendChunk(png, @"IDAT",
                            MTPNGFixtureCompressedData(raster));
    for (NSDictionary<NSString *, id> *chunk in chunksAfterImageData) {
        MTPNGFixtureAppendChunk(png, chunk[@"type"],
                               chunk[@"data"] ?: NSData.data);
    }
    MTPNGFixtureAppendChunk(png, @"IEND", NSData.data);
    return png;
}

static NSData *MTPNGFixtureDataWithRaster(
    uint32_t width,
    uint32_t height,
    uint8_t bitDepth,
    uint8_t colorType,
    uint8_t interlace,
    NSArray<NSDictionary<NSString *, id> *> *chunksBeforeImageData,
    NSData *raster,
    NSData *trailingCompressedBytes) {
    NSMutableData *png = [NSMutableData data];
    const uint8_t signature[] = {
        0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a,
    };
    [png appendBytes:signature length:sizeof(signature)];
    NSMutableData *header = [NSMutableData data];
    MTPNGFixtureAppendBE32(header, width);
    MTPNGFixtureAppendBE32(header, height);
    const uint8_t headerTail[] = {
        bitDepth, colorType, 0, 0, interlace,
    };
    [header appendBytes:headerTail length:sizeof(headerTail)];
    MTPNGFixtureAppendChunk(png, @"IHDR", header);
    for (NSDictionary<NSString *, id> *chunk in chunksBeforeImageData) {
        MTPNGFixtureAppendChunk(png, chunk[@"type"],
                               chunk[@"data"] ?: NSData.data);
    }
    NSMutableData *compressed = [NSMutableData dataWithData:
        MTPNGFixtureCompressedData(raster)];
    [compressed appendData:trailingCompressedBytes ?: NSData.data];
    MTPNGFixtureAppendChunk(png, @"IDAT", compressed);
    MTPNGFixtureAppendChunk(png, @"IEND", NSData.data);
    return png;
}

static NSData *MTHighContrastShareActivityPNGData(void) {
    const uint32_t dimension = 180;
    NSMutableData *raster = [NSMutableData dataWithCapacity:
        (NSUInteger)dimension * ((NSUInteger)dimension * 4U + 1U)];
    for (uint32_t y = 0; y < dimension; y++) {
        const uint8_t filter = 0;
        [raster appendBytes:&filter length:1];
        for (uint32_t x = 0; x < dimension; x++) {
            int32_t diagonalA = (int32_t)x - (int32_t)y;
            int32_t diagonalB = (int32_t)x + (int32_t)y -
                (int32_t)(dimension - 1U);
            int32_t centerX = (int32_t)x - (int32_t)(dimension / 2U);
            int32_t centerY = (int32_t)y - (int32_t)(dimension / 2U);
            BOOL border = x < 10U || y < 10U ||
                x >= dimension - 10U || y >= dimension - 10U;
            BOOL cross = abs(diagonalA) < 7 || abs(diagonalB) < 7;
            BOOL center = centerX * centerX + centerY * centerY < 24 * 24;
            uint8_t pixel[4] = {0xff, 0x00, 0xaa, 0xff};
            if (border) {
                pixel[0] = 0x00;
                pixel[1] = 0xff;
                pixel[2] = 0xff;
            } else if (cross) {
                pixel[0] = 0xff;
                pixel[1] = 0xff;
                pixel[2] = 0xff;
            }
            if (center) {
                pixel[0] = 0xff;
                pixel[1] = 0xe5;
                pixel[2] = 0x00;
            }
            [raster appendBytes:pixel length:sizeof(pixel)];
        }
    }
    return MTPNGFixtureDataWithRaster(
        dimension, dimension, 8, 6, 0, @[], raster, nil);
}

static NSString *MTWritePNGFixture(NSString *root,
                                   NSString *name,
                                   NSData *contents) {
    NSString *path = [root stringByAppendingPathComponent:name];
    NSError *error = nil;
    MTAssert([contents writeToFile:path options:NSDataWritingAtomic error:&error] &&
             chmod(path.fileSystemRepresentation, 0600) == 0,
             [NSString stringWithFormat:
                @"PNG fixture must be privately written (%@)",
                error.localizedDescription ?: @"no error"]);
    return path;
}

static NSString *MTWriteZIPFixture(
    NSString *root,
    NSString *name,
    NSArray<NSDictionary<NSString *, id> *> *entries) {
    NSString *path = [root stringByAppendingPathComponent:name];
    NSError *error = nil;
    MTAssert([MTZIPFixtureData(entries) writeToFile:path
                                            options:NSDataWritingAtomic
                                              error:&error],
             [NSString stringWithFormat:@"ZIP fixture write failed: %@", error]);
    return path;
}

static void MTTarFixtureWriteOctal(unsigned char *field,
                                  size_t length,
                                  uint64_t value) {
    memset(field, '0', length);
    char buffer[32] = {0};
    snprintf(buffer, sizeof(buffer), "%llo", (unsigned long long)value);
    size_t digits = strlen(buffer);
    MTAssert(digits + 1 <= length,
             @"tar fixture octal value must fit its field");
    memcpy(field + length - digits - 1, buffer, digits);
    field[length - 1] = '\0';
}

static NSData *MTTarFixtureData(
    NSArray<NSDictionary<NSString *, id> *> *entries) {
    NSMutableData *tar = [NSMutableData data];
    for (NSDictionary<NSString *, id> *entry in entries) {
        NSString *name = entry[@"name"];
        NSData *nameData = [name dataUsingEncoding:NSUTF8StringEncoding];
        NSData *contents = entry[@"data"] ?: NSData.data;
        BOOL directory = [entry[@"directory"] boolValue];
        MTAssert(nameData.length > 0 && nameData.length < 100 &&
                 contents.length <= UINT32_MAX,
                 @"tar fixture path and data must fit ustar fields");
        unsigned char header[512] = {0};
        memcpy(header, nameData.bytes, nameData.length);
        MTTarFixtureWriteOctal(header + 100, 8,
            directory ? 0755 : 0644);
        MTTarFixtureWriteOctal(header + 108, 8, 0);
        MTTarFixtureWriteOctal(header + 116, 8, 0);
        MTTarFixtureWriteOctal(header + 124, 12,
            directory ? 0 : contents.length);
        MTTarFixtureWriteOctal(header + 136, 12, 0);
        memset(header + 148, ' ', 8);
        header[156] = directory ? '5' : '0';
        memcpy(header + 257, "ustar", 5);
        header[262] = '\0';
        header[263] = '0';
        header[264] = '0';
        memcpy(header + 265, "marktheme", 9);
        memcpy(header + 297, "marktheme", 9);
        unsigned int checksum = 0;
        for (NSUInteger index = 0; index < sizeof(header); index++) {
            checksum += header[index];
        }
        char checksumText[8] = {0};
        snprintf(checksumText, sizeof(checksumText), "%06o", checksum);
        memcpy(header + 148, checksumText, 6);
        header[154] = '\0';
        header[155] = ' ';
        [tar appendBytes:header length:sizeof(header)];
        if (!directory) {
            [tar appendData:contents];
            NSUInteger padding = (512 - (contents.length % 512)) % 512;
            if (padding > 0) {
                unsigned char zeros[512] = {0};
                [tar appendBytes:zeros length:padding];
            }
        }
    }
    unsigned char terminator[1024] = {0};
    [tar appendBytes:terminator length:sizeof(terminator)];
    return tar;
}

static NSData *MTGzipFixtureData(NSData *data) {
    MTAssert(data.length <= UINT32_MAX,
             @"gzip fixture input must fit zlib counters");
    z_stream stream = {0};
    MTAssert(deflateInit2(&stream, Z_BEST_SPEED, Z_DEFLATED,
                         MAX_WBITS + 16, 8, Z_DEFAULT_STRATEGY) == Z_OK,
             @"gzip fixture encoder must initialize");
    uLong bound = deflateBound(&stream, (uLong)data.length);
    NSMutableData *compressed = [NSMutableData dataWithLength:(NSUInteger)bound];
    stream.next_in = (Bytef *)data.bytes;
    stream.avail_in = (uInt)data.length;
    stream.next_out = compressed.mutableBytes;
    stream.avail_out = (uInt)compressed.length;
    MTAssert(deflate(&stream, Z_FINISH) == Z_STREAM_END,
             @"gzip fixture encoder must finish");
    [compressed setLength:(NSUInteger)stream.total_out];
    MTAssert(deflateEnd(&stream) == Z_OK,
             @"gzip fixture encoder must release state");
    return compressed;
}

static void MTArFixtureAppendMember(NSMutableData *archive,
                                    NSString *name,
                                    NSData *contents) {
    NSData *nameData = [[name stringByAppendingString:@"/"]
        dataUsingEncoding:NSASCIIStringEncoding];
    MTAssert(nameData.length <= 16 && contents.length <= 9999999999ULL,
             @"ar fixture member must fit the common header");
    unsigned char header[60];
    memset(header, ' ', sizeof(header));
    memcpy(header, nameData.bytes, nameData.length);
    const char *timestamp = "0";
    memcpy(header + 16, timestamp, strlen(timestamp));
    memcpy(header + 28, "0", 1);
    memcpy(header + 34, "0", 1);
    memcpy(header + 40, "100644", 6);
    NSString *size = [NSString stringWithFormat:@"%lu",
        (unsigned long)contents.length];
    NSData *sizeData = [size dataUsingEncoding:NSASCIIStringEncoding];
    memcpy(header + 48, sizeData.bytes, sizeData.length);
    header[58] = '`';
    header[59] = '\n';
    [archive appendBytes:header length:sizeof(header)];
    [archive appendData:contents];
    if ((contents.length & 1U) != 0) {
        const unsigned char padding = '\n';
        [archive appendBytes:&padding length:1];
    }
}

static NSData *MTDebFixtureData(NSData *dataTarGzip) {
    NSMutableData *archive = [NSMutableData dataWithBytes:"!<arch>\n"
                                                   length:8];
    MTArFixtureAppendMember(archive, @"debian-binary",
        [@"2.0\n" dataUsingEncoding:NSASCIIStringEncoding]);
    MTArFixtureAppendMember(archive, @"control.tar.gz",
        MTGzipFixtureData(MTTarFixtureData(@[])));
    MTArFixtureAppendMember(archive, @"data.tar.gz", dataTarGzip);
    return archive;
}

static NSString *MTWriteDataFixture(NSString *root,
                                    NSString *name,
                                    NSData *data) {
    NSString *path = [root stringByAppendingPathComponent:name];
    NSError *error = nil;
    MTAssert([data writeToFile:path options:NSDataWritingAtomic error:&error],
             [NSString stringWithFormat:@"archive fixture write failed: %@",
                error.localizedDescription ?: @"unknown"]);
    return path;
}

static MTResourceKey *MTMakeKey(NSString *subject) {
    NSError *error = nil;
    MTResourceKey *key = [[MTResourceKey alloc]
        initWithModuleID:@"icons.static"
                 surface:@"springboard.home"
                 subject:subject
                 variant:@"primary"
                   scale:3
                   trait:@"any"
                   error:&error];
    MTAssert(key != nil && error == nil, @"valid resource key must initialize");
    return key;
}

static MTResourceCandidate *MTMakeCandidate(MTResourceKey *key,
                                             NSString *themeID,
                                             NSString *path,
                                             NSInteger priority,
                                             NSUInteger matchRank,
                                             BOOL override) {
    NSError *error = nil;
    MTResourceCandidate *candidate = [[MTResourceCandidate alloc]
        initWithResourceKey:key
                    themeID:themeID
           relativeAssetPath:path
              layerPriority:priority
                  matchRank:matchRank
            explicitOverride:override
                      error:&error];
    MTAssert(candidate != nil && error == nil,
             @"valid resource candidate must initialize");
    return candidate;
}

static void MTTestIdentifiersAndContracts(void) {
    MTAssert(MTIdentifierIsValid(@"icons.static"), @"stable module ID must validate");
    MTAssert(!MTIdentifierIsValid(@"Icons.Static"), @"noncanonical uppercase ID must fail");
    MTAssert(!MTIdentifierIsValid(@"icons..static"), @"double separator must fail");
    MTAssert(!MTIdentifierIsValid(@"../icons"), @"path-like ID must fail");

    NSError *error = nil;
    NSString *normalized = MTNormalizeIdentifier(@"Icons.Static", &error);
    MTAssert([normalized isEqualToString:@"icons.static"] && error == nil,
             @"identifier normalization must be deterministic");

    NSDictionary<NSString *, NSNumber *> *versions = MTCurrentContractVersions();
    MTAssert(versions.count == 5, @"all five version contracts must be present");
    MTAssert(MTContractVersionsAreSupported(versions, &error),
             @"current contract versions must validate");

    NSMutableDictionary *future = [versions mutableCopy];
    future[@"optionalFutureContract"] = @7;
    error = nil;
    MTAssert(MTContractVersionsAreSupported(future, &error),
             @"unknown optional contract keys must not replace required checks");

    NSMutableDictionary *incompatible = [versions mutableCopy];
    incompatible[MTRuntimeSnapshotVersionKey] = @2;
    error = nil;
    MTAssert(!MTContractVersionsAreSupported(incompatible, &error) && error != nil,
             @"incompatible runtime snapshot must fail");
}

static void MTTestResourceKeys(void) {
    MTResourceKey *first = MTMakeKey(@"com.example.alpha");
    MTResourceKey *second = MTMakeKey(@"com.example.alpha");
    MTAssert([first isEqual:second] && first.hash == second.hash,
             @"equal semantic keys must compare and hash equally");
    MTAssert([first.canonicalString hasPrefix:@"mtk1|12:icons.static|"],
             @"canonical key must be versioned and length-prefixed");

    NSError *error = nil;
    MTResourceKey *unsafe = [[MTResourceKey alloc]
        initWithModuleID:@"icons.static"
                 surface:@"springboard.home"
                 subject:@"../com.example.alpha"
                 variant:@"primary"
                   scale:3
                   trait:@"any"
                   error:&error];
    MTAssert(unsafe == nil && error != nil,
             @"path-like resource subject must fail");

    error = nil;
    MTResourceKey *invalidScale = [[MTResourceKey alloc]
        initWithModuleID:@"icons.static"
                 surface:@"springboard.home"
                 subject:@"com.example.alpha"
                 variant:@"primary"
                   scale:4
                   trait:@"any"
                   error:&error];
    MTAssert(invalidScale == nil && error != nil,
             @"unsupported resource scale must fail");
}

static void MTTestCanonicalJSON(void) {
    NSMutableDictionary *first = [NSMutableDictionary dictionary];
    first[@"z"] = @2;
    first[@"a"] = @"Cafe\u0301";
    first[@"array"] = @[@YES, NSNull.null, @3];
    NSMutableDictionary *second = [NSMutableDictionary dictionary];
    second[@"array"] = @[@YES, NSNull.null, @3];
    second[@"a"] = @"Café";
    second[@"z"] = @2;
    NSError *error = nil;
    NSData *firstData = MTCanonicalJSONData(first, &error);
    NSData *secondData = MTCanonicalJSONData(second, &error);
    NSString *canonical = [[NSString alloc] initWithData:firstData
                                                encoding:NSUTF8StringEncoding];
    MTAssert(firstData != nil && [firstData isEqualToData:secondData],
             @"canonical JSON must ignore insertion order and normalize NFC");
    MTAssert([canonical isEqualToString:
        @"{\"a\":\"Café\",\"array\":[true,null,3],\"z\":2}"],
        @"canonical JSON bytes must match the version-one encoding");
    error = nil;
    MTAssert(MTCanonicalJSONData(@{ @"float" : @1.25 }, &error) == nil &&
             error != nil,
             @"canonical JSON must reject floating-point values");
    MTAssert([MTSHA256HexDigestForData([@"abc"
        dataUsingEncoding:NSUTF8StringEncoding]) isEqualToString:
        @"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"],
        @"SHA-256 must match the standard abc vector");
    error = nil;
    NSArray<MTSourceFile *> *invalidInventoryFiles =
        (NSArray<MTSourceFile *> *)(id)@[NSNull.null];
    MTAssert([MTSourceInventory inventoryWithFiles:invalidInventoryFiles
                                             error:&error] == nil && error != nil,
             @"source inventory must reject non-file objects without dispatching to them");
}

static void MTTestLayerResolution(void) {
    MTResourceKey *key = MTMakeKey(@"com.example.alpha");
    MTResourceCandidate *lower = MTMakeCandidate(
        key, @"theme.lower", @"Icons/Lower.png", 10, 0, NO);
    MTResourceCandidate *higherFallback = MTMakeCandidate(
        key, @"theme.higher", @"Icons/Higher-Fallback.png", 20, 1, NO);
    MTResolutionResult *layerResult = [MTLayerResolver
        resolveCandidates:@[lower, higherFallback]
           forResourceKey:key];
    MTAssert(layerResult.winner == higherFallback && !layerResult.hasConflict,
             @"higher layer fallback must beat every lower layer");

    MTResourceCandidate *override = MTMakeCandidate(
        key, @"theme.override", @"Icons/Override.png", -100, 0, YES);
    MTResolutionResult *overrideResult = [MTLayerResolver
        resolveCandidates:@[higherFallback, override]
           forResourceKey:key];
    MTAssert(overrideResult.winner == override,
             @"explicit override must beat layer priority");

    MTResourceCandidate *tieA = MTMakeCandidate(
        key, @"theme.tie-a", @"Icons/Tie-A.png", 30, 0, NO);
    MTResourceCandidate *tieB = MTMakeCandidate(
        key, @"theme.tie-b", @"Icons/Tie-B.png", 30, 0, NO);
    MTResolutionResult *conflict = [MTLayerResolver
        resolveCandidates:@[tieB, tieA]
           forResourceKey:key];
    MTAssert(conflict.winner == nil && conflict.hasConflict &&
             [conflict.diagnostic.code isEqualToString:@"resolution.conflict"],
             @"equal winning priority must produce an explicit conflict");

    NSError *error = nil;
    MTResourceCandidate *unsafe = [[MTResourceCandidate alloc]
        initWithResourceKey:key
                    themeID:@"theme.unsafe"
           relativeAssetPath:@"../Outside.png"
              layerPriority:1
                  matchRank:0
            explicitOverride:NO
                      error:&error];
    MTAssert(unsafe == nil && error != nil,
             @"candidate path traversal must fail at the contract boundary");
}

static MTModuleDescriptor *MTMakeDescriptor(NSString *moduleID,
                                             NSArray<NSString *> *dependencies) {
    NSError *error = nil;
    NSString *kind = [moduleID stringByAppendingString:@".resource"];
    MTModuleDescriptor *descriptor = [[MTModuleDescriptor alloc]
        initWithModuleID:moduleID
              apiVersion:MTModuleAPIVersion
           resourceKinds:@[kind]
            dependencies:dependencies
         processAdapters:@[]
      refreshRequirement:MTRefreshRequirementUnsupported
                   error:&error];
    MTAssert(descriptor != nil && error == nil,
             @"valid module descriptor must initialize");
    return descriptor;
}

static void MTTestModuleRegistry(void) {
    MTModuleDescriptor *icons = MTStaticIconsModuleDescriptor();
    MTModuleDescriptor *calendar = MTCalendarIconsModuleDescriptor();
    MTModuleDescriptor *clock = MTClockIconsModuleDescriptor();
    MTModuleDescriptor *folders = MTFolderIconsModuleDescriptor();
    MTModuleDescriptor *iconMask = MTIconMaskModuleDescriptor();
    MTModuleDescriptor *iconOverlay = MTIconOverlayModuleDescriptor();
    MTModuleDescriptor *uiResources = MTUIResourcesModuleDescriptor();
    MTModuleDescriptor *badges = MTBadgesModuleDescriptor();
    MTModuleDescriptor *dialer = MTDialerModuleDescriptor();
    MTModuleDescriptor *iconShadows = MTIconShadowsModuleDescriptor();
    MTModuleDescriptor *statusBar = MTStatusBarModuleDescriptor();
    NSError *error = nil;
    MTModuleRegistry *registry = [[MTModuleRegistry alloc]
        initWithDescriptors:@[
            badges, calendar, clock, dialer, folders, iconMask, iconOverlay,
            iconShadows, icons, statusBar, uiResources,
        ]
                       error:&error];
    MTAssert(registry != nil && error == nil && registry.descriptors.count == 11,
             @"built-in module registry must initialize");
    MTAssert([registry descriptorForModuleID:@"Icons.Static"] == icons,
             @"module lookup must normalize caller case");
    MTAssert([registry descriptorForModuleID:@"ICONS.OVERLAY"] == iconOverlay,
             @"overlay module must participate in built-in registry lookup");
    MTAssert([[MTBadgeResourceTraitCandidates(
                  @"iphone", MTBadgeAppearanceDark)
                  componentsJoinedByString:@","]
                 isEqualToString:@"iphone-dark,dark,iphone,any"] &&
             [[MTBadgeResourceTraitCandidates(
                  @"any", MTBadgeAppearanceLight)
                  componentsJoinedByString:@","]
                 isEqualToString:@"light,any"] &&
             MTBadgeResourceTraitIsSupported(@"ipad-light") &&
             !MTBadgeResourceTraitIsSupported(@"dark-iphone"),
             @"badge appearance lookup must prefer an exact trait and retain a universal fallback");
    NSError *badgeConfigurationError = nil;
    MTBadgeConfiguration *badgeConfiguration =
        [[MTBadgeConfiguration alloc] initWithDictionary:@{
            @"defaultVariant" : @"Oxy-Blue",
        } error:&badgeConfigurationError];
    MTAssert(badgeConfiguration != nil &&
             badgeConfigurationError == nil &&
             [badgeConfiguration.defaultVariant
                 isEqualToString:@"oxy-blue"] &&
             [badgeConfiguration.canonicalDictionary isEqual:@{
                 @"defaultVariant" : @"oxy-blue",
             }],
             @"badge configuration must canonicalize one authored default style");
    badgeConfigurationError = nil;
    MTAssert([[MTBadgeConfiguration alloc] initWithDictionary:@{}
                                                    error:&badgeConfigurationError] == nil &&
             badgeConfigurationError != nil &&
             [[MTBadgeConfiguration alloc] initWithDictionary:@{
                 @"defaultVariant" : @"oxy-blue",
                 @"appearance" : @"dark",
             } error:NULL] == nil &&
             [[MTBadgeConfiguration alloc] initWithDictionary:@{
                 @"defaultVariant" : @"***",
             } error:NULL] == nil,
             @"badge configuration must reject missing, extra, and invalid fields");
    NSError *shadowConfigurationError = nil;
    MTIconShadowConfiguration *shadowConfiguration =
        [[MTIconShadowConfiguration alloc] initWithDictionary:@{
            @"defaultVariant" : @"Oxy-Shadow-Mini",
        } error:&shadowConfigurationError];
    MTAssert(shadowConfiguration != nil &&
             shadowConfigurationError == nil &&
             [shadowConfiguration.defaultVariant
                 isEqualToString:@"oxy-shadow-mini"] &&
             [shadowConfiguration.canonicalDictionary isEqual:@{
                 @"defaultVariant" : @"oxy-shadow-mini",
             }],
             @"icon-shadow configuration must canonicalize one authored style independently of device traits");
    shadowConfigurationError = nil;
    MTAssert([[MTIconShadowConfiguration alloc]
                 initWithDictionary:@{} error:&shadowConfigurationError] == nil &&
             shadowConfigurationError != nil &&
             [[MTIconShadowConfiguration alloc] initWithDictionary:@{
                 @"defaultVariant" : @"***",
             } error:NULL] == nil &&
             MTIconShadowSubjectIsSupported(MTIconShadowSubjectIPhone) &&
             MTIconShadowCanvasPointDimension(
                 MTIconShadowSubjectIPhone) == 110.0 &&
             MTIconShadowCanvasPointDimension(
                 MTIconShadowSubjectIPad) == 139.5 &&
             MTIconShadowCanvasPointDimension(
                 MTIconShadowSubjectIPadPro) == 153.0,
             @"icon-shadow contract must reject malformed configuration and preserve established canvas dimensions");
    NSArray<NSString *> *applicationIconSourceAdapters = @[
        @"iconservices.application-icon-source",
        @"preferences.application-icon-native-invalidation",
        @"share-sheet.application-icon-native-invalidation",
        @"spotlight.application-icon-native-invalidation",
        @"springboard.application-icon-native-invalidation",
    ];
    MTAssert([icons.processAdapters
                 isEqualToArray:applicationIconSourceAdapters] &&
             icons.refreshRequirement == MTRefreshRequirementTargeted &&
             [calendar.dependencies isEqualToArray:@[@"icons.static"]] &&
             [calendar.processAdapters isEqualToArray:@[
                 @"spotlight.calendar-icon-image",
                 @"springboard.calendar-application-icon",
             ]] &&
             calendar.refreshRequirement == MTRefreshRequirementTargeted &&
             [clock.dependencies isEqualToArray:@[@"icons.static"]] &&
             [clock.processAdapters
                 isEqualToArray:@[@"springboard.clock-image-set"]] &&
             clock.refreshRequirement == MTRefreshRequirementTargeted &&
             folders.dependencies.count == 0 &&
             [folders.processAdapters
                 isEqualToArray:@[@"springboard.folder-image"]] &&
             [folders.resourceKinds isEqualToArray:@[
                 @"folder.background", @"folder.background.light",
             ]] &&
             iconMask.dependencies.count == 0 &&
             [iconMask.processAdapters
                 isEqualToArray:applicationIconSourceAdapters] &&
             [iconMask.resourceKinds
                 isEqualToArray:@[@"icon.mask", @"icon.pattern"]] &&
             iconOverlay.dependencies.count == 0 &&
             [iconOverlay.processAdapters
                 isEqualToArray:applicationIconSourceAdapters] &&
             [iconOverlay.resourceKinds
                 isEqualToArray:@[@"icon.overlay"]] &&
             [uiResources.processAdapters
                 isEqualToArray:@[
                    @"preferences.ui-resource-image",
                    @"share-sheet.activity-glyph",
                 ]] &&
             [uiResources.resourceKinds isEqualToArray:@[
                    @"ui.preferences.icon",
                    @"ui.share.activity",
                 ]] &&
             uiResources.dependencies.count == 0 &&
             uiResources.refreshRequirement == MTRefreshRequirementTargeted &&
             [badges.processAdapters
                 isEqualToArray:@[@"springboard.badge-background"]] &&
             [badges.resourceKinds isEqualToArray:@[@"badge.background"]] &&
             badges.refreshRequirement == MTRefreshRequirementTargeted &&
             [dialer.processAdapters
                 isEqualToArray:@[@"mobilephone.dialer-buttons"]] &&
             [dialer.resourceKinds
                 isEqualToArray:@[@"ui.phone.dialer-image"]] &&
             [iconShadows.processAdapters
                 isEqualToArray:@[@"springboard.icon-shadow"]] &&
             [iconShadows.resourceKinds isEqualToArray:@[@"icon.shadow"]] &&
             [statusBar.processAdapters isEqualToArray:@[
                 @"springboard.statusbar-signal-image",
             ]] &&
             [statusBar.resourceKinds
                 isEqualToArray:@[@"ui.statusbar-image"]] &&
             dialer.refreshRequirement == MTRefreshRequirementTargeted &&
             iconShadows.refreshRequirement == MTRefreshRequirementTargeted &&
             statusBar.refreshRequirement == MTRefreshRequirementTargeted,
             @"built-in modules must declare their exact process adapters");
    MTAssert(MTDialerButtonPointDimension == 75.0 &&
             MTDialerNumberButtonSubjects().count == 12 &&
             [MTDialerNumberButtonSubjects().firstObject
                 isEqualToString:@"0"] &&
             [MTDialerNumberButtonSubjects().lastObject
                 isEqualToString:@"11"] &&
             MTDialerRuntimeSubjects().count == 14 &&
             MTDialerResourceSubjectIsSupported(
                 MTDialerCallButtonSubject) &&
             MTDialerResourceSubjectIsSupported(
                 MTDialerCallButtonPressedSubject) &&
             !MTDialerResourceSubjectIsSupported(@"../unsafe"),
             @"Dialer contract must preserve the 12 legacy keypad slots and two call-button states");
    MTAssert(MTStatusBarRuntimeSubjects().count == 18 &&
             MTStatusBarMaximumLevel(MTStatusBarSignalKindCellular) == 4 &&
             MTStatusBarMaximumLevel(MTStatusBarSignalKindWiFi) == 3 &&
             [MTStatusBarResourceSubject(
                 MTStatusBarSignalKindCellular,
                 MTStatusBarArtworkStyleBlack, 4)
                 isEqualToString:@"Black_4_Bars"] &&
             [MTStatusBarResourceSubject(
                 MTStatusBarSignalKindWiFi,
                 MTStatusBarArtworkStyleLockScreen, 3)
                 isEqualToString:@"LockScreen_3_WifiBars"] &&
             MTStatusBarResourceSubject(
                 MTStatusBarSignalKindWiFi,
                 MTStatusBarArtworkStyleBlack, 4) == nil &&
             MTStatusBarResourceSubject(
                 (MTStatusBarSignalKind)99,
                 MTStatusBarArtworkStyleBlack, 0) == nil &&
             MTStatusBarResourceSubject(
                 MTStatusBarSignalKindWiFi,
                 (MTStatusBarArtworkStyle)99, 0) == nil &&
             MTStatusBarResourceSubjectIsSupported(
                 @"Black_0_WifiBars") &&
             !MTStatusBarResourceSubjectIsSupported(@"Black_5_Bars"),
             @"Status Bar contract must preserve exact SnowBoard Wi-Fi and cellular level bounds");

    error = nil;
    MTModuleRegistry *duplicate = [[MTModuleRegistry alloc]
        initWithDescriptors:@[icons, icons]
                       error:&error];
    MTAssert(duplicate == nil && error != nil,
             @"duplicate module IDs must fail");

    MTModuleDescriptor *missing = MTMakeDescriptor(
        @"module.missing-user", @[@"module.not-registered"]);
    error = nil;
    MTModuleRegistry *missingRegistry = [[MTModuleRegistry alloc]
        initWithDescriptors:@[missing]
                       error:&error];
    MTAssert(missingRegistry == nil && error != nil,
             @"missing module dependency must fail");

    MTModuleDescriptor *cycleA = MTMakeDescriptor(
        @"module.cycle-a", @[@"module.cycle-b"]);
    MTModuleDescriptor *cycleB = MTMakeDescriptor(
        @"module.cycle-b", @[@"module.cycle-a"]);
    error = nil;
    MTModuleRegistry *cycleRegistry = [[MTModuleRegistry alloc]
        initWithDescriptors:@[cycleA, cycleB]
                       error:&error];
    MTAssert(cycleRegistry == nil && error != nil,
             @"module dependency cycle must fail");
}

static void MTTestPlatformPaths(void) {
    NSError *error = nil;
    MTAssert([MTManagerDataRootLiteralPath isEqualToString:
        @"/var/mobile/Library/Application Support/MarkTheme"],
        @"Manager data must remain on the literal mobile user-data volume");
    MTBootstrapPathResolver *rootless = [MTBootstrapPathResolver
        resolverForTestingScheme:MTPackageSchemeRootless
                   physicalPrefix:@"/var/jb"];
    NSString *rootlessPath = [rootless
        resolvedPathForLogicalPath:MTRuntimeStoreLogicalPath
                             error:&error];
    MTAssert([rootlessPath isEqualToString:
        @"/var/jb/var/lib/marktheme"] &&
             error == nil,
             @"rootless provider must map the stable logical runtime root");
    NSString *rootlessReloadExecutable = [rootless
        resolvedPathForLogicalPath:MTDesktopReloadExecutableLogicalPath
                             error:&error];
    MTAssert([rootlessReloadExecutable isEqualToString:
        @"/var/jb/usr/bin/sbreload"],
        @"rootless provider must map the fixed desktop reload executable");

    MTBootstrapPathResolver *rootHide = [MTBootstrapPathResolver
        resolverForTestingScheme:MTPackageSchemeRootHide
                   physicalPrefix:@"/private/preboot/SYNTHETIC/procursus"];
    NSString *rootHidePath = [rootHide
        resolvedPathForLogicalPath:MTRuntimeStoreLogicalPath
                             error:&error];
    MTAssert([rootHidePath isEqualToString:
        @"/private/preboot/SYNTHETIC/procursus/var/lib/marktheme"],
        @"RootHide provider must resolve at use time through its supplied semantic root");

    NSString *inboxPath = [rootHide
        resolvedPathForLogicalPath:MTGenerationInboxLogicalPath error:&error];
    MTAssert([inboxPath isEqualToString:
        @"/private/preboot/SYNTHETIC/procursus/var/mobile/Library/Application Support/MarkTheme/PublishInbox"],
        @"RootHide provider must keep the mobile-owned publication inbox separate");

    NSString *reloadExecutable = [rootHide
        resolvedPathForLogicalPath:MTDesktopReloadExecutableLogicalPath
                             error:&error];
    MTAssert([reloadExecutable isEqualToString:
        @"/private/preboot/SYNTHETIC/procursus/usr/bin/sbreload"],
        @"RootHide provider must resolve the fixed desktop reload executable at use time");

    MTBootstrapPathResolver *host = [MTBootstrapPathResolver
        resolverForTestingScheme:MTPackageSchemeHost physicalPrefix:@""];
    MTAssert([[host resolvedPathForLogicalPath:MTRuntimeStateLogicalPath error:&error]
                 isEqualToString:MTRuntimeStateLogicalPath],
             @"host provider must preserve logical paths");

    error = nil;
    MTAssert([rootless resolvedPathForLogicalPath:@"/var/../etc/passwd"
                                           error:&error] == nil && error != nil,
             @"logical path traversal must fail");
}

static NSString *MTCreateTemporaryDirectory(NSString *label) {
    NSString *template = [NSTemporaryDirectory()
        stringByAppendingPathComponent:[NSString stringWithFormat:
            @"marktheme-%@.XXXXXX", label]];
    NSMutableData *buffer = [[template dataUsingEncoding:NSUTF8StringEncoding]
        mutableCopy];
    [buffer increaseLengthBy:1];
    char *path = buffer.mutableBytes;
    MTAssert(mkdtemp(path) != NULL, @"temporary test directory must be created");
    return [NSFileManager.defaultManager
        stringWithFileSystemRepresentation:path length:strlen(path)];
}

static void MTAssertImageFailure(
    MTSafeImageInspector *inspector,
    NSURL *fileURL,
    MTImportCancellationToken *token,
    MTSafeImageInspectorErrorCode expectedCode,
    NSString *message) {
    NSError *error = nil;
    MTSafeImageInspection *inspection = [inspector
        inspectOwnedPNGFileAtURL:fileURL
              cancellationToken:token
                           error:&error];
    MTAssert(inspection == nil &&
             [error.domain isEqualToString:MTSafeImageInspectorErrorDomain] &&
             error.code == expectedCode,
             [NSString stringWithFormat:@"%@ (%@/%ld: %@)", message,
                error.domain ?: @"no-domain", (long)error.code,
                error.localizedDescription ?: @"no error"]);
}

static MTSafeImageLimits *MTImageFixtureLimits(
    uint64_t encodedBytes,
    uint32_t dimension,
    uint64_t pixels,
    uint64_t decodedBytes,
    NSUInteger chunks,
    uint64_t ancillaryBytes) {
    return [[MTSafeImageLimits alloc]
        initWithMaximumEncodedBytes:encodedBytes
             maximumDimensionPixels:dimension
                  maximumPixelCount:pixels
                maximumDecodedBytes:decodedBytes
                   maximumChunkCount:chunks
              maximumAncillaryBytes:ancillaryBytes];
}

static void MTTestSafeImageInspector(void) {
    NSString *root = MTCreateTemporaryDirectory(@"safe-image");
    NSData *validPNG = MTPNGFixtureData(
        2, 3, 8, 6, 0, YES, @[], @[]);
    NSString *validPath = MTWritePNGFixture(root, @"valid.png", validPNG);
    NSURL *validURL = [NSURL fileURLWithPath:validPath];
    MTSafeImageInspector *inspector = MTSafeImageInspector.defaultInspector;
    NSError *error = nil;
    MTSafeImageInspection *inspection = [inspector
        inspectOwnedPNGFileAtURL:validURL cancellationToken:nil error:&error];
    MTAssert(inspection != nil && error == nil &&
             [inspection.typeIdentifier isEqualToString:@"public.png"] &&
             inspection.encodedByteCount == validPNG.length &&
             inspection.pixelWidth == 2 && inspection.pixelHeight == 3 &&
             inspection.pixelCount == 6 &&
             inspection.decodedByteEstimate == 24 &&
             inspection.frameCount == 1 && inspection.hasAlpha &&
             inspection.orientation == 1 && inspection.bitDepth == 8 &&
             inspection.colorType == 6 && !inspection.isInterlaced,
             [NSString stringWithFormat:
                @"valid static RGBA PNG metadata must pass without pixel decode (%@/%ld: %@)",
                error.domain ?: @"no-domain", (long)error.code,
                error.localizedDescription ?: @"no error"]);

    NSMutableData *leadingEmptyIDAT = [NSMutableData dataWithData:
        [validPNG subdataWithRange:NSMakeRange(0, 33)]];
    MTPNGFixtureAppendChunk(leadingEmptyIDAT, @"IDAT", NSData.data);
    [leadingEmptyIDAT appendData:[validPNG subdataWithRange:
        NSMakeRange(33, validPNG.length - 33)]];
    NSString *emptyIDATPath = MTWritePNGFixture(
        root, @"leading-empty-idat.png", leadingEmptyIDAT);
    error = nil;
    MTAssert([inspector inspectOwnedPNGFileAtURL:
        [NSURL fileURLWithPath:emptyIDATPath]
        cancellationToken:nil error:&error] != nil && error == nil,
        @"a legal empty IDAT before non-empty consecutive IDAT must be accepted");

    NSData *rgbPNG = MTPNGFixtureData(1, 1, 8, 2, 0, YES, @[], @[]);
    NSString *rgbPath = MTWritePNGFixture(root, @"rgb.png", rgbPNG);
    error = nil;
    MTSafeImageInspection *rgbInspection = [inspector
        inspectOwnedPNGFileAtURL:[NSURL fileURLWithPath:rgbPath]
              cancellationToken:nil error:&error];
    MTAssert(rgbInspection != nil && error == nil && !rgbInspection.hasAlpha &&
             rgbInspection.colorType == 2,
             @"ImageIO and IHDR must agree that an RGB PNG has no alpha");

    const uint8_t transparentRGBValue[6] = {0, 0, 0, 0, 0, 0};
    NSData *transparency = [NSData dataWithBytes:transparentRGBValue
                                          length:sizeof(transparentRGBValue)];
    NSData *transparentRGB = MTPNGFixtureData(1, 1, 8, 2, 0, YES,
        @[@{ @"type" : @"tRNS", @"data" : transparency }], @[]);
    NSString *transparentPath = MTWritePNGFixture(
        root, @"rgb-transparency.png", transparentRGB);
    error = nil;
    MTSafeImageInspection *transparentInspection = [inspector
        inspectOwnedPNGFileAtURL:[NSURL fileURLWithPath:transparentPath]
              cancellationToken:nil error:&error];
    MTAssert(transparentInspection != nil && error == nil &&
             transparentInspection.hasAlpha,
             @"a valid tRNS color key must be represented as alpha-bearing");

    NSString *notPNGPath = MTWritePNGFixture(root, @"not-png.bin",
        [@"not a PNG" dataUsingEncoding:NSUTF8StringEncoding]);
    MTAssertImageFailure(inspector, [NSURL fileURLWithPath:notPNGPath], nil,
        MTSafeImageInspectorErrorUnsupportedFormat,
        @"non-PNG input must fail before ImageIO");

    NSMutableData *badCRC = [validPNG mutableCopy];
    ((uint8_t *)badCRC.mutableBytes)[29] ^= 0x01;
    NSString *badCRCPath = MTWritePNGFixture(root, @"bad-crc.png", badCRC);
    MTAssertImageFailure(inspector, [NSURL fileURLWithPath:badCRCPath], nil,
        MTSafeImageInspectorErrorCorruptData,
        @"a PNG with a corrupted IHDR CRC must fail closed");

    NSMutableData *trailing = [validPNG mutableCopy];
    uint8_t trailingByte = 0;
    [trailing appendBytes:&trailingByte length:1];
    NSString *trailingPath = MTWritePNGFixture(root, @"trailing.png", trailing);
    MTAssertImageFailure(inspector, [NSURL fileURLWithPath:trailingPath], nil,
        MTSafeImageInspectorErrorCorruptData,
        @"bytes after IEND must be rejected");

    NSData *truncated = [validPNG subdataWithRange:
        NSMakeRange(0, validPNG.length - 2)];
    NSString *truncatedPath = MTWritePNGFixture(
        root, @"truncated.png", truncated);
    MTAssertImageFailure(inspector, [NSURL fileURLWithPath:truncatedPath], nil,
        MTSafeImageInspectorErrorCorruptData,
        @"a truncated PNG chunk must be rejected");

    NSMutableData *animationControl = [NSMutableData data];
    MTPNGFixtureAppendBE32(animationControl, 2);
    MTPNGFixtureAppendBE32(animationControl, 0);
    NSData *animated = MTPNGFixtureData(1, 1, 8, 6, 0, YES,
        @[@{ @"type" : @"acTL", @"data" : animationControl }], @[]);
    NSString *animatedPath = MTWritePNGFixture(root, @"animated.png", animated);
    MTAssertImageFailure(inspector, [NSURL fileURLWithPath:animatedPath], nil,
        MTSafeImageInspectorErrorAnimatedImage,
        @"APNG control chunks must be rejected before frame decode");

    NSData *unknownCritical = MTPNGFixtureData(1, 1, 8, 6, 0, YES,
        @[@{ @"type" : @"ABCD", @"data" : NSData.data }], @[]);
    NSString *criticalPath = MTWritePNGFixture(
        root, @"unknown-critical.png", unknownCritical);
    MTAssertImageFailure(inspector, [NSURL fileURLWithPath:criticalPath], nil,
        MTSafeImageInspectorErrorUnsupportedFormat,
        @"unknown critical PNG chunks must not reach ImageIO");

    NSData *malformedICCProfile = MTPNGFixtureData(1, 1, 8, 6, 0, YES,
        @[@{ @"type" : @"iCCP",
             @"data" : [@"profile" dataUsingEncoding:NSUTF8StringEncoding] }],
        @[]);
    NSString *metadataPath = MTWritePNGFixture(
        root, @"malformed-icc-profile.png", malformedICCProfile);
    MTAssertImageFailure(inspector, [NSURL fileURLWithPath:metadataPath], nil,
        MTSafeImageInspectorErrorCorruptData,
        @"malformed compressed ICC metadata must fail at the bounded image gate");

    NSMutableData *iccProfile = [NSMutableData data];
    [iccProfile appendData:[@"Display P3" dataUsingEncoding:
        NSISOLatin1StringEncoding]];
    const uint8_t iccFields[] = {0, 0};
    [iccProfile appendBytes:iccFields length:sizeof(iccFields)];
    [iccProfile appendData:MTPNGFixtureCompressedData(
        [@"bounded color profile" dataUsingEncoding:NSUTF8StringEncoding])];
    NSData *boundedICC = MTPNGFixtureData(1, 1, 8, 6, 0, YES,
        @[@{ @"type" : @"iCCP", @"data" : iccProfile }], @[]);
    NSString *boundedICCPath = MTWritePNGFixture(
        root, @"bounded-icc-profile.png", boundedICC);
    error = nil;
    MTAssert([inspector inspectOwnedPNGFileAtURL:
        [NSURL fileURLWithPath:boundedICCPath]
        cancellationToken:nil error:&error] != nil && error == nil,
        @"bounded zlib-compressed ICC metadata must be accepted");

    NSMutableData *internationalText = [NSMutableData data];
    [internationalText appendData:[@"XML:com.adobe.xmp"
        dataUsingEncoding:NSISOLatin1StringEncoding]];
    const uint8_t internationalTextFields[] = {0, 0, 0, 0, 0};
    [internationalText appendBytes:internationalTextFields
                            length:sizeof(internationalTextFields)];
    [internationalText appendData:[@"<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"/>"
        dataUsingEncoding:NSUTF8StringEncoding]];
    const uint8_t exifBytes[] = {
        'M', 'M', 0, 0x2a, 0, 0, 0, 8, 0, 0,
    };
    NSData *boundedMetadata = MTPNGFixtureData(1, 1, 8, 6, 0, YES, @[
        @{ @"type" : @"iTXt", @"data" : internationalText },
        @{ @"type" : @"eXIf",
           @"data" : [NSData dataWithBytes:exifBytes
                                     length:sizeof(exifBytes)] },
    ], @[]);
    NSString *boundedMetadataPath = MTWritePNGFixture(
        root, @"bounded-metadata.png", boundedMetadata);
    error = nil;
    MTAssert([inspector inspectOwnedPNGFileAtURL:
        [NSURL fileURLWithPath:boundedMetadataPath]
        cancellationToken:nil error:&error] != nil && error == nil,
        @"bounded uncompressed iTXt and structurally valid eXIf metadata must be accepted");

    NSMutableData *compressedInternationalText = [internationalText mutableCopy];
    ((uint8_t *)compressedInternationalText.mutableBytes)[
        @"XML:com.adobe.xmp".length + 1] = 1;
    NSData *compressedInternationalTextPNG = MTPNGFixtureData(
        1, 1, 8, 6, 0, YES,
        @[@{ @"type" : @"iTXt",
             @"data" : compressedInternationalText }], @[]);
    NSString *compressedInternationalTextPath = MTWritePNGFixture(
        root, @"compressed-international-text.png",
        compressedInternationalTextPNG);
    MTAssertImageFailure(inspector,
        [NSURL fileURLWithPath:compressedInternationalTextPath], nil,
        MTSafeImageInspectorErrorUnsupportedFormat,
        @"compressed iTXt must remain rejected before ImageIO can expand it");

    NSData *sixteenBit = MTPNGFixtureData(
        1, 1, 16, 6, 0, NO, @[], @[]);
    NSString *sixteenBitPath = MTWritePNGFixture(
        root, @"sixteen-bit.png", sixteenBit);
    MTAssertImageFailure(inspector, [NSURL fileURLWithPath:sixteenBitPath], nil,
        MTSafeImageInspectorErrorUnsupportedFormat,
        @"16-bit PNG must fail before an oversized pixel representation is possible");

    NSData *pixelBomb = MTPNGFixtureData(
        16384, 16384, 8, 6, 0, NO, @[], @[]);
    NSString *pixelBombPath = MTWritePNGFixture(
        root, @"pixel-bomb.png", pixelBomb);
    MTAssertImageFailure(inspector, [NSURL fileURLWithPath:pixelBombPath], nil,
        MTSafeImageInspectorErrorLimitExceeded,
        @"legal dimensions with excessive total pixels must fail at IHDR");

    MTSafeImageInspector *dimensionInspector = [[MTSafeImageInspector alloc]
        initWithLimits:MTImageFixtureLimits(1024 * 1024, 1, 64, 256, 16, 64)];
    MTAssertImageFailure(dimensionInspector, validURL, nil,
        MTSafeImageInspectorErrorLimitExceeded,
        @"a caller-tightened dimension limit must be enforced");

    MTSafeImageInspector *pixelInspector = [[MTSafeImageInspector alloc]
        initWithLimits:MTImageFixtureLimits(1024 * 1024, 16, 5, 256, 16, 64)];
    MTAssertImageFailure(pixelInspector, validURL, nil,
        MTSafeImageInspectorErrorLimitExceeded,
        @"a caller-tightened pixel-count limit must be enforced");

    MTSafeImageInspector *decodeInspector = [[MTSafeImageInspector alloc]
        initWithLimits:MTImageFixtureLimits(1024 * 1024, 16, 64, 23, 16, 64)];
    MTAssertImageFailure(decodeInspector, validURL, nil,
        MTSafeImageInspectorErrorLimitExceeded,
        @"the RGBA decoded-byte estimate must have an independent ceiling");

    NSData *textChunk = MTPNGFixtureData(1, 1, 8, 6, 0, YES,
        @[@{ @"type" : @"tEXt",
             @"data" : [@"key=value" dataUsingEncoding:NSUTF8StringEncoding] }],
        @[]);
    NSString *textPath = MTWritePNGFixture(root, @"text.png", textChunk);
    MTSafeImageInspector *ancillaryInspector = [[MTSafeImageInspector alloc]
        initWithLimits:MTImageFixtureLimits(1024 * 1024, 16, 64, 256, 16, 4)];
    MTAssertImageFailure(ancillaryInspector, [NSURL fileURLWithPath:textPath], nil,
        MTSafeImageInspectorErrorLimitExceeded,
        @"ancillary PNG bytes must have an aggregate budget");

    MTSafeImageInspector *chunkInspector = [[MTSafeImageInspector alloc]
        initWithLimits:MTImageFixtureLimits(1024 * 1024, 16, 64, 256, 2, 64)];
    MTAssertImageFailure(chunkInspector, validURL, nil,
        MTSafeImageInspectorErrorLimitExceeded,
        @"PNG chunk count must be bounded independently of encoded bytes");

    MTSafeImageInspector *encodedInspector = [[MTSafeImageInspector alloc]
        initWithLimits:MTImageFixtureLimits(validPNG.length - 1, 16, 64,
                                             256, 16, 64)];
    MTAssertImageFailure(encodedInspector, validURL, nil,
        MTSafeImageInspectorErrorLimitExceeded,
        @"encoded image bytes must be rejected before parsing");

    NSString *linkPath = [root stringByAppendingPathComponent:@"link.png"];
    MTAssert(symlink(validPath.fileSystemRepresentation,
                     linkPath.fileSystemRepresentation) == 0,
             @"image symlink fixture must be created");
    MTAssertImageFailure(inspector, [NSURL fileURLWithPath:linkPath], nil,
        MTSafeImageInspectorErrorUnsafeSource,
        @"the image gate must reject a symlink without following it");
    MTAssert(unlink(linkPath.fileSystemRepresentation) == 0,
             @"image symlink fixture must be removed exactly");

    NSString *hardlinkPath = [root stringByAppendingPathComponent:@"hard.png"];
    MTAssert(link(validPath.fileSystemRepresentation,
                  hardlinkPath.fileSystemRepresentation) == 0,
             @"image hardlink fixture must be created");
    MTAssertImageFailure(inspector, validURL, nil,
        MTSafeImageInspectorErrorUnsafeSource,
        @"the image gate must reject a multiply linked staging file");
    MTAssert(unlink(hardlinkPath.fileSystemRepresentation) == 0,
             @"image hardlink fixture must be removed exactly");

    MTAssert(chmod(validPath.fileSystemRepresentation, 0700) == 0,
             @"image executable-mode fixture must be created");
    MTAssertImageFailure(inspector, validURL, nil,
        MTSafeImageInspectorErrorUnsafeSource,
        @"an executable image staging file must be rejected");
    MTAssert(chmod(validPath.fileSystemRepresentation, 0600) == 0,
             @"image executable-mode fixture must be restored");

    MTAssert(chmod(validPath.fileSystemRepresentation, 0660) == 0,
             @"image shared-write fixture must be created");
    MTAssertImageFailure(inspector, validURL, nil,
        MTSafeImageInspectorErrorUnsafeSource,
        @"a group-writable image staging file must be rejected");
    MTAssert(chmod(validPath.fileSystemRepresentation, 0600) == 0,
             @"image shared-write fixture must be restored");

    MTImportCancellationToken *cancelled = [[MTImportCancellationToken alloc] init];
    [cancelled cancel];
    MTAssertImageFailure(inspector, validURL, cancelled,
        MTSafeImageInspectorErrorCancelled,
        @"pre-cancelled image inspection must not open the staging file");

    MTDeterministicCancellationToken *midInspection =
        [[MTDeterministicCancellationToken alloc] init];
    MTAssertImageFailure(inspector, validURL, midInspection,
        MTSafeImageInspectorErrorCancelled,
        @"chunk reads must expose deterministic cancellation points");

    MTImageMutationToken *mutation = [[MTImageMutationToken alloc]
        initWithPath:validPath triggerCount:5];
    MTAssertImageFailure(inspector, validURL, mutation,
        MTSafeImageInspectorErrorSourceChanged,
        @"source identity and mode must be revalidated after ImageIO");
    MTAssert(mutation.mutationSucceeded &&
             chmod(validPath.fileSystemRepresentation, 0600) == 0,
             @"source-mutation fixture must execute and restore safely");

    MTImageMutationToken *providerMutation = [[MTImageMutationToken alloc]
        initWithPath:validPath triggerCount:11];
    MTAssertImageFailure(inspector, validURL, providerMutation,
        MTSafeImageInspectorErrorSourceChanged,
        @"the ImageIO provider must reject a post-preflight source change");
    MTAssert(providerMutation.mutationSucceeded &&
             chmod(validPath.fileSystemRepresentation, 0600) == 0,
             @"ImageIO-provider mutation fixture must execute and restore safely");

    [NSFileManager.defaultManager removeItemAtPath:root error:NULL];
}

static void MTAssertImageDecodeFailure(
    MTSafeImageDecoder *decoder,
    NSURL *fileURL,
    uint32_t thumbnailMaximumDimension,
    MTImportCancellationToken *token,
    MTSafeImageDecoderErrorCode expectedCode,
    NSString *message) {
    NSError *error = nil;
    MTSafeImageDecodeResult *result = [decoder
        decodeOwnedPNGFileAtURL:fileURL
        thumbnailMaximumDimension:thumbnailMaximumDimension
        cancellationToken:token
        error:&error];
    MTAssert(result == nil &&
             [error.domain isEqualToString:MTSafeImageDecoderErrorDomain] &&
             error.code == expectedCode,
             [NSString stringWithFormat:@"%@ (%@/%ld: %@)", message,
                error.domain ?: @"no-domain", (long)error.code,
                error.localizedDescription ?: @"no error"]);
}

static MTSafeImageDecodeLimits *MTImageDecodeFixtureLimits(
    uint32_t fullDimension,
    uint64_t fullPixels,
    uint64_t fullBytes,
    uint32_t thumbnailDimension,
    uint64_t thumbnailBytes) {
    return [[MTSafeImageDecodeLimits alloc]
        initWithMaximumFullResolutionDimensionPixels:fullDimension
                  maximumFullResolutionPixelCount:fullPixels
                maximumFullResolutionDecodedBytes:fullBytes
                 maximumThumbnailDimensionPixels:thumbnailDimension
                         maximumThumbnailBytes:thumbnailBytes];
}

static void MTTestSafeImageDecoder(void) {
    NSString *root = MTCreateTemporaryDirectory(@"safe-image-decode");
    const uint8_t renderingIntent = 0;
    NSData *sRGBChunk = [NSData dataWithBytes:&renderingIntent length:1];
    NSData *validPNG = MTPNGFixtureData(2, 3, 8, 6, 0, YES,
        @[@{ @"type" : @"sRGB", @"data" : sRGBChunk }], @[]);
    NSString *validPath = MTWritePNGFixture(root, @"valid-srgb.png", validPNG);
    NSURL *validURL = [NSURL fileURLWithPath:validPath];
    MTSafeImageDecoder *decoder = MTSafeImageDecoder.defaultDecoder;
    NSError *error = nil;
    MTSafeImageDecodeResult *result = [decoder
        decodeOwnedPNGFileAtURL:validURL
        thumbnailMaximumDimension:512
        cancellationToken:nil
        error:&error];
    MTAssert(result != nil && error == nil &&
             result.inspection.pixelWidth == 2 &&
             result.inspection.pixelHeight == 3 &&
             result.thumbnailPixelWidth == 2 &&
             result.thumbnailPixelHeight == 3 &&
             result.thumbnailBytesPerRow == 8 &&
             result.thumbnailPixelData.length == 24 &&
             result.fullResolutionDecodedByteCount >= 24 &&
             [result.pixelFormat isEqualToString:
                 MTSafeImagePixelFormatRGBA8PremultipliedLast] &&
             [result.colorSpaceName isEqualToString:
                 MTSafeImageColorSpaceSRGB] &&
             MTStringIsLowercaseSHA256Digest(result.thumbnailPixelSHA256) &&
             !result.isDownsampled,
             [NSString stringWithFormat:
                @"a valid PNG must complete full decode and bounded sRGB normalization (%@/%ld: %@)",
                error.domain ?: @"no-domain", (long)error.code,
                error.localizedDescription ?: @"no error"]);
    const uint8_t *pixels = result.thumbnailPixelData.bytes;
    BOOL opaque = result.thumbnailPixelData.length == 24;
    for (NSUInteger offset = 3; opaque &&
         offset < result.thumbnailPixelData.length; offset += 4) {
        opaque = pixels[offset] == 0xff;
    }
    MTAssert(opaque,
        @"normalized RGBA8 output must preserve opaque alpha deterministically");
    const uint8_t expectedTopLeftPixels[] = {
        0, 0, 127, 255, 31, 0, 127, 255,
        0, 47, 127, 255, 31, 47, 127, 255,
        0, 94, 127, 255, 31, 94, 127, 255,
    };
    MTAssert([result.thumbnailPixelData isEqualToData:
        [NSData dataWithBytes:expectedTopLeftPixels
                       length:sizeof(expectedTopLeftPixels)]],
        [NSString stringWithFormat:
            @"normalized pixels must be exact top-left sRGB RGBA8 bytes (%@)",
            result.thumbnailPixelData]);

    const uint8_t paletteBytes[] = {0x11, 0x22, 0x33};
    const uint8_t oneBitGrayRaster[] = {0, 0x00};
    const uint8_t twoBitIndexedRaster[] = {0, 0x40};
    const uint8_t twoColorPalette[] = {
        0x11, 0x22, 0x33,
        0xaa, 0xbb, 0xcc,
    };
    const uint8_t paletteAlpha[] = {0xff, 0x00};
    NSArray<NSDictionary<NSString *, id> *> *acceptedFormats = @[
        @{ @"name" : @"rgb",
           @"data" : MTPNGFixtureData(1, 1, 8, 2, 0, YES, @[], @[]) },
        @{ @"name" : @"grayscale",
           @"data" : MTPNGFixtureData(1, 1, 8, 0, 0, YES, @[], @[]) },
        @{ @"name" : @"grayscale-alpha",
           @"data" : MTPNGFixtureData(1, 1, 8, 4, 0, YES, @[], @[]) },
        @{ @"name" : @"indexed",
           @"data" : MTPNGFixtureData(1, 1, 8, 3, 0, YES,
               @[@{ @"type" : @"PLTE",
                    @"data" : [NSData dataWithBytes:paletteBytes
                                               length:sizeof(paletteBytes)] }],
               @[]) },
        @{ @"name" : @"grayscale-1-bit",
           @"data" : MTPNGFixtureDataWithRaster(1, 1, 1, 0, 0, @[],
               [NSData dataWithBytes:oneBitGrayRaster
                              length:sizeof(oneBitGrayRaster)], NSData.data) },
        @{ @"name" : @"indexed-2-bit-alpha",
           @"data" : MTPNGFixtureDataWithRaster(1, 1, 2, 3, 0,
               @[@{ @"type" : @"PLTE",
                    @"data" : [NSData dataWithBytes:twoColorPalette
                                               length:sizeof(twoColorPalette)] },
                 @{ @"type" : @"tRNS",
                    @"data" : [NSData dataWithBytes:paletteAlpha
                                               length:sizeof(paletteAlpha)] }],
               [NSData dataWithBytes:twoBitIndexedRaster
                              length:sizeof(twoBitIndexedRaster)], NSData.data) },
    ];
    for (NSDictionary<NSString *, id> *format in acceptedFormats) {
        NSString *name = format[@"name"];
        NSString *path = MTWritePNGFixture(root,
            [name stringByAppendingPathExtension:@"png"], format[@"data"]);
        error = nil;
        MTSafeImageDecodeResult *formatResult = [decoder
            decodeOwnedPNGFileAtURL:[NSURL fileURLWithPath:path]
            thumbnailMaximumDimension:16
            cancellationToken:nil
            error:&error];
        MTAssert(formatResult != nil && error == nil &&
                 formatResult.thumbnailPixelData.length == 4,
            [NSString stringWithFormat:
                @"admitted %@ PNG pixels must normalize to RGBA8 (%@/%ld: %@)",
                name, error.domain ?: @"no-domain", (long)error.code,
                error.localizedDescription ?: @"no error"]);
    }

    const uint8_t transparentRGBValue[6] = {0, 0, 0, 0, 0, 127};
    NSData *transparency = [NSData dataWithBytes:transparentRGBValue
                                          length:sizeof(transparentRGBValue)];
    NSData *transparentRGB = MTPNGFixtureData(1, 1, 8, 2, 0, YES,
        @[@{ @"type" : @"tRNS", @"data" : transparency }], @[]);
    NSString *transparentPath = MTWritePNGFixture(
        root, @"rgb-transparency.png", transparentRGB);
    error = nil;
    MTSafeImageDecodeResult *transparent = [decoder
        decodeOwnedPNGFileAtURL:[NSURL fileURLWithPath:transparentPath]
        thumbnailMaximumDimension:16
        cancellationToken:nil
        error:&error];
    const uint8_t transparentPixel[] = {0, 0, 0, 0};
    MTAssert(transparent != nil && error == nil &&
             [transparent.thumbnailPixelData isEqualToData:
                 [NSData dataWithBytes:transparentPixel
                                length:sizeof(transparentPixel)]],
        @"tRNS transparency must survive bounded RGBA8 normalization");

    NSData *interlacedPNG = MTPNGFixtureData(
        7, 5, 8, 6, 1, YES, @[], @[]);
    NSString *interlacedPath = MTWritePNGFixture(
        root, @"adam7.png", interlacedPNG);
    error = nil;
    MTSafeImageDecodeResult *interlaced = [decoder
        decodeOwnedPNGFileAtURL:[NSURL fileURLWithPath:interlacedPath]
        thumbnailMaximumDimension:16
        cancellationToken:nil
        error:&error];
    MTAssert(interlaced != nil && error == nil &&
             interlaced.inspection.isInterlaced &&
             interlaced.thumbnailPixelWidth == 7 &&
             interlaced.thumbnailPixelHeight == 5 &&
             interlaced.thumbnailPixelData.length == 140,
             @"Adam7 passes must use exact scanline budgets before ImageIO decode");

    NSData *largePNG = MTPNGFixtureData(
        64, 32, 8, 6, 0, YES, @[], @[]);
    NSString *largePath = MTWritePNGFixture(root, @"large.png", largePNG);
    error = nil;
    MTSafeImageDecodeResult *thumbnail = [decoder
        decodeOwnedPNGFileAtURL:[NSURL fileURLWithPath:largePath]
        thumbnailMaximumDimension:16
        cancellationToken:nil
        error:&error];
    MTAssert(thumbnail != nil && error == nil &&
             thumbnail.thumbnailPixelWidth == 16 &&
             thumbnail.thumbnailPixelHeight == 8 &&
             thumbnail.thumbnailBytesPerRow == 64 &&
             thumbnail.thumbnailPixelData.length == 512 &&
             thumbnail.isDownsampled,
             @"thumbnail dimensions and storage must be bounded before allocation");

    NSData *invalidRaster = MTPNGFixtureData(
        2, 3, 8, 6, 0, NO, @[], @[]);
    NSString *invalidRasterPath = MTWritePNGFixture(
        root, @"invalid-idat.png", invalidRaster);
    error = nil;
    MTSafeImageInspection *metadataOnly = [MTSafeImageInspector.defaultInspector
        inspectOwnedPNGFileAtURL:[NSURL fileURLWithPath:invalidRasterPath]
        cancellationToken:nil
        error:&error];
    MTAssert(metadataOnly != nil && error == nil,
        @"the metadata-only gate must remain distinct from IDAT pixel decode");
    MTAssertImageDecodeFailure(decoder,
        [NSURL fileURLWithPath:invalidRasterPath], 64, nil,
        MTSafeImageDecoderErrorDecode,
        @"a structurally valid PNG with an invalid raster must fail full decode");

    const uint8_t invalidFilterBytes[] = {5, 0, 0, 0, 0};
    NSData *invalidFilterPNG = MTPNGFixtureDataWithRaster(
        1, 1, 8, 6, 0, @[],
        [NSData dataWithBytes:invalidFilterBytes
                       length:sizeof(invalidFilterBytes)], NSData.data);
    NSString *invalidFilterPath = MTWritePNGFixture(
        root, @"invalid-filter.png", invalidFilterPNG);
    MTAssertImageDecodeFailure(decoder,
        [NSURL fileURLWithPath:invalidFilterPath], 64, nil,
        MTSafeImageDecoderErrorDecode,
        @"a PNG scanline filter outside 0 through 4 must fail before ImageIO");

    const uint8_t excessRasterBytes[] = {0, 1, 2, 3, 0xff, 0};
    NSData *excessRasterPNG = MTPNGFixtureDataWithRaster(
        1, 1, 8, 6, 0, @[],
        [NSData dataWithBytes:excessRasterBytes
                       length:sizeof(excessRasterBytes)], NSData.data);
    NSString *excessRasterPath = MTWritePNGFixture(
        root, @"excess-raster.png", excessRasterPNG);
    MTAssertImageDecodeFailure(decoder,
        [NSURL fileURLWithPath:excessRasterPath], 64, nil,
        MTSafeImageDecoderErrorDecode,
        @"inflated bytes beyond the declared raster must fail before ImageIO");

    const uint8_t onePixelRaster[] = {0, 1, 2, 3, 0xff};
    const uint8_t compressedTail[] = {0xaa, 0xbb};
    NSData *trailingIDAT = MTPNGFixtureDataWithRaster(
        1, 1, 8, 6, 0, @[],
        [NSData dataWithBytes:onePixelRaster
                       length:sizeof(onePixelRaster)],
        [NSData dataWithBytes:compressedTail
                       length:sizeof(compressedTail)]);
    NSString *trailingIDATPath = MTWritePNGFixture(
        root, @"trailing-idat-stream.png", trailingIDAT);
    MTAssertImageDecodeFailure(decoder,
        [NSURL fileURLWithPath:trailingIDATPath], 64, nil,
        MTSafeImageDecoderErrorDecode,
        @"bytes after the zlib end marker inside IDAT must fail closed");

    MTSafeImageDecoder *dimensionDecoder = [[MTSafeImageDecoder alloc]
        initWithInspectionLimits:MTSafeImageLimits.defaultLimits
        decodeLimits:MTImageDecodeFixtureLimits(2, 64, 256, 16, 1024)];
    MTAssertImageDecodeFailure(dimensionDecoder, validURL, 16, nil,
        MTSafeImageDecoderErrorLimitExceeded,
        @"full decode dimensions must have a tighter independent ceiling");

    MTSafeImageDecoder *pixelDecoder = [[MTSafeImageDecoder alloc]
        initWithInspectionLimits:MTSafeImageLimits.defaultLimits
        decodeLimits:MTImageDecodeFixtureLimits(16, 5, 256, 16, 1024)];
    MTAssertImageDecodeFailure(pixelDecoder, validURL, 16, nil,
        MTSafeImageDecoderErrorLimitExceeded,
        @"full decode pixel count must have a tighter independent ceiling");

    MTSafeImageDecoder *fullByteDecoder = [[MTSafeImageDecoder alloc]
        initWithInspectionLimits:MTSafeImageLimits.defaultLimits
        decodeLimits:MTImageDecodeFixtureLimits(16, 64, 23, 16, 1024)];
    MTAssertImageDecodeFailure(fullByteDecoder, validURL, 16, nil,
        MTSafeImageDecoderErrorLimitExceeded,
        @"full-resolution decoded bytes must be rejected before ImageIO decode");

    MTSafeImageDecoder *thumbnailByteDecoder = [[MTSafeImageDecoder alloc]
        initWithInspectionLimits:MTSafeImageLimits.defaultLimits
        decodeLimits:MTImageDecodeFixtureLimits(16, 64, 256, 16, 23)];
    MTAssertImageDecodeFailure(thumbnailByteDecoder, validURL, 16, nil,
        MTSafeImageDecoderErrorLimitExceeded,
        @"normalized thumbnail bytes must have their own exact ceiling");

    MTAssertImageDecodeFailure(decoder, validURL, 0, nil,
        MTSafeImageDecoderErrorInvalidRequest,
        @"a zero thumbnail dimension must fail before source processing");
    MTAssertImageDecodeFailure(decoder, validURL,
        decoder.decodeLimits.maximumThumbnailDimensionPixels + 1U, nil,
        MTSafeImageDecoderErrorInvalidRequest,
        @"caller thumbnail requests cannot widen decoder policy");

    MTImportCancellationToken *cancelled =
        [[MTImportCancellationToken alloc] init];
    [cancelled cancel];
    MTAssertImageDecodeFailure(decoder, validURL, 64, cancelled,
        MTSafeImageDecoderErrorCancelled,
        @"pre-cancelled pixel decode must not open the staging file");

    MTThresholdCancellationToken *midDecode =
        [[MTThresholdCancellationToken alloc] initWithThreshold:16];
    MTAssertImageDecodeFailure(decoder,
        [NSURL fileURLWithPath:largePath], 16, midDecode,
        MTSafeImageDecoderErrorCancelled,
        @"pixel decode and render must retain deterministic cancellation points");
    MTAssert(midDecode.readCount >= 16,
        @"the threshold cancellation fixture must execute inside image processing");

    NSString *hardlinkPath = [root stringByAppendingPathComponent:@"hard.png"];
    MTAssert(link(validPath.fileSystemRepresentation,
                  hardlinkPath.fileSystemRepresentation) == 0,
        @"decoder hardlink fixture must be created");
    MTAssertImageDecodeFailure(decoder, validURL, 64, nil,
        MTSafeImageDecoderErrorSourceRejected,
        @"pixel decode must reuse the single-link owned-file trust boundary");
    MTAssert(unlink(hardlinkPath.fileSystemRepresentation) == 0,
        @"decoder hardlink fixture must be removed exactly");

    [NSFileManager.defaultManager removeItemAtPath:root error:NULL];
}

static NSUInteger MTSessionDirectoryCount(NSString *rootPath) {
    NSArray<NSString *> *entries = [NSFileManager.defaultManager
        contentsOfDirectoryAtPath:rootPath error:NULL];
    NSUInteger count = 0;
    for (NSString *entry in entries) {
        if ([entry hasPrefix:@"session-"]) count++;
    }
    return count;
}

static void MTTestImportSession(void) {
    NSString *testRoot = MTCreateTemporaryDirectory(@"import-session");
    NSString *sessionsPath = [testRoot
        stringByAppendingPathComponent:@"missing/parent/sessions"];
    MTImportLimits *limits = [[MTImportLimits alloc]
        initWithMaximumRegularFiles:16
               maximumExpandedBytes:4096
             maximumSingleFileBytes:1024
                   maximumPathDepth:8
               maximumPathUTF8Bytes:256];
    MTImportSessionConfiguration *configuration =
        [[MTImportSessionConfiguration alloc]
            initWithSessionsRootURL:[NSURL fileURLWithPath:sessionsPath
                                               isDirectory:YES]
                             limits:limits];
    NSError *error = nil;
    MTAssert([MTImportSession
        discardAbandonedSessionsWithConfiguration:configuration error:&error] &&
        error == nil && ![NSFileManager.defaultManager fileExistsAtPath:sessionsPath],
        @"orphan cleanup must be a no-op when the private root does not exist");

    NSString *sourcePath = [testRoot stringByAppendingPathComponent:@"theme.zip"];
    NSData *sourceData = [@"synthetic-theme-archive"
        dataUsingEncoding:NSUTF8StringEncoding];
    MTAssert([sourceData writeToFile:sourcePath options:NSDataWritingAtomic
                               error:&error],
        @"import-session source fixture must be written");
    MTImportSession *session = [MTImportSession
        sessionByImportingFileAtURL:[NSURL fileURLWithPath:sourcePath]
                      configuration:configuration
                  cancellationToken:nil
                              error:&error];
    NSString *sessionFailure = [NSString stringWithFormat:
        @"a regular file must produce a bounded private import session (%@/%ld: %@)",
        error.domain ?: @"no-domain", (long)error.code,
        error ?: @"no error"];
    MTAssert(session != nil && error == nil &&
             session.byteCount == sourceData.length,
        sessionFailure);
    NSData *copiedData = [NSData dataWithContentsOfURL:session.payloadURL];
    MTAssert([session.payloadURL.lastPathComponent isEqualToString:@"source.payload"] &&
             [copiedData isEqualToData:sourceData] &&
             ![session.payloadURL.path isEqualToString:sourcePath],
        @"the session must publish one fixed-name byte-identical private copy");
    struct stat directoryStatus = {0};
    struct stat payloadStatus = {0};
    MTAssert(lstat(session.sessionDirectoryURL.path.fileSystemRepresentation,
                   &directoryStatus) == 0 &&
             lstat(session.payloadURL.path.fileSystemRepresentation,
                   &payloadStatus) == 0 &&
             S_ISDIR(directoryStatus.st_mode) &&
             (directoryStatus.st_mode & 0777) == 0700 &&
             S_ISREG(payloadStatus.st_mode) && payloadStatus.st_nlink == 1 &&
             (payloadStatus.st_mode & 0777) == 0600,
        @"session directories and payloads must retain private verified modes");
    MTAssert([NSFileManager.defaultManager fileExistsAtPath:sourcePath],
        @"import acquisition must not remove the selected source");
    MTAssert([session discard:&error] &&
             ![NSFileManager.defaultManager
                 fileExistsAtPath:session.sessionDirectoryURL.path] &&
             [NSFileManager.defaultManager fileExistsAtPath:sourcePath],
        @"discard must remove only the exact private session");
    MTAssert([session discard:&error], @"session discard must be idempotent");

    MTImportLimits *tinyLimits = [[MTImportLimits alloc]
        initWithMaximumRegularFiles:1
               maximumExpandedBytes:4
             maximumSingleFileBytes:4
                   maximumPathDepth:1
               maximumPathUTF8Bytes:64];
    MTImportSessionConfiguration *tinyConfiguration =
        [[MTImportSessionConfiguration alloc]
            initWithSessionsRootURL:configuration.sessionsRootURL
                             limits:tinyLimits];
    error = nil;
    MTAssert([MTImportSession
        sessionByImportingFileAtURL:[NSURL fileURLWithPath:sourcePath]
                      configuration:tinyConfiguration
                  cancellationToken:nil error:&error] == nil &&
        [error.domain isEqualToString:MTImportSessionErrorDomain] &&
        error.code == MTImportSessionErrorLimitExceeded,
        @"a source larger than the acquisition limit must fail closed");
    MTAssert(MTSessionDirectoryCount(sessionsPath) == 0,
        @"a failed size gate must not leave a private session behind");

    MTImportCancellationToken *cancelled =
        [[MTImportCancellationToken alloc] init];
    [cancelled cancel];
    error = nil;
    MTAssert([MTImportSession
        sessionByImportingFileAtURL:[NSURL fileURLWithPath:sourcePath]
                      configuration:configuration
                  cancellationToken:cancelled error:&error] == nil &&
        error.code == MTImportSessionErrorCancelled &&
        MTSessionDirectoryCount(sessionsPath) == 0,
        @"a cancelled acquisition must fail before publishing any session");

    MTDeterministicCancellationToken *midCopyCancellation =
        [[MTDeterministicCancellationToken alloc] init];
    error = nil;
    MTAssert([MTImportSession
        sessionByImportingFileAtURL:[NSURL fileURLWithPath:sourcePath]
                      configuration:configuration
                  cancellationToken:midCopyCancellation error:&error] == nil &&
        error.code == MTImportSessionErrorCancelled &&
        MTSessionDirectoryCount(sessionsPath) == 0,
        @"cancellation after a partial write must remove the unpublished session");

    NSString *sourceLink = [testRoot stringByAppendingPathComponent:@"source-link.zip"];
    MTAssert(symlink(sourcePath.fileSystemRepresentation,
                     sourceLink.fileSystemRepresentation) == 0,
        @"import-session symlink source fixture must be created");
    error = nil;
    MTAssert([MTImportSession
        sessionByImportingFileAtURL:[NSURL fileURLWithPath:sourceLink]
                      configuration:configuration
                  cancellationToken:nil error:&error] == nil &&
        [error.domain isEqualToString:MTImportSessionErrorDomain] &&
        MTSessionDirectoryCount(sessionsPath) == 0,
        @"source acquisition must reject a symlink without following its target");
    MTAssert(unlink(sourceLink.fileSystemRepresentation) == 0,
        @"import-session symlink source fixture must be removed exactly");

    error = nil;
    MTImportSession *abandoned = [MTImportSession
        sessionByImportingFileAtURL:[NSURL fileURLWithPath:sourcePath]
                      configuration:configuration
                  cancellationToken:nil error:&error];
    MTAssert(abandoned != nil && MTSessionDirectoryCount(sessionsPath) == 1,
        @"orphan-cleanup fixture must create one owned session");
    NSString *unrelatedPath = [sessionsPath
        stringByAppendingPathComponent:@"not-owned-by-marktheme"];
    MTAssert([NSFileManager.defaultManager createDirectoryAtPath:unrelatedPath
                                      withIntermediateDirectories:NO
                                                       attributes:nil
                                                            error:&error],
        @"orphan cleanup must be tested beside an unrelated entry");
    error = nil;
    MTAssert([MTImportSession
        discardAbandonedSessionsWithConfiguration:configuration error:&error] &&
        MTSessionDirectoryCount(sessionsPath) == 0 &&
        [NSFileManager.defaultManager fileExistsAtPath:unrelatedPath],
        @"orphan cleanup must remove canonical sessions and preserve unrelated entries");
    MTAssert([abandoned discard:&error] &&
             [NSFileManager.defaultManager fileExistsAtPath:sourcePath],
        @"a live owner must tolerate its session having been swept at startup");
    [NSFileManager.defaultManager removeItemAtPath:unrelatedPath error:NULL];

    NSString *outsidePath = [testRoot stringByAppendingPathComponent:@"outside"];
    NSString *markerPath = [outsidePath stringByAppendingPathComponent:@"marker"];
    MTAssert([NSFileManager.defaultManager createDirectoryAtPath:outsidePath
                                      withIntermediateDirectories:NO
                                                       attributes:nil
                                                            error:&error] &&
             [@"keep" writeToFile:markerPath atomically:YES
                           encoding:NSUTF8StringEncoding error:&error],
        @"cleanup link-target fixture must contain a protected marker");
    NSString *maliciousIdentifier = [@"session-" stringByAppendingString:
        NSUUID.UUID.UUIDString.lowercaseString];
    NSString *maliciousPath = [sessionsPath
        stringByAppendingPathComponent:maliciousIdentifier];
    MTAssert(symlink(outsidePath.fileSystemRepresentation,
                     maliciousPath.fileSystemRepresentation) == 0,
        @"canonical-name cleanup symlink fixture must be created");
    error = nil;
    MTAssert(![MTImportSession
        discardAbandonedSessionsWithConfiguration:configuration error:&error] &&
        error.code == MTImportSessionErrorCleanup &&
        [NSFileManager.defaultManager fileExistsAtPath:markerPath],
        @"orphan cleanup must reject a canonical-name symlink and preserve its target");
    MTAssert(unlink(maliciousPath.fileSystemRepresentation) == 0,
        @"cleanup symlink fixture must be removed without following it");

    [NSFileManager.defaultManager removeItemAtPath:testRoot error:NULL];
}

static NSUInteger MTDirectorySnapshotSessionCount(NSString *rootPath) {
    NSArray<NSString *> *entries = [NSFileManager.defaultManager
        contentsOfDirectoryAtPath:rootPath error:NULL];
    NSUInteger count = 0;
    for (NSString *entry in entries) {
        if ([entry hasPrefix:@"directory-session-"]) count++;
    }
    return count;
}

static NSString *MTCreateDirectorySnapshotFixture(NSString *root,
                                                   NSString *name) {
    NSString *source = [root stringByAppendingPathComponent:name];
    NSString *nested = [source stringByAppendingPathComponent:@"Nested"];
    NSError *error = nil;
    MTAssert([NSFileManager.defaultManager createDirectoryAtPath:nested
                                      withIntermediateDirectories:YES
                                                       attributes:@{
        NSFilePosixPermissions : @0700
    } error:&error], @"directory snapshot fixture tree must be created");
    NSData *metadata = [@"snapshot-metadata"
        dataUsingEncoding:NSUTF8StringEncoding];
    NSData *payload = [NSMutableData dataWithLength:192 * 1024];
    MTAssert([metadata writeToFile:
        [source stringByAppendingPathComponent:@"Metadata.txt"]
                           options:0 error:&error] &&
             [payload writeToFile:
        [nested stringByAppendingPathComponent:@"Payload.bin"]
                          options:0 error:&error],
        @"directory snapshot fixture files must be written");
    return source;
}

static void MTTestDirectorySnapshotSession(void) {
    NSString *root = MTCreateTemporaryDirectory(@"directory-snapshot");
    NSString *sessionsPath = [root
        stringByAppendingPathComponent:@"missing/parent/sessions"];
    NSString *sourcePath = MTCreateDirectorySnapshotFixture(root, @"Source");
    MTImportLimits *limits = [[MTImportLimits alloc]
        initWithMaximumRegularFiles:16
              maximumArchiveEntries:32
                 maximumSourceBytes:1024 * 1024
               maximumExpandedBytes:1024 * 1024
             maximumSingleFileBytes:512 * 1024
       maximumArchiveExpansionRatio:100
                   maximumPathDepth:8
               maximumPathUTF8Bytes:256];
    MTDirectorySnapshotConfiguration *configuration =
        [[MTDirectorySnapshotConfiguration alloc]
            initWithSessionsRootURL:[NSURL fileURLWithPath:sessionsPath
                                               isDirectory:YES]
                             limits:limits
               minimumFreeSpaceReserveBytes:0];
    MTSafeDirectoryScanner *scanner = [[MTSafeDirectoryScanner alloc]
        initWithLimits:limits];
    NSError *error = nil;
    MTSafeDirectoryScan *external = [scanner
        scanDirectorySourceAtURL:[NSURL fileURLWithPath:sourcePath
                                           isDirectory:YES]
        cancellationToken:nil error:&error];
    MTDirectorySnapshotSession *session = [MTDirectorySnapshotSession
        sessionBySnapshottingDirectoryAtURL:
            [NSURL fileURLWithPath:sourcePath isDirectory:YES]
        configuration:configuration
        cancellationToken:nil
        auditor:^id<MTAuditedSource>(NSURL *candidateURL,
                                     NSError **auditError) {
            return [scanner scanDirectorySourceAtURL:candidateURL
                                   cancellationToken:nil error:auditError];
        }
        error:&error];
    NSString *validFailure = [NSString stringWithFormat:
        @"a safe directory must become an owned verified snapshot (%@/%ld: %@)",
        error.domain ?: @"no-domain", (long)error.code,
        error.localizedDescription ?: @"no error"];
    MTAssert(session != nil && external != nil && error == nil &&
             session.isActive && session.fileCount == 2 &&
             session.byteCount == external.inventory.totalBytes &&
             [session.sourceInventory.sourceFingerprint
                 isEqualToString:external.inventory.sourceFingerprint] &&
             [session.auditedSource.inventory.sourceFingerprint
                 isEqualToString:external.inventory.sourceFingerprint],
        validFailure);
    struct stat sessionStatus = {0};
    struct stat snapshotStatus = {0};
    struct stat fileStatus = {0};
    NSString *ownedMetadata = [session.snapshotDirectoryURL.path
        stringByAppendingPathComponent:@"Metadata.txt"];
    MTAssert(lstat(session.sessionDirectoryURL.path.fileSystemRepresentation,
                   &sessionStatus) == 0 &&
             lstat(session.snapshotDirectoryURL.path.fileSystemRepresentation,
                   &snapshotStatus) == 0 &&
             lstat(ownedMetadata.fileSystemRepresentation, &fileStatus) == 0 &&
             S_ISDIR(sessionStatus.st_mode) &&
             (sessionStatus.st_mode & 0777) == 0700 &&
             S_ISDIR(snapshotStatus.st_mode) &&
             (snapshotStatus.st_mode & 0777) == 0700 &&
             S_ISREG(fileStatus.st_mode) && fileStatus.st_nlink == 1 &&
             (fileStatus.st_mode & 0777) == 0600,
        @"owned snapshot directories and files must have exact private modes");
    MTAssert([NSFileManager.defaultManager removeItemAtPath:sourcePath
                                                       error:&error],
        @"external directory fixture must be removable after snapshot return");
    NSData *ownedData = [session.auditedSource
        readFileDataAtRelativePath:@"Metadata.txt"
                  maximumByteCount:1024
                 cancellationToken:nil error:&error];
    MTAssert([ownedData isEqualToData:[@"snapshot-metadata"
        dataUsingEncoding:NSUTF8StringEncoding]] && error == nil,
        @"returned audited source must remain readable after the external tree disappears");
    MTAssert([session discard:&error] && error == nil && !session.isActive &&
             MTDirectorySnapshotSessionCount(sessionsPath) == 0,
        @"snapshot discard must remove only the private owned tree");
    MTAssert([session discard:&error],
        @"directory snapshot discard must be idempotent");

    NSString *cancelSource = MTCreateDirectorySnapshotFixture(root,
                                                               @"CancelSource");
    MTImportCancellationToken *preCancelled =
        [[MTImportCancellationToken alloc] init];
    [preCancelled cancel];
    error = nil;
    MTAssert([MTDirectorySnapshotSession
        sessionBySnapshottingDirectoryAtURL:
            [NSURL fileURLWithPath:cancelSource isDirectory:YES]
        configuration:configuration cancellationToken:preCancelled
        auditor:^id<MTAuditedSource>(NSURL *candidateURL,
                                     NSError **auditError) {
            return [scanner scanDirectorySourceAtURL:candidateURL
                                   cancellationToken:preCancelled
                                               error:auditError];
        } error:&error] == nil &&
             error.code == MTDirectorySnapshotSessionErrorCancelled &&
             MTDirectorySnapshotSessionCount(sessionsPath) == 0,
        @"pre-cancelled directory snapshot must not create private residue");

    MTThresholdCancellationToken *midCopy =
        [[MTThresholdCancellationToken alloc] initWithThreshold:4];
    error = nil;
    MTAssert([MTDirectorySnapshotSession
        sessionBySnapshottingDirectoryAtURL:
            [NSURL fileURLWithPath:cancelSource isDirectory:YES]
        configuration:configuration cancellationToken:midCopy
        auditor:^id<MTAuditedSource>(NSURL *candidateURL,
                                     NSError **auditError) {
            return [scanner scanDirectorySourceAtURL:candidateURL
                                   cancellationToken:nil error:auditError];
        } error:&error] == nil &&
             error.code == MTDirectorySnapshotSessionErrorCancelled &&
             MTDirectorySnapshotSessionCount(sessionsPath) == 0,
        @"mid-copy cancellation must remove the unpublished directory snapshot");

    NSString *mutableMetadata = [cancelSource
        stringByAppendingPathComponent:@"Metadata.txt"];
    MTImageMutationToken *mutationToken = [[MTImageMutationToken alloc]
        initWithPath:mutableMetadata triggerCount:4];
    error = nil;
    MTAssert([MTDirectorySnapshotSession
        sessionBySnapshottingDirectoryAtURL:
            [NSURL fileURLWithPath:cancelSource isDirectory:YES]
        configuration:configuration cancellationToken:mutationToken
        auditor:^id<MTAuditedSource>(NSURL *candidateURL,
                                     NSError **auditError) {
            return [scanner scanDirectorySourceAtURL:candidateURL
                                   cancellationToken:nil error:auditError];
        } error:&error] == nil && mutationToken.mutationSucceeded &&
             error.code == MTDirectorySnapshotSessionErrorSourceRejected &&
             MTDirectorySnapshotSessionCount(sessionsPath) == 0,
        @"source metadata mutation during an audited stream must invalidate and clean the whole snapshot");
    MTAssert(chmod(mutableMetadata.fileSystemRepresentation, 0600) == 0,
        @"directory snapshot mutation fixture permissions must be restored");

    NSString *sourceLink = [root stringByAppendingPathComponent:@"SourceLink"];
    MTAssert(symlink(cancelSource.fileSystemRepresentation,
                     sourceLink.fileSystemRepresentation) == 0,
        @"directory snapshot source symlink fixture must be created");
    error = nil;
    MTAssert([MTDirectorySnapshotSession
        sessionBySnapshottingDirectoryAtURL:
            [NSURL fileURLWithPath:sourceLink isDirectory:YES]
        configuration:configuration cancellationToken:nil
        auditor:^id<MTAuditedSource>(NSURL *candidateURL,
                                     NSError **auditError) {
            return [scanner scanDirectorySourceAtURL:candidateURL
                                   cancellationToken:nil error:auditError];
        } error:&error] == nil &&
             error.code == MTDirectorySnapshotSessionErrorSourceAudit &&
             MTDirectorySnapshotSessionCount(sessionsPath) == 0 &&
             [NSFileManager.defaultManager fileExistsAtPath:cancelSource],
        @"directory snapshot acquisition must reject a source-root symlink without touching its target");
    MTAssert(unlink(sourceLink.fileSystemRepresentation) == 0,
        @"directory source symlink fixture must be removed without following it");

    MTImportCancellationToken *scanCancelled =
        [[MTImportCancellationToken alloc] init];
    [scanCancelled cancel];
    error = nil;
    MTAssert([scanner scanDirectorySourceAtURL:
        [NSURL fileURLWithPath:cancelSource isDirectory:YES]
        cancellationToken:scanCancelled error:&error] == nil &&
             [error.domain isEqualToString:
                 MTSafeDirectoryScannerErrorDomain] &&
             error.code == MTSafeDirectoryScannerErrorCancelled,
        @"directory hashing must expose a first-class cancellation result");

    MTDirectorySnapshotConfiguration *noSpaceConfiguration =
        [[MTDirectorySnapshotConfiguration alloc]
            initWithSessionsRootURL:configuration.sessionsRootURL
                             limits:limits
               minimumFreeSpaceReserveBytes:UINT64_MAX];
    error = nil;
    MTAssert([MTDirectorySnapshotSession
        sessionBySnapshottingDirectoryAtURL:
            [NSURL fileURLWithPath:cancelSource isDirectory:YES]
        configuration:noSpaceConfiguration cancellationToken:nil
        auditor:^id<MTAuditedSource>(NSURL *candidateURL,
                                     NSError **auditError) {
            return [scanner scanDirectorySourceAtURL:candidateURL
                                   cancellationToken:nil error:auditError];
        } error:&error] == nil &&
             error.code == MTDirectorySnapshotSessionErrorLimitExceeded &&
             MTDirectorySnapshotSessionCount(sessionsPath) == 0,
        @"deterministic no-space admission must fail before snapshot copying");

    __block NSUInteger auditInvocation = 0;
    error = nil;
    MTAssert([MTDirectorySnapshotSession
        sessionBySnapshottingDirectoryAtURL:
            [NSURL fileURLWithPath:cancelSource isDirectory:YES]
        configuration:configuration cancellationToken:nil
        auditor:^id<MTAuditedSource>(NSURL *candidateURL,
                                     NSError **auditError) {
            auditInvocation++;
            if (auditInvocation == 2) {
                NSString *path = [candidateURL.path
                    stringByAppendingPathComponent:@"Metadata.txt"];
                int descriptor = open(path.fileSystemRepresentation,
                                      O_WRONLY | O_TRUNC | O_CLOEXEC);
                NSData *replacement = [@"tampered-metadata"
                    dataUsingEncoding:NSUTF8StringEncoding];
                if (descriptor >= 0) {
                    write(descriptor, replacement.bytes, replacement.length);
                    fsync(descriptor);
                    close(descriptor);
                }
            }
            return [scanner scanDirectorySourceAtURL:candidateURL
                                   cancellationToken:nil error:auditError];
        } error:&error] == nil && auditInvocation == 2 &&
             error.code ==
                 MTDirectorySnapshotSessionErrorDestinationVerification &&
             MTDirectorySnapshotSessionCount(sessionsPath) == 0,
        @"destination re-audit must reject content changed after private copy");

    NSString *abandonedIdentifier = [@"directory-session-"
        stringByAppendingString:NSUUID.UUID.UUIDString.lowercaseString];
    NSString *partialRoot = [[sessionsPath
        stringByAppendingPathComponent:abandonedIdentifier]
        stringByAppendingPathComponent:@".snapshot.partial"];
    NSString *partialNested = [partialRoot
        stringByAppendingPathComponent:@"Nested"];
    MTAssert([NSFileManager.defaultManager
        createDirectoryAtPath:partialNested
        withIntermediateDirectories:YES attributes:nil error:&error] &&
             chmod([sessionsPath stringByAppendingPathComponent:
                abandonedIdentifier].fileSystemRepresentation, 0700) == 0 &&
             chmod(partialRoot.fileSystemRepresentation, 0700) == 0 &&
             chmod(partialNested.fileSystemRepresentation, 0700) == 0 &&
             [@"partial" writeToFile:[partialNested
                stringByAppendingPathComponent:@"file"] atomically:YES
                encoding:NSUTF8StringEncoding error:&error] &&
             chmod([partialNested stringByAppendingPathComponent:@"file"]
                .fileSystemRepresentation, 0600) == 0,
        @"abandoned unpublished snapshot fixture must be created safely");
    NSString *unrelatedFileSession = [sessionsPath
        stringByAppendingPathComponent:[@"session-"
            stringByAppendingString:NSUUID.UUID.UUIDString.lowercaseString]];
    MTAssert([NSFileManager.defaultManager
        createDirectoryAtPath:unrelatedFileSession
        withIntermediateDirectories:NO attributes:nil error:&error],
        @"directory recovery must be tested beside a file-session namespace");
    error = nil;
    MTAssert([MTDirectorySnapshotSession
        discardAbandonedSessionsWithConfiguration:configuration
        error:&error] && error == nil &&
             MTDirectorySnapshotSessionCount(sessionsPath) == 0 &&
             [NSFileManager.defaultManager
                 fileExistsAtPath:unrelatedFileSession],
        @"startup recovery must remove safe partial snapshots and preserve other session kinds");
    [NSFileManager.defaultManager removeItemAtPath:unrelatedFileSession
                                             error:NULL];

    NSString *publishedIdentifier = [@"directory-session-"
        stringByAppendingString:NSUUID.UUID.UUIDString.lowercaseString];
    NSString *publishedRoot = [[sessionsPath
        stringByAppendingPathComponent:publishedIdentifier]
        stringByAppendingPathComponent:@"snapshot"];
    MTAssert([NSFileManager.defaultManager
        createDirectoryAtPath:publishedRoot
        withIntermediateDirectories:YES attributes:nil error:&error] &&
             chmod([sessionsPath stringByAppendingPathComponent:
                publishedIdentifier].fileSystemRepresentation, 0700) == 0 &&
             chmod(publishedRoot.fileSystemRepresentation, 0700) == 0 &&
             [@"published" writeToFile:[publishedRoot
                stringByAppendingPathComponent:@"file"] atomically:YES
                encoding:NSUTF8StringEncoding error:&error] &&
             chmod([publishedRoot stringByAppendingPathComponent:@"file"]
                .fileSystemRepresentation, 0600) == 0,
        @"abandoned published snapshot fixture must be created safely");
    error = nil;
    MTAssert([MTDirectorySnapshotSession
        discardAbandonedSessionsWithConfiguration:configuration
        error:&error] && error == nil &&
             MTDirectorySnapshotSessionCount(sessionsPath) == 0,
        @"startup recovery must also remove a complete abandoned published snapshot");

    NSString *outside = [root stringByAppendingPathComponent:@"outside"];
    NSString *outsideMarker = [outside
        stringByAppendingPathComponent:@"marker"];
    MTAssert([NSFileManager.defaultManager
        createDirectoryAtPath:outside withIntermediateDirectories:NO
        attributes:nil error:&error] &&
             [@"keep" writeToFile:outsideMarker atomically:YES
                encoding:NSUTF8StringEncoding error:&error],
        @"snapshot cleanup symlink target must contain a protected marker");
    NSString *linkedIdentifier = [@"directory-session-"
        stringByAppendingString:NSUUID.UUID.UUIDString.lowercaseString];
    NSString *linkedPartial = [[sessionsPath
        stringByAppendingPathComponent:linkedIdentifier]
        stringByAppendingPathComponent:@".snapshot.partial"];
    MTAssert([NSFileManager.defaultManager
        createDirectoryAtPath:linkedPartial
        withIntermediateDirectories:YES attributes:nil error:&error] &&
             chmod([sessionsPath stringByAppendingPathComponent:
                linkedIdentifier].fileSystemRepresentation, 0700) == 0 &&
             chmod(linkedPartial.fileSystemRepresentation, 0700) == 0 &&
             symlink(outsideMarker.fileSystemRepresentation,
                [linkedPartial stringByAppendingPathComponent:@"link"]
                    .fileSystemRepresentation) == 0,
        @"snapshot cleanup symlink fixture must be created");
    error = nil;
    MTAssert(![MTDirectorySnapshotSession
        discardAbandonedSessionsWithConfiguration:configuration
        error:&error] &&
             error.code == MTDirectorySnapshotSessionErrorCleanup &&
             [NSFileManager.defaultManager fileExistsAtPath:outsideMarker],
        @"snapshot recovery must refuse symlinks without touching their target");
    [NSFileManager.defaultManager removeItemAtPath:
        [sessionsPath stringByAppendingPathComponent:linkedIdentifier]
                                             error:NULL];

    NSString *unsafeIdentifier = [@"directory-session-"
        stringByAppendingString:NSUUID.UUID.UUIDString.lowercaseString];
    NSString *unsafeSession = [sessionsPath
        stringByAppendingPathComponent:unsafeIdentifier];
    MTAssert([NSFileManager.defaultManager
        createDirectoryAtPath:unsafeSession
        withIntermediateDirectories:NO attributes:nil error:&error] &&
             chmod(unsafeSession.fileSystemRepresentation, 0700) == 0 &&
             [@"unknown" writeToFile:[unsafeSession
                stringByAppendingPathComponent:@"unexpected"] atomically:YES
                encoding:NSUTF8StringEncoding error:&error],
        @"unknown snapshot-root cleanup fixture must be created");
    error = nil;
    MTAssert(![MTDirectorySnapshotSession
        discardAbandonedSessionsWithConfiguration:configuration
        error:&error] &&
             error.code == MTDirectorySnapshotSessionErrorCleanup &&
             [NSFileManager.defaultManager fileExistsAtPath:unsafeSession],
        @"startup recovery must fail closed on an unknown snapshot root node");
    [NSFileManager.defaultManager removeItemAtPath:unsafeSession error:NULL];

    [NSFileManager.defaultManager removeItemAtPath:root error:NULL];
}

static NSData *MTPropertyListFixtureData(id object,
                                         NSPropertyListFormat format) {
    NSError *error = nil;
    NSData *data = [NSPropertyListSerialization
        dataWithPropertyList:object format:format options:0 error:&error];
    MTAssert(data != nil && error == nil,
             [NSString stringWithFormat:
                @"property-list fixture must serialize (%@)",
                error.localizedDescription ?: @"no error"]);
    return data;
}

static void MTAssertPropertyListFailure(
    MTSafePropertyListReader *reader,
    NSData *data,
    MTImportCancellationToken *token,
    MTSafePropertyListReaderErrorCode expectedCode,
    NSString *message) {
    NSError *error = nil;
    MTSafePropertyListDocument *document = [reader
        readPropertyListData:data cancellationToken:token error:&error];
    MTAssert(document == nil &&
             [error.domain isEqualToString:MTSafePropertyListReaderErrorDomain] &&
             error.code == expectedCode,
             [NSString stringWithFormat:@"%@ (%@/%ld: %@)", message,
                error.domain ?: @"no-domain", (long)error.code,
                error.localizedDescription ?: @"no error"]);
}

static void MTTestSafePropertyListReader(void) {
    MTSafePropertyListReader *reader = [[MTSafePropertyListReader alloc]
        initWithLimits:MTSafePropertyListLimits.defaultLimits];
    NSMutableData *mutablePayload = [NSMutableData
        dataWithData:[@"payload" dataUsingEncoding:NSUTF8StringEncoding]];
    NSString *decomposedKey = @"Cafe\u0301";
    NSDictionary *fixture = @{
        decomposedKey : @"The\u0301me",
        @"Enabled" : @YES,
        @"Count" : @7,
        @"Opacity" : @0.75,
        @"Released" : [NSDate dateWithTimeIntervalSinceReferenceDate:1234],
        @"Payload" : mutablePayload,
        @"Nested" : @[@{ @"Name" : @"Nested" }],
    };
    NSError *error = nil;
    NSData *xml = MTPropertyListFixtureData(
        fixture, NSPropertyListXMLFormat_v1_0);
    MTSafePropertyListDocument *xmlDocument = [reader
        readPropertyListData:xml cancellationToken:nil error:&error];
    MTAssert(xmlDocument != nil && error == nil &&
             xmlDocument.format == NSPropertyListXMLFormat_v1_0 &&
             xmlDocument.nodeCount > fixture.count &&
             xmlDocument.maximumObservedDepth == 4 &&
             xmlDocument.aggregateScalarBytes > 0,
             @"valid XML plist must pass the bounded normalization walk");
    MTAssert([xmlDocument.rootDictionary[@"Café"] isEqualToString:@"Théme"] &&
             xmlDocument.rootDictionary[decomposedKey] == nil,
             @"plist strings and keys must normalize to NFC");
    MTAssert(xmlDocument.rootDictionary != fixture &&
             xmlDocument.rootDictionary[@"Nested"] != fixture[@"Nested"] &&
             xmlDocument.rootDictionary[@"Payload"] != mutablePayload,
             @"caller-owned plist objects must not cross the reader boundary");

    error = nil;
    NSData *binary = MTPropertyListFixtureData(
        fixture, NSPropertyListBinaryFormat_v1_0);
    MTSafePropertyListDocument *binaryDocument = [reader
        readPropertyListData:binary cancellationToken:nil error:&error];
    MTAssert(binaryDocument != nil && error == nil &&
             binaryDocument.format == NSPropertyListBinaryFormat_v1_0 &&
             [binaryDocument.rootDictionary[@"Café"] isEqualToString:@"Théme"],
             @"valid binary plist must use the same normalized contract as XML");

    MTAssertPropertyListFailure(reader,
        [@"not a property list" dataUsingEncoding:NSUTF8StringEncoding], nil,
        MTSafePropertyListReaderErrorMalformed,
        @"malformed plist bytes must fail closed");
    MTAssertPropertyListFailure(reader,
        MTPropertyListFixtureData(@[@"not-a-dictionary"],
                                  NSPropertyListXMLFormat_v1_0), nil,
        MTSafePropertyListReaderErrorInvalidRoot,
        @"plist array roots must not enter theme metadata mapping");
    MTAssertPropertyListFailure(reader,
        [@"{ Name = Theme; }" dataUsingEncoding:NSUTF8StringEncoding], nil,
        MTSafePropertyListReaderErrorUnsupportedFormat,
        @"ambiguous legacy OpenStep plist syntax must be rejected");

    MTSafePropertyListLimits *tight = [[MTSafePropertyListLimits alloc]
        initWithMaximumInputBytes:4096
                     maximumDepth:3
                     maximumNodes:8
         maximumCollectionEntries:2
               maximumKeyUTF8Bytes:8
            maximumStringUTF8Bytes:12
                    maximumDataBytes:4
         maximumAggregateScalarBytes:24];
    MTSafePropertyListReader *tightReader = [[MTSafePropertyListReader alloc]
        initWithLimits:tight];
    MTAssertPropertyListFailure(tightReader,
        MTPropertyListFixtureData(@{ @"A" : @[@[@[@"too-deep"]]] },
                                  NSPropertyListBinaryFormat_v1_0), nil,
        MTSafePropertyListReaderErrorLimitExceeded,
        @"plist nesting must stop at the configured depth");
    MTSafePropertyListLimits *nodeLimits = [[MTSafePropertyListLimits alloc]
        initWithMaximumInputBytes:4096
                     maximumDepth:8
                     maximumNodes:4
         maximumCollectionEntries:16
               maximumKeyUTF8Bytes:8
            maximumStringUTF8Bytes:12
                    maximumDataBytes:4
         maximumAggregateScalarBytes:24];
    MTAssertPropertyListFailure(
        [[MTSafePropertyListReader alloc] initWithLimits:nodeLimits],
        MTPropertyListFixtureData(@{ @"A" : @1, @"B" : @2 },
                                  NSPropertyListBinaryFormat_v1_0), nil,
        MTSafePropertyListReaderErrorLimitExceeded,
        @"plist node counting must include dictionary keys and values");
    MTAssertPropertyListFailure(tightReader,
        MTPropertyListFixtureData(@{ @"A" : @1, @"B" : @2, @"C" : @3 },
                                  NSPropertyListBinaryFormat_v1_0), nil,
        MTSafePropertyListReaderErrorLimitExceeded,
        @"each plist collection must respect its entry limit");
    MTAssertPropertyListFailure(tightReader,
        MTPropertyListFixtureData(@{ @"LongKey12" : @1 },
                                  NSPropertyListBinaryFormat_v1_0), nil,
        MTSafePropertyListReaderErrorLimitExceeded,
        @"plist keys must respect their UTF-8 byte limit");
    MTAssertPropertyListFailure(tightReader,
        MTPropertyListFixtureData(@{ @"A" : @"1234567890123" },
                                  NSPropertyListBinaryFormat_v1_0), nil,
        MTSafePropertyListReaderErrorLimitExceeded,
        @"plist strings must respect their UTF-8 byte limit");
    MTAssertPropertyListFailure(tightReader,
        MTPropertyListFixtureData(@{ @"A" : [NSMutableData dataWithLength:5] },
                                  NSPropertyListBinaryFormat_v1_0), nil,
        MTSafePropertyListReaderErrorLimitExceeded,
        @"plist data values must respect their byte limit");

    MTSafePropertyListLimits *aggregateLimits =
        [[MTSafePropertyListLimits alloc]
            initWithMaximumInputBytes:4096
                         maximumDepth:8
                         maximumNodes:64
             maximumCollectionEntries:16
                   maximumKeyUTF8Bytes:8
                maximumStringUTF8Bytes:16
                        maximumDataBytes:16
             maximumAggregateScalarBytes:16];
    MTSafePropertyListReader *aggregateReader =
        [[MTSafePropertyListReader alloc] initWithLimits:aggregateLimits];
    MTAssertPropertyListFailure(aggregateReader,
        MTPropertyListFixtureData(@{ @"A" : @"12345678", @"B" : @"12345678" },
                                  NSPropertyListBinaryFormat_v1_0), nil,
        MTSafePropertyListReaderErrorLimitExceeded,
        @"aggregate scalar bytes must bound repeated binary-plist references");

    MTSafePropertyListLimits *tinyInput = [[MTSafePropertyListLimits alloc]
        initWithMaximumInputBytes:16
                     maximumDepth:8
                     maximumNodes:64
         maximumCollectionEntries:16
               maximumKeyUTF8Bytes:8
            maximumStringUTF8Bytes:16
                    maximumDataBytes:16
         maximumAggregateScalarBytes:16];
    MTAssertPropertyListFailure(
        [[MTSafePropertyListReader alloc] initWithLimits:tinyInput], xml, nil,
        MTSafePropertyListReaderErrorLimitExceeded,
        @"plist source bytes must be bounded before Foundation parsing");

    NSString *collisionXML =
        @"<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
         "<plist version=\"1.0\"><dict>"
         "<key>Café</key><string>one</string>"
         "<key>Cafe\u0301</key><string>two</string>"
         "</dict></plist>";
    MTAssertPropertyListFailure(reader,
        [collisionXML dataUsingEncoding:NSUTF8StringEncoding], nil,
        MTSafePropertyListReaderErrorCanonicalCollision,
        @"NFC-equivalent plist keys must never overwrite one another");

    MTImportCancellationToken *cancelled =
        [[MTImportCancellationToken alloc] init];
    [cancelled cancel];
    MTAssertPropertyListFailure(reader, xml, cancelled,
        MTSafePropertyListReaderErrorCancelled,
        @"pre-cancelled plist validation must not enter Foundation parsing");
    MTAssertPropertyListFailure(reader, xml,
        [[MTDeterministicCancellationToken alloc] init],
        MTSafePropertyListReaderErrorCancelled,
        @"plist normalization must observe mid-walk cancellation");
}

static MTThemeImportMetadata *MTTestThemeInfoMetadataMapper(void) {
    NSDictionary *fixture = @{
        @"CFBundleDisplayName" : @"  Mark The\u0301me  ",
        @"CFBundleName" : @"Fallback Name",
        @"CFBundleShortVersionString" : @" 1.2.3 ",
        @"CFBundleVersion" : @"4",
        @"Author" : @"Unverified Author Key",
        @"PackageName" : @"Unverified Package Key",
    };
    MTSafePropertyListReader *reader = [[MTSafePropertyListReader alloc]
        initWithLimits:MTSafePropertyListLimits.defaultLimits];
    NSError *error = nil;
    MTSafePropertyListDocument *document = [reader
        readPropertyListData:MTPropertyListFixtureData(
            fixture, NSPropertyListBinaryFormat_v1_0)
        cancellationToken:nil
        error:&error];
    MTThemeImportMetadata *metadata = [[[MTThemeInfoMetadataMapper alloc] init]
        mapDocument:document sourceName:@"Source.theme" error:&error];
    MTThemeDisplayMetadata *display = metadata.displayMetadata;
    MTAssert(metadata != nil && error == nil &&
             [display.profileID isEqualToString:
                 MTThemeInfoMetadataProfileCoreFoundationBundleV1] &&
             [display.displayName isEqualToString:@"Mark Théme"] &&
             [display.themeVersion isEqualToString:@"1.2.3"] &&
             display.author.length == 0 &&
             !display.usedSourceNameFallback &&
             metadata.moduleConfigurations.count == 0,
             @"bundle metadata profile must normalize only display-safe fields");
    MTAssert([display.displayNameSourceKey
                 isEqualToString:@"CFBundleDisplayName"] &&
             [display.themeVersionSourceKey
                 isEqualToString:@"CFBundleShortVersionString"] &&
             display.recognizedFieldCount == 5 &&
             metadata.diagnostics.count == 0,
             @"metadata precedence and recognized-field accounting must be explicit");

    NSDictionary *fallbackFixture = @{
        @"CFBundleDisplayName" : @42,
        @"CFBundleName" : @"Fallback Name",
        @"CFBundleShortVersionString" : @[@"invalid-type"],
        @"CFBundleVersion" : @"7",
    };
    error = nil;
    MTSafePropertyListDocument *fallbackDocument = [reader
        readPropertyListData:MTPropertyListFixtureData(
            fallbackFixture, NSPropertyListXMLFormat_v1_0)
        cancellationToken:nil
        error:&error];
    MTThemeImportMetadata *fallback = [[[MTThemeInfoMetadataMapper alloc] init]
        mapDocument:fallbackDocument sourceName:@"Ignored.theme" error:&error];
    MTThemeDisplayMetadata *fallbackDisplay = fallback.displayMetadata;
    MTAssert(fallback != nil && error == nil &&
             [fallbackDisplay.displayName isEqualToString:@"Fallback Name"] &&
             [fallbackDisplay.themeVersion isEqualToString:@"7"] &&
             [fallbackDisplay.displayNameSourceKey isEqualToString:@"CFBundleName"] &&
             [fallbackDisplay.themeVersionSourceKey isEqualToString:@"CFBundleVersion"],
             @"invalid primary metadata must diagnose and use the documented fallback key");
    MTAssert(fallbackDisplay.recognizedFieldCount == 2 &&
             fallback.diagnostics.count == 2 &&
             [fallback.diagnostics.firstObject.code
                 isEqualToString:@"import.metadata.invalid-known-field"],
             @"known metadata type failures must remain visible to Import Review");

    error = nil;
    MTSafePropertyListDocument *unknownDocument = [reader
        readPropertyListData:MTPropertyListFixtureData(
            @{ @"Author" : @"Still Unverified" },
            NSPropertyListXMLFormat_v1_0)
        cancellationToken:nil
        error:&error];
    MTThemeImportMetadata *sourceFallback =
        [[[MTThemeInfoMetadataMapper alloc] init]
            mapDocument:unknownDocument
              sourceName:@"Folder.theme"
                   error:&error];
    MTThemeDisplayMetadata *sourceFallbackDisplay =
        sourceFallback.displayMetadata;
    MTAssert(sourceFallback != nil && error == nil &&
             [sourceFallbackDisplay.displayName isEqualToString:@"Folder"] &&
             sourceFallbackDisplay.author.length == 0 &&
             sourceFallbackDisplay.recognizedFieldCount == 0 &&
             sourceFallbackDisplay.usedSourceNameFallback,
             @"unverified theme keys must not override the safe source-name fallback");

    error = nil;
    MTSafePropertyListDocument *packageNameDocument = [reader
        readPropertyListData:MTPropertyListFixtureData(
            @{ @"PackageName" : @"Oxyg3n" },
            NSPropertyListXMLFormat_v1_0)
        cancellationToken:nil error:&error];
    MTThemeImportMetadata *packageNameMetadata =
        [[[MTThemeInfoMetadataMapper alloc] init]
            mapDocument:packageNameDocument
              sourceName:@"Package.theme"
                   error:&error];
    MTAssert(packageNameMetadata != nil && error == nil &&
             [packageNameMetadata.displayMetadata.displayName
                 isEqualToString:@"Oxyg3n"] &&
             [packageNameMetadata.displayMetadata.displayNameSourceKey
                 isEqualToString:@"PackageName"] &&
             !packageNameMetadata.displayMetadata.usedSourceNameFallback,
        @"SnowBoard PackageName must be the final display-name fallback");

    NSDictionary *calendarFixture = @{
        @"CalendarIconDaySettings" : @{
            @"FontSize" : @6,
            @"TextColor" : @"#FFF",
            @"TextYoffset" : @"7",
        },
        @"CalendarIconDateSettings" : @{
            @"FontAlpha" : @"0.8",
            @"FontName" : @"HelveticaNeue-Regular",
            @"FontSize" : @20,
            @"TextColor" : @"#444242",
            @"TextYoffset" : @14,
        },
    };
    error = nil;
    MTSafePropertyListDocument *calendarDocument = [reader
        readPropertyListData:MTPropertyListFixtureData(
            calendarFixture, NSPropertyListXMLFormat_v1_0)
        cancellationToken:nil
        error:&error];
    MTThemeImportMetadata *calendarMetadata =
        [[[MTThemeInfoMetadataMapper alloc] init]
            mapDocument:calendarDocument
              sourceName:@"Calendar.theme"
                   error:&error];
    NSDictionary *calendarDictionary =
        calendarMetadata.moduleConfigurations[MTCalendarIconsModuleID];
    MTCalendarIconConfiguration *calendar = calendarDictionary == nil ? nil :
        [[MTCalendarIconConfiguration alloc]
            initWithDictionary:calendarDictionary error:&error];
    MTAssert(calendarMetadata != nil && calendar != nil && error == nil &&
             calendarMetadata.recognizedModuleConfigurationCount == 1 &&
             calendarMetadata.diagnostics.count == 0 &&
             calendar.dayStyle.fontSizeMilliPoints == 6000 &&
             [calendar.dayStyle.fontName isEqualToString:@"HelveticaNeue"] &&
             calendar.dayStyle.yOffsetMilliPoints == 7000 &&
             [calendar.dayStyle.textColorRGB isEqualToString:@"ffffff"] &&
             calendar.dateStyle.fontSizeMilliPoints == 20000 &&
             [calendar.dateStyle.fontName isEqualToString:@"HelveticaNeue"] &&
             calendar.dateStyle.alphaPermille == 800 &&
             calendar.dateStyle.yOffsetMilliPoints == 14000,
             @"Calendar metadata must normalize the real-theme style into deterministic fixed-point values");

    NSMutableDictionary *invalidCalendarFixture = [calendarFixture mutableCopy];
    invalidCalendarFixture[@"CalendarIconDateSettings"] = @{
        @"FontName" : @"HelveticaNeue-Regular",
        @"FontSize" : @20,
        @"TextColor" : @"not-a-color",
        @"TextYoffset" : @14,
    };
    error = nil;
    MTSafePropertyListDocument *invalidCalendarDocument = [reader
        readPropertyListData:MTPropertyListFixtureData(
            invalidCalendarFixture, NSPropertyListXMLFormat_v1_0)
        cancellationToken:nil
        error:&error];
    MTThemeImportMetadata *invalidCalendar =
        [[[MTThemeInfoMetadataMapper alloc] init]
            mapDocument:invalidCalendarDocument
              sourceName:@"Invalid.theme"
                   error:&error];
    MTAssert(invalidCalendar != nil && error == nil &&
             invalidCalendar.moduleConfigurations.count == 0 &&
             invalidCalendar.diagnostics.count == 1 &&
             [invalidCalendar.diagnostics.firstObject.code
                 isEqualToString:@"import.metadata.invalid-calendar-settings"],
             @"invalid Calendar settings must be dropped as one visible module diagnostic");

    error = nil;
    MTSafePropertyListDocument *iconMaskDocument = [reader
        readPropertyListData:MTPropertyListFixtureData(
            @{
                @"IB-MaskIcons" : @YES,
                @"PackageName" : @"display-only-unverified",
            },
            NSPropertyListBinaryFormat_v1_0)
        cancellationToken:nil
        error:&error];
    MTThemeImportMetadata *iconMaskMetadata =
        [[[MTThemeInfoMetadataMapper alloc] init]
            mapDocument:iconMaskDocument
              sourceName:@"Mask.theme"
                   error:&error];
    MTIconMaskConfiguration *iconMask =
        [[MTIconMaskConfiguration alloc]
            initWithDictionary:
                iconMaskMetadata.moduleConfigurations[MTIconMaskModuleID]
            error:&error];
    MTAssert(iconMaskMetadata != nil && iconMask != nil &&
             iconMask.isEnabled && error == nil &&
             iconMaskMetadata.recognizedModuleConfigurationCount == 1 &&
             iconMaskMetadata.diagnostics.count == 0,
             @"IB-MaskIcons=true must become one typed module-owned enablement");

    error = nil;
    MTSafePropertyListDocument *invalidIconMaskDocument = [reader
        readPropertyListData:MTPropertyListFixtureData(
            @{ @"IB-MaskIcons" : @1 }, NSPropertyListXMLFormat_v1_0)
        cancellationToken:nil
        error:&error];
    MTThemeImportMetadata *invalidIconMask =
        [[[MTThemeInfoMetadataMapper alloc] init]
            mapDocument:invalidIconMaskDocument
              sourceName:@"Invalid-Mask.theme"
                   error:&error];
    MTAssert(invalidIconMask != nil && error == nil &&
             invalidIconMask.moduleConfigurations.count == 0 &&
             invalidIconMask.diagnostics.count == 1 &&
             [invalidIconMask.diagnostics.firstObject.code
                 isEqualToString:
                    @"import.metadata.invalid-icon-mask-setting"] &&
             [invalidIconMask.diagnostics.firstObject.details[@"profile"]
                 isEqualToString:
                    MTThemeInfoMetadataProfileIconBundlesMaskV1],
             @"non-Boolean IB-MaskIcons must remain a visible ignored setting");

    MTStaticIconConfiguration *orderedMatching = [MTStaticIconConfiguration
        configurationWithFuzzyBundleIdentifiers:@[
            @"example.target", @"com.example.target",
        ]
        bundleAliases:@{
            @"TEAM.com.example.target" : @"com.example.missing",
        }];
    NSArray<NSString *> *orderedCandidates = [orderedMatching
        themedBundleIdentifierCandidatesForRequestedIdentifier:
            @"TEAM.com.example.target"];
    MTAssert([orderedCandidates isEqualToArray:@[
                 @"com.example.missing", @"com.example.target",
                 @"example.target",
             ]] &&
             [[orderedMatching
                 themedBundleIdentifierForRequestedIdentifier:
                     @"TEAM.com.example.target"]
                 isEqualToString:@"com.example.missing"] &&
             [orderedMatching
                 themedBundleIdentifierCandidatesForRequestedIdentifier:
                     @"../invalid"].count == 0,
        @"static icon matching must preserve alias-first lookup while exposing every deterministic fuzzy fallback");

    MTThemeInfoMetadataMapper *matchingMapper =
        [[MTThemeInfoMetadataMapper alloc] init];
    MTSafePropertyListDocument *dualAliasDocument = [reader
        readPropertyListData:MTPropertyListFixtureData(@{
            @"BundleAliases" : @{
                @"shared.alias" : @"com.example.legacy",
                @"legacy.only" : @"com.example.legacy",
            },
            @"MarkThemeBundleAliases" : @{
                @"SHARED.ALIAS" : @"com.example.preferred",
                @"preferred.only" : @"com.example.preferred",
            },
        }, NSPropertyListXMLFormat_v1_0)
        cancellationToken:nil error:&error];
    MTThemeImportMetadata *dualAliasMetadata = [matchingMapper
        mapDocument:dualAliasDocument sourceName:@"Aliases.theme"
        error:&error];
    MTStaticIconConfiguration *dualAliasConfiguration =
        [[MTStaticIconConfiguration alloc] initWithDictionary:
            dualAliasMetadata.moduleConfigurations[@"icons.static"]
                                                     error:&error];
    MTAssert(dualAliasConfiguration.bundleAliases.count == 3 &&
             [[[dualAliasConfiguration
                 themedBundleIdentifierCandidatesForRequestedIdentifier:
                     @"shared.alias"] firstObject]
                 isEqualToString:@"com.example.preferred"] &&
             [dualAliasConfiguration.bundleAliases[@"legacy.only"]
                 isEqualToString:@"com.example.legacy"] &&
             [dualAliasConfiguration.bundleAliases[@"preferred.only"]
                 isEqualToString:@"com.example.preferred"] &&
             dualAliasMetadata.diagnostics.count == 1 &&
             [dualAliasMetadata.diagnostics.firstObject.code
                 isEqualToString:@"import.metadata.invalid-bundle-matching"] &&
             error == nil,
        @"MarkTheme aliases must override only conflicting legacy aliases while retaining nonconflicting keys from both Info fields");

    NSMutableArray<NSString *> *primaryFuzzy = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSString *> *primaryAliases =
        [NSMutableDictionary dictionary];
    for (NSUInteger index = 0;
         index < MTStaticIconMaximumFuzzyBundleIdentifierCount; index++) {
        NSString *identifier = [NSString stringWithFormat:
            @"com.example.primary%03lu", (unsigned long)index];
        [primaryFuzzy addObject:identifier];
        primaryAliases[[NSString stringWithFormat:
            @"alias%03lu.example", (unsigned long)index]] = identifier;
    }
    MTSafePropertyListDocument *primaryMatchingDocument = [reader
        readPropertyListData:MTPropertyListFixtureData(@{
            @"FuzzyBundleIdentifiers" : primaryFuzzy,
            @"BundleAliases" : primaryAliases,
        }, NSPropertyListBinaryFormat_v1_0)
        cancellationToken:nil error:&error];
    MTThemeImportMetadata *primaryMatching = [matchingMapper
        mapDocument:primaryMatchingDocument
        sourceName:@"Primary.theme" error:&error];
    MTSafePropertyListDocument *componentMatchingDocument = [reader
        readPropertyListData:MTPropertyListFixtureData(@{
            @"FuzzyBundleIdentifiers" : @[
                @"com.example.primary000", @"com.example.overflow",
            ],
            @"MarkThemeBundleAliases" : @{
                @"ALIAS000.EXAMPLE" : @"com.example.conflict",
                @"overflow.alias" : @"com.example.overflow",
            },
        }, NSPropertyListXMLFormat_v1_0)
        cancellationToken:nil error:&error];
    MTThemeImportMetadata *componentMatching = [matchingMapper
        mapDocument:componentMatchingDocument
        sourceName:@"Component.theme" error:&error];
    MTThemeImportMetadata *mergedMatching = [matchingMapper
        metadataByMergingPrimaryMetadata:primaryMatching
        componentMetadata:@[componentMatching]];
    MTStaticIconConfiguration *mergedConfiguration =
        [[MTStaticIconConfiguration alloc] initWithDictionary:
            mergedMatching.moduleConfigurations[@"icons.static"]
                                                     error:&error];
    NSCountedSet<NSString *> *matchingDiagnosticCodes = [NSCountedSet set];
    for (MTDiagnostic *diagnostic in mergedMatching.diagnostics) {
        [matchingDiagnosticCodes addObject:diagnostic.code];
    }
    MTAssert(primaryMatching != nil && componentMatching != nil &&
             mergedConfiguration != nil && error == nil &&
             mergedConfiguration.fuzzyBundleIdentifiers.count ==
                 MTStaticIconMaximumFuzzyBundleIdentifierCount &&
             [mergedConfiguration.fuzzyBundleIdentifiers
                 containsObject:@"com.example.primary000"] &&
             ![mergedConfiguration.fuzzyBundleIdentifiers
                 containsObject:@"com.example.overflow"] &&
             mergedConfiguration.bundleAliases.count ==
                 MTStaticIconMaximumBundleAliasCount &&
             [mergedConfiguration.bundleAliases[@"alias000.example"]
                 isEqualToString:@"com.example.primary000"] &&
             mergedConfiguration.bundleAliases[@"overflow.alias"] == nil &&
             [matchingDiagnosticCodes countForObject:
                 @"import.metadata.fuzzy-bundle-identifiers-truncated"] == 1 &&
             [matchingDiagnosticCodes countForObject:
                 @"import.metadata.bundle-aliases-truncated"] == 1 &&
             [matchingDiagnosticCodes countForObject:
                 @"import.metadata.bundle-alias-shadowed"] == 1,
        @"component Info matching must deduplicate and bound merged hints without dropping the primary configuration");
    return metadata;
}

static NSData *MTSyntheticPNGData(NSString *payload) {
    static const unsigned char signature[] = {
        0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a
    };
    NSMutableData *data = [NSMutableData dataWithBytes:signature
                                               length:sizeof(signature)];
    [data appendData:[payload dataUsingEncoding:NSUTF8StringEncoding]];
    return data;
}

static NSString *MTCreateIconBundlesFixture(NSString *label, BOOL reversed) {
    NSString *root = MTCreateTemporaryDirectory(label);
    NSString *icons = [root stringByAppendingPathComponent:@"IconBundles"];
    NSError *error = nil;
    MTAssert([NSFileManager.defaultManager createDirectoryAtPath:icons
                                     withIntermediateDirectories:NO
                                                      attributes:@{
        NSFilePosixPermissions : @0700
    } error:&error], @"synthetic IconBundles directory must be created");
    NSArray<NSString *> *names = reversed ? @[
        @"com.example.Bad-large.png",
        @"com.example.Beta@3x.png",
        @"com.apple.AppStore-large.png",
    ] : @[
        @"com.apple.AppStore-large.png",
        @"com.example.Beta@3x.png",
        @"com.example.Bad-large.png",
    ];
    for (NSString *name in names) {
        NSData *data = [name containsString:@"Bad"]
            ? [@"not a png" dataUsingEncoding:NSUTF8StringEncoding]
            : MTSyntheticPNGData(name);
        MTAssert([data writeToFile:[icons stringByAppendingPathComponent:name]
                           options:0 error:&error],
                 @"synthetic icon must be written");
    }
    NSData *info = [@"<?xml version=\"1.0\"?><plist version=\"1.0\"><dict/></plist>"
        dataUsingEncoding:NSUTF8StringEncoding];
    MTAssert([info writeToFile:[root stringByAppendingPathComponent:@"Info.plist"]
                       options:0 error:&error],
             @"synthetic metadata must be written");
    return root;
}

static void MTAssertZIPFailure(MTSafeZIPArchiveReader *reader,
                               NSString *archivePath,
                               MTImportCancellationToken *token,
                               MTSafeZIPArchiveReaderErrorCode expectedCode,
                               NSString *message) {
    NSError *error = nil;
    MTSafeZIPArchiveScan *scan = [reader
        scanArchiveAtURL:[NSURL fileURLWithPath:archivePath]
        cancellationToken:token
        error:&error];
    MTAssert(scan == nil &&
             [error.domain isEqualToString:MTSafeZIPArchiveReaderErrorDomain] &&
             error.code == expectedCode,
             [NSString stringWithFormat:@"%@ (%@/%ld: %@)", message,
                error.domain ?: @"no-domain", (long)error.code,
                error.localizedDescription ?: @"no error"]);
}

static void MTAssertAuditedReadFailure(
    id<MTAuditedSource> source,
    NSString *relativePath,
    uint64_t maximumByteCount,
    MTImportCancellationToken *token,
    MTAuditedSourceErrorCode expectedCode,
    NSString *message) {
    NSError *error = nil;
    NSData *data = [source readFileDataAtRelativePath:relativePath
                                     maximumByteCount:maximumByteCount
                                    cancellationToken:token
                                                error:&error];
    MTAssert(data == nil &&
             [error.domain isEqualToString:MTAuditedSourceErrorDomain] &&
             error.code == expectedCode,
             [NSString stringWithFormat:@"%@ (%@/%ld: %@)", message,
                error.domain ?: @"no-domain", (long)error.code,
                error.localizedDescription ?: @"no error"]);
}

static void MTTestSafeZIPArchiveReader(void) {
    NSString *root = MTCreateTemporaryDirectory(@"safe-zip");
    NSString *directoryRoot = MTCreateIconBundlesFixture(@"zip-equivalent", NO);
    NSData *containerInfo = MTPropertyListFixtureData(@{
        @"CFBundleDisplayName" : @"Container Theme",
        @"CFBundleShortVersionString" : @"2.4.0",
        @"Author" : @"Unverified Author",
    }, NSPropertyListBinaryFormat_v1_0);
    NSError *error = nil;
    MTAssert([containerInfo writeToFile:
        [directoryRoot stringByAppendingPathComponent:@"Info.plist"]
                              options:0 error:&error],
        @"container-neutral metadata fixture must be written");
    NSArray<NSString *> *relativeFiles = @[
        @"IconBundles/com.apple.AppStore-large.png",
        @"IconBundles/com.example.Beta@3x.png",
        @"IconBundles/com.example.Bad-large.png",
        @"Info.plist",
    ];
    NSMutableArray<NSDictionary<NSString *, id> *> *validEntries =
        [NSMutableArray arrayWithObject:@{
            @"name" : @"IconBundles/",
            @"data" : NSData.data,
            @"mode" : @(S_IFDIR | 0755),
        }];
    for (NSUInteger index = 0; index < relativeFiles.count; index++) {
        NSString *relativePath = relativeFiles[index];
        NSData *data = [NSData dataWithContentsOfFile:
            [directoryRoot stringByAppendingPathComponent:relativePath]];
        MTAssert(data != nil, @"ZIP equivalence fixture source must be readable");
        [validEntries addObject:@{
            @"name" : relativePath,
            @"data" : data,
            @"method" : @(index == 1 ? 8 : 0),
        }];
    }
    NSString *validPath = MTWriteZIPFixture(root, @"valid.zip", validEntries);
    MTSafeZIPArchiveReader *reader = [[MTSafeZIPArchiveReader alloc]
        initWithLimits:MTImportLimits.defaultLimits];
    error = nil;
    MTSafeZIPArchiveScan *validScan = [reader
        scanArchiveAtURL:[NSURL fileURLWithPath:validPath]
        cancellationToken:nil
        error:&error];
    NSString *validFailure = [NSString stringWithFormat:
        @"stored/deflated ZIP must pass both audit phases (%@/%ld: %@)",
        error.domain ?: @"no-domain", (long)error.code,
        error.localizedDescription ?: @"no error"];
    MTAssert(validScan != nil && error == nil &&
             validScan.archiveEntryCount == 5 &&
             validScan.inventory.files.count == 4 &&
             validScan.totalCompressedBytes > 0,
             validFailure);
    NSString *macPackagingPath = MTWriteZIPFixture(root,
        @"mac-packaging.zip", @[
        @{ @"name" : @"Info.plist", @"data" : containerInfo },
        @{ @"name" : @".DS_Store", @"data" : [@"finder"
            dataUsingEncoding:NSUTF8StringEncoding] },
        @{ @"name" : @"__MACOSX/", @"mode" : @(S_IFDIR | 0755) },
        @{ @"name" : @"__MACOSX/._Info.plist", @"data" : [@"appledouble"
            dataUsingEncoding:NSUTF8StringEncoding] },
    ]);
    error = nil;
    MTSafeZIPArchiveScan *macPackagingScan = [reader
        scanArchiveAtURL:[NSURL fileURLWithPath:macPackagingPath]
        cancellationToken:nil error:&error];
    MTAssert(macPackagingScan != nil && error == nil &&
             macPackagingScan.archiveEntryCount == 4 &&
             macPackagingScan.inventory.files.count == 1 &&
             [macPackagingScan.inventory
                 fileAtRelativePath:@"Info.plist"] != nil &&
             [macPackagingScan.inventory
                 fileAtRelativePath:@".DS_Store"] == nil,
        @"macOS AppleDouble and Finder entries may be hidden by libarchive without invalidating required ZIP content");
    NSString *unflaggedUTF8Path = MTWriteZIPFixture(root,
        @"unflagged-utf8.zip", @[
        @{
            @"name" : @"尺玉/",
            @"flags" : @0,
            @"mode" : @(S_IFDIR | 0755),
        },
        @{
            @"name" : @"尺玉/Info.plist",
            @"flags" : @0,
            @"data" : containerInfo,
        },
    ]);
    error = nil;
    MTSafeZIPArchiveScan *unflaggedUTF8Scan = [reader
        scanArchiveAtURL:[NSURL fileURLWithPath:unflaggedUTF8Path]
        cancellationToken:nil error:&error];
    MTAssert(unflaggedUTF8Scan != nil && error == nil &&
             [unflaggedUTF8Scan.inventory
                fileAtRelativePath:@"尺玉/Info.plist"] != nil,
        @"strict UTF-8 ZIP names must remain usable when a legacy creator omits the language flag");
    MTSafeDirectoryScan *directoryScan = [[[MTSafeDirectoryScanner alloc]
        initWithLimits:MTImportLimits.defaultLimits]
        scanDirectorySourceAtURL:
            [NSURL fileURLWithPath:directoryRoot isDirectory:YES]
        error:&error];
    MTSourceInventory *directoryInventory = directoryScan.inventory;
    MTAssert(directoryInventory != nil &&
             [validScan.inventory.sourceFingerprint
                 isEqualToString:directoryInventory.sourceFingerprint],
             @"ZIP and directory containers must produce the same source inventory");
    error = nil;
    NSData *zipInfo = [validScan
        readFileDataAtRelativePath:@"Info.plist"
                  maximumByteCount:
                      MTSafePropertyListLimits.defaultLimits.maximumInputBytes
                 cancellationToken:nil error:&error];
    NSData *directoryInfo = [directoryScan
        readFileDataAtRelativePath:@"Info.plist"
                  maximumByteCount:
                      MTSafePropertyListLimits.defaultLimits.maximumInputBytes
                 cancellationToken:nil error:&error];
    MTAssert(zipInfo != nil && directoryInfo != nil && error == nil &&
             [zipInfo isEqualToData:containerInfo] &&
             [directoryInfo isEqualToData:containerInfo],
             @"both audited containers must reproduce the exact inventoried metadata bytes");
    NSString *deflatedRelativePath =
        @"IconBundles/com.example.Beta@3x.png";
    NSData *expectedDeflatedData = [NSData dataWithContentsOfFile:
        [directoryRoot stringByAppendingPathComponent:deflatedRelativePath]];
    error = nil;
    NSData *directDeflatedData = [validScan
        readFileDataAtRelativePath:deflatedRelativePath
                  maximumByteCount:expectedDeflatedData.length
                 cancellationToken:nil error:&error];
    MTAssert(directDeflatedData != nil && error == nil &&
             [directDeflatedData isEqualToData:expectedDeflatedData],
             @"an audited deflate entry must support exact offset-bound direct reads");
    __block NSMutableData *zipStreamData = [NSMutableData data];
    __block NSMutableData *directoryStreamData = [NSMutableData data];
    error = nil;
    BOOL zipStreamed = [validScan
        streamFileAtRelativePath:@"Info.plist"
                maximumByteCount:containerInfo.length
               cancellationToken:nil
                    byteConsumer:^BOOL(const void *bytes, NSUInteger length,
                                       __unused NSError **consumerError) {
        [zipStreamData appendBytes:bytes length:length];
        return YES;
    }
                           error:&error];
    BOOL directoryStreamed = [directoryScan
        streamFileAtRelativePath:@"Info.plist"
                maximumByteCount:containerInfo.length
               cancellationToken:nil
                    byteConsumer:^BOOL(const void *bytes, NSUInteger length,
                                       __unused NSError **consumerError) {
        [directoryStreamData appendBytes:bytes length:length];
        return YES;
    }
                           error:&error];
    MTAssert(zipStreamed && directoryStreamed && error == nil &&
             [zipStreamData isEqualToData:containerInfo] &&
             [directoryStreamData isEqualToData:containerInfo],
             @"directory and ZIP streams must deliver identical audited chunks");

    NSError *expectedConsumerError = [NSError
        errorWithDomain:@"com.hmmzzz.marktheme.tests.consumer"
                   code:41
               userInfo:@{NSLocalizedDescriptionKey : @"stop"}];
    error = nil;
    BOOL consumerAccepted = [directoryScan
        streamFileAtRelativePath:@"Info.plist"
                maximumByteCount:containerInfo.length
               cancellationToken:nil
                    byteConsumer:^BOOL(__unused const void *bytes,
                                       __unused NSUInteger length,
                                       NSError **consumerError) {
        if (consumerError != NULL) *consumerError = expectedConsumerError;
        return NO;
    }
                           error:&error];
    MTAssert(!consumerAccepted && error == expectedConsumerError,
             @"audited streams must stop immediately and preserve a consumer error");
    error = nil;
    BOOL zipConsumerAccepted = [validScan
        streamFileAtRelativePath:deflatedRelativePath
                maximumByteCount:expectedDeflatedData.length
               cancellationToken:nil
                    byteConsumer:^BOOL(__unused const void *bytes,
                                       __unused NSUInteger length,
                                       NSError **consumerError) {
        if (consumerError != NULL) *consumerError = expectedConsumerError;
        return NO;
    }
                           error:&error];
    MTAssert(!zipConsumerAccepted && error == expectedConsumerError,
             @"direct ZIP streams must stop immediately and preserve a consumer error");
    MTAssertAuditedReadFailure(validScan, @"Missing.plist", 1024, nil,
        MTAuditedSourceErrorNotInventoried,
        @"ZIP reads must reject paths absent from the immutable inventory");
    MTAssertAuditedReadFailure(directoryScan, @"Missing.plist", 1024, nil,
        MTAuditedSourceErrorNotInventoried,
        @"directory reads must reject paths absent from the immutable inventory");
    MTAssertAuditedReadFailure(validScan, @"Info.plist",
        containerInfo.length - 1, nil, MTAuditedSourceErrorLimitExceeded,
        @"ZIP reads must honor the caller's smaller byte limit");
    MTAssertAuditedReadFailure(directoryScan, @"Info.plist",
        containerInfo.length - 1, nil, MTAuditedSourceErrorLimitExceeded,
        @"directory reads must honor the caller's smaller byte limit");
    MTImportCancellationToken *readCancelled =
        [[MTImportCancellationToken alloc] init];
    [readCancelled cancel];
    MTAssertAuditedReadFailure(validScan, @"Info.plist",
        containerInfo.length, readCancelled, MTAuditedSourceErrorCancelled,
        @"ZIP audited reads must stop before opening when pre-cancelled");
    MTThresholdCancellationToken *directReadCancelled =
        [[MTThresholdCancellationToken alloc] initWithThreshold:2];
    MTAssertAuditedReadFailure(validScan, deflatedRelativePath,
        expectedDeflatedData.length, directReadCancelled,
        MTAuditedSourceErrorCancelled,
        @"direct deflate reads must honor cancellation after opening");
    MTAssertAuditedReadFailure(directoryScan, @"Info.plist",
        containerInfo.length, readCancelled, MTAuditedSourceErrorCancelled,
        @"directory audited reads must stop before opening when pre-cancelled");

    MTThemeInfoMetadataImporter *metadataImporter =
        [[MTThemeInfoMetadataImporter alloc] init];
    error = nil;
    MTThemeImportMetadata *zipMetadata = [metadataImporter
        importMetadataFromSource:validScan
                      sourceName:@"Fixture.theme"
               cancellationToken:nil error:&error];
    MTThemeImportMetadata *directoryMetadata = [metadataImporter
        importMetadataFromSource:directoryScan
                      sourceName:@"Fixture.theme"
               cancellationToken:nil error:&error];
    MTAssert(zipMetadata != nil && directoryMetadata != nil && error == nil &&
             [zipMetadata.displayMetadata.displayName
                 isEqualToString:@"Container Theme"] &&
             [zipMetadata.displayMetadata.themeVersion
                 isEqualToString:@"2.4.0"] &&
             [zipMetadata.displayMetadata.displayName
                 isEqualToString:directoryMetadata.displayMetadata.displayName] &&
             [zipMetadata.displayMetadata.themeVersion
                 isEqualToString:directoryMetadata.displayMetadata.themeVersion] &&
             zipMetadata.displayMetadata.author.length == 0,
             @"root Info.plist metadata import must be container-neutral and display-only");
    MTIconBundlesImporter *importer = [[MTIconBundlesImporter alloc] init];
    MTIconBundlesImportResult *zipImport = [importer
        importSourceInventory:validScan.inventory
                    sourceName:@"Fixture.theme"
                importMetadata:zipMetadata
                         error:&error];
    MTIconBundlesImportResult *directoryImport = [importer
        importSourceInventory:directoryInventory
                    sourceName:@"Fixture.theme"
                importMetadata:directoryMetadata
                         error:&error];
    MTAssert(zipImport != nil && directoryImport != nil &&
             zipImport.manifest.importerVersion == 3 &&
             [zipImport.manifest.displayName
                 isEqualToString:@"Container Theme"] &&
             [[[zipImport manifest] contentDigestWithError:&error]
                 isEqualToString:[[directoryImport manifest]
                    contentDigestWithError:&error]],
             @"metadata and resources must remain container-neutral through manifest creation");

    NSString *traversal = MTWriteZIPFixture(root, @"traversal.zip", @[@{
        @"name" : @"../escape.png", @"data" : MTSyntheticPNGData(@"escape")
    }]);
    MTAssertZIPFailure(reader, traversal, nil,
        MTSafeZIPArchiveReaderErrorUnsafePath,
        @"ZIP path traversal must fail before streaming");

    const unsigned char legacyNameBytes[] = {
        'I', 'c', 'o', 'n', 's', '/', 0xff, '.', 'p', 'n', 'g'
    };
    NSString *undecodableLegacy = MTWriteZIPFixture(root,
        @"undecodable-legacy-name.zip", @[@{
        @"nameData" : [NSData dataWithBytes:legacyNameBytes
                                      length:sizeof(legacyNameBytes)],
        @"flags" : @0,
        @"data" : MTSyntheticPNGData(@"legacy-name"),
    }]);
    MTAssertZIPFailure(reader, undecodableLegacy, nil,
        MTSafeZIPArchiveReaderErrorUnsupportedFeature,
        @"non-ASCII legacy ZIP names must still fail when their bytes are not strict UTF-8");

    NSString *collision = MTWriteZIPFixture(root, @"collision.zip", @[
        @{@"name" : @"Icons/A.png", @"data" : MTSyntheticPNGData(@"a")},
        @{@"name" : @"icons/a.png", @"data" : MTSyntheticPNGData(@"b")},
    ]);
    MTAssertZIPFailure(reader, collision, nil,
        MTSafeZIPArchiveReaderErrorCanonicalCollision,
        @"case-folded archive path collisions must fail closed");

    NSString *parentCollision = MTWriteZIPFixture(root, @"parent.zip", @[
        @{@"name" : @"node", @"data" : [@"file" dataUsingEncoding:NSUTF8StringEncoding]},
        @{@"name" : @"node/child.png", @"data" : MTSyntheticPNGData(@"child")},
    ]);
    MTAssertZIPFailure(reader, parentCollision, nil,
        MTSafeZIPArchiveReaderErrorCanonicalCollision,
        @"a regular archive file must never become a parent directory");

    // A symlink is never theme content. It must never reach the inventory --
    // that is what keeps a link pointing outside the tree from being followed
    // -- but an archive that merely carries one beside real artwork still has
    // to import, so the entry is excluded rather than failing the package.
    NSString *symlinkArchive = MTWriteZIPFixture(root, @"symlink.zip", @[
        @{ @"name" : @"Icons/link.png",
           @"data" : [@"../../outside" dataUsingEncoding:NSUTF8StringEncoding],
           @"mode" : @(S_IFLNK | 0777) },
        @{ @"name" : @"Icons/real.png",
           @"data" : MTSyntheticPNGData(@"real") },
    ]);
    error = nil;
    MTSafeZIPArchiveScan *symlinkScan = [reader
        scanArchiveAtURL:[NSURL fileURLWithPath:symlinkArchive]
        cancellationToken:nil error:&error];
    MTAssert(symlinkScan != nil && error == nil &&
             [symlinkScan.inventory
                 fileAtRelativePath:@"Icons/link.png"] == nil &&
             [symlinkScan.inventory
                 fileAtRelativePath:@"Icons/real.png"] != nil,
        @"archive symlinks must be excluded without failing the import");

    // An archive whose only entries are unusable still has nothing to import,
    // and must say so rather than producing an empty theme.
    NSString *symlinkOnly = MTWriteZIPFixture(root, @"symlink-only.zip", @[@{
        @"name" : @"Icons/link.png",
        @"data" : [@"../../outside" dataUsingEncoding:NSUTF8StringEncoding],
        @"mode" : @(S_IFLNK | 0777),
    }]);
    MTAssertZIPFailure(reader, symlinkOnly, nil,
        MTSafeZIPArchiveReaderErrorLimitExceeded,
        @"an archive with no usable content must still be refused");

    NSString *executable = MTWriteZIPFixture(root, @"executable.zip", @[@{
        @"name" : @"Icons/run.png",
        @"data" : MTSyntheticPNGData(@"run"),
        @"mode" : @(S_IFREG | 0755),
    }]);
    error = nil;
    MTSafeZIPArchiveScan *executableScan = [reader
        scanArchiveAtURL:[NSURL fileURLWithPath:executable]
        cancellationToken:nil error:&error];
    MTAssert(executableScan != nil && error == nil &&
             [executableScan.inventory fileAtRelativePath:@"Icons/run.png"] != nil,
        @"archive executable bits on data resources must be ignored");

    // Permission bits are never applied: resources are copied into the App's
    // own storage under its own modes and are only ever read as image data.
    // Refusing artwork over a set-user-ID bit cost the user a whole theme for
    // metadata that import discards anyway.
    NSString *privileged = MTWriteZIPFixture(root, @"privileged.zip", @[@{
        @"name" : @"Icons/privileged.png",
        @"data" : MTSyntheticPNGData(@"privileged"),
        @"mode" : @(S_IFREG | 04755),
    }]);
    error = nil;
    MTSafeZIPArchiveScan *privilegedScan = [reader
        scanArchiveAtURL:[NSURL fileURLWithPath:privileged]
        cancellationToken:nil error:&error];
    MTAssert(privilegedScan != nil && error == nil &&
             [privilegedScan.inventory
                 fileAtRelativePath:@"Icons/privileged.png"] != nil,
        @"privileged permission bits must not cost the user the import");

    // A bundled archive is packaging debris, not theme content. It must stay
    // out of the inventory (it is never expanded) without costing the user
    // the rest of an otherwise importable theme.
    NSString *nestedName = MTWriteZIPFixture(root, @"nested-name.zip", @[
        @{ @"name" : @"Payload/inner.zip",
           @"data" : [@"not opened" dataUsingEncoding:NSUTF8StringEncoding] },
        @{ @"name" : @"Icons/keep.png",
           @"data" : MTSyntheticPNGData(@"keep") },
    ]);
    error = nil;
    MTSafeZIPArchiveScan *nestedNameScan = [reader
        scanArchiveAtURL:[NSURL fileURLWithPath:nestedName]
        cancellationToken:nil error:&error];
    MTAssert(nestedNameScan != nil && error == nil &&
             [nestedNameScan.inventory
                 fileAtRelativePath:@"Payload/inner.zip"] == nil &&
             [nestedNameScan.inventory
                 fileAtRelativePath:@"Icons/keep.png"] != nil,
        @"nested archive extensions must be ignored without failing the import");

    const unsigned char nestedMagicBytes[] = {
        0x50, 0x4b, 0x03, 0x04, 'n', 'e', 's', 't', 'e', 'd'
    };
    NSString *nestedMagic = MTWriteZIPFixture(root, @"nested-magic.zip", @[
        @{ @"name" : @"Payload/disguised.png",
           @"data" : [NSData dataWithBytes:nestedMagicBytes
                                    length:sizeof(nestedMagicBytes)] },
        @{ @"name" : @"Icons/keep.png",
           @"data" : MTSyntheticPNGData(@"keep") },
    ]);
    error = nil;
    MTSafeZIPArchiveScan *nestedMagicScan = [reader
        scanArchiveAtURL:[NSURL fileURLWithPath:nestedMagic]
        cancellationToken:nil error:&error];
    MTAssert(nestedMagicScan != nil && error == nil &&
             [nestedMagicScan.inventory
                 fileAtRelativePath:@"Payload/disguised.png"] == nil &&
             [nestedMagicScan.inventory
                 fileAtRelativePath:@"Icons/keep.png"] != nil,
        @"nested archive magic must be ignored without failing the import");

    // Import must be generous: a ZIP that carries theme content alongside
    // documents, fonts, sidecar archives and unknown binaries has to import
    // the parts that are recognizable and quietly drop the rest. Refusing the
    // whole package over a file that would never have been used is the single
    // biggest cause of a theme that "cannot be imported".
    const unsigned char gzipBytes[] = {0x1f, 0x8b, 0x08, 0x00, 0x01, 0x02};
    NSString *mixed = MTWriteZIPFixture(root, @"mixed-payload.zip", @[
        @{ @"name" : @"Mixed.theme/IconBundles/com.example.App.png",
           @"data" : MTSyntheticPNGData(@"mixed") },
        @{ @"name" : @"Mixed.theme/README.txt",
           @"data" : [@"read me" dataUsingEncoding:NSUTF8StringEncoding] },
        @{ @"name" : @"Mixed.theme/preview.gif",
           @"data" : [@"GIF89a" dataUsingEncoding:NSUTF8StringEncoding] },
        @{ @"name" : @"Extras/companion.deb",
           @"data" : [@"!<arch>\n" dataUsingEncoding:NSUTF8StringEncoding] },
        // Content whose bytes look like a compressed stream but whose name
        // does not. The two passes must agree about this file or the import
        // dies on a preflight/stream mismatch.
        @{ @"name" : @"Extras/disguised.bin",
           @"data" : [NSData dataWithBytes:gzipBytes length:sizeof(gzipBytes)] },
    ]);
    error = nil;
    MTSafeZIPArchiveScan *mixedScan = [reader
        scanArchiveAtURL:[NSURL fileURLWithPath:mixed]
        cancellationToken:nil error:&error];
    MTAssert(mixedScan != nil && error == nil,
        @"a ZIP mixing theme content with unrelated files must still import");
    MTAssert([mixedScan.inventory
                 fileAtRelativePath:@"Mixed.theme/IconBundles/com.example.App.png"]
                 != nil,
        @"recognizable theme content must survive a mixed archive");
    MTAssert([mixedScan.inventory
                 fileAtRelativePath:@"Extras/companion.deb"] == nil &&
             [mixedScan.inventory
                 fileAtRelativePath:@"Extras/disguised.bin"] == nil,
        @"archive payloads must be dropped from the inventory, not fail import");

    // The single most common real-world shape: one wrapper folder holding
    // several .theme bundles, plus loose files beside them. Every one of the
    // bundles has to survive, and unreadable extras must not cost the import.
    NSString *suite = MTWriteZIPFixture(root, @"suite.zip", @[
        @{ @"name" : @"My Pack/Alpha.theme/IconBundles/com.example.A.png",
           @"data" : MTSyntheticPNGData(@"alpha") },
        @{ @"name" : @"My Pack/Beta.theme/IconBundles/com.example.B.png",
           @"data" : MTSyntheticPNGData(@"beta") },
        @{ @"name" : @"My Pack/README.txt",
           @"data" : [@"notes" dataUsingEncoding:NSUTF8StringEncoding] },
        @{ @"name" : @"My Pack/screenshot.jpg",
           @"data" : [@"jpeg" dataUsingEncoding:NSUTF8StringEncoding] },
    ]);
    error = nil;
    MTSafeZIPArchiveScan *suiteScan = [reader
        scanArchiveAtURL:[NSURL fileURLWithPath:suite]
        cancellationToken:nil error:&error];
    MTAssert(suiteScan != nil && error == nil,
        @"a wrapped multi-theme suite must scan");
    NSError *suiteRootError = nil;
    id<MTAuditedSource> suiteRoot = [MTThemeSourceRoot
        sourceByResolvingThemeRootInSource:suiteScan error:&suiteRootError];
    MTAssert(suiteRoot != nil && suiteRootError == nil,
        @"a wrapped multi-theme suite must resolve a theme root");
    NSUInteger suiteResources = 0;
    for (MTSourceFile *file in suiteRoot.inventory.files) {
        if ([file.relativePath.lowercaseString containsString:@"iconbundles/"]) {
            suiteResources++;
        }
    }
    MTAssert(suiteResources == 2,
        @"both bundles of a wrapped suite must survive root resolution");

    // One file compressed with a method this reader cannot verify (bzip2 here)
    // must not cost the user the rest of the package.
    NSString *oddMethod = MTWriteZIPFixture(root, @"odd-method.zip", @[
        @{ @"name" : @"Odd.theme/IconBundles/com.example.App.png",
           @"data" : MTSyntheticPNGData(@"odd") },
        @{ @"name" : @"Odd.theme/extras/compressed.dat",
           @"data" : [@"payload" dataUsingEncoding:NSUTF8StringEncoding],
           @"method" : @12 },
    ]);
    error = nil;
    MTSafeZIPArchiveScan *oddScan = [reader
        scanArchiveAtURL:[NSURL fileURLWithPath:oddMethod]
        cancellationToken:nil error:&error];
    MTAssert(oddScan != nil && error == nil &&
             [oddScan.inventory
                 fileAtRelativePath:@"Odd.theme/IconBundles/com.example.App.png"]
                 != nil &&
             [oddScan.inventory
                 fileAtRelativePath:@"Odd.theme/extras/compressed.dat"] == nil,
        @"an unverifiable compression method must drop the entry, not the import");

    // A stored (uncompressed) entry and a deflated entry must both import;
    // the compression method is not a property of theme content.
    NSString *storedAndDeflated = MTWriteZIPFixture(root, @"methods.zip", @[
        @{ @"name" : @"Methods.theme/IconBundles/stored.png",
           @"data" : MTSyntheticPNGData(@"stored"), @"method" : @0 },
        @{ @"name" : @"Methods.theme/IconBundles/deflated.png",
           @"data" : MTSyntheticPNGData(@"deflated"), @"method" : @8 },
    ]);
    error = nil;
    MTSafeZIPArchiveScan *methodScan = [reader
        scanArchiveAtURL:[NSURL fileURLWithPath:storedAndDeflated]
        cancellationToken:nil error:&error];
    MTAssert(methodScan != nil && error == nil &&
             [methodScan.inventory
                 fileAtRelativePath:@"Methods.theme/IconBundles/stored.png"] != nil &&
             [methodScan.inventory
                 fileAtRelativePath:@"Methods.theme/IconBundles/deflated.png"] != nil,
        @"stored and deflated entries must both import");

    NSString *encrypted = MTWriteZIPFixture(root, @"encrypted.zip", @[@{
        @"name" : @"Icons/encrypted.png",
        @"data" : MTSyntheticPNGData(@"encrypted"),
        @"flags" : @(0x0801),
    }]);
    MTAssertZIPFailure(reader, encrypted, nil,
        MTSafeZIPArchiveReaderErrorUnsupportedFeature,
        @"encrypted ZIP flags must be rejected before decoding");

    NSString *splitName = MTWriteZIPFixture(root, @"split-name.zip", @[@{
        @"name" : @"safe-a.png",
        @"localNameData" : [@"safe-b.png" dataUsingEncoding:NSUTF8StringEncoding],
        @"data" : MTSyntheticPNGData(@"split"),
    }]);
    MTAssertZIPFailure(reader, splitName, nil,
        MTSafeZIPArchiveReaderErrorCorruptArchive,
        @"local/central ZIP entry-name disagreement must be rejected");

    NSString *badCRC = MTWriteZIPFixture(root, @"bad-crc.zip", @[@{
        @"name" : @"Icons/bad-crc.png",
        @"data" : MTSyntheticPNGData(@"bad-crc"),
        @"crc" : @0,
    }]);
    MTAssertZIPFailure(reader, badCRC, nil,
        MTSafeZIPArchiveReaderErrorCorruptArchive,
        @"streamed ZIP CRC corruption must be rejected");

    NSMutableData *zeros = [NSMutableData dataWithLength:4096];
    NSString *ratio = MTWriteZIPFixture(root, @"ratio.zip", @[@{
        @"name" : @"Icons/zeros.png", @"data" : zeros, @"method" : @8
    }]);
    MTImportLimits *ratioLimits = [[MTImportLimits alloc]
        initWithMaximumRegularFiles:4
              maximumArchiveEntries:8
                 maximumSourceBytes:1024 * 1024
               maximumExpandedBytes:1024 * 1024
             maximumSingleFileBytes:1024 * 1024
       maximumArchiveExpansionRatio:2
                   maximumPathDepth:8
               maximumPathUTF8Bytes:256];
    MTSafeZIPArchiveReader *ratioReader = [[MTSafeZIPArchiveReader alloc]
        initWithLimits:ratioLimits];
    MTAssertZIPFailure(ratioReader, ratio, nil,
        MTSafeZIPArchiveReaderErrorLimitExceeded,
        @"high-ratio deflate payload must fail during central preflight");

    MTImportCancellationToken *cancelled = [[MTImportCancellationToken alloc] init];
    [cancelled cancel];
    MTAssertZIPFailure(reader, validPath, cancelled,
        MTSafeZIPArchiveReaderErrorCancelled,
        @"pre-cancelled archive inspection must not enter libarchive");
    MTDeterministicCancellationToken *midStream =
        [[MTDeterministicCancellationToken alloc] init];
    MTAssertZIPFailure(reader, validPath, midStream,
        MTSafeZIPArchiveReaderErrorCancelled,
        @"mid-audit cancellation must stop streaming without output files");

    NSString *sourceLink = [root stringByAppendingPathComponent:@"source-link.zip"];
    MTAssert(symlink(validPath.fileSystemRepresentation,
                     sourceLink.fileSystemRepresentation) == 0,
             @"ZIP source symlink fixture must be created");
    MTAssertZIPFailure(reader, sourceLink, nil,
        MTSafeZIPArchiveReaderErrorInvalidInput,
        @"archive source symlink must not be followed");

    NSMutableData *changedArchive = [NSMutableData
        dataWithContentsOfFile:validPath];
    ((unsigned char *)changedArchive.mutableBytes)[0] ^= 0x01;
    MTAssert([changedArchive writeToFile:validPath options:NSDataWritingAtomic
                                  error:&error],
             @"post-audit ZIP mutation fixture must be written");
    MTAssertAuditedReadFailure(validScan, @"Info.plist",
        containerInfo.length, nil, MTAuditedSourceErrorSourceChanged,
        @"ZIP audited reads must reject a replaced archive identity");

    NSMutableData *changedInfo = [containerInfo mutableCopy];
    ((unsigned char *)changedInfo.mutableBytes)[changedInfo.length - 1] ^= 0x01;
    MTAssert([changedInfo writeToFile:
        [directoryRoot stringByAppendingPathComponent:@"Info.plist"]
                            options:0 error:&error],
             @"post-audit directory mutation fixture must be written");
    MTAssertAuditedReadFailure(directoryScan, @"Info.plist",
        containerInfo.length, nil, MTAuditedSourceErrorSourceChanged,
        @"directory audited reads must reject changed inventoried bytes");

    [NSFileManager.defaultManager removeItemAtPath:directoryRoot error:NULL];
    [NSFileManager.defaultManager removeItemAtPath:root error:NULL];
}

static void MTTestAssetStagingSession(void) {
    NSString *root = MTCreateTemporaryDirectory(@"asset-staging");
    NSString *sourceRoot = [root stringByAppendingPathComponent:@"source"];
    NSString *assetsRoot = [sourceRoot stringByAppendingPathComponent:@"Assets"];
    NSString *iconsRoot = [sourceRoot
        stringByAppendingPathComponent:@"IconBundles"];
    NSError *error = nil;
    MTAssert([NSFileManager.defaultManager
        createDirectoryAtPath:assetsRoot
  withIntermediateDirectories:YES
                   attributes:@{NSFilePosixPermissions : @0700}
                        error:&error] &&
             [NSFileManager.defaultManager
        createDirectoryAtPath:iconsRoot
  withIntermediateDirectories:NO
                   attributes:@{NSFilePosixPermissions : @0700}
                        error:&error],
             @"asset-staging source directories must be created");

    NSMutableData *largeAsset = [NSMutableData dataWithLength:192 * 1024 + 37];
    uint8_t *largeBytes = largeAsset.mutableBytes;
    uint32_t state = 0x4d61726b;
    for (NSUInteger index = 0; index < largeAsset.length; index++) {
        state = state * 1664525U + 1013904223U;
        largeBytes[index] = (uint8_t)(state >> 24);
    }
    NSData *validPNG = MTPNGFixtureData(3, 2, 8, 6, 0, YES, @[], @[]);
    NSString *largePath = [assetsRoot stringByAppendingPathComponent:
        @"large-resource.bin"];
    NSString *pngPath = [iconsRoot stringByAppendingPathComponent:
        @"com.example.Staged-large.png"];
    MTAssert([largeAsset writeToFile:largePath options:0 error:&error] &&
             [validPNG writeToFile:pngPath options:0 error:&error] &&
             chmod(largePath.fileSystemRepresentation, 0600) == 0 &&
             chmod(pngPath.fileSystemRepresentation, 0600) == 0,
             @"asset-staging source files must be privately written");

    MTSafeDirectoryScan *directorySource =
        [[[MTSafeDirectoryScanner alloc]
            initWithLimits:MTImportLimits.defaultLimits]
            scanDirectorySourceAtURL:
                [NSURL fileURLWithPath:sourceRoot isDirectory:YES]
            error:&error];
    NSString *archivePath = MTWriteZIPFixture(root, @"source.zip", @[
        @{ @"name" : @"Assets/", @"mode" : @(S_IFDIR | 0755) },
        @{ @"name" : @"IconBundles/", @"mode" : @(S_IFDIR | 0755) },
        @{ @"name" : @"Assets/large-resource.bin", @"data" : largeAsset },
        @{ @"name" : @"IconBundles/com.example.Staged-large.png",
           @"data" : validPNG, @"method" : @8 },
    ]);
    MTSafeZIPArchiveScan *archiveSource =
        [[[MTSafeZIPArchiveReader alloc]
            initWithLimits:MTImportLimits.defaultLimits]
            scanArchiveAtURL:[NSURL fileURLWithPath:archivePath]
            cancellationToken:nil
            error:&error];
    MTAssert(directorySource != nil && archiveSource != nil && error == nil &&
             [directorySource.inventory.sourceFingerprint isEqualToString:
                 archiveSource.inventory.sourceFingerprint],
             @"directory and ZIP asset-staging fixtures must audit identically");

    NSURL *sessionsRootURL = [NSURL fileURLWithPath:
        [root stringByAppendingPathComponent:@"missing/parent/sessions"]
        isDirectory:YES];
    MTAssetStagingConfiguration *configuration =
        [[MTAssetStagingConfiguration alloc]
            initWithSessionsRootURL:sessionsRootURL
                             limits:MTImportLimits.defaultLimits];
    MTAssetStagingSession *session = [MTAssetStagingSession
        sessionWithConfiguration:configuration error:&error];
    MTStagedAsset *directoryAsset = [session
        stageAssetAtRelativePath:@"Assets/large-resource.bin"
                      fromSource:directorySource
                maximumByteCount:largeAsset.length
               cancellationToken:nil
                           error:&error];
    MTStagedAsset *archiveAsset = [session
        stageAssetAtRelativePath:@"Assets/large-resource.bin"
                      fromSource:archiveSource
                maximumByteCount:largeAsset.length
               cancellationToken:nil
                           error:&error];
    NSData *ownedLargeAsset = [NSData
        dataWithContentsOfURL:directoryAsset.ownedFileURL options:0 error:&error];
    struct stat stagedStatus = {0};
    MTAssert(session != nil && directoryAsset != nil && archiveAsset != nil &&
             error == nil &&
             [directoryAsset.ownedFileURL
                 isEqual:archiveAsset.ownedFileURL] &&
             [ownedLargeAsset isEqualToData:largeAsset] &&
             session.stagedObjectCount == 1 &&
             session.stagedByteCount == largeAsset.length &&
             [directoryAsset.ownedFileURL.lastPathComponent
                 isEqualToString:directoryAsset.contentSHA256] &&
             [directoryAsset.ownedFileURL.URLByDeletingLastPathComponent
                 .lastPathComponent isEqualToString:@"objects"] &&
             ![directoryAsset.ownedFileURL.path
                 containsString:@"large-resource.bin"] &&
             lstat(directoryAsset.ownedFileURL.path.fileSystemRepresentation,
                   &stagedStatus) == 0 &&
             S_ISREG(stagedStatus.st_mode) && stagedStatus.st_nlink == 1 &&
             stagedStatus.st_uid == geteuid() &&
             (stagedStatus.st_mode & 0777) == 0600,
             @"large directory/ZIP assets must deduplicate into one private digest object");

    MTStagedAsset *pngAsset = [session
        stageAssetAtRelativePath:
            @"IconBundles/com.example.Staged-large.png"
                      fromSource:archiveSource
                maximumByteCount:
                    MTSafeImageLimits.defaultLimits.maximumEncodedBytes
               cancellationToken:nil
                           error:&error];
    MTSafeImageInspection *inspection =
        [MTSafeImageInspector.defaultInspector
            inspectOwnedPNGFileAtURL:pngAsset.ownedFileURL
                  cancellationToken:nil
                               error:&error];
    MTSafeImageDecodeResult *decoded = [MTSafeImageDecoder.defaultDecoder
        decodeOwnedPNGFileAtURL:pngAsset.ownedFileURL
        thumbnailMaximumDimension:128
        cancellationToken:nil
        error:&error];
    MTAssert(pngAsset != nil && inspection != nil && decoded != nil &&
             error == nil &&
             session.stagedObjectCount == 2 &&
             session.stagedByteCount == largeAsset.length + validPNG.length &&
             inspection.pixelWidth == 3 && inspection.pixelHeight == 2 &&
             inspection.encodedByteCount == validPNG.length &&
             decoded.thumbnailPixelWidth == 3 &&
             decoded.thumbnailPixelHeight == 2 &&
             decoded.thumbnailPixelData.length == 24,
             @"an audited ZIP PNG must reach owned metadata and pixel-decode gates");

    NSString *sessionPath = session.sessionDirectoryURL.path;
    error = nil;
    MTAssert([session discard:&error] && [session discard:&error] &&
             error == nil &&
             access(sessionPath.fileSystemRepresentation, F_OK) != 0 &&
             access(largePath.fileSystemRepresentation, F_OK) == 0 &&
             access(pngPath.fileSystemRepresentation, F_OK) == 0,
             @"asset-session discard must be idempotent and preserve audited sources");

    error = nil;
    MTAssetStagingSession *limited = [MTAssetStagingSession
        sessionWithConfiguration:configuration error:&error];
    NSString *limitedPath = limited.sessionDirectoryURL.path;
    MTAssert([limited stageAssetAtRelativePath:@"Assets/large-resource.bin"
                                    fromSource:directorySource
                              maximumByteCount:largeAsset.length - 1
                             cancellationToken:nil error:&error] == nil &&
             [error.domain
                 isEqualToString:MTAssetStagingSessionErrorDomain] &&
             error.code == MTAssetStagingSessionErrorLimitExceeded &&
             !limited.isActive &&
             access(limitedPath.fileSystemRepresentation, F_OK) != 0,
             @"an asset byte-limit failure must roll back its complete session");

    error = nil;
    MTAssetStagingSession *cancelledSession = [MTAssetStagingSession
        sessionWithConfiguration:configuration error:&error];
    NSString *cancelledPath = cancelledSession.sessionDirectoryURL.path;
    MTImportCancellationToken *cancelled =
        [[MTImportCancellationToken alloc] init];
    [cancelled cancel];
    MTAssert([cancelledSession
        stageAssetAtRelativePath:
            @"IconBundles/com.example.Staged-large.png"
                      fromSource:directorySource
                maximumByteCount:validPNG.length
               cancellationToken:cancelled error:&error] == nil &&
             [error.domain
                 isEqualToString:MTAssetStagingSessionErrorDomain] &&
             error.code == MTAssetStagingSessionErrorCancelled &&
             access(cancelledPath.fileSystemRepresentation, F_OK) != 0,
             @"pre-cancelled asset staging must leave no session residue");

    error = nil;
    MTAssetStagingSession *midStreamSession = [MTAssetStagingSession
        sessionWithConfiguration:configuration error:&error];
    NSString *midStreamPath = midStreamSession.sessionDirectoryURL.path;
    MTAssert([midStreamSession
        stageAssetAtRelativePath:@"Assets/large-resource.bin"
                      fromSource:directorySource
                maximumByteCount:largeAsset.length
               cancellationToken:
                   [[MTDeterministicCancellationToken alloc] init]
                           error:&error] == nil &&
             [error.domain
                 isEqualToString:MTAssetStagingSessionErrorDomain] &&
             error.code == MTAssetStagingSessionErrorCancelled &&
             access(midStreamPath.fileSystemRepresentation, F_OK) != 0,
             @"mid-stream cancellation must roll back partial and prior state");

    error = nil;
    MTAssetStagingSession *mutatedSourceSession = [MTAssetStagingSession
        sessionWithConfiguration:configuration error:&error];
    NSString *mutatedSessionPath =
        mutatedSourceSession.sessionDirectoryURL.path;
    MTImageMutationToken *sourceMutation = [[MTImageMutationToken alloc]
        initWithPath:largePath triggerCount:4];
    MTAssert([mutatedSourceSession
        stageAssetAtRelativePath:@"Assets/large-resource.bin"
                      fromSource:directorySource
                maximumByteCount:largeAsset.length
               cancellationToken:sourceMutation
                           error:&error] == nil &&
             sourceMutation.mutationSucceeded &&
             [error.domain
                 isEqualToString:MTAssetStagingSessionErrorDomain] &&
             error.code == MTAssetStagingSessionErrorSourceRejected &&
             access(mutatedSessionPath.fileSystemRepresentation, F_OK) != 0 &&
             chmod(largePath.fileSystemRepresentation, 0600) == 0,
             @"source identity changes during streaming must reject and roll back");

    MTImportLimits *oneObjectLimits = [[MTImportLimits alloc]
        initWithMaximumRegularFiles:1
              maximumArchiveEntries:1
                 maximumSourceBytes:1024 * 1024
               maximumExpandedBytes:1024 * 1024
             maximumSingleFileBytes:1024 * 1024
       maximumArchiveExpansionRatio:100
                   maximumPathDepth:8
               maximumPathUTF8Bytes:256];
    MTAssetStagingConfiguration *oneObjectConfiguration =
        [[MTAssetStagingConfiguration alloc]
            initWithSessionsRootURL:sessionsRootURL limits:oneObjectLimits];
    error = nil;
    MTAssetStagingSession *oneObjectSession = [MTAssetStagingSession
        sessionWithConfiguration:oneObjectConfiguration error:&error];
    MTStagedAsset *firstObject = [oneObjectSession
        stageAssetAtRelativePath:
            @"IconBundles/com.example.Staged-large.png"
                      fromSource:directorySource
                maximumByteCount:validPNG.length
               cancellationToken:nil error:&error];
    NSString *oneObjectSessionPath =
        oneObjectSession.sessionDirectoryURL.path;
    NSString *firstObjectPath = firstObject.ownedFileURL.path;
    error = nil;
    MTAssert(firstObject != nil && [oneObjectSession
        stageAssetAtRelativePath:@"Assets/large-resource.bin"
                      fromSource:directorySource
                maximumByteCount:largeAsset.length
               cancellationToken:nil error:&error] == nil &&
             [error.domain
                 isEqualToString:MTAssetStagingSessionErrorDomain] &&
             error.code == MTAssetStagingSessionErrorLimitExceeded &&
             access(oneObjectSessionPath.fileSystemRepresentation, F_OK) != 0 &&
             access(firstObjectPath.fileSystemRepresentation, F_OK) != 0,
             @"object-count overflow must remove the complete staging transaction");

    uint64_t tightTotalBytes = largeAsset.length + validPNG.length - 1;
    MTImportLimits *tightTotalLimits = [[MTImportLimits alloc]
        initWithMaximumRegularFiles:4
              maximumArchiveEntries:4
                 maximumSourceBytes:1024 * 1024
               maximumExpandedBytes:tightTotalBytes
             maximumSingleFileBytes:largeAsset.length
       maximumArchiveExpansionRatio:100
                   maximumPathDepth:8
               maximumPathUTF8Bytes:256];
    MTAssetStagingConfiguration *tightTotalConfiguration =
        [[MTAssetStagingConfiguration alloc]
            initWithSessionsRootURL:sessionsRootURL limits:tightTotalLimits];
    error = nil;
    MTAssetStagingSession *tightTotalSession = [MTAssetStagingSession
        sessionWithConfiguration:tightTotalConfiguration error:&error];
    MTStagedAsset *firstLargeObject = [tightTotalSession
        stageAssetAtRelativePath:@"Assets/large-resource.bin"
                      fromSource:directorySource
                maximumByteCount:largeAsset.length
               cancellationToken:nil error:&error];
    NSString *tightTotalSessionPath =
        tightTotalSession.sessionDirectoryURL.path;
    error = nil;
    MTAssert(firstLargeObject != nil && [tightTotalSession
        stageAssetAtRelativePath:
            @"IconBundles/com.example.Staged-large.png"
                      fromSource:directorySource
                maximumByteCount:validPNG.length
               cancellationToken:nil error:&error] == nil &&
             [error.domain
                 isEqualToString:MTAssetStagingSessionErrorDomain] &&
             error.code == MTAssetStagingSessionErrorLimitExceeded &&
             access(tightTotalSessionPath.fileSystemRepresentation, F_OK) != 0,
             @"aggregate-byte overflow must remove the complete staging transaction");

    error = nil;
    MTAssetStagingSession *tampered = [MTAssetStagingSession
        sessionWithConfiguration:configuration error:&error];
    MTStagedAsset *tamperedAsset = [tampered
        stageAssetAtRelativePath:
            @"IconBundles/com.example.Staged-large.png"
                      fromSource:directorySource
                maximumByteCount:validPNG.length
               cancellationToken:nil error:&error];
    NSMutableData *changedPNG = [validPNG mutableCopy];
    ((uint8_t *)changedPNG.mutableBytes)[0] ^= 0x01;
    MTAssert([changedPNG writeToURL:tamperedAsset.ownedFileURL
                           options:0 error:&error] &&
             chmod(tamperedAsset.ownedFileURL.path.fileSystemRepresentation,
                   0600) == 0,
             @"destination-tamper fixture must replace only staged bytes");
    NSString *tamperedSessionPath = tampered.sessionDirectoryURL.path;
    error = nil;
    MTAssert([tampered
        stageAssetAtRelativePath:
            @"IconBundles/com.example.Staged-large.png"
                      fromSource:directorySource
                maximumByteCount:validPNG.length
               cancellationToken:nil error:&error] == nil &&
             [error.domain
                 isEqualToString:MTAssetStagingSessionErrorDomain] &&
             error.code == MTAssetStagingSessionErrorVerification &&
             access(tamperedSessionPath.fileSystemRepresentation, F_OK) != 0,
             @"a corrupt existing digest object must fail closed and roll back");

    error = nil;
    MTAssetStagingSession *abandoned = [MTAssetStagingSession
        sessionWithConfiguration:configuration error:&error];
    MTStagedAsset *abandonedAsset = [abandoned
        stageAssetAtRelativePath:
            @"IconBundles/com.example.Staged-large.png"
                      fromSource:archiveSource
                maximumByteCount:validPNG.length
               cancellationToken:nil error:&error];
    NSString *abandonedPath = abandoned.sessionDirectoryURL.path;
    NSString *unrelatedPath = [sessionsRootURL.path
        stringByAppendingPathComponent:@"unrelated-owner-file"];
    MTAssert([@"keep" writeToFile:unrelatedPath atomically:NO
                          encoding:NSUTF8StringEncoding error:&error] &&
             abandonedAsset != nil &&
             [MTAssetStagingSession
                discardAbandonedSessionsWithConfiguration:configuration
                error:&error] &&
             access(abandonedPath.fileSystemRepresentation, F_OK) != 0 &&
             access(unrelatedPath.fileSystemRepresentation, F_OK) == 0 &&
             [abandoned discard:&error],
             @"startup sweep must remove only canonical abandoned asset sessions");

    error = nil;
    MTAssetStagingSession *guarded = [MTAssetStagingSession
        sessionWithConfiguration:configuration error:&error];
    NSString *unknownPath = [guarded.sessionDirectoryURL.path
        stringByAppendingPathComponent:@"unexpected"];
    MTAssert([@"owned by test" writeToFile:unknownPath
                                  atomically:NO
                                    encoding:NSUTF8StringEncoding
                                       error:&error],
             @"unknown cleanup-node fixture must be written");
    error = nil;
    MTAssert(![guarded discard:&error] &&
             [error.domain
                 isEqualToString:MTAssetStagingSessionErrorDomain] &&
             error.code == MTAssetStagingSessionErrorCleanup &&
             access(unknownPath.fileSystemRepresentation, F_OK) == 0,
             @"cleanup must refuse unknown session nodes without deleting them");

    [NSFileManager.defaultManager removeItemAtPath:root error:NULL];
}

static void MTTestAuditedMetadataFallbacks(void) {
    MTSafeDirectoryScanner *scanner = [[MTSafeDirectoryScanner alloc]
        initWithLimits:MTImportLimits.defaultLimits];
    MTThemeInfoMetadataImporter *metadataImporter =
        [[MTThemeInfoMetadataImporter alloc] init];
    NSError *error = nil;

    NSString *malformedRoot =
        MTCreateIconBundlesFixture(@"metadata-malformed", NO);
    MTAssert([[NSData dataWithBytes:"not-a-plist" length:11]
        writeToFile:[malformedRoot stringByAppendingPathComponent:@"Info.plist"]
            options:0 error:&error],
        @"malformed metadata fixture must be written");
    MTSafeDirectoryScan *malformedSource = [scanner
        scanDirectorySourceAtURL:
            [NSURL fileURLWithPath:malformedRoot isDirectory:YES]
        error:&error];
    MTThemeImportMetadata *malformedMetadata = [metadataImporter
        importMetadataFromSource:malformedSource
                      sourceName:@"Broken.theme"
               cancellationToken:nil error:&error];
    MTAssert(malformedMetadata != nil && error == nil &&
             [malformedMetadata.displayMetadata.displayName
                 isEqualToString:@"Broken"] &&
             malformedMetadata.displayMetadata.usedSourceNameFallback &&
             malformedMetadata.diagnostics.count == 1 &&
             [malformedMetadata.diagnostics.firstObject.code
                 isEqualToString:
                     @"import.metadata.unreadable-info-plist"],
             @"malformed but bounded Info.plist data must degrade to a visible fallback diagnostic");
    MTIconBundlesImportResult *malformedImport =
        [[[MTIconBundlesImporter alloc] init]
            importSourceInventory:malformedSource.inventory
                        sourceName:@"Broken.theme"
                    importMetadata:malformedMetadata
                             error:&error];
    MTAssert(malformedImport != nil &&
             malformedImport.manifest.importerVersion == 3 &&
             malformedImport.manifest.resources.count == 2 &&
             malformedImport.diagnostics.count == 2,
             @"invalid display metadata must not hide otherwise valid icon resources");

    NSString *missingRoot =
        MTCreateIconBundlesFixture(@"metadata-missing", NO);
    MTAssert([NSFileManager.defaultManager removeItemAtPath:
        [missingRoot stringByAppendingPathComponent:@"Info.plist"] error:&error],
        @"missing metadata fixture must remove only its root Info.plist");
    MTSafeDirectoryScan *missingSource = [scanner
        scanDirectorySourceAtURL:
            [NSURL fileURLWithPath:missingRoot isDirectory:YES]
        error:&error];
    MTThemeImportMetadata *missingMetadata = [metadataImporter
        importMetadataFromSource:missingSource
                      sourceName:@"Missing.theme"
               cancellationToken:nil error:&error];
    MTAssert(missingMetadata != nil && error == nil &&
             [missingMetadata.displayMetadata.displayName
                 isEqualToString:@"Missing"] &&
             missingMetadata.displayMetadata.usedSourceNameFallback &&
             missingMetadata.diagnostics.count == 0,
             @"an absent Info.plist must be a normal source-name fallback, not a parse warning");

    NSString *oversizedRoot =
        MTCreateIconBundlesFixture(@"metadata-oversized", NO);
    NSUInteger plistLimit =
        MTSafePropertyListLimits.defaultLimits.maximumInputBytes;
    NSMutableData *oversizedInfo =
        [NSMutableData dataWithLength:plistLimit + 1];
    MTAssert([oversizedInfo writeToFile:
        [oversizedRoot stringByAppendingPathComponent:@"Info.plist"]
                               options:0 error:&error],
        @"oversized metadata fixture must be written");
    MTSafeDirectoryScan *oversizedSource = [scanner
        scanDirectorySourceAtURL:
            [NSURL fileURLWithPath:oversizedRoot isDirectory:YES]
        error:&error];
    MTThemeImportMetadata *oversizedMetadata = [metadataImporter
        importMetadataFromSource:oversizedSource
                      sourceName:@"Oversized.theme"
               cancellationToken:nil error:&error];
    MTAssert(oversizedMetadata != nil && error == nil &&
             [oversizedMetadata.displayMetadata.displayName
                 isEqualToString:@"Oversized"] &&
             oversizedMetadata.diagnostics.count == 1 &&
             [oversizedMetadata.diagnostics.firstObject.code
                 isEqualToString:@"import.metadata.info-plist-limit"],
             @"metadata larger than the parser gate must be ignored before requesting its bytes");

    MTImportCancellationToken *cancelled =
        [[MTImportCancellationToken alloc] init];
    [cancelled cancel];
    error = nil;
    MTAssert([metadataImporter importMetadataFromSource:missingSource
                                             sourceName:@"Missing.theme"
                                      cancellationToken:cancelled
                                                  error:&error] == nil &&
             [error.domain
                 isEqualToString:MTThemeInfoMetadataImporterErrorDomain] &&
             error.code == 2,
             @"metadata fallback must not bypass an already-cancelled import");

    [NSFileManager.defaultManager removeItemAtPath:malformedRoot error:NULL];
    [NSFileManager.defaultManager removeItemAtPath:missingRoot error:NULL];
    [NSFileManager.defaultManager removeItemAtPath:oversizedRoot error:NULL];
}

static MTIconBundlesImportResult *MTTestDirectoryScanAndImporter(
    NSString *goldenDigestPath,
    MTThemeImportMetadata *importMetadata) {
    NSString *firstRoot = MTCreateIconBundlesFixture(@"iconbundles-a", NO);
    NSString *secondRoot = MTCreateIconBundlesFixture(@"iconbundles-b", YES);
    MTSafeDirectoryScanner *scanner = [[MTSafeDirectoryScanner alloc]
        initWithLimits:MTImportLimits.defaultLimits];
    NSError *error = nil;
    MTSourceInventory *first = [scanner
        scanDirectoryAtURL:[NSURL fileURLWithPath:firstRoot isDirectory:YES]
                     error:&error];
    MTSourceInventory *second = [scanner
        scanDirectoryAtURL:[NSURL fileURLWithPath:secondRoot isDirectory:YES]
                     error:&error];
    MTAssert(first != nil && second != nil && first.files.count == 4,
             @"safe scanner must inventory all deterministic regular files");
    MTAssert([first.sourceFingerprint isEqualToString:second.sourceFingerprint],
             @"source fingerprint must not depend on directory enumeration order");
    MTAssert(MTStringIsLowercaseSHA256Digest(first.sourceFingerprint),
             @"source fingerprint must be a lowercase SHA-256 digest");

    MTIconBundlesImporter *importer = [[MTIconBundlesImporter alloc] init];
    MTIconBundlesImportResult *result = [importer
        importSourceInventory:first
                    sourceName:@"Fixture.theme"
                         error:&error];
    MTAssert(result != nil && result.recognizedFileCount == 2 &&
             result.rejectedFileCount == 1 && result.ignoredFileCount == 1,
             @"IconBundles importer must report recognized, rejected and ignored files");
    MTAssert(result.manifest.resources.count == 2 &&
             result.diagnostics.count == 1,
             @"invalid PNG metadata must be diagnosed without hiding valid icons");
    MTThemeResource *appStore = nil;
    for (MTThemeResource *resource in result.manifest.resources) {
        if ([resource.resourceKey.subject isEqualToString:@"com.apple.AppStore"]) {
            appStore = resource;
            break;
        }
    }
    MTAssert([appStore.resourceKey.subject isEqualToString:@"com.apple.AppStore"] &&
             [appStore.resourceKey.variant
                 isEqualToString:MTStaticIconSourceVariantLarge],
             @"bundle identifier case and SnowBoard source family must survive canonical import");
    MTAssert([result.manifest.displayName isEqualToString:@"Fixture"] &&
             [result.manifest.importerID isEqualToString:@"import.iconbundles"] &&
             result.manifest.importerVersion == 1,
             @"importer metadata must identify its source and display name");
    error = nil;
    MTIconBundlesImportResult *metadataResult = [importer
        importSourceInventory:first
                    sourceName:@"Fixture.theme"
                importMetadata:importMetadata
                         error:&error];
    MTAssert(metadataResult != nil && error == nil &&
             [metadataResult.manifest.displayName isEqualToString:@"Mark Théme"] &&
             [metadataResult.manifest.themeVersion isEqualToString:@"1.2.3"] &&
             metadataResult.manifest.author.length == 0 &&
             metadataResult.manifest.importerVersion == 3,
             @"validated display metadata must merge without changing resource parsing");
    MTAssert(metadataResult.recognizedFileCount == result.recognizedFileCount &&
             metadataResult.rejectedFileCount == result.rejectedFileCount &&
             [metadataResult.manifest.sourceFingerprint
                 isEqualToString:result.manifest.sourceFingerprint],
             @"display metadata must not affect resource recognition or source identity");

    NSString *compatibilityRoot = MTCreateTemporaryDirectory(
        @"iconbundles-filename-compatibility");
    NSString *compatibilityIcons = [compatibilityRoot
        stringByAppendingPathComponent:@"IconBundles"];
    MTAssert([NSFileManager.defaultManager
        createDirectoryAtPath:compatibilityIcons
        withIntermediateDirectories:NO
        attributes:@{ NSFilePosixPermissions : @0700 }
        error:&error],
        @"IconBundles compatibility fixture directory must be created");
    for (NSString *filename in @[
            @" dotless.PNG ", @"under_score.PNG.PNG.PNG",
            @"com..example..Dots@3X.PNG",
        ]) {
        MTAssert([MTSyntheticPNGData(filename) writeToFile:
            [compatibilityIcons stringByAppendingPathComponent:filename]
            options:0 error:&error],
            @"IconBundles compatibility fixture must write its image");
    }
    MTSourceInventory *compatibilityInventory = [scanner
        scanDirectoryAtURL:[NSURL fileURLWithPath:compatibilityRoot
                                       isDirectory:YES]
        error:&error];
    MTIconBundlesImportResult *compatibilityResult = [importer
        importSourceInventory:compatibilityInventory
        sourceName:@"Compatibility.theme" error:&error];
    NSMutableSet<NSString *> *compatibilitySubjects = [NSMutableSet set];
    for (MTThemeResource *resource in
            compatibilityResult.manifest.resources) {
        [compatibilitySubjects addObject:resource.resourceKey.subject];
    }
    MTAssert(compatibilityResult != nil && error == nil &&
             compatibilityResult.recognizedFileCount == 3 &&
             compatibilityResult.rejectedFileCount == 0 &&
             [compatibilitySubjects isEqualToSet:[NSSet setWithArray:@[
                 @"dotless", @"under_score", @"com.example.Dots",
             ]]],
        @"IconBundles parsing must normalize whitespace, uppercase PNG, repeated extensions, consecutive dots, and dotless or underscore IDs");
    error = nil;
    MTAssert([[MTThemeManifest alloc]
        initWithThemeID:result.manifest.themeID
             displayName:result.manifest.displayName
                  author:@""
            themeVersion:@""
              importerID:result.manifest.importerID
         importerVersion:1
       sourceFingerprint:result.manifest.sourceFingerprint
            capabilities:@[@"module.unrelated"]
               resources:result.manifest.resources
                   error:&error] == nil && error != nil,
        @"manifest must reject a resource whose module capability is undeclared");
    NSData *canonical = [result.manifest canonicalDataWithError:&error];
    MTGoldenManifestDigest = [result.manifest contentDigestWithError:&error];
    MTAssert(canonical != nil && MTGoldenManifestDigest != nil,
             @"imported manifest must canonicalize and hash");
    NSString *expectedDigest = [[NSString
        stringWithContentsOfFile:goldenDigestPath
                       encoding:NSUTF8StringEncoding
                          error:&error]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *digestMessage = [NSString stringWithFormat:
        @"canonical manifest digest must match the pinned golden vector (expected=%@ actual=%@)",
        expectedDigest, MTGoldenManifestDigest];
    MTAssert(MTStringIsLowercaseSHA256Digest(expectedDigest) &&
             [MTGoldenManifestDigest isEqualToString:expectedDigest],
             digestMessage);

    MTImportLimits *oneFileLimit = [[MTImportLimits alloc]
        initWithMaximumRegularFiles:1
               maximumExpandedBytes:1024 * 1024
             maximumSingleFileBytes:1024 * 1024
                   maximumPathDepth:8
               maximumPathUTF8Bytes:256];
    error = nil;
    MTAssert([[[MTSafeDirectoryScanner alloc] initWithLimits:oneFileLimit]
        scanDirectoryAtURL:[NSURL fileURLWithPath:firstRoot isDirectory:YES]
                     error:&error] == nil &&
        [error.domain isEqualToString:MTSafeDirectoryScannerErrorDomain] &&
        error.code == MTSafeDirectoryScannerErrorLimitExceeded,
        @"safe scanner must stop at its configured file-count limit");

    NSString *linkPath = [firstRoot stringByAppendingPathComponent:
        @"IconBundles/com.example.Link-large.png"];
    MTAssert(symlink("/etc/passwd", linkPath.fileSystemRepresentation) == 0,
             @"symlink attack fixture must be created");
    error = nil;
    MTAssert([scanner scanDirectoryAtURL:
        [NSURL fileURLWithPath:firstRoot isDirectory:YES] error:&error] == nil &&
        error.code == MTSafeDirectoryScannerErrorUnsupportedNode,
        @"safe scanner must reject a symlink before reading its target");

    MTAssert(unlink(linkPath.fileSystemRepresentation) == 0,
             @"symlink attack fixture must be removed exactly");
    NSString *executablePath = [firstRoot stringByAppendingPathComponent:
        @"IconBundles/com.example.Beta@3x.png"];
    MTAssert(chmod(executablePath.fileSystemRepresentation, 0700) == 0,
             @"executable permission fixture must be created");
    error = nil;
    MTSourceInventory *executableInventory = [scanner scanDirectoryAtURL:
        [NSURL fileURLWithPath:firstRoot isDirectory:YES] error:&error];
    MTAssert(executableInventory != nil && error == nil &&
             [executableInventory fileAtRelativePath:
                 @"IconBundles/com.example.Beta@3x.png"] != nil,
        @"safe scanner must accept executable bits on data resources");
    BOOL privilegedModeSet =
        chmod(executablePath.fileSystemRepresentation, 04700) == 0;
    struct stat privilegedStatus = {0};
    privilegedModeSet = privilegedModeSet &&
        lstat(executablePath.fileSystemRepresentation, &privilegedStatus) == 0 &&
        (privilegedStatus.st_mode & S_ISUID) != 0;
    if (privilegedModeSet) {
        error = nil;
        MTAssert([scanner scanDirectoryAtURL:
            [NSURL fileURLWithPath:firstRoot isDirectory:YES]
            error:&error] == nil &&
            error.code == MTSafeDirectoryScannerErrorUnsupportedNode,
            @"safe scanner must reject privileged theme content");
    }
    MTAssert(chmod(executablePath.fileSystemRepresentation, 0600) == 0,
             @"permission fixture must be restored");

    NSString *hardlinkPath = [firstRoot stringByAppendingPathComponent:
        @"IconBundles/com.example.Hardlink-large.png"];
    MTAssert(link(executablePath.fileSystemRepresentation,
                  hardlinkPath.fileSystemRepresentation) == 0,
             @"hardlink attack fixture must be created");
    error = nil;
    MTAssert([scanner scanDirectoryAtURL:
        [NSURL fileURLWithPath:firstRoot isDirectory:YES] error:&error] == nil &&
        error.code == MTSafeDirectoryScannerErrorUnsupportedNode,
        @"safe scanner must reject hardlinked theme content");

    [NSFileManager.defaultManager removeItemAtPath:firstRoot error:NULL];
    [NSFileManager.defaultManager removeItemAtPath:secondRoot error:NULL];
    [NSFileManager.defaultManager removeItemAtPath:compatibilityRoot
                                             error:NULL];
    return result;
}

// Theme packages in the wild vary in ways that carry no meaning: the case of
// a directory name, an extra wrapper folder beside a README, icons filed into
// subfolders, or the WinterBoard Bundles/<id>/icon.png layout. None of these
// change what the theme is, so none of them may decide whether it imports.
static void MTTestTolerantThemeLayoutImport(void) {
    NSData *icon = MTPNGFixtureData(1, 1, 8, 6, 0, YES, @[], @[]);
    NSArray<NSDictionary<NSString *, id> *> *layouts = @[
        @{ @"label" : @"lowercase IconBundles directory",
           @"files" : @[@"iconbundles/com.example.Lower.png"] },
        @{ @"label" : @"icons filed into an IconBundles subfolder",
           @"files" : @[@"IconBundles/Games/com.example.Nested.png"] },
        @{ @"label" : @"WinterBoard Bundles/<id>/icon.png layout",
           @"files" : @[@"Bundles/com.example.Winter/icon.png"] },
        @{ @"label" : @"wrapper folder beside a loose README",
           @"files" : @[@"MyTheme/IconBundles/com.example.Wrapped.png",
                        @"README.txt"] },
        @{ @"label" : @"deeply wrapped supported resource tree",
           @"files" : @[@"Download/Theme/Assets/IconBundles/com.example.Deep.png"] },
        @{ @"label" : @"loose icons with confirmed IconBundles names",
           @"files" : @[@"Artwork/Apps/com.example.Loose@2x.png",
                        @"Artwork/README.txt"] },
        @{ @"label" : @"supported trees split across unrelated folders",
           @"files" : @[@"App Icons/IconBundles/com.example.Split.png",
                        @"Effects/AnemoneEffects/iPhoneShadow@3x.png"],
           @"expectedResources" : @2 },
        @{ @"label" : @"semantic filenames under incorrect folders",
           @"files" : @[
               @"Wrong/Badge/SBBadgeBG@3x.png",
               @"Wrong/Status/Black_2_Bars@3x.png",
               @"Wrong/Effects/iPhoneShadow@3x.png",
               @"Wrong/Mask/AppIconMask@3x~iphone.png",
               @"Wrong/Clock/ClockIconHourHand.png",
               @"Wrong/Settings/com.apple.Preferences/WiFi@3x.png",
               @"Wrong/Phone/com.apple.TelephonyUI/1@3x.png",
               @"Wrong/Folder/FolderIconBG@3x.png",
           ],
           @"expectedResources" : @8 },
    ];
    for (NSDictionary<NSString *, id> *layout in layouts) {
        NSString *root = MTCreateTemporaryDirectory(@"tolerant-layout");
        NSError *error = nil;
        for (NSString *relativePath in layout[@"files"]) {
            NSString *path = [root
                stringByAppendingPathComponent:relativePath];
            MTAssert([NSFileManager.defaultManager
                createDirectoryAtPath:path.stringByDeletingLastPathComponent
          withIntermediateDirectories:YES
                           attributes:@{NSFilePosixPermissions : @0700}
                                error:&error],
                @"tolerant layout fixture directories must initialize");
            NSData *contents = [relativePath.pathExtension
                caseInsensitiveCompare:@"png"] == NSOrderedSame
                ? icon : [@"notes" dataUsingEncoding:NSUTF8StringEncoding];
            MTAssert([contents writeToFile:path options:0 error:&error],
                @"tolerant layout fixture files must be privately written");
        }
        MTSafeDirectoryScan *scan = [[[MTSafeDirectoryScanner alloc]
            initWithLimits:MTImportLimits.defaultLimits]
            scanDirectorySourceAtURL:
                [NSURL fileURLWithPath:root isDirectory:YES]
            error:&error];
        id<MTAuditedSource> themeRoot = scan == nil ? nil :
            [MTThemeSourceRoot sourceByResolvingThemeRootInSource:scan
                                                            error:&error];
        MTIconBundlesImportResult *result = themeRoot == nil ? nil :
            [[[MTIconBundlesImporter alloc] init]
                importSourceInventory:themeRoot.inventory
                           sourceName:@"Tolerant.theme"
                                error:&error];
        NSUInteger expectedResources = [layout[@"expectedResources"]
            unsignedIntegerValue];
        if (expectedResources == 0) expectedResources = 1;
        MTAssert(result != nil &&
                 result.manifest.resources.count == expectedResources,
            ([NSString stringWithFormat:
                @"a theme using the %@ must still import",
                layout[@"label"]]));
        [NSFileManager.defaultManager removeItemAtPath:root error:NULL];
    }
}

static void MTTestClockComponentImport(void) {
    NSString *root = MTCreateTemporaryDirectory(@"clock-import");
    NSString *iconBundles = [root stringByAppendingPathComponent:
        @"IconBundles"];
    NSString *springBoardBundle = [root stringByAppendingPathComponent:
        @"Bundles/com.apple.springboard"];
    NSError *error = nil;
    MTAssert([NSFileManager.defaultManager
        createDirectoryAtPath:iconBundles
  withIntermediateDirectories:YES
                   attributes:@{NSFilePosixPermissions : @0700}
                        error:&error] &&
        [NSFileManager.defaultManager
        createDirectoryAtPath:springBoardBundle
  withIntermediateDirectories:YES
                   attributes:@{NSFilePosixPermissions : @0700}
                        error:&error],
        @"Clock import fixture directories must initialize");
    NSData *icon = MTPNGFixtureData(1, 1, 8, 6, 0, YES, @[], @[]);
    NSData *background = icon;
    NSData *hand = icon;
    MTAssert([icon writeToFile:[iconBundles stringByAppendingPathComponent:
        @"com.example.ClockFixture-large.png"] options:0 error:&error] &&
        [background writeToFile:[springBoardBundle
            stringByAppendingPathComponent:@"ClockIconBackgroundSquare.png"]
            options:0 error:&error] &&
        [hand writeToFile:[springBoardBundle
            stringByAppendingPathComponent:@"ClockIconHourHand.png"]
            options:0 error:&error],
        @"Clock import fixture images must be privately written");
    MTSafeDirectoryScan *scan = [[[MTSafeDirectoryScanner alloc]
        initWithLimits:MTImportLimits.defaultLimits]
        scanDirectorySourceAtURL:
            [NSURL fileURLWithPath:root isDirectory:YES]
        error:&error];
    MTIconBundlesImportResult *result = [[[MTIconBundlesImporter alloc] init]
        importSourceInventory:scan.inventory
                    sourceName:@"Clock.theme"
                         error:&error];
    NSSet<NSString *> *keys = [NSSet setWithArray:[result.manifest.resources
        valueForKeyPath:@"resourceKey.canonicalString"]];
    MTResourceKey *backgroundKey = [[MTResourceKey alloc]
        initWithModuleID:MTClockIconsModuleID
                 surface:@"springboard.home"
                 subject:MTClockIconTargetBundleIdentifier
                 variant:@"background" scale:0 trait:@"any" error:&error];
    MTResourceKey *hourKey = [[MTResourceKey alloc]
        initWithModuleID:MTClockIconsModuleID
                 surface:@"springboard.home"
                 subject:MTClockIconTargetBundleIdentifier
                 variant:@"hour-hand" scale:0 trait:@"any" error:&error];
    MTResourceKey *staticAliasKey = [[MTResourceKey alloc]
        initWithModuleID:@"icons.static"
                 surface:@"springboard.home"
                 subject:MTClockIconTargetBundleIdentifier
                 variant:@"primary" scale:0 trait:@"any" error:&error];
    MTAssert(result != nil && error == nil &&
        result.recognizedFileCount == 3 &&
        result.rejectedFileCount == 0 && result.ignoredFileCount == 0 &&
        result.manifest.importerVersion == 4 &&
        [result.manifest.capabilities containsObject:MTClockIconsModuleID] &&
        [keys containsObject:backgroundKey.canonicalString] &&
        [keys containsObject:hourKey.canonicalString] &&
        [keys containsObject:staticAliasKey.canonicalString],
        @"legacy Clock components must enter their module and alias the live face into the static cache");
    [NSFileManager.defaultManager removeItemAtPath:root error:NULL];
}

static void MTTestGlobalIconSurfaceImport(void) {
    NSString *root = MTCreateTemporaryDirectory(@"global-icon-surfaces");
    NSString *iconBundles = [root stringByAppendingPathComponent:
        @"IconBundles"];
    NSError *error = nil;
    MTAssert([NSFileManager.defaultManager
        createDirectoryAtPath:iconBundles
  withIntermediateDirectories:YES
                   attributes:@{ NSFilePosixPermissions : @0700 }
                        error:&error],
        @"global icon surface fixture directory must initialize");
    NSData *png = MTPNGFixtureData(240, 240, 8, 6, 0, YES, @[], @[]);
    for (NSString *filename in @[
        @"icon_mask.png", @"icon_pattern.png",
        @"icon_folder.png", @"icon_folder_light.png",
    ]) {
        MTAssert([png writeToFile:[iconBundles
            stringByAppendingPathComponent:filename]
                         options:0 error:&error],
            @"global icon surface fixture must write each PNG");
    }
    NSData *info = MTPropertyListFixtureData(
        @{ @"IB-MaskIcons" : @YES }, NSPropertyListBinaryFormat_v1_0);
    MTAssert([info writeToFile:[root stringByAppendingPathComponent:
        @"Info.plist"] options:0 error:&error],
        @"global icon surface fixture must write its metadata");

    MTSafeDirectoryScan *scan = [[[MTSafeDirectoryScanner alloc]
        initWithLimits:MTImportLimits.defaultLimits]
        scanDirectorySourceAtURL:
            [NSURL fileURLWithPath:root isDirectory:YES]
        error:&error];
    MTSafePropertyListDocument *document =
        [[[MTSafePropertyListReader alloc]
            initWithLimits:MTSafePropertyListLimits.defaultLimits]
            readPropertyListData:info
            cancellationToken:nil
            error:&error];
    MTThemeImportMetadata *metadata =
        [[[MTThemeInfoMetadataMapper alloc] init]
            mapDocument:document sourceName:@"Surfaces.theme" error:&error];
    MTIconBundlesImporter *importer = [[MTIconBundlesImporter alloc] init];
    MTIconBundlesImportResult *result = [importer
        importSourceInventory:scan.inventory
                    sourceName:@"Surfaces.theme"
                importMetadata:metadata
                         error:&error];

    NSMutableSet<NSString *> *canonicalKeys = [NSMutableSet set];
    NSMutableSet<NSString *> *assetDigests = [NSMutableSet set];
    for (MTThemeResource *resource in result.manifest.resources) {
        [canonicalKeys addObject:resource.resourceKey.canonicalString];
        [assetDigests addObject:resource.contentSHA256];
    }
    NSMutableSet<NSString *> *expectedKeys = [NSMutableSet set];
    for (NSString *variant in MTIconMaskResourceVariants()) {
        MTResourceKey *key = [[MTResourceKey alloc]
            initWithModuleID:MTIconMaskModuleID
                     surface:MTIconMaskSurface
                     subject:MTIconMaskGlobalSubject
                     variant:variant scale:0 trait:@"any" error:&error];
        [expectedKeys addObject:key.canonicalString];
    }
    for (NSString *variant in MTFolderIconResourceVariants()) {
        MTResourceKey *key = [[MTResourceKey alloc]
            initWithModuleID:MTFolderIconsModuleID
                     surface:MTFolderIconSurface
                     subject:MTFolderIconGlobalSubject
                     variant:variant scale:0 trait:@"any" error:&error];
        [expectedKeys addObject:key.canonicalString];
    }
    MTIconMaskConfiguration *configuration =
        [[MTIconMaskConfiguration alloc]
            initWithDictionary:
                result.manifest.moduleConfigurations[MTIconMaskModuleID]
            error:&error];
    MTThemeCapabilityReport *capabilityReport =
        [MTThemeCapabilityReport reportForManifest:result.manifest];
    MTThemeCapabilityItem *maskCapability = [capabilityReport
        itemForFeatureID:MTThemeFeatureIconMask];
    MTThemeCapabilityItem *patternCapability = [capabilityReport
        itemForFeatureID:MTThemeFeatureIconPattern];
    MTAssert(result != nil && error == nil &&
             result.recognizedFileCount == 4 &&
             result.rejectedFileCount == 0 &&
             result.ignoredFileCount == 1 &&
             result.manifest.importerVersion == 7 &&
             result.manifest.resources.count == 4 &&
             [canonicalKeys isEqualToSet:expectedKeys] &&
             assetDigests.count == 1 && configuration.isEnabled &&
             [result.manifest.capabilities
                 containsObject:MTIconMaskModuleID] &&
             [result.manifest.capabilities
                 containsObject:MTFolderIconsModuleID] &&
             capabilityReport.recognizedFeatureCount == 3 &&
             capabilityReport.runtimeApplicableFeatureCount == 2 &&
             maskCapability.isRuntimeApplicable &&
             patternCapability.hasRecognizedContent &&
             !patternCapability.isRuntimeApplicable &&
             maskCapability.metricPresentation ==
                 MTThemeCapabilityMetricPresentationComponentProgress &&
             [maskCapability.titleLocalizationKey
                 isEqualToString:@"theme.capability.icon-mask.title"] &&
             [maskCapability.symbolName
                 isEqualToString:@"square.dashed.inset.filled"],
        @"global mask, pattern, and folder resources must keep distinct semantics while sharing identical bytes");

    MTThemeResource *folderLightResource = nil;
    for (MTThemeResource *resource in result.manifest.resources) {
        if ([resource.resourceKey.moduleID
                isEqualToString:MTFolderIconsModuleID] &&
            [resource.resourceKey.variant
                isEqualToString:MTFolderIconVariantBackgroundLight]) {
            folderLightResource = resource;
            break;
        }
    }
    MTThemeManifest *incompleteFolderManifest = [[MTThemeManifest alloc]
        initWithThemeID:@"theme.incomplete-folder-fixture"
             displayName:@"Incomplete Folder Fixture"
                  author:@""
            themeVersion:@""
              importerID:@"import.test"
         importerVersion:1
       sourceFingerprint:result.manifest.sourceFingerprint
            capabilities:@[MTFolderIconsModuleID]
               resources:folderLightResource == nil
                   ? @[] : @[folderLightResource]
                   error:&error];
    MTThemeCapabilityItem *incompleteFolderCapability =
        [[MTThemeCapabilityReport
            reportForManifest:incompleteFolderManifest]
            itemForFeatureID:MTThemeFeatureFolders];
    MTAssert(incompleteFolderManifest != nil && error == nil &&
             incompleteFolderCapability.hasRecognizedContent &&
             !incompleteFolderCapability.isRuntimeApplicable &&
             incompleteFolderCapability.availability ==
                 MTThemeCapabilityAvailabilityImportedOnly,
        @"an existing incomplete Folder manifest must not be presented as Runtime-applicable");

    MTSafePropertyListDocument *disabledDocument =
        [[[MTSafePropertyListReader alloc]
            initWithLimits:MTSafePropertyListLimits.defaultLimits]
            readPropertyListData:MTPropertyListFixtureData(
                @{}, NSPropertyListXMLFormat_v1_0)
            cancellationToken:nil
            error:&error];
    MTThemeImportMetadata *disabledMetadata =
        [[[MTThemeInfoMetadataMapper alloc] init]
            mapDocument:disabledDocument
              sourceName:@"Surfaces.theme"
                   error:&error];
    MTIconBundlesImportResult *disabled = [importer
        importSourceInventory:scan.inventory
                    sourceName:@"Surfaces.theme"
                importMetadata:disabledMetadata
                         error:&error];
    MTAssert(disabled != nil && error == nil &&
             disabled.recognizedFileCount == 2 &&
             disabled.rejectedFileCount == 2 &&
             disabled.ignoredFileCount == 1 &&
             disabled.diagnostics.count == 2 &&
             [disabled.manifest.capabilities
                 isEqualToArray:@[MTFolderIconsModuleID]],
        @"mask files without the explicit source opt-in must not silently activate masking");

    NSString *baseFolderPath = [iconBundles
        stringByAppendingPathComponent:@"icon_folder.png"];
    NSString *staticIconPath = [iconBundles
        stringByAppendingPathComponent:@"com.example.FolderGuard.png"];
    MTAssert([NSFileManager.defaultManager
        removeItemAtPath:baseFolderPath error:&error] &&
        [png writeToFile:staticIconPath options:0 error:&error],
        @"orphaned Folder fixture must remove the base and retain another applicable resource");
    MTSafeDirectoryScan *orphanedScan = [[[MTSafeDirectoryScanner alloc]
        initWithLimits:MTImportLimits.defaultLimits]
        scanDirectorySourceAtURL:
            [NSURL fileURLWithPath:root isDirectory:YES]
        error:&error];
    MTIconBundlesImportResult *orphaned = [importer
        importSourceInventory:orphanedScan.inventory
                    sourceName:@"Surfaces.theme"
                importMetadata:disabledMetadata
                         error:&error];
    BOOL hasMissingFolderDiagnostic = NO;
    for (MTDiagnostic *diagnostic in orphaned.diagnostics) {
        hasMissingFolderDiagnostic = hasMissingFolderDiagnostic ||
            [diagnostic.code isEqualToString:
                @"import.folder.background-missing"];
    }
    MTAssert(orphaned != nil && error == nil &&
             orphaned.recognizedFileCount == 1 &&
             orphaned.rejectedFileCount == 2 &&
             orphaned.ignoredFileCount == 2 &&
             orphaned.manifest.resources.count == 1 &&
             [orphaned.manifest.capabilities
                 isEqualToArray:@[@"icons.static"]] &&
             hasMissingFolderDiagnostic,
        @"a light-only Folder resource must be ignored during import without disabling unrelated theme content");

    [NSFileManager.defaultManager removeItemAtPath:root error:NULL];
}

static void MTTestLegacyAppIconMaskImport(void) {
    NSString *root = MTCreateTemporaryDirectory(@"legacy-appicon-mask");
    NSString *maskDirectory = [root stringByAppendingPathComponent:
        @"Bundles/com.apple.mobileicons.framework"];
    NSError *error = nil;
    MTAssert([NSFileManager.defaultManager
        createDirectoryAtPath:maskDirectory
  withIntermediateDirectories:YES
                   attributes:@{ NSFilePosixPermissions : @0700 }
                        error:&error],
        @"legacy mask fixture directory must initialize");
    NSData *png = MTPNGFixtureData(240, 240, 8, 6, 0, YES, @[], @[]);
    for (NSString *filename in @[
        @"AppIconMask@3x~iphone.png",
        @"AppIconMask@2x~iphone.png",
        @"AppIconMask@3x~ipad.png",
        @"AppIconPattern@2x~iphone.png",
    ]) {
        MTAssert([png writeToFile:[maskDirectory
            stringByAppendingPathComponent:filename]
                         options:0 error:&error],
            @"legacy mask fixture must write each PNG");
    }
    NSString *iconBundles = [root stringByAppendingPathComponent:
        @"IconBundles"];
    MTAssert([NSFileManager.defaultManager
        createDirectoryAtPath:iconBundles
  withIntermediateDirectories:YES
                   attributes:@{ NSFilePosixPermissions : @0700 }
                        error:&error] &&
        [png writeToFile:
            [iconBundles stringByAppendingPathComponent:
                @"com.apple.AppStore-large.png"]
                   options:0 error:&error],
        @"legacy mask fixture must also carry one ordinary app icon");
    NSData *info = MTPropertyListFixtureData(
        @{ @"IB-MaskIcons" : @YES }, NSPropertyListBinaryFormat_v1_0);
    MTAssert([info writeToFile:[root stringByAppendingPathComponent:
        @"Info.plist"] options:0 error:&error],
        @"legacy mask fixture must write its metadata");

    MTSafeDirectoryScan *scan = [[[MTSafeDirectoryScanner alloc]
        initWithLimits:MTImportLimits.defaultLimits]
        scanDirectorySourceAtURL:
            [NSURL fileURLWithPath:root isDirectory:YES]
        error:&error];
    MTSafePropertyListDocument *document =
        [[[MTSafePropertyListReader alloc]
            initWithLimits:MTSafePropertyListLimits.defaultLimits]
            readPropertyListData:info
            cancellationToken:nil
            error:&error];
    MTThemeImportMetadata *metadata =
        [[[MTThemeInfoMetadataMapper alloc] init]
            mapDocument:document sourceName:@"LegacyMask.theme" error:&error];
    MTIconBundlesImporter *importer = [[MTIconBundlesImporter alloc] init];
    MTIconBundlesImportResult *result = [importer
        importSourceInventory:scan.inventory
                    sourceName:@"LegacyMask.theme"
                importMetadata:metadata
                         error:&error];

    MTResourceKey *maskKey = [[MTResourceKey alloc]
        initWithModuleID:MTIconMaskModuleID
                 surface:MTIconMaskSurface
                 subject:MTIconMaskGlobalSubject
                 variant:MTIconMaskVariantMask
                   scale:0
                   trait:@"any"
                   error:&error];
    MTResourceKey *patternKey = [[MTResourceKey alloc]
        initWithModuleID:MTIconMaskModuleID
                 surface:MTIconMaskSurface
                 subject:MTIconMaskGlobalSubject
                 variant:MTIconMaskVariantPattern
                   scale:0
                   trait:@"any"
                   error:&error];
    MTThemeResource *maskResource = nil;
    MTThemeResource *patternResource = nil;
    NSUInteger maskVariantCount = 0;
    NSUInteger shadowedDiagnostics = 0;
    for (MTThemeResource *resource in result.manifest.resources) {
        if (![resource.resourceKey.moduleID
                isEqualToString:MTIconMaskModuleID]) continue;
        if ([resource.resourceKey.variant
                isEqualToString:MTIconMaskVariantMask]) {
            maskVariantCount++;
            maskResource = resource;
        } else if ([resource.resourceKey.variant
                isEqualToString:MTIconMaskVariantPattern]) {
            patternResource = resource;
        }
    }
    for (MTDiagnostic *diagnostic in result.diagnostics) {
        shadowedDiagnostics +=
            [diagnostic.code isEqualToString:@"import.resource.shadowed"];
    }
    MTIconMaskConfiguration *configuration =
        [[MTIconMaskConfiguration alloc]
            initWithDictionary:
                result.manifest.moduleConfigurations[MTIconMaskModuleID]
            error:&error];
    MTAssert(result != nil && error == nil &&
             maskVariantCount == 1 &&
             [maskResource.resourceKey.canonicalString
                 isEqualToString:maskKey.canonicalString] &&
             [maskResource.relativeAssetPath hasSuffix:
                 @"AppIconMask@3x~iphone.png"] &&
             [patternResource.relativeAssetPath hasSuffix:
                 @"AppIconPattern@2x~iphone.png"] &&
             [patternResource.resourceKey.canonicalString
                 isEqualToString:patternKey.canonicalString] &&
             shadowedDiagnostics >= 2 &&
             configuration.isEnabled &&
             [result.manifest.capabilities containsObject:MTIconMaskModuleID] &&
             [result.manifest.capabilities containsObject:@"icons.static"],
        @"WinterBoard AppIconMask artwork must import onto the canonical mask key with the sharpest variant winning");

    // The legacy WinterBoard location activates by file presence: classic
    // themes predate the IB-MaskIcons opt-in, exactly as WinterBoard and
    // SnowBoard treated AppIconMask under mobileicons.framework.
    NSData *plainInfo = MTPropertyListFixtureData(
        @{ @"PackageName" : @"Classic Mask" }, NSPropertyListBinaryFormat_v1_0);
    MTSafePropertyListDocument *plainDocument =
        [[[MTSafePropertyListReader alloc]
            initWithLimits:MTSafePropertyListLimits.defaultLimits]
            readPropertyListData:plainInfo
            cancellationToken:nil
            error:&error];
    MTThemeImportMetadata *plainMetadata =
        [[[MTThemeInfoMetadataMapper alloc] init]
            mapDocument:plainDocument
              sourceName:@"LegacyMask.theme"
               error:&error];
    MTIconBundlesImportResult *plain = [importer
        importSourceInventory:scan.inventory
                    sourceName:@"LegacyMask.theme"
                importMetadata:plainMetadata
                         error:&error];
    BOOL plainHasMaskResource = NO;
    NSUInteger plainMaskCount = 0;
    for (MTThemeResource *resource in plain.manifest.resources) {
        if ([resource.resourceKey.moduleID
                isEqualToString:MTIconMaskModuleID]) {
            plainHasMaskResource = YES;
            plainMaskCount++;
        }
    }
    MTIconMaskConfiguration *plainConfiguration =
        [[MTIconMaskConfiguration alloc]
            initWithDictionary:
                plain.manifest.moduleConfigurations[MTIconMaskModuleID]
            error:&error];
    MTAssert(plain != nil && error == nil &&
             plainHasMaskResource && plainMaskCount == 2 &&
             [plain.manifest.capabilities containsObject:MTIconMaskModuleID] &&
             plainConfiguration.isEnabled,
        @"legacy AppIconMask files must activate masking by presence without IB-MaskIcons");

    [NSFileManager.defaultManager removeItemAtPath:root error:NULL];
}

static void MTTestLegacyIconOverlayImport(void) {
    NSString *root = MTCreateTemporaryDirectory(@"legacy-icon-overlay");
    NSString *effectsDirectory = [root stringByAppendingPathComponent:
        @"AnemoneEffects"];
    NSError *error = nil;
    MTAssert([NSFileManager.defaultManager
        createDirectoryAtPath:effectsDirectory
  withIntermediateDirectories:YES
                   attributes:@{ NSFilePosixPermissions : @0700 }
                        error:&error],
        @"legacy overlay fixture directory must initialize");
    NSData *png = MTPNGFixtureData(180, 180, 8, 6, 0, YES, @[], @[]);
    for (NSString *filename in @[
        @"iPhoneOverlay@3x.png",
        @"iPhoneOverlay@2x~iphone.png",
        @"iPadOverlay@3x.png",
        // The shadow canvas shares this directory and must keep its own family.
        @"iPhoneShadow@3x.png",
        // An unrecognized stem stays rejected with its existing diagnostic.
        @"iPhoneGlow@3x.png",
    ]) {
        MTAssert([png writeToFile:[effectsDirectory
            stringByAppendingPathComponent:filename]
                         options:0 error:&error],
            @"legacy overlay fixture must write each PNG");
    }
    NSString *iconBundles = [root stringByAppendingPathComponent:
        @"IconBundles"];
    MTAssert([NSFileManager.defaultManager
        createDirectoryAtPath:iconBundles
  withIntermediateDirectories:YES
                   attributes:@{ NSFilePosixPermissions : @0700 }
                        error:&error] &&
        [png writeToFile:
            [iconBundles stringByAppendingPathComponent:
                @"com.apple.AppStore-large.png"]
                   options:0 error:&error],
        @"legacy overlay fixture must also carry one ordinary app icon");
    NSData *info = MTPropertyListFixtureData(
        @{ @"PackageName" : @"Classic Overlay" },
        NSPropertyListBinaryFormat_v1_0);
    MTAssert([info writeToFile:[root stringByAppendingPathComponent:
        @"Info.plist"] options:0 error:&error],
        @"legacy overlay fixture must write its metadata");

    MTSafeDirectoryScan *scan = [[[MTSafeDirectoryScanner alloc]
        initWithLimits:MTImportLimits.defaultLimits]
        scanDirectorySourceAtURL:
            [NSURL fileURLWithPath:root isDirectory:YES]
        error:&error];
    MTSafePropertyListDocument *document =
        [[[MTSafePropertyListReader alloc]
            initWithLimits:MTSafePropertyListLimits.defaultLimits]
            readPropertyListData:info
            cancellationToken:nil
            error:&error];
    MTThemeImportMetadata *metadata =
        [[[MTThemeInfoMetadataMapper alloc] init]
            mapDocument:document
             sourceName:@"LegacyOverlay.theme"
                  error:&error];
    MTIconBundlesImporter *importer = [[MTIconBundlesImporter alloc] init];
    MTIconBundlesImportResult *result = [importer
        importSourceInventory:scan.inventory
                    sourceName:@"LegacyOverlay.theme"
                importMetadata:metadata
                         error:&error];

    MTResourceKey *overlayKey = [[MTResourceKey alloc]
        initWithModuleID:MTIconOverlayModuleID
                 surface:MTIconOverlaySurface
                 subject:MTIconOverlayGlobalSubject
                 variant:MTIconOverlayVariantOverlay
                   scale:0
                   trait:@"any"
                   error:&error];
    MTThemeResource *overlayResource = nil;
    NSUInteger overlayCount = 0;
    NSUInteger shadowCount = 0;
    NSUInteger shadowedDiagnostics = 0;
    NSUInteger unsupportedShadowDiagnostics = 0;
    for (MTThemeResource *resource in result.manifest.resources) {
        if ([resource.resourceKey.moduleID
                isEqualToString:MTIconOverlayModuleID]) {
            overlayCount++;
            overlayResource = resource;
        } else if ([resource.resourceKey.moduleID
                isEqualToString:MTIconShadowsModuleID]) {
            shadowCount++;
        }
    }
    for (MTDiagnostic *diagnostic in result.diagnostics) {
        shadowedDiagnostics +=
            [diagnostic.code isEqualToString:@"import.resource.shadowed"];
        unsupportedShadowDiagnostics += [diagnostic.code
            isEqualToString:@"import.icon-shadow.unsupported-subject"];
    }
    MTAssert(result != nil && error == nil &&
             // Every authored scale and device suffix converges on one
             // device-neutral key; the sharpest candidate wins.
             overlayCount == 1 &&
             [overlayResource.resourceKey.canonicalString
                 isEqualToString:overlayKey.canonicalString] &&
             // matchRank prefers a device-qualified suffix over a bare
             // scale, exactly as the mask family resolves its own conflicts.
             [overlayResource.relativeAssetPath hasSuffix:
                 @"iPhoneOverlay@2x~iphone.png"] &&
             overlayResource.resourceKey.scale == 0 &&
             [overlayResource.resourceKey.trait isEqualToString:@"any"] &&
             shadowedDiagnostics == 2 &&
             shadowCount == 1 &&
             unsupportedShadowDiagnostics == 1 &&
             // The overlay activates on artwork alone and carries no
             // module configuration of its own.
             [result.manifest.capabilities
                 containsObject:MTIconOverlayModuleID] &&
             result.manifest.moduleConfigurations[
                 MTIconOverlayModuleID] == nil &&
             [result.manifest.capabilities
                 containsObject:MTIconShadowsModuleID] &&
             [result.manifest.capabilities containsObject:@"icons.static"],
        @"AnemoneEffects overlay artwork must import onto the canonical overlay key without disturbing the shadow family");

    MTThemeCapabilityReport *report = [MTThemeCapabilityReport
        reportForManifest:result.manifest];
    MTThemeCapabilityItem *overlayItem =
        [report itemForFeatureID:MTThemeFeatureIconOverlay];
    MTAssert(overlayItem != nil &&
             overlayItem.availability ==
                 MTThemeCapabilityAvailabilityReady &&
             overlayItem.resourceCount == 1 &&
             [overlayItem.moduleID isEqualToString:MTIconOverlayModuleID],
        @"one imported overlay must report as an applicable capability");

    [NSFileManager.defaultManager removeItemAtPath:root error:NULL];
}

static void MTTestThemeLibrary(MTThemeManifest *manifest) {
    NSString *libraryRoot = MTCreateTemporaryDirectory(@"library");
    MTThemeLibraryStore *library = [[MTThemeLibraryStore alloc]
        initWithRootURL:[NSURL fileURLWithPath:libraryRoot isDirectory:YES]];
    NSError *error = nil;
    NSString *firstDigest = [library saveManifestRevision:manifest error:&error];
    MTThemeManifest *loaded = [library
        loadCurrentManifestForThemeID:manifest.themeID error:&error];
    MTAssert(firstDigest != nil && [loaded.themeID isEqualToString:manifest.themeID],
             @"library must atomically save and reload a canonical manifest");
    MTAssert([[loaded contentDigestWithError:&error] isEqualToString:firstDigest],
             @"library readback must preserve the canonical digest");
    MTAssert([[library saveManifestRevision:manifest error:&error]
                 isEqualToString:firstDigest],
             @"saving an identical manifest revision must be idempotent");

    MTThemeManifest *changed = [[MTThemeManifest alloc]
        initWithThemeID:manifest.themeID
             displayName:@"Fixture Revised"
                  author:manifest.author
            themeVersion:@"2"
              importerID:manifest.importerID
         importerVersion:manifest.importerVersion
       sourceFingerprint:manifest.sourceFingerprint
            capabilities:manifest.capabilities
    moduleConfigurations:manifest.moduleConfigurations
               resources:manifest.resources
                   error:&error];
    NSString *secondDigest = [library saveManifestRevision:changed error:&error];
    MTThemeManifest *current = [library
        loadCurrentManifestForThemeID:manifest.themeID error:&error];
    MTAssert(secondDigest != nil && ![secondDigest isEqualToString:firstDigest] &&
             [current.displayName isEqualToString:@"Fixture Revised"],
             @"new library revision must atomically replace only the current pointer");

    NSString *themesPath = [libraryRoot stringByAppendingPathComponent:@"themes"];
    NSArray<NSString *> *storageIDs = [NSFileManager.defaultManager
        contentsOfDirectoryAtPath:themesPath error:&error];
    MTAssert(storageIDs.count == 1 && [storageIDs.firstObject hasPrefix:@"t-"] &&
             ![storageIDs.firstObject containsString:manifest.themeID],
             @"theme ID must be mapped to a controlled storage identifier");
    NSString *revisionsPath = [[[themesPath
        stringByAppendingPathComponent:storageIDs.firstObject]
        stringByAppendingPathComponent:@"revisions"] copy];
    NSArray *revisions = [NSFileManager.defaultManager
        contentsOfDirectoryAtPath:revisionsPath error:&error];
    MTAssert(revisions.count == 2,
             @"publishing a new manifest must preserve the previous revision");
    NSString *currentManifestPath = [[revisionsPath
        stringByAppendingPathComponent:secondDigest]
        stringByAppendingPathComponent:@"manifest.json"];
    MTAssert([[@"tampered" dataUsingEncoding:NSUTF8StringEncoding]
        writeToFile:currentManifestPath options:0 error:&error],
        @"library corruption fixture must be written");
    error = nil;
    MTAssert([library loadCurrentManifestForThemeID:manifest.themeID
                                              error:&error] == nil && error != nil,
        @"library readback must reject a corrupted current manifest");
    [NSFileManager.defaultManager removeItemAtPath:libraryRoot error:NULL];
}

static MTAssetStagingSession *_Nullable MTStageLibraryFixtureAssets(
    MTAssetStagingConfiguration *configuration,
    id<MTAuditedSource> source,
    NSArray<NSString *> *relativePaths,
    NSError **error) {
    MTAssetStagingSession *session = [MTAssetStagingSession
        sessionWithConfiguration:configuration error:error];
    if (session == nil) return nil;
    for (NSString *relativePath in relativePaths) {
        MTSourceFile *file = [source.inventory
            fileAtRelativePath:relativePath];
        if (file == nil || [session
            stageAssetAtRelativePath:relativePath
                          fromSource:source
                    maximumByteCount:file.byteCount
                   cancellationToken:nil
                               error:error] == nil) {
            return nil;
        }
    }
    return session;
}

static MTThemeManifest *MTLibraryFixtureManifest(
    NSString *displayName,
    NSString *themeVersion,
    MTSourceInventory *inventory,
    NSError **error) {
    MTSourceFile *primary = [inventory
        fileAtRelativePath:@"Assets/Primary.bin"];
    MTSourceFile *secondary = [inventory
        fileAtRelativePath:@"Assets/Secondary.bin"];
    MTThemeResource *first = [[MTThemeResource alloc]
        initWithResourceKey:MTMakeKey(@"com.example.library-primary")
           relativeAssetPath:primary.relativePath
               contentSHA256:primary.contentSHA256
                sourceFormat:@"opaque"
                   matchRank:0
                       error:error];
    MTThemeResource *second = [[MTThemeResource alloc]
        initWithResourceKey:MTMakeKey(@"com.example.library-secondary")
           relativeAssetPath:secondary.relativePath
               contentSHA256:secondary.contentSHA256
                sourceFormat:@"opaque"
                   matchRank:0
                       error:error];
    if (first == nil || second == nil) return nil;
    return [[MTThemeManifest alloc]
        initWithThemeID:@"theme.formal-library-fixture"
             displayName:displayName
                  author:@"MarkTheme Tests"
            themeVersion:themeVersion
              importerID:@"import.formal-library-fixture"
         importerVersion:1
       sourceFingerprint:inventory.sourceFingerprint
            capabilities:@[@"icons.static"]
               resources:@[first, second]
                   error:error];
}

static void MTTestFormalThemeLibraryTransaction(void) {
    NSString *root = MTCreateTemporaryDirectory(@"formal-library");
    NSString *sourceRoot = [root stringByAppendingPathComponent:@"source"];
    NSString *assetsRoot = [sourceRoot
        stringByAppendingPathComponent:@"Assets"];
    NSError *error = nil;
    MTAssert([NSFileManager.defaultManager
        createDirectoryAtPath:assetsRoot
  withIntermediateDirectories:YES
                   attributes:@{NSFilePosixPermissions : @0700}
                        error:&error],
        @"formal Library fixture directory must be created");

    NSMutableData *primaryData =
        [NSMutableData dataWithLength:192 * 1024 + 41];
    uint8_t *primaryBytes = primaryData.mutableBytes;
    uint32_t state = 0x4c696272;
    for (NSUInteger index = 0; index < primaryData.length; index++) {
        state = state * 1103515245U + 12345U;
        primaryBytes[index] = (uint8_t)(state >> 23);
    }
    NSData *secondaryData = [@"secondary formal asset"
        dataUsingEncoding:NSUTF8StringEncoding];
    NSData *extraData = [@"unreferenced staged asset"
        dataUsingEncoding:NSUTF8StringEncoding];
    NSString *primaryPath = [assetsRoot
        stringByAppendingPathComponent:@"Primary.bin"];
    NSString *secondaryPath = [assetsRoot
        stringByAppendingPathComponent:@"Secondary.bin"];
    NSString *extraPath = [assetsRoot
        stringByAppendingPathComponent:@"Extra.bin"];
    MTAssert([primaryData writeToFile:primaryPath options:0 error:&error] &&
             [secondaryData writeToFile:secondaryPath options:0 error:&error] &&
             [extraData writeToFile:extraPath options:0 error:&error] &&
             chmod(primaryPath.fileSystemRepresentation, 0600) == 0 &&
             chmod(secondaryPath.fileSystemRepresentation, 0600) == 0 &&
             chmod(extraPath.fileSystemRepresentation, 0600) == 0,
        @"formal Library fixture assets must be privately written");

    MTSafeDirectoryScan *source =
        [[[MTSafeDirectoryScanner alloc]
            initWithLimits:MTImportLimits.defaultLimits]
            scanDirectorySourceAtURL:
                [NSURL fileURLWithPath:sourceRoot isDirectory:YES]
            error:&error];
    MTThemeManifest *manifest = MTLibraryFixtureManifest(
        @"Formal Fixture", @"1", source.inventory, &error);
    MTThemeManifest *changedManifest = MTLibraryFixtureManifest(
        @"Formal Fixture Revised", @"2", source.inventory, &error);
    MTAssert(source != nil && manifest != nil && changedManifest != nil &&
             error == nil,
        @"formal Library source and manifests must initialize");

    NSURL *sessionsRootURL = [NSURL fileURLWithPath:
        [root stringByAppendingPathComponent:@"sessions"] isDirectory:YES];
    MTAssetStagingConfiguration *stagingConfiguration =
        [[MTAssetStagingConfiguration alloc]
            initWithSessionsRootURL:sessionsRootURL
                             limits:MTImportLimits.defaultLimits];
    NSArray<NSString *> *requiredPaths = @[
        @"Assets/Primary.bin", @"Assets/Secondary.bin"
    ];
    NSString *libraryRoot = [root stringByAppendingPathComponent:@"library"];
    MTThemeLibraryConfiguration *libraryConfiguration =
        [[MTThemeLibraryConfiguration alloc]
            initWithRootURL:[NSURL fileURLWithPath:libraryRoot isDirectory:YES]
                     limits:MTImportLimits.defaultLimits
       minimumFreeSpaceReserveBytes:0];
    MTThemeLibraryStore *library = [[MTThemeLibraryStore alloc]
        initWithConfiguration:libraryConfiguration];

    NSString *normalizedThemeID = MTNormalizeIdentifier(manifest.themeID, NULL);
    NSString *storageDigest = MTSHA256HexDigestForData(
        [normalizedThemeID dataUsingEncoding:NSUTF8StringEncoding]);
    NSString *storageID = [@"t-" stringByAppendingString:
        [storageDigest substringToIndex:32]];
    NSString *themePath = [[[libraryRoot
        stringByAppendingPathComponent:@"themes"]
        stringByAppendingPathComponent:storageID] copy];
    NSString *revisionsPath = [themePath
        stringByAppendingPathComponent:@"revisions"];
    MTAssert([NSFileManager.defaultManager
        createDirectoryAtPath:revisionsPath
  withIntermediateDirectories:YES
                   attributes:@{NSFilePosixPermissions : @0700}
                        error:&error],
        @"formal Library lock fixture directories must be created");
    NSString *lockPath = [themePath
        stringByAppendingPathComponent:@"transaction.lock"];
    int heldLock = open(lockPath.fileSystemRepresentation,
        O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600);
    MTAssert(heldLock >= 0 && fchmod(heldLock, 0600) == 0 &&
             flock(heldLock, LOCK_EX | LOCK_NB) == 0,
        @"formal Library contention fixture must hold the per-theme lock");

    MTAssetStagingSession *firstSession = MTStageLibraryFixtureAssets(
        stagingConfiguration, source, requiredPaths, &error);
    NSString *firstSessionPath = firstSession.sessionDirectoryURL.path;
    error = nil;
    MTAssert([library commitManifest:manifest
            fromAssetStagingSession:firstSession
            cancellationToken:nil error:&error] == nil &&
             [error.domain
                isEqualToString:MTThemeLibraryStoreErrorDomain] &&
             error.code == MTThemeLibraryStoreErrorBusy &&
             firstSession.isActive &&
             access(firstSessionPath.fileSystemRepresentation, F_OK) == 0,
        @"a contended theme commit must fail quickly without consuming staging");
    MTAssert(flock(heldLock, LOCK_UN) == 0 && close(heldLock) == 0,
             @"formal Library contention fixture must release its lock");

    error = nil;
    MTThemeLibraryRevision *firstRevision = [library
        commitManifest:manifest
        fromAssetStagingSession:firstSession
        cancellationToken:nil error:&error];
    uint64_t expectedAssetBytes = primaryData.length + secondaryData.length;
    NSData *storedPrimary = [NSData dataWithContentsOfURL:
        firstRevision.assetURLsByContentSHA256[
            [source.inventory fileAtRelativePath:@"Assets/Primary.bin"]
                .contentSHA256]
        options:0 error:&error];
    MTAssert(firstRevision != nil && error == nil &&
             [firstRevision.revisionIdentifier hasPrefix:@"r1-"] &&
             [firstRevision.revisionIdentifier substringFromIndex:3].length == 64 &&
             firstRevision.assetCount == 2 &&
             firstRevision.assetByteCount == expectedAssetBytes &&
             [storedPrimary isEqualToData:primaryData] &&
             !firstSession.isActive &&
             access(firstSessionPath.fileSystemRepresentation, F_OK) != 0,
        @"formal commit must atomically publish and consume the exact staged set");

    MTThemeLibraryRevision *loaded = [library
        loadCurrentRevisionForThemeID:manifest.themeID error:&error];
    MTThemeManifest *metadataLoaded = [library
        loadCurrentManifestForThemeID:manifest.themeID error:&error];
    MTAssert(loaded != nil && metadataLoaded != nil && error == nil &&
             [loaded.revisionIdentifier
                isEqualToString:firstRevision.revisionIdentifier] &&
             [loaded.manifestDigest isEqualToString:
                [manifest contentDigestWithError:&error]] &&
             [metadataLoaded.displayName isEqualToString:@"Formal Fixture"],
        @"formal current reads must validate every asset and support manifest callers");

    error = nil;
    MTAssetStagingSession *duplicateSession = MTStageLibraryFixtureAssets(
        stagingConfiguration, source, requiredPaths, &error);
    MTThemeLibraryRevision *duplicateRevision = [library
        commitManifest:manifest
        fromAssetStagingSession:duplicateSession
        cancellationToken:nil error:&error];
    NSArray<NSString *> *revisionNames = [NSFileManager.defaultManager
        contentsOfDirectoryAtPath:revisionsPath error:&error];
    NSPredicate *formalRevisionPredicate = [NSPredicate
        predicateWithBlock:^BOOL(NSString *name,
                                 __unused NSDictionary *bindings) {
        return [name hasPrefix:@"r1-"];
    }];
    MTAssert(duplicateRevision != nil && error == nil &&
             [duplicateRevision.revisionIdentifier
                isEqualToString:firstRevision.revisionIdentifier] &&
             !duplicateSession.isActive &&
             [[revisionNames filteredArrayUsingPredicate:
                formalRevisionPredicate] count] == 1,
        @"an identical formal revision must verify and reuse one immutable tree");

    error = nil;
    MTAssetStagingSession *missingSession = MTStageLibraryFixtureAssets(
        stagingConfiguration, source, @[requiredPaths.firstObject], &error);
    MTAssert([library commitManifest:changedManifest
            fromAssetStagingSession:missingSession
            cancellationToken:nil error:&error] == nil &&
             [error.domain
                isEqualToString:MTThemeLibraryStoreErrorDomain] &&
             error.code == MTThemeLibraryStoreErrorAssetSetMismatch &&
             missingSession.isActive &&
             [[library loadCurrentRevisionForThemeID:manifest.themeID
                error:NULL].revisionIdentifier
                isEqualToString:firstRevision.revisionIdentifier],
        @"a missing manifest asset must not switch current or consume retry state");
    MTAssert([missingSession discard:&error],
             @"missing-asset staging fixture must discard");

    error = nil;
    MTAssetStagingSession *extraSession = MTStageLibraryFixtureAssets(
        stagingConfiguration, source, @[
            @"Assets/Primary.bin", @"Assets/Secondary.bin", @"Assets/Extra.bin"
        ], &error);
    MTAssert([library commitManifest:changedManifest
            fromAssetStagingSession:extraSession
            cancellationToken:nil error:&error] == nil &&
             error.code == MTThemeLibraryStoreErrorAssetSetMismatch &&
             extraSession.isActive,
        @"an extra staged object must fail the exact-set transaction contract");
    MTAssert([extraSession discard:&error],
             @"extra-asset staging fixture must discard");

    error = nil;
    MTAssetStagingSession *cancelledSession = MTStageLibraryFixtureAssets(
        stagingConfiguration, source, requiredPaths, &error);
    MTThresholdCancellationToken *commitCancellation =
        [[MTThresholdCancellationToken alloc] initWithThreshold:5];
    NSString *changedRevisionID = [@"r1-" stringByAppendingString:
        [changedManifest contentDigestWithError:&error]];
    NSString *changedRevisionPath = [revisionsPath
        stringByAppendingPathComponent:changedRevisionID];
    error = nil;
    MTAssert([library commitManifest:changedManifest
            fromAssetStagingSession:cancelledSession
            cancellationToken:commitCancellation error:&error] == nil &&
             error.code == MTThemeLibraryStoreErrorCancelled &&
             cancelledSession.isActive && commitCancellation.readCount >= 5 &&
             access(changedRevisionPath.fileSystemRepresentation, F_OK) != 0 &&
             [[library loadCurrentRevisionForThemeID:manifest.themeID
                error:NULL].revisionIdentifier
                isEqualToString:firstRevision.revisionIdentifier],
        @"mid-commit cancellation must remove unpublished state and preserve current");
    MTAssert([cancelledSession discard:&error],
             @"cancelled formal staging fixture must discard");

    error = nil;
    MTAssetStagingSession *spaceSession = MTStageLibraryFixtureAssets(
        stagingConfiguration, source, requiredPaths, &error);
    MTThemeLibraryConfiguration *noSpaceConfiguration =
        [[MTThemeLibraryConfiguration alloc]
            initWithRootURL:[NSURL fileURLWithPath:libraryRoot isDirectory:YES]
                     limits:MTImportLimits.defaultLimits
       minimumFreeSpaceReserveBytes:UINT64_MAX];
    MTThemeLibraryStore *noSpaceLibrary = [[MTThemeLibraryStore alloc]
        initWithConfiguration:noSpaceConfiguration];
    error = nil;
    MTAssert([noSpaceLibrary commitManifest:changedManifest
            fromAssetStagingSession:spaceSession
            cancellationToken:nil error:&error] == nil &&
             error.code == MTThemeLibraryStoreErrorInsufficientSpace &&
             spaceSession.isActive &&
             access(changedRevisionPath.fileSystemRepresentation, F_OK) != 0,
        @"space admission must reserve the complete revision before copying");
    MTAssert([spaceSession discard:&error],
             @"space-rejected formal staging fixture must discard");

    NSString *abandonedName = [@".transaction-"
        stringByAppendingString:NSUUID.UUID.UUIDString.lowercaseString];
    NSString *abandonedPath = [revisionsPath
        stringByAppendingPathComponent:abandonedName];
    NSString *abandonedAssetsPath = [abandonedPath
        stringByAppendingPathComponent:@"assets"];
    MTAssert([NSFileManager.defaultManager
        createDirectoryAtPath:abandonedAssetsPath
  withIntermediateDirectories:YES
                   attributes:@{NSFilePosixPermissions : @0700}
                        error:&error],
        @"abandoned formal transaction fixture must be created");
    NSString *primaryDigest = [source.inventory
        fileAtRelativePath:@"Assets/Primary.bin"].contentSHA256;
    NSString *abandonedAssetPath = [abandonedAssetsPath
        stringByAppendingPathComponent:primaryDigest];
    NSString *abandonedManifestPath = [abandonedPath
        stringByAppendingPathComponent:@"manifest.json"];
    NSString *currentPartialName = [@".current-"
        stringByAppendingString:NSUUID.UUID.UUIDString.lowercaseString];
    NSString *currentPartialPath = [themePath
        stringByAppendingPathComponent:currentPartialName];
    MTAssert([primaryData writeToFile:abandonedAssetPath options:0
                                error:&error] &&
             [[manifest canonicalDataWithError:&error]
                writeToFile:abandonedManifestPath options:0 error:&error] &&
             [@"partial" writeToFile:currentPartialPath atomically:NO
                              encoding:NSUTF8StringEncoding error:&error] &&
             chmod(abandonedAssetPath.fileSystemRepresentation, 0600) == 0 &&
             chmod(abandonedManifestPath.fileSystemRepresentation, 0600) == 0 &&
             chmod(currentPartialPath.fileSystemRepresentation, 0600) == 0,
        @"abandoned formal transaction nodes must be privately written");
    error = nil;
    MTAssetStagingSession *recoverySession = MTStageLibraryFixtureAssets(
        stagingConfiguration, source, requiredPaths, &error);
    MTAssert([library commitManifest:manifest
            fromAssetStagingSession:recoverySession
            cancellationToken:nil error:&error] != nil && error == nil &&
             access(abandonedPath.fileSystemRepresentation, F_OK) != 0 &&
             access(currentPartialPath.fileSystemRepresentation, F_OK) != 0,
        @"the next locked commit must recover only canonical abandoned nodes");

    NSString *guardedName = [@".transaction-"
        stringByAppendingString:NSUUID.UUID.UUIDString.lowercaseString];
    NSString *guardedPath = [revisionsPath
        stringByAppendingPathComponent:guardedName];
    NSString *unknownPath = [guardedPath
        stringByAppendingPathComponent:@"unexpected"];
    MTAssert([NSFileManager.defaultManager
        createDirectoryAtPath:guardedPath
  withIntermediateDirectories:NO
                   attributes:@{NSFilePosixPermissions : @0700}
                        error:&error] &&
             [@"keep" writeToFile:unknownPath atomically:NO
                           encoding:NSUTF8StringEncoding error:&error] &&
             chmod(unknownPath.fileSystemRepresentation, 0600) == 0,
        @"unknown recovery-node fixture must be privately written");
    error = nil;
    MTAssetStagingSession *guardedSession = MTStageLibraryFixtureAssets(
        stagingConfiguration, source, requiredPaths, &error);
    MTAssert([library commitManifest:manifest
            fromAssetStagingSession:guardedSession
            cancellationToken:nil error:&error] == nil &&
             error.code == MTThemeLibraryStoreErrorRecovery &&
             guardedSession.isActive &&
             access(unknownPath.fileSystemRepresentation, F_OK) == 0,
        @"recovery must refuse unknown transaction nodes without deleting them");
    MTAssert([guardedSession discard:&error] &&
             [NSFileManager.defaultManager removeItemAtPath:guardedPath
                                                       error:&error],
        @"guarded recovery fixture must be explicitly removed by the test owner");

    error = nil;
    MTAssetStagingSession *changedSession = MTStageLibraryFixtureAssets(
        stagingConfiguration, source, requiredPaths, &error);
    MTThemeLibraryRevision *changedRevision = [library
        commitManifest:changedManifest
        fromAssetStagingSession:changedSession
        cancellationToken:nil error:&error];
    revisionNames = [NSFileManager.defaultManager
        contentsOfDirectoryAtPath:revisionsPath error:&error];
    MTAssert(changedRevision != nil && error == nil &&
             [changedRevision.revisionIdentifier
                isEqualToString:changedRevisionID] &&
             [[revisionNames filteredArrayUsingPredicate:
                formalRevisionPredicate] count] == 2 &&
             [[[library loadCurrentRevisionForThemeID:manifest.themeID
                error:&error] manifest].displayName
                isEqualToString:@"Formal Fixture Revised"],
        @"a second formal commit must switch current while preserving the old revision");

    NSString *changedRevisionPathPublished = [revisionsPath
        stringByAppendingPathComponent:changedRevision.revisionIdentifier];
    NSString *unknownRevisionPath = [changedRevisionPathPublished
        stringByAppendingPathComponent:@"unknown"];
    MTAssert([@"unknown" writeToFile:unknownRevisionPath atomically:NO
                              encoding:NSUTF8StringEncoding error:&error] &&
             chmod(unknownRevisionPath.fileSystemRepresentation, 0600) == 0,
        @"unknown formal revision fixture must be written");
    error = nil;
    MTAssert([library loadCurrentRevisionForThemeID:manifest.themeID
                                                error:&error] == nil &&
             error.code == MTThemeLibraryStoreErrorVerification &&
             [NSFileManager.defaultManager removeItemAtPath:unknownRevisionPath
                                                       error:NULL],
        @"formal reads must reject unknown revision entries");

    NSURL *corruptAssetURL = changedRevision.assetURLsByContentSHA256[
        primaryDigest];
    NSMutableData *corruptAsset = [primaryData mutableCopy];
    ((uint8_t *)corruptAsset.mutableBytes)[0] ^= 0xff;
    MTAssert([corruptAsset writeToURL:corruptAssetURL options:0 error:&error] &&
             chmod(corruptAssetURL.path.fileSystemRepresentation, 0600) == 0,
        @"formal revision corruption fixture must preserve private metadata");
    error = nil;
    MTAssert([library loadCurrentRevisionForThemeID:manifest.themeID
                                                error:&error] == nil &&
             error.code == MTThemeLibraryStoreErrorVerification &&
             [library loadCurrentManifestForThemeID:manifest.themeID
                                               error:NULL] == nil,
        @"formal reads must fail closed on complete asset checksum corruption");

    [NSFileManager.defaultManager removeItemAtPath:root error:NULL];
}

static MTThemeLibraryRevision *_Nullable MTCommitCatalogFixtureRevision(
    MTThemeLibraryStore *library,
    MTAssetStagingConfiguration *stagingConfiguration,
    id<MTAuditedSource> source,
    MTThemeManifest *manifest,
    NSError **error) {
    MTAssetStagingSession *session = MTStageLibraryFixtureAssets(
        stagingConfiguration, source,
        @[@"Assets/Primary.bin", @"Assets/Secondary.bin"], error);
    if (session == nil) return nil;
    return [library commitManifest:manifest
           fromAssetStagingSession:session
                 cancellationToken:nil
                             error:error];
}

static void MTTestThemeLibraryCatalog(void) {
    NSString *root = MTCreateTemporaryDirectory(@"library-catalog");
    NSError *error = nil;
    MTThemeLibraryConfiguration *emptyConfiguration =
        [[MTThemeLibraryConfiguration alloc]
            initWithRootURL:[NSURL fileURLWithPath:
                [root stringByAppendingPathComponent:@"empty-library"]
                isDirectory:YES]
                     limits:MTImportLimits.defaultLimits
       minimumFreeSpaceReserveBytes:0];
    MTThemeLibraryStore *emptyLibrary = [[MTThemeLibraryStore alloc]
        initWithConfiguration:emptyConfiguration];
    NSArray<MTThemeLibraryThemeSummary *> *emptyCatalog = [emptyLibrary
        loadThemeCatalogWithCancellationToken:nil error:&error];
    MTAssert(emptyCatalog.count == 0 && error == nil &&
             [emptyLibrary recoverAbandonedLibraryOperationsWithError:&error],
        @"an absent Library must project as an empty catalog and recover idempotently");

    NSString *sourceRoot = [root stringByAppendingPathComponent:@"source"];
    NSString *assetsRoot = [sourceRoot stringByAppendingPathComponent:@"Assets"];
    MTAssert([NSFileManager.defaultManager
        createDirectoryAtPath:assetsRoot
  withIntermediateDirectories:YES
                   attributes:@{NSFilePosixPermissions : @0700}
                        error:&error],
        @"catalog fixture source directory must be created");
    NSMutableData *primaryData = [NSMutableData dataWithLength:32 * 1024 + 17];
    uint8_t *primaryBytes = primaryData.mutableBytes;
    uint32_t state = 0x43617431;
    for (NSUInteger index = 0; index < primaryData.length; index++) {
        state = state * 1664525U + 1013904223U;
        primaryBytes[index] = (uint8_t)(state >> 24);
    }
    NSData *secondaryData = [@"catalog secondary asset"
        dataUsingEncoding:NSUTF8StringEncoding];
    NSString *primaryPath = [assetsRoot
        stringByAppendingPathComponent:@"Primary.bin"];
    NSString *secondaryPath = [assetsRoot
        stringByAppendingPathComponent:@"Secondary.bin"];
    MTAssert([primaryData writeToFile:primaryPath options:0 error:&error] &&
             [secondaryData writeToFile:secondaryPath options:0 error:&error] &&
             chmod(primaryPath.fileSystemRepresentation, 0600) == 0 &&
             chmod(secondaryPath.fileSystemRepresentation, 0600) == 0,
        @"catalog fixture assets must be privately written");

    MTSafeDirectoryScan *source = [[[MTSafeDirectoryScanner alloc]
        initWithLimits:MTImportLimits.defaultLimits]
        scanDirectorySourceAtURL:
            [NSURL fileURLWithPath:sourceRoot isDirectory:YES]
        error:&error];
    MTThemeManifest *firstManifest = MTLibraryFixtureManifest(
        @"Catalog Fixture", @"1", source.inventory, &error);
    MTThemeManifest *secondManifest = MTLibraryFixtureManifest(
        @"Catalog Fixture Revised", @"2", source.inventory, &error);
    MTAssert(source != nil && firstManifest != nil && secondManifest != nil &&
             error == nil,
        @"catalog source and revision manifests must initialize");

    NSURL *sessionsRootURL = [NSURL fileURLWithPath:
        [root stringByAppendingPathComponent:@"asset-sessions"]
        isDirectory:YES];
    MTAssetStagingConfiguration *stagingConfiguration =
        [[MTAssetStagingConfiguration alloc]
            initWithSessionsRootURL:sessionsRootURL
                             limits:MTImportLimits.defaultLimits];
    NSString *libraryRoot = [root stringByAppendingPathComponent:@"library"];
    MTThemeLibraryConfiguration *configuration =
        [[MTThemeLibraryConfiguration alloc]
            initWithRootURL:[NSURL fileURLWithPath:libraryRoot isDirectory:YES]
                     limits:MTImportLimits.defaultLimits
       minimumFreeSpaceReserveBytes:0];
    MTThemeLibraryStore *library = [[MTThemeLibraryStore alloc]
        initWithConfiguration:configuration];
    MTAssetStagingSession *incompleteSession = MTStageLibraryFixtureAssets(
        stagingConfiguration, source, @[@"Assets/Primary.bin"], &error);
    error = nil;
    MTAssert([library commitManifest:firstManifest
        fromAssetStagingSession:incompleteSession
        cancellationToken:nil error:&error] == nil &&
             error.code == MTThemeLibraryStoreErrorAssetSetMismatch &&
             incompleteSession.isActive,
        @"an incomplete first import must remain retryable without publication");
    error = nil;
    MTAssert([library loadThemeCatalogWithCancellationToken:nil
                                                     error:&error].count == 0 &&
             error == nil,
        @"a failed first import may leave a safe empty shell but no catalog theme");
    MTAssert([incompleteSession discard:&error],
        @"the incomplete catalog fixture session must remain explicitly discardable");
    error = nil;
    MTThemeLibraryRevision *firstRevision = MTCommitCatalogFixtureRevision(
        library, stagingConfiguration, source, firstManifest, &error);
    MTThemeLibraryRevision *secondRevision = MTCommitCatalogFixtureRevision(
        library, stagingConfiguration, source, secondManifest, &error);
    MTAssert(firstRevision != nil && secondRevision != nil && error == nil &&
             ![firstRevision.revisionIdentifier
                isEqualToString:secondRevision.revisionIdentifier],
        @"catalog fixture must publish two distinct formal revisions");

    NSArray<MTThemeLibraryThemeSummary *> *catalog = [library
        loadThemeCatalogWithCancellationToken:nil error:&error];
    MTThemeLibraryThemeSummary *theme = catalog.firstObject;
    MTAssert(catalog.count == 1 && error == nil &&
             [theme.themeID isEqualToString:firstManifest.themeID] &&
             theme.revisionCount == 2 && theme.formalRevisionCount == 2 &&
             theme.legacyRevisionCount == 0 && !theme.requiresReimport &&
             theme.revisionHistory.count == theme.revisionCount &&
             theme.revisionHistory.firstObject == theme.currentRevision &&
             [theme.currentRevision.revisionIdentifier
                isEqualToString:secondRevision.revisionIdentifier],
        @"catalog must retain one immutable history read model without a persisted index");

    NSString *previewPrimaryDigest = [source.inventory
        fileAtRelativePath:@"Assets/Primary.bin"].contentSHA256;
    NSString *previewSecondaryDigest = [source.inventory
        fileAtRelativePath:@"Assets/Secondary.bin"].contentSHA256;
    error = nil;
    NSDictionary<NSString *, NSData *> *previewData = [library
        loadPreviewAssetDataForThemeID:theme.themeID
        expectedRevisionIdentifier:theme.currentRevision.revisionIdentifier
        expectedManifest:theme.currentRevision.manifest
        contentSHA256Digests:@[previewPrimaryDigest]
        error:&error];
    MTAssert([previewData[previewPrimaryDigest] isEqualToData:primaryData] &&
             error == nil,
        @"bounded preview reads must return only requested current-revision data");
    MTImportCancellationToken *cancelledPreviewToken =
        [[MTImportCancellationToken alloc] init];
    [cancelledPreviewToken cancel];
    error = nil;
    MTAssert([library loadPreviewAssetDataForThemeID:theme.themeID
        expectedRevisionIdentifier:theme.currentRevision.revisionIdentifier
        expectedManifest:theme.currentRevision.manifest
        contentSHA256Digests:@[previewPrimaryDigest]
        cancellationToken:cancelledPreviewToken
        error:&error] == nil &&
             error.code == MTThemeLibraryStoreErrorCancelled,
        @"bounded preview reads must stop before I/O when already cancelled");
    error = nil;
    MTAssert([library loadPreviewAssetDataForThemeID:theme.themeID
        expectedRevisionIdentifier:firstRevision.revisionIdentifier
        expectedManifest:firstManifest
        contentSHA256Digests:@[previewPrimaryDigest]
        error:&error] == nil &&
             error.code == MTThemeLibraryStoreErrorCurrentRevision,
        @"bounded preview reads must reject stale catalog revisions");

    NSURL *currentSecondaryURL =
        secondRevision.assetURLsByContentSHA256[previewSecondaryDigest];
    NSMutableData *corruptSecondary = [secondaryData mutableCopy];
    ((uint8_t *)corruptSecondary.mutableBytes)[0] ^= 0xff;
    MTAssert([corruptSecondary writeToURL:currentSecondaryURL
                                 options:0 error:&error] &&
             chmod(currentSecondaryURL.path.fileSystemRepresentation, 0600) == 0,
        @"bounded preview checksum fixture must preserve asset metadata");
    error = nil;
    previewData = [library loadPreviewAssetDataForThemeID:theme.themeID
        expectedRevisionIdentifier:theme.currentRevision.revisionIdentifier
        expectedManifest:theme.currentRevision.manifest
        contentSHA256Digests:@[previewPrimaryDigest]
        error:&error];
    MTAssert([previewData[previewPrimaryDigest] isEqualToData:primaryData] &&
             error == nil,
        @"a preview read must not hash unrelated assets in a large revision");
    error = nil;
    MTAssert([library loadPreviewAssetDataForThemeID:theme.themeID
        expectedRevisionIdentifier:theme.currentRevision.revisionIdentifier
        expectedManifest:theme.currentRevision.manifest
        contentSHA256Digests:@[previewSecondaryDigest]
        error:&error] == nil &&
             error.code == MTThemeLibraryStoreErrorVerification,
        @"a preview read must still hash every asset it returns");
    MTAssert([secondaryData writeToURL:currentSecondaryURL options:0
                                  error:&error] &&
             chmod(currentSecondaryURL.path.fileSystemRepresentation, 0600) == 0,
        @"bounded preview checksum fixture must restore the current asset");

    error = nil;
    NSArray<MTThemeLibraryRevisionSummary *> *history = [library
        loadRevisionHistoryForThemeID:firstManifest.themeID
        cancellationToken:nil error:&error];
    MTAssert(history.count == 2 && history.firstObject.isCurrent &&
             [history.firstObject.revisionIdentifier
                isEqualToString:secondRevision.revisionIdentifier] &&
             !history.lastObject.isCurrent &&
             history.firstObject.assetCount == 2 &&
             history.firstObject.assetByteCount ==
                primaryData.length + secondaryData.length,
        @"history must order current first and expose verified aggregate metadata");

    NSString *normalizedThemeID = MTNormalizeIdentifier(firstManifest.themeID,
                                                        NULL);
    NSString *storageDigest = MTSHA256HexDigestForData(
        [normalizedThemeID dataUsingEncoding:NSUTF8StringEncoding]);
    NSString *storageID = [@"t-" stringByAppendingString:
        [storageDigest substringToIndex:32]];
    NSString *themePath = [[[libraryRoot
        stringByAppendingPathComponent:@"themes"]
        stringByAppendingPathComponent:storageID] copy];
    NSString *revisionsPath = [themePath
        stringByAppendingPathComponent:@"revisions"];
    NSString *lockPath = [themePath
        stringByAppendingPathComponent:@"transaction.lock"];
    int heldLock = open(lockPath.fileSystemRepresentation,
        O_RDWR | O_CLOEXEC | O_NOFOLLOW);
    MTAssert(heldLock >= 0 && flock(heldLock, LOCK_EX | LOCK_NB) == 0,
        @"catalog contention fixture must hold the per-theme exclusive lock");
    error = nil;
    MTAssert([library loadRevisionHistoryForThemeID:firstManifest.themeID
        cancellationToken:nil error:&error] == nil &&
             error.code == MTThemeLibraryStoreErrorBusy &&
             flock(heldLock, LOCK_UN) == 0 && close(heldLock) == 0,
        @"history reads must fail quickly while a mutation owns the theme lock");

    NSString *primaryDigest = [source.inventory
        fileAtRelativePath:@"Assets/Primary.bin"].contentSHA256;
    NSURL *firstPrimaryURL =
        firstRevision.assetURLsByContentSHA256[primaryDigest];
    NSMutableData *corruptPrimary = [primaryData mutableCopy];
    ((uint8_t *)corruptPrimary.mutableBytes)[0] ^= 0xff;
    MTAssert([corruptPrimary writeToURL:firstPrimaryURL options:0 error:&error] &&
             chmod(firstPrimaryURL.path.fileSystemRepresentation, 0600) == 0,
        @"catalog checksum-boundary fixture must preserve asset metadata");
    error = nil;
    history = [library loadRevisionHistoryForThemeID:firstManifest.themeID
        cancellationToken:nil error:&error];
    MTAssert(history.count == 2 && error == nil,
        @"metadata-only history must avoid rehashing every asset during listing");
    error = nil;
    MTAssert([library switchCurrentRevisionForThemeID:firstManifest.themeID
        revisionIdentifier:firstRevision.revisionIdentifier
        cancellationToken:nil error:&error] == nil &&
             error.code == MTThemeLibraryStoreErrorVerification &&
             [[[library loadCurrentRevisionForThemeID:firstManifest.themeID
                error:NULL] revisionIdentifier]
                isEqualToString:secondRevision.revisionIdentifier],
        @"switch-current must fully hash its target and preserve current on corruption");
    MTAssert([primaryData writeToURL:firstPrimaryURL options:0 error:&error] &&
             chmod(firstPrimaryURL.path.fileSystemRepresentation, 0600) == 0,
        @"catalog checksum-boundary fixture must restore the formal asset");

    MTImportCancellationToken *cancelledSwitch =
        [[MTImportCancellationToken alloc] init];
    [cancelledSwitch cancel];
    error = nil;
    MTAssert([library switchCurrentRevisionForThemeID:firstManifest.themeID
        revisionIdentifier:firstRevision.revisionIdentifier
        cancellationToken:cancelledSwitch error:&error] == nil &&
             error.code == MTThemeLibraryStoreErrorCancelled,
        @"a pre-cancelled revision switch must not acquire or mutate Library state");
    error = nil;
    MTThemeLibraryRevision *switched = [library
        switchCurrentRevisionForThemeID:firstManifest.themeID
        revisionIdentifier:firstRevision.revisionIdentifier
        cancellationToken:nil error:&error];
    MTAssert(switched != nil && error == nil &&
             [switched.revisionIdentifier
                isEqualToString:firstRevision.revisionIdentifier] &&
             [[[library loadCurrentRevisionForThemeID:firstManifest.themeID
                error:&error] manifest].displayName
                isEqualToString:@"Catalog Fixture"],
        @"a verified formal revision must atomically become current");

    error = nil;
    MTAssert(![library removeRevisionForThemeID:firstManifest.themeID
        revisionIdentifier:firstRevision.revisionIdentifier
        cancellationToken:nil error:&error] &&
             error.code == MTThemeLibraryStoreErrorCurrentRevision,
        @"Library garbage collection must reject the current revision");
    MTImportCancellationToken *cancelledRemoval =
        [[MTImportCancellationToken alloc] init];
    [cancelledRemoval cancel];
    NSString *secondRevisionPath = [revisionsPath
        stringByAppendingPathComponent:secondRevision.revisionIdentifier];
    error = nil;
    MTAssert(![library removeRevisionForThemeID:firstManifest.themeID
        revisionIdentifier:secondRevision.revisionIdentifier
        cancellationToken:cancelledRemoval error:&error] &&
             error.code == MTThemeLibraryStoreErrorCancelled &&
             access(secondRevisionPath.fileSystemRepresentation, F_OK) == 0,
        @"cancellation before quarantine must leave a non-current revision published");
    error = nil;
    MTAssert([library removeRevisionForThemeID:firstManifest.themeID
        revisionIdentifier:secondRevision.revisionIdentifier
        cancellationToken:nil error:&error] && error == nil &&
             access(secondRevisionPath.fileSystemRepresentation, F_OK) != 0 &&
             [library loadRevisionHistoryForThemeID:firstManifest.themeID
                cancellationToken:nil error:&error].count == 1,
        @"removing a non-current formal revision must collect its self-contained tree");

    secondRevision = MTCommitCatalogFixtureRevision(library,
        stagingConfiguration, source, secondManifest, &error);
    switched = [library switchCurrentRevisionForThemeID:firstManifest.themeID
        revisionIdentifier:firstRevision.revisionIdentifier
        cancellationToken:nil error:&error];
    NSString *deletionName = [@".deletion-" stringByAppendingString:
        NSUUID.UUID.UUIDString.lowercaseString];
    NSString *deletionPath = [revisionsPath
        stringByAppendingPathComponent:deletionName];
    secondRevisionPath = [revisionsPath
        stringByAppendingPathComponent:secondRevision.revisionIdentifier];
    MTAssert(secondRevision != nil && switched != nil && error == nil &&
             rename(secondRevisionPath.fileSystemRepresentation,
                    deletionPath.fileSystemRepresentation) == 0,
        @"abandoned deletion fixture must quarantine a non-current formal revision");
    error = nil;
    MTAssert([library recoverAbandonedLibraryOperationsWithError:&error] &&
             error == nil &&
             access(deletionPath.fileSystemRepresentation, F_OK) != 0 &&
             access(secondRevisionPath.fileSystemRepresentation, F_OK) != 0 &&
             [[[library loadCurrentRevisionForThemeID:firstManifest.themeID
                error:&error] revisionIdentifier]
                isEqualToString:firstRevision.revisionIdentifier],
        @"startup recovery must finish a quarantined deletion without changing current");

    error = nil;
    NSString *legacyDigest = [library saveManifestRevision:secondManifest
                                                      error:&error];
    catalog = [library loadThemeCatalogWithCancellationToken:nil error:&error];
    theme = catalog.firstObject;
    history = [library loadRevisionHistoryForThemeID:firstManifest.themeID
        cancellationToken:nil error:&error];
    MTAssert(legacyDigest != nil && catalog.count == 1 && history.count == 2 &&
             error == nil && theme.requiresReimport &&
             theme.formalRevisionCount == 1 &&
             theme.legacyRevisionCount == 1 &&
             history.firstObject.requiresReimport &&
             [history.firstObject.revisionIdentifier
                isEqualToString:legacyDigest],
        @"catalog must identify legacy manifest-only current data without faking migration");
    error = nil;
    MTAssert([library loadCurrentRevisionForThemeID:firstManifest.themeID
        error:&error] == nil &&
             error.code == MTThemeLibraryStoreErrorUnsupportedVersion,
        @"formal content consumers must reject a legacy manifest-only current revision");
    NSString *legacyPath = [revisionsPath
        stringByAppendingPathComponent:legacyDigest];
    error = nil;
    MTAssert(![library removeRevisionForThemeID:firstManifest.themeID
        revisionIdentifier:legacyDigest cancellationToken:nil error:&error] &&
             error.code == MTThemeLibraryStoreErrorUnsupportedVersion &&
             access(legacyPath.fileSystemRepresentation, F_OK) == 0,
        @"R1 garbage collection must leave compatibility-only legacy revisions untouched");
    error = nil;
    switched = [library switchCurrentRevisionForThemeID:firstManifest.themeID
        revisionIdentifier:firstRevision.revisionIdentifier
        cancellationToken:nil error:&error];
    MTAssert(switched != nil && error == nil &&
             [library loadRevisionHistoryForThemeID:firstManifest.themeID
                cancellationToken:nil error:&error].firstObject.format ==
                MTThemeLibraryRevisionFormatFormalV1,
        @"a verified formal revision must recover current state from legacy compatibility data");

    // Whole-theme deletion removes the current revision too, which
    // per-revision garbage collection deliberately refuses to do.
    error = nil;
    MTImportCancellationToken *cancelledThemeRemoval =
        [[MTImportCancellationToken alloc] init];
    [cancelledThemeRemoval cancel];
    MTAssert(![library removeThemeWithID:firstManifest.themeID
        cancellationToken:cancelledThemeRemoval error:&error] &&
             error.code == MTThemeLibraryStoreErrorCancelled &&
             access(themePath.fileSystemRepresentation, F_OK) == 0,
        @"cancellation before quarantine must leave the theme published");
    error = nil;
    MTAssert(![library removeThemeWithID:@"" cancellationToken:nil
                                   error:&error] &&
             error.code == MTThemeLibraryStoreErrorInvalidRequest,
        @"theme removal must reject a non-canonical theme identifier");
    error = nil;
    MTAssert([library removeThemeWithID:firstManifest.themeID
        cancellationToken:nil error:&error] && error == nil &&
             access(themePath.fileSystemRepresentation, F_OK) != 0 &&
             [library loadThemeCatalogWithCancellationToken:nil
                                                      error:&error].count == 0,
        @"removing a theme must collect its current revision, legacy data and whole tree");
    error = nil;
    MTAssert([library recoverAbandonedLibraryOperationsWithError:&error] &&
             error == nil,
        @"startup recovery must stay clean after a whole-theme deletion");

    [NSFileManager.defaultManager removeItemAtPath:root error:NULL];
}

static MTThemeImportConfiguration *MTWorkflowFixtureConfiguration(
    NSString *root) {
    MTImportLimits *limits = MTImportLimits.defaultLimits;
    return [[MTThemeImportConfiguration alloc]
        initWithLimits:limits
        importSessionsRootURL:[NSURL fileURLWithPath:
            [root stringByAppendingPathComponent:@"import-sessions"]
            isDirectory:YES]
        assetSessionsRootURL:[NSURL fileURLWithPath:
            [root stringByAppendingPathComponent:@"asset-sessions"]
            isDirectory:YES]
        libraryRootURL:[NSURL fileURLWithPath:
            [root stringByAppendingPathComponent:@"library"]
            isDirectory:YES]
        libraryFreeSpaceReserveBytes:0
        imageDecoder:MTSafeImageDecoder.defaultDecoder
        maximumPreviewCount:4
        previewMaximumDimension:16];
}

// One hostile-but-realistic ZIP exercises every resource family through the
// complete pipeline. Folder names are deliberately misleading; only
// distinctive filenames or known bundle identifiers may recover semantics.
static void MTTestSemanticLayoutCompatibilityMatrix(void) {
    NSString *root = MTCreateTemporaryDirectory(@"semantic-layout-matrix");
    NSData *png = MTPNGFixtureData(87, 87, 8, 6, 0, YES, @[], @[]);
    NSData *alternatePNG = MTPNGFixtureData(
        120, 120, 8, 6, 0, YES, @[], @[]);
    NSData *info = MTPropertyListFixtureData(@{
        @"CFBundleDisplayName" : @"Semantic Matrix",
        @"IB-MaskIcons" : @YES,
        @"CalendarIconDaySettings" : @{
            @"FontSize" : @6,
            @"TextColor" : @"#FFF",
            @"TextYoffset" : @7,
        },
        @"CalendarIconDateSettings" : @{
            @"FontSize" : @20,
            @"TextColor" : @"#000",
            @"TextYoffset" : @14,
        },
    }, NSPropertyListBinaryFormat_v1_0);
    NSArray<NSDictionary<NSString *, id> *> *entries = @[
        @{ @"name" : @"Info.plist", @"data" : info },
        @{ @"name" : @"Loose/Apps/com.example.Loose@3x.png", @"data" : png },
        @{ @"name" : @"Wrong/App/com.example.bundle/icon.png", @"data" : png },
        @{ @"name" : @"Mixed/ICONBUNDLES/com.example.Case.png", @"data" : png },
        @{ @"name" : @"Download/Theme/Assets/IconBundles/com.example.Deep.png", @"data" : png },
        @{ @"name" : @"Loose/Calendar/com.apple.mobilecal-large.png", @"data" : png },
        @{ @"name" : @"Wrong/Clock/ClockIconBackgroundSquare.png", @"data" : png },
        @{ @"name" : @"Wrong/Clock/ClockIconHourHand.png", @"data" : png },
        @{ @"name" : @"Wrong/Badge/SBBadgeBG@3x.png", @"data" : png },
        @{ @"name" : @"Wrong/Phone/com.apple.TelephonyUI/1@3x.png", @"data" : png },
        @{ @"name" : @"Wrong/Folder/FolderIconBG@3x.png", @"data" : png },
        @{ @"name" : @"Wrong/Folder/icon_folder_light.png", @"data" : png },
        @{ @"name" : @"Wrong/Mask/AppIconMask@3x~iphone.png", @"data" : png },
        @{ @"name" : @"Wrong/Mask/icon_mask.png", @"data" : png },
        @{ @"name" : @"Wrong/Effects/iPhoneOverlay@3x.png", @"data" : png },
        @{ @"name" : @"Wrong/Effects/iPhoneShadow@3x.png", @"data" : png },
        @{ @"name" : @"Wrong/Status/Black_3_WifiBars@3x.png", @"data" : png },
        @{ @"name" : @"Wrong/Settings/com.apple.Preferences/WiFi@3x.png", @"data" : png },
        @{ @"name" : @"Wrong/Share/com.apple.SharingUIService/UIMessageActivity@3x.png", @"data" : png },
        // Exact duplicates collapse before import; different content at the
        // same inferred path becomes a component and enters normal conflict
        // resolution without overwriting the primary resource.
        @{ @"name" : @"Duplicate/A/com.example.Duplicate.png", @"data" : png },
        @{ @"name" : @"Duplicate/B/com.example.Duplicate.png", @"data" : png },
        @{ @"name" : @"Conflict/A/com.example.Conflict.png", @"data" : png },
        @{ @"name" : @"Conflict/B/com.example.Conflict.png", @"data" : alternatePNG },
        // These names are ambiguous without a bundle or family context and
        // must not be guessed as app icons or UI resources.
        @{ @"name" : @"Ambiguous/WiFi@3x.png", @"data" : png },
        @{ @"name" : @"Ambiguous/1@3x.png", @"data" : png },
        @{ @"name" : @"Ambiguous/icon.png", @"data" : png },
        @{ @"name" : @"Fake/SBBadgeBG@2x.png",
           @"data" : [@"not a png" dataUsingEncoding:NSUTF8StringEncoding] },
        @{ @"name" : @"__MACOSX/._Info.plist",
           @"data" : [@"metadata" dataUsingEncoding:NSUTF8StringEncoding] },
    ];
    NSString *archivePath = MTWriteZIPFixture(root, @"matrix.zip", entries);
    MTThemeImportConfiguration *configuration =
        MTWorkflowFixtureConfiguration(root);
    MTThemeImportPipeline *pipeline = [[MTThemeImportPipeline alloc]
        initWithConfiguration:configuration];
    NSError *error = nil;
    MTPreparedThemeImport *prepared = [pipeline
        prepareZIPThemeAtURL:[NSURL fileURLWithPath:archivePath]
        sourceName:@"Semantic Matrix.theme"
        cancellationToken:nil progressHandler:nil error:&error];

    NSSet<NSString *> *expectedCapabilities = [NSSet setWithArray:@[
        @"icons.static", MTCalendarIconsModuleID, MTClockIconsModuleID,
        MTBadgesModuleID, MTDialerModuleID, MTFolderIconsModuleID,
        MTIconMaskModuleID, MTIconOverlayModuleID, MTIconShadowsModuleID,
        MTStatusBarModuleID, MTUIResourcesModuleID,
    ]];
    NSSet<NSString *> *actualCapabilities = prepared == nil
        ? [NSSet set]
        : [NSSet setWithArray:prepared.manifest.capabilities];
    NSMutableSet<NSString *> *coveredModules = [NSMutableSet set];
    BOOL standardPaths = prepared != nil;
    BOOL ambiguousMisclassified = NO;
    for (MTThemeResource *resource in prepared.manifest.resources) {
        NSString *moduleID = resource.resourceKey.moduleID;
        NSString *path = resource.relativeAssetPath;
        [coveredModules addObject:moduleID];
        NSDictionary<NSString *, NSArray<NSString *> *> *prefixes = @{
            @"icons.static" : @[@"IconBundles/", @"Bundles/"],
            MTClockIconsModuleID : @[@"Clock/", @"Bundles/"],
            MTBadgesModuleID : @[@"Badges/"],
            MTDialerModuleID : @[@"Dialer/"],
            MTFolderIconsModuleID : @[@"Folders/"],
            MTIconMaskModuleID : @[@"IconEffects/Masks/"],
            MTIconOverlayModuleID : @[@"IconEffects/Overlays/"],
            MTIconShadowsModuleID : @[@"IconEffects/Shadows/"],
            MTStatusBarModuleID : @[@"StatusBar/"],
            MTUIResourcesModuleID : @[@"Settings/", @"ShareSheet/"],
        };
        BOOL pathAccepted = NO;
        for (NSString *prefix in prefixes[moduleID]) {
            pathAccepted = pathAccepted || [path hasPrefix:prefix] ||
                [path containsString:[@"/" stringByAppendingString:prefix]];
        }
        standardPaths = standardPaths && pathAccepted &&
            ![path hasPrefix:@"Modules/"];
        ambiguousMisclassified = ambiguousMisclassified ||
            ([moduleID isEqualToString:@"icons.static"] &&
             ([@[@"WiFi", @"1", @"icon"]
                containsObject:resource.resourceKey.subject]));
    }
    NSCountedSet<NSString *> *diagnosticCodes = [NSCountedSet set];
    for (MTDiagnostic *diagnostic in prepared.diagnostics) {
        [diagnosticCodes addObject:diagnostic.code];
    }
    NSSet<NSString *> *expectedResourceModules = [expectedCapabilities
        objectsPassingTest:^BOOL(NSString *moduleID, __unused BOOL *stop) {
            return ![moduleID isEqualToString:MTCalendarIconsModuleID];
        }];
    NSString *matrixMessage = [NSString stringWithFormat:
        @"semantic ZIP matrix failed (prepared=%@ error=%@ caps=%@ expected=%@ modules=%@ expectedModules=%@ standard=%d ambiguous=%d shadowed=%lu resources=%@)",
        prepared == nil ? @"no" : @"yes",
        error.localizedDescription ?: @"none", actualCapabilities,
        expectedCapabilities, coveredModules, expectedResourceModules,
        standardPaths, ambiguousMisclassified,
        (unsigned long)[diagnosticCodes countForObject:
            @"import.resource.shadowed"],
        [prepared.manifest.resources valueForKey:@"relativeAssetPath"]];
    MTAssert(prepared != nil && error == nil &&
             [actualCapabilities isEqualToSet:expectedCapabilities] &&
             [coveredModules isEqualToSet:expectedResourceModules] &&
             standardPaths && !ambiguousMisclassified &&
             [diagnosticCodes countForObject:@"import.resource.shadowed"] >= 1,
        matrixMessage);

    MTThemeLibraryRevision *revision = [pipeline
        commitPreparedImport:prepared cancellationToken:nil
        progressHandler:nil error:&error];
    BOOL materialized = revision != nil &&
        revision.resourcesDirectoryURL != nil;
    for (MTThemeResource *resource in revision.manifest.resources) {
        NSData *data = [NSData dataWithContentsOfURL:
            [revision.resourcesDirectoryURL
                URLByAppendingPathComponent:resource.relativeAssetPath]];
        materialized = materialized && data != nil &&
            [MTSHA256HexDigestForData(data)
                isEqualToString:resource.contentSHA256];
    }
    MTThemeLibraryRevision *reloaded = [[[MTThemeLibraryStore alloc]
        initWithRootURL:configuration.libraryRootURL]
        loadCurrentRevisionForThemeID:revision.manifest.themeID error:&error];
    MTAssert(materialized && reloaded != nil && error == nil &&
             [[[reloaded manifest] contentDigestWithError:&error]
                isEqualToString:
                    [[revision manifest] contentDigestWithError:&error]],
        @"every matrix resource must materialize into the standard Library tree and survive an authoritative reload");
    [NSFileManager.defaultManager removeItemAtPath:root error:NULL];
}

static void MTTestSnowBoardThemeSuiteImport(void) {
    NSString *sourceRoot = MTCreateTemporaryDirectory(@"snowboard-suite-source");
    NSString *workflowRoot = MTCreateTemporaryDirectory(@"snowboard-suite-workflow");
    NSString *themesRoot = [sourceRoot stringByAppendingPathComponent:
        @"var/jb/Library/Themes"];
    NSData *png = MTPNGFixtureData(87, 87, 8, 6, 0, YES, @[], @[]);
    NSData *info = MTPropertyListFixtureData(@{
        @"PackageName" : @"Oxy Fixture",
        @"IB-MaskIcons" : @YES,
        @"CalendarIconDaySettings" : @{
            @"FontSize" : @6,
            @"TextColor" : @"#FFF",
            @"TextYoffset" : @7,
        },
        @"CalendarIconDateSettings" : @{
            @"FontSize" : @20,
            @"TextColor" : @"#000",
            @"TextYoffset" : @14,
        },
    }, NSPropertyListBinaryFormat_v1_0);
    NSData *independentInfo = MTPropertyListFixtureData(@{
        @"PackageName" : @"Independent Component",
        @"FuzzyBundleIdentifiers" : @[ @"com.example.Other" ],
        @"BundleAliases" : @{
            @"team.example.Other" : @"com.example.Other",
        },
    }, NSPropertyListBinaryFormat_v1_0);
    NSDictionary<NSString *, NSData *> *files = @{
        @"OxyFixture.theme/Info.plist" : info,
        @"OxyFixture.theme/IconBundles/com.example.App-large.png" : png,
        @"OxyFixture.theme/IconBundles/com.example.App.png" : png,
        @"OxyFixture.theme/IconBundles/com.apple.mobilecal-large.png" : png,
        @"OxyFixture.theme/Bundles/com.apple.springboard/ClockIconBackgroundSquare.png" : png,
        @"OxyFixture.theme/Bundles/com.apple.mobileicons.framework/AppIconMask@3x~iphone.png" : png,
        @"OxyFixture - Settings.theme/Bundles/com.apple.preferences-ui-framework/WiFi@3x.png" : png,
        @"OxyFixture - Badges Blue.theme/Bundles/com.apple.springboard/SBBadgeBG@2x.png" : png,
        @"OxyFixture - Badges Blue.theme/Bundles/com.apple.springboard/SBBadgeBGLight@3x.png" : png,
        @"OxyFixture - Badges Blue.theme/Bundles/com.apple.springboard/SBBadgeBGDark@3x~iphone.png" : png,
        @"OxyFixture - Badges Red.theme/Bundles/com.apple.springboard/SBBadgeBG@2x.png" : png,
        @"OxyFixture - Dialer.theme/Bundles/com.apple.TelephonyUI/1@3x.png" : png,
        @"OxyFixture - Folders.theme/Bundles/com.apple.springboard/foldericonbg@3x.png" : png,
        @"OxyFixture - Folders.theme/Bundles/com.apple.springboard/FolderIconBGLight@3x.png" : png,
        @"OxyFixture - Status Bar.theme/UIImages/Black_3_WifiBars@3x.png" : png,
        @"OxyFixture - Status Bar.theme/BUNDLES/COM.APPLE.UI/Black_2_Bars@3x.png" : png,
        @"OxyFixture - Status Bar.theme/bundles/com.apple.uikit/LockScreen_2_WifiBars@3x.png" : png,
        @"OxyFixture - Status Bar.theme/UIImages/Black_5_Bars@3x.png" : png,
        @"OxyFixture - Shadow.theme/AnemoneEffects/iPhoneShadow@3x.png" : png,
        @"OxyFixture - Shadow.theme/AnemoneEffects/iPhoneOverlay@3x.png" : png,
        @"Other/Independent.theme/info.PLIST" : independentInfo,
        @"Other/Independent.theme/IconBundles/com.example.Other.png" : png,
        @"Other/Independent.theme/IconBundles/com.example.App-large.png" : png,
        @".DS_Store" : [@"Finder metadata" dataUsingEncoding:
            NSUTF8StringEncoding],
        @"__MACOSX/._OxyFixture.theme" : [@"AppleDouble metadata"
            dataUsingEncoding:NSUTF8StringEncoding],
    };
    NSError *error = nil;
    for (NSString *relativePath in files) {
        NSString *path = [themesRoot stringByAppendingPathComponent:relativePath];
        MTAssert([NSFileManager.defaultManager
            createDirectoryAtPath:path.stringByDeletingLastPathComponent
      withIntermediateDirectories:YES
                       attributes:@{NSFilePosixPermissions : @0700}
                            error:&error] &&
            [files[relativePath] writeToFile:path options:0 error:&error] &&
            chmod(path.fileSystemRepresentation, 0755) == 0,
            @"SnowBoard suite fixture must write executable-marked data files");
    }

    MTThemeImportPipeline *pipeline = [[MTThemeImportPipeline alloc]
        initWithConfiguration:MTWorkflowFixtureConfiguration(workflowRoot)];
    error = nil;
    MTPreparedThemeImport *prepared = [pipeline
        prepareDirectoryThemeAtURL:
            [NSURL fileURLWithPath:sourceRoot isDirectory:YES]
        sourceName:@"OxyFixture"
        cancellationToken:nil progressHandler:nil error:&error];
    NSCountedSet<NSString *> *diagnosticCodes = [NSCountedSet set];
    for (MTDiagnostic *diagnostic in prepared.diagnostics) {
        [diagnosticCodes addObject:diagnostic.code];
    }
    NSSet<NSString *> *expectedCapabilities = [NSSet setWithArray:@[
        @"icons.static", MTCalendarIconsModuleID, MTClockIconsModuleID,
        MTUIResourcesModuleID, MTIconMaskModuleID, MTBadgesModuleID,
        MTDialerModuleID, MTFolderIconsModuleID, MTIconShadowsModuleID,
        MTIconOverlayModuleID, MTStatusBarModuleID,
    ]];
    NSSet<NSString *> *actualCapabilities = prepared == nil
        ? [NSSet set]
        : [NSSet setWithArray:prepared.manifest.capabilities];
    BOOL hasSettingsComponentPath = NO;
    BOOL selectedLargeAppIcon = NO;
    BOOL hasLightBadge = NO;
    BOOL hasPhoneDarkBadge = NO;
    BOOL hasFolderBackground = NO;
    BOOL hasLightFolderBackground = NO;
    BOOL hasUIStatusBarResource = NO;
    BOOL hasUIKitStatusBarResource = NO;
    BOOL hasIndependentComponentPath = NO;
    for (MTThemeResource *resource in prepared.manifest.resources) {
        if ([resource.relativeAssetPath
                hasPrefix:@"Components/OxyFixture - Settings.theme/"]) {
            hasSettingsComponentPath = YES;
        }
        if ([resource.relativeAssetPath
                hasPrefix:@"Components/Independent.theme/"]) {
            hasIndependentComponentPath = YES;
        }
        if ([resource.resourceKey.moduleID isEqualToString:@"icons.static"] &&
            [resource.resourceKey.subject isEqualToString:@"com.example.App"]) {
            selectedLargeAppIcon = selectedLargeAppIcon ||
                [resource.relativeAssetPath
                isEqualToString:
                    @"IconBundles/com.example.App-large.png"];
        }
        if ([resource.resourceKey.moduleID isEqualToString:MTBadgesModuleID]) {
            hasLightBadge = hasLightBadge ||
                [resource.resourceKey.trait isEqualToString:
                    MTBadgeAppearanceLight];
            hasPhoneDarkBadge = hasPhoneDarkBadge ||
                [resource.resourceKey.trait isEqualToString:@"iphone-dark"];
        }
        if ([resource.resourceKey.moduleID
                isEqualToString:MTFolderIconsModuleID]) {
            hasFolderBackground = hasFolderBackground ||
                [resource.resourceKey.variant
                    isEqualToString:MTFolderIconVariantBackground];
            hasLightFolderBackground = hasLightFolderBackground ||
                [resource.resourceKey.variant
                    isEqualToString:MTFolderIconVariantBackgroundLight];
        }
        if ([resource.resourceKey.moduleID
                isEqualToString:MTStatusBarModuleID]) {
            hasUIStatusBarResource = hasUIStatusBarResource ||
                [resource.resourceKey.subject
                    isEqualToString:@"Black_2_Bars"];
            hasUIKitStatusBarResource = hasUIKitStatusBarResource ||
                [resource.resourceKey.subject
                    isEqualToString:@"LockScreen_2_WifiBars"];
        }
    }
    MTStaticIconConfiguration *staticConfiguration =
        [[MTStaticIconConfiguration alloc] initWithDictionary:
            prepared.manifest.moduleConfigurations[@"icons.static"]
                                                        error:NULL];
    NSString *suiteMessage = [NSString stringWithFormat:
        @"one SnowBoard suite must merge every .theme component while ignoring directory packaging metadata (resources=%lu recognized=%lu rejected=%lu ignored=%lu shadowed=%lu caps=%@ expectedCaps=%@ settings=%d independent=%d large=%d light=%d phoneDark=%d folder=%d lightFolder=%d uiStatus=%d uiKitStatus=%d mask=%@ error=%@)",
        (unsigned long)prepared.manifest.resources.count,
        (unsigned long)prepared.recognizedFileCount,
        (unsigned long)prepared.rejectedFileCount,
        (unsigned long)prepared.ignoredFileCount,
        (unsigned long)[diagnosticCodes countForObject:@"import.resource.shadowed"],
        actualCapabilities,
        expectedCapabilities,
        hasSettingsComponentPath,
        hasIndependentComponentPath,
        selectedLargeAppIcon,
        hasLightBadge,
        hasPhoneDarkBadge,
        hasFolderBackground,
        hasLightFolderBackground,
        hasUIStatusBarResource,
        hasUIKitStatusBarResource,
        prepared.manifest.moduleConfigurations[MTIconMaskModuleID],
        error.localizedDescription ?: @"none"];
    MTAssert(prepared != nil && error == nil &&
             [prepared.manifest.displayName isEqualToString:@"Oxy Fixture"] &&
             [actualCapabilities isEqualToSet:expectedCapabilities] &&
             prepared.sourceFileCount == files.count - 2 &&
             prepared.recognizedFileCount == 20 &&
             prepared.rejectedFileCount == 1 &&
             prepared.ignoredFileCount == 2 &&
             prepared.manifest.resources.count == 20 &&
             hasSettingsComponentPath &&
             hasIndependentComponentPath &&
             selectedLargeAppIcon &&
             hasLightBadge && hasPhoneDarkBadge &&
             hasFolderBackground && hasLightFolderBackground &&
             hasUIStatusBarResource && hasUIKitStatusBarResource &&
             [diagnosticCodes countForObject:@"import.resource.shadowed"] == 1 &&
             [diagnosticCodes countForObject:
                 @"import.statusbar.unsupported-subject"] == 1 &&
             [diagnosticCodes countForObject:
                 @"import.icon-mask.resource-missing"] == 0 &&
             [prepared.manifest.moduleConfigurations[MTIconMaskModuleID]
                 isEqualToDictionary:@{ @"enabled" : @YES }],
        suiteMessage);
    MTAssert(staticConfiguration != nil &&
             [staticConfiguration.fuzzyBundleIdentifiers
                 isEqualToArray:@[@"com.example.Other"]] &&
             [[staticConfiguration
                 themedBundleIdentifierForRequestedIdentifier:
                     @"ABCD.com.example.Other"]
                 isEqualToString:@"com.example.Other"] &&
             [[staticConfiguration
                 themedBundleIdentifierForRequestedIdentifier:
                     @"team.example.Other"]
                 isEqualToString:@"com.example.Other"],
        @"component Info.plist matching hints must merge into one typed static-icon configuration");

    MTThemeCapabilityReport *report = prepared == nil ? nil :
        [MTThemeCapabilityReport reportForManifest:prepared.manifest];
    MTThemeCapabilityItem *appIcons = [report
        itemForFeatureID:MTThemeFeatureAppIcons];
    MTThemeCapabilityItem *badges = [report
        itemForFeatureID:MTThemeFeatureBadges];
    MTThemeCapabilityItem *iconMask = [report
        itemForFeatureID:MTThemeFeatureIconMask];
    MTThemeCapabilityItem *statusBar = [report
        itemForFeatureID:MTThemeFeatureStatusBar];
    MTThemeCapabilityItem *folders = [report
        itemForFeatureID:MTThemeFeatureFolders];
    MTThemeCapabilityItem *dialer = [report
        itemForFeatureID:MTThemeFeatureDialer];
    MTBadgeConfiguration *badgeConfiguration =
        [[MTBadgeConfiguration alloc]
            initWithDictionary:prepared.manifest
                .moduleConfigurations[MTBadgesModuleID]
                         error:NULL];
    MTThemeCapabilityItem *iconShadows = [report
        itemForFeatureID:MTThemeFeatureIconShadows];
    MTThemeCapabilityItem *iconOverlay = [report
        itemForFeatureID:MTThemeFeatureIconOverlay];
    MTAssert(report != nil && report.recognizedFeatureCount == 11 &&
             report.runtimeApplicableFeatureCount == 11 &&
             appIcons.uniqueSubjectCount == 4 &&
             appIcons.resourceCount == 5 &&
             iconMask.availability ==
                 MTThemeCapabilityAvailabilityReady &&
             iconMask.resourceCount == 1 &&
             [iconMask.presentVariants
                 isEqualToArray:@[MTIconMaskVariantMask]] &&
             badges.availability ==
                 MTThemeCapabilityAvailabilityReady &&
             [badgeConfiguration.defaultVariant
                 isEqualToString:@"oxyfixture-badges-blue"] &&
             badges.presentVariants.count == 2 &&
             badges.resourceCount == 4 &&
             [badges.presentTraits isEqualToArray:@[
                 @"any", @"iphone-dark", @"light"
             ]] &&
             badges.appearanceCoverage ==
                 (MTThemeCapabilityAppearanceCoverageShared |
                  MTThemeCapabilityAppearanceCoverageLight |
                  MTThemeCapabilityAppearanceCoverageDark) &&
             iconShadows.availability ==
                 MTThemeCapabilityAvailabilityReady &&
             iconShadows.presentVariants.count == 1 &&
             iconShadows.resourceCount == 1 &&
             iconOverlay.availability ==
                 MTThemeCapabilityAvailabilityReady &&
             iconOverlay.resourceCount == 1 &&
             [iconOverlay.presentVariants
                 isEqualToArray:@[MTIconOverlayVariantOverlay]] &&
             folders.availability == MTThemeCapabilityAvailabilityReady &&
             folders.resourceCount == 2 &&
             [folders.presentVariants isEqualToArray:@[
                 MTFolderIconVariantBackground,
                 MTFolderIconVariantBackgroundLight,
             ]] &&
             statusBar.availability ==
                 MTThemeCapabilityAvailabilityReady &&
             statusBar.uniqueSubjectCount == 3 &&
             statusBar.resourceCount == 3 &&
             dialer.availability == MTThemeCapabilityAvailabilityReady &&
             dialer.uniqueSubjectCount == 1,
        @"theme details must project ready suite capabilities with stable counts");

    error = nil;
    MTThemeComponentCatalog *componentCatalog =
        [MTThemeComponentCatalog catalogForManifest:prepared.manifest
                                               error:&error];
    NSSet<NSString *> *componentIDs = [NSSet setWithArray:
        [componentCatalog.components valueForKey:@"componentIdentifier"]];
    MTThemeVariantGroup *badgeGroup = [componentCatalog
        variantGroupWithIdentifier:MTBadgesModuleID];
    MTThemeVariantGroup *shadowGroup = [componentCatalog
        variantGroupWithIdentifier:MTIconShadowsModuleID];
    MTThemeComponentSelection *customSelection =
        [componentCatalog.defaultSelection
            selectionBySelectingVariantIdentifier:@"oxyfixture-badges-red"
            forGroupIdentifier:MTBadgesModuleID
            catalog:componentCatalog error:&error];
    customSelection = [customSelection
        selectionBySettingComponentIdentifier:@"oxyfixture-settings"
                                       enabled:NO
                                       catalog:componentCatalog
                                         error:&error];
    NSSet<NSString *> *directApplicableFeatures =
        MTThemeRuntimeApplicableFeatureIdentifiersForSelection(
            prepared.manifest, customSelection);
    NSSet<NSString *> *cachedApplicableFeatures =
        MTThemeRuntimeApplicableFeatureIdentifiersForSelectionUsingReport(
            prepared.manifest, customSelection, report);
    MTAssert(componentCatalog != nil && error == nil &&
             componentCatalog.components.count == 7 &&
             // The Shadow component now also carries overlay artwork, which
             // lives outside the Shadow variant group, so it additionally
             // appears as one additive component.
             [componentIDs isEqualToSet:[NSSet setWithArray:@[
                 @"primary", @"independent", @"oxyfixture-dialer",
                 @"oxyfixture-folders", @"oxyfixture-settings",
                 @"oxyfixture-shadow", @"oxyfixture-status-bar",
             ]]] &&
             componentCatalog.variantGroups.count == 2 &&
             badgeGroup.options.count == 2 &&
             [badgeGroup.defaultVariantIdentifier
                 isEqualToString:@"oxyfixture-badges-blue"] &&
             shadowGroup.options.count == 1 &&
             componentCatalog.defaultSelection.enabledComponentIDs.count == 7 &&
             [[componentCatalog.defaultSelection
                 selectedVariantForGroup:MTIconShadowsModuleID]
                 isEqualToString:@"oxyfixture-shadow"] &&
             customSelection != nil &&
             ![customSelection isComponentEnabled:@"oxyfixture-settings"] &&
             [[customSelection selectedVariantForGroup:MTBadgesModuleID]
                 isEqualToString:@"oxyfixture-badges-red"] &&
             MTThemeFeatureIsRuntimeApplicableForSelection(
                 prepared.manifest, customSelection,
                 MTThemeFeatureAppIcons) &&
             MTThemeFeatureIsRuntimeApplicableForSelection(
                 prepared.manifest, customSelection,
                 MTThemeFeatureBadges) &&
             !MTThemeFeatureIsRuntimeApplicableForSelection(
                 prepared.manifest, customSelection,
                 MTThemeFeatureSettingsIcons) &&
             [cachedApplicableFeatures
                 isEqualToSet:directApplicableFeatures] &&
             MTThemeFeatureSupportsMixing(MTThemeFeatureIconMask) &&
             !MTThemeFeatureSupportsMixing(MTThemeFeatureIconPattern),
        @"component catalog must separate additive suite components from authored Badge and Shadow variants");

    error = nil;
    MTThemeLibraryRevision *revision = [pipeline
        commitPreparedImport:prepared cancellationToken:nil
        progressHandler:nil error:&error];
    MTCompiledGeneration *generation = revision == nil ? nil :
        [[MTStaticIconCompiler defaultCompiler]
            compileLibraryRevision:revision cancellationToken:nil error:&error];
    NSSet<NSString *> *generationCapabilities = generation == nil
        ? [NSSet set]
        : [NSSet setWithArray:generation.descriptor.moduleIDs];
    MTAssert(revision != nil && generation != nil && error == nil &&
             generation.index.recordCount == 19 &&
             generation.descriptor.assets.count == 1 &&
             [generationCapabilities isEqualToSet:expectedCapabilities],
        [NSString stringWithFormat:
            @"default compile must publish one selected style per variant axis without dropping additive components (records=%lu assets=%lu caps=%@ expected=%@ error=%@)",
            (unsigned long)generation.index.recordCount,
            (unsigned long)generation.descriptor.assets.count,
            generationCapabilities, expectedCapabilities,
            error.localizedDescription ?: @"none"]);

    error = nil;
    MTCompiledGeneration *customGeneration = revision == nil ? nil :
        [[MTStaticIconCompiler defaultCompiler]
            compileLibraryRevision:revision
            componentSelection:customSelection
            cancellationToken:nil error:&error];
    NSSet<NSString *> *customCapabilities = customGeneration == nil
        ? [NSSet set]
        : [NSSet setWithArray:customGeneration.descriptor.moduleIDs];
    NSMutableSet<NSString *> *expectedCustomCapabilities =
        [expectedCapabilities mutableCopy];
    [expectedCustomCapabilities removeObject:MTUIResourcesModuleID];
    MTBadgeConfiguration *compiledBadge = [[MTBadgeConfiguration alloc]
        initWithDictionary:customGeneration.descriptor
            .moduleConfigurations[MTBadgesModuleID]
        error:NULL];
    MTAssert(customGeneration != nil && error == nil &&
             customGeneration.index.recordCount == 16 &&
             customGeneration.descriptor.assets.count == 1 &&
             [customCapabilities isEqualToSet:expectedCustomCapabilities] &&
             [compiledBadge.defaultVariant
                 isEqualToString:@"oxyfixture-badges-red"] &&
             ![customGeneration.descriptor.generationIdentifier
                 isEqualToString:generation.descriptor.generationIdentifier],
        [NSString stringWithFormat:
            @"custom compile must filter one additive component and every unselected authored variant into a distinct Generation (records=%lu assets=%lu caps=%@ expected=%@ error=%@)",
            (unsigned long)customGeneration.index.recordCount,
            (unsigned long)customGeneration.descriptor.assets.count,
            customCapabilities, expectedCustomCapabilities,
            error.localizedDescription ?: @"none"]);

    NSString *defaultsSuite = [@"com.hmmzzz.marktheme.tests.components."
        stringByAppendingString:NSUUID.UUID.UUIDString.lowercaseString];
    NSUserDefaults *defaults = [[NSUserDefaults alloc]
        initWithSuiteName:defaultsSuite];
    [defaults removePersistentDomainForName:defaultsSuite];
    MTThemeComponentSelectionStore *selectionStore =
        [[MTThemeComponentSelectionStore alloc]
            initWithUserDefaults:defaults];
    error = nil;
    BOOL savedSelection = [selectionStore saveSelection:customSelection
        forCatalog:componentCatalog error:&error];
    MTThemeComponentSelection *loadedSelection = [selectionStore
        selectionForCatalog:componentCatalog];
    BOOL recordedSelection = [selectionStore
        recordAppliedSelection:customSelection
        themeIdentifier:prepared.manifest.themeID
        revisionIdentifier:revision.revisionIdentifier
        generationIdentifier:customGeneration.descriptor.generationIdentifier
        error:&error];
    MTThemeComponentSelection *appliedSelection = [selectionStore
        appliedSelectionForGenerationIdentifier:
            customGeneration.descriptor.generationIdentifier
        themeIdentifier:prepared.manifest.themeID
        revisionIdentifier:revision.revisionIdentifier
        catalog:componentCatalog];
    MTAssert(savedSelection && recordedSelection && error == nil &&
             [loadedSelection isEqual:customSelection] &&
             [appliedSelection isEqual:customSelection],
        @"Manager selection preferences must round-trip desired and applied Generation choices without touching Library data");

    NSString *alternateSourceRoot = MTCreateTemporaryDirectory(
        @"snowboard-mix-alternate-source");
    NSData *alternatePNG = MTPNGFixtureData(91, 91, 8, 6, 0, YES, @[], @[]);
    NSData *alternateOverlayPNG =
        MTPNGFixtureData(93, 93, 8, 6, 0, YES, @[], @[]);
    NSDictionary<NSString *, NSData *> *alternateFiles = @{
        @"Alternate.theme/Info.plist" : MTPropertyListFixtureData(@{
            @"PackageName" : @"Alternate Mix Source",
        }, NSPropertyListBinaryFormat_v1_0),
        @"Alternate.theme/IconBundles/com.example.Alternate.png" : alternatePNG,
        @"Alternate.theme/Bundles/com.apple.springboard/SBBadgeBG@2x.png" :
            alternatePNG,
        @"Alternate.theme/AnemoneEffects/iPhoneOverlay@3x.png" :
            alternateOverlayPNG,
    };
    for (NSString *relativePath in alternateFiles) {
        NSString *path = [alternateSourceRoot
            stringByAppendingPathComponent:relativePath];
        MTAssert([NSFileManager.defaultManager
            createDirectoryAtPath:path.stringByDeletingLastPathComponent
      withIntermediateDirectories:YES
                       attributes:@{NSFilePosixPermissions : @0700}
                            error:&error] &&
            [alternateFiles[relativePath] writeToFile:path options:0
                                                error:&error],
            @"Cross-theme mix fixture must write its alternate source");
    }
    MTPreparedThemeImport *alternatePrepared = [pipeline
        prepareDirectoryThemeAtURL:
            [NSURL fileURLWithPath:alternateSourceRoot isDirectory:YES]
        sourceName:@"Alternate"
        cancellationToken:nil progressHandler:nil error:&error];
    MTThemeLibraryRevision *alternateRevision = [pipeline
        commitPreparedImport:alternatePrepared cancellationToken:nil
        progressHandler:nil error:&error];
    MTThemeComponentCatalog *alternateCatalog = alternateRevision == nil ? nil :
        [MTThemeComponentCatalog catalogForManifest:alternateRevision.manifest
                                               error:&error];
    NSDictionary<NSString *, MTThemeLibraryRevision *> *mixRevisions =
        alternateRevision == nil ? @{} : @{
            revision.manifest.themeID : revision,
            alternateRevision.manifest.themeID : alternateRevision,
        };
    NSDictionary<NSString *, NSString *> *mixRevisionIdentifiers =
        alternateRevision == nil ? @{} : @{
            revision.manifest.themeID : revision.revisionIdentifier,
            alternateRevision.manifest.themeID :
                alternateRevision.revisionIdentifier,
        };
    NSDictionary<NSString *, MTThemeComponentSelection *> *mixComponents =
        alternateCatalog == nil ? @{} : @{
            revision.manifest.themeID : customSelection,
            alternateRevision.manifest.themeID :
                alternateCatalog.defaultSelection,
        };
    NSDictionary<NSString *, NSSet<NSString *> *> *mixAvailableFeatures =
        alternateCatalog == nil ? @{} : @{
            revision.manifest.themeID :
                MTThemeRuntimeApplicableFeatureIdentifiersForSelection(
                    revision.manifest, customSelection),
            alternateRevision.manifest.themeID :
                MTThemeRuntimeApplicableFeatureIdentifiersForSelection(
                    alternateRevision.manifest,
                    alternateCatalog.defaultSelection),
        };
    MTThemeMixSelection *mixSelection = [MTThemeMixSelection
        selectionWithBaseThemeIdentifier:revision.manifest.themeID
        sourceThemeIdentifiersByFeature:@{
            MTThemeFeatureBadges : alternateRevision.manifest.themeID ?: @"",
        }
        disabledFeatureIdentifiers:@[MTThemeFeatureStatusBar]
        revisionIdentifiersByThemeIdentifier:mixRevisionIdentifiers
        componentSelectionsByThemeIdentifier:mixComponents
        error:&error];
    MTCompiledGeneration *mixedGeneration = mixSelection == nil ? nil :
        [[MTStaticIconCompiler defaultCompiler]
            compileLibraryRevisionsByThemeIdentifier:mixRevisions
            mixSelection:mixSelection cancellationToken:nil error:&error];
    MTThemeMixSelection *overlaySourceMix = [MTThemeMixSelection
        selectionWithBaseThemeIdentifier:revision.manifest.themeID
        sourceThemeIdentifiersByFeature:@{
            MTThemeFeatureIconOverlay :
                alternateRevision.manifest.themeID ?: @"",
        }
        disabledFeatureIdentifiers:@[]
        revisionIdentifiersByThemeIdentifier:mixRevisionIdentifiers
        componentSelectionsByThemeIdentifier:mixComponents
        error:&error];
    MTCompiledGeneration *overlaySourceGeneration =
        overlaySourceMix == nil ? nil :
        [[MTStaticIconCompiler defaultCompiler]
            compileLibraryRevisionsByThemeIdentifier:mixRevisions
            mixSelection:overlaySourceMix cancellationToken:nil error:&error];
    MTThemeMixSelection *overlayDisabledMix = [overlaySourceMix
        selectionBySettingFeatureIdentifier:MTThemeFeatureIconOverlay
        enabled:NO error:&error];
    MTCompiledGeneration *overlayDisabledGeneration =
        overlayDisabledMix == nil ? nil :
        [[MTStaticIconCompiler defaultCompiler]
            compileLibraryRevisionsByThemeIdentifier:@{
                revision.manifest.themeID : revision,
            }
            mixSelection:overlayDisabledMix cancellationToken:nil
            error:&error];
    NSArray<NSString *> *allMixFeatures = @[
        MTThemeFeatureAppIcons,
        MTThemeFeatureSettingsIcons,
        MTThemeFeatureShareIcons,
        MTThemeFeatureFolders,
        MTThemeFeatureDynamicClock,
        MTThemeFeatureDynamicCalendar,
        MTThemeFeatureIconMask,
        MTThemeFeatureIconOverlay,
        MTThemeFeatureBadges,
        MTThemeFeatureStatusBar,
        MTThemeFeatureIconShadows,
        MTThemeFeatureDialer,
    ];
    MTThemeMixSelection *allDisabledMix = [MTThemeMixSelection
        selectionWithBaseThemeIdentifier:revision.manifest.themeID
        sourceThemeIdentifiersByFeature:@{}
        disabledFeatureIdentifiers:allMixFeatures
        revisionIdentifiersByThemeIdentifier:mixRevisionIdentifiers
        componentSelectionsByThemeIdentifier:mixComponents
        error:&error];
    MTCompiledGeneration *allDisabledGeneration = allDisabledMix == nil ? nil :
        [[MTStaticIconCompiler defaultCompiler]
            compileLibraryRevisionsByThemeIdentifier:@{
                revision.manifest.themeID : revision,
            }
            mixSelection:allDisabledMix cancellationToken:nil error:&error];
    MTThresholdCancellationToken *mixPreprocessingCancellation =
        [[MTThresholdCancellationToken alloc]
            initWithThreshold:7 + revision.manifest.resources.count];
    NSError *mixCancellationError = nil;
    MTCompiledGeneration *cancelledMixGeneration = allDisabledMix == nil ? nil :
        [[MTStaticIconCompiler defaultCompiler]
            compileLibraryRevisionsByThemeIdentifier:@{
                revision.manifest.themeID : revision,
            }
            mixSelection:allDisabledMix
            cancellationToken:mixPreprocessingCancellation
            error:&mixCancellationError];
    BOOL hasAlternateBadge = NO;
    BOOL hasAlternateOverlay = NO;
    BOOL hasStaticIcons = NO;
    BOOL hasDisabledStatusBar = NO;
    for (NSUInteger index = 0; index < mixedGeneration.index.recordCount;
         index++) {
        MTGenerationIndexRecord *record = [mixedGeneration.index
            recordAtIndex:index];
        hasAlternateBadge = hasAlternateBadge ||
            ([record.canonicalResourceKey containsString:MTBadgesModuleID] &&
             [record.contentSHA256 isEqualToString:
                 MTSHA256HexDigestForData(alternatePNG)]);
        hasStaticIcons = hasStaticIcons ||
            [record.canonicalResourceKey containsString:@"icons.static"];
        hasDisabledStatusBar = hasDisabledStatusBar ||
            [record.canonicalResourceKey containsString:MTStatusBarModuleID];
    }
    for (NSUInteger index = 0;
         index < overlaySourceGeneration.index.recordCount; index++) {
        MTGenerationIndexRecord *record = [overlaySourceGeneration.index
            recordAtIndex:index];
        hasAlternateOverlay = hasAlternateOverlay ||
            ([record.canonicalResourceKey
                containsString:MTIconOverlayModuleID] &&
             [record.contentSHA256 isEqualToString:
                 MTSHA256HexDigestForData(alternateOverlayPNG)]);
    }
    BOOL overlayDisabledGenerationHasOverlay = NO;
    for (NSUInteger index = 0;
         index < overlayDisabledGeneration.index.recordCount; index++) {
        MTGenerationIndexRecord *record = [overlayDisabledGeneration.index
            recordAtIndex:index];
        overlayDisabledGenerationHasOverlay =
            overlayDisabledGenerationHasOverlay ||
            [record.canonicalResourceKey
                containsString:MTIconOverlayModuleID];
    }
    BOOL savedMix = [selectionStore saveMixSelection:mixSelection error:&error];
    MTThemeMixSelection *loadedMix = [selectionStore
        mixSelectionForBaseThemeIdentifier:revision.manifest.themeID
        revisionIdentifiersByThemeIdentifier:mixRevisionIdentifiers
        componentSelectionsByThemeIdentifier:mixComponents
        availableFeatureIdentifiersByThemeIdentifier:mixAvailableFeatures];
    MTThemeMixSelection *partiallyRevalidatedMix = [selectionStore
        mixSelectionForBaseThemeIdentifier:revision.manifest.themeID
        revisionIdentifiersByThemeIdentifier:mixRevisionIdentifiers
        componentSelectionsByThemeIdentifier:mixComponents
        availableFeatureIdentifiersByThemeIdentifier:@{
            revision.manifest.themeID :
                mixAvailableFeatures[revision.manifest.themeID],
        }];
    BOOL recordedMix = [selectionStore
        recordAppliedMixSelection:mixSelection
        generationIdentifier:mixedGeneration.descriptor.generationIdentifier
        error:&error];
    MTThemeMixSelection *appliedMix = [selectionStore
        appliedMixSelectionForGenerationIdentifier:
            mixedGeneration.descriptor.generationIdentifier
        baseThemeIdentifier:revision.manifest.themeID
        baseRevisionIdentifier:revision.revisionIdentifier];
    MTThemeMixSelection *roundTripMix = [MTThemeMixSelection
        selectionWithCanonicalDictionary:mixSelection.canonicalDictionary
        error:&error];
    MTThemeMixSelection *badgeDisabledMix = [mixSelection
        selectionBySettingFeatureIdentifier:MTThemeFeatureBadges
        enabled:NO error:&error];
    MTCompiledGeneration *badgeDisabledGeneration = badgeDisabledMix == nil
        ? nil : [[MTStaticIconCompiler defaultCompiler]
            compileLibraryRevisionsByThemeIdentifier:@{
                revision.manifest.themeID : revision,
            }
            mixSelection:badgeDisabledMix cancellationToken:nil error:&error];
    MTThemeMixSelection *badgeDisabledWithoutRememberedSource =
        [MTThemeMixSelection
            selectionWithBaseThemeIdentifier:revision.manifest.themeID
            sourceThemeIdentifiersByFeature:@{}
            disabledFeatureIdentifiers:@[
                MTThemeFeatureBadges, MTThemeFeatureStatusBar,
            ]
            revisionIdentifiersByThemeIdentifier:mixRevisionIdentifiers
            componentSelectionsByThemeIdentifier:mixComponents
            error:&error];
    MTCompiledGeneration *badgeDisabledWithoutSourceGeneration =
        badgeDisabledWithoutRememberedSource == nil ? nil :
        [[MTStaticIconCompiler defaultCompiler]
            compileLibraryRevisionsByThemeIdentifier:@{
                revision.manifest.themeID : revision,
            }
            mixSelection:badgeDisabledWithoutRememberedSource
            cancellationToken:nil error:&error];
    MTAssert(alternatePrepared != nil && alternateRevision != nil &&
             alternateCatalog != nil && mixSelection != nil &&
             mixedGeneration != nil && overlaySourceMix != nil &&
             overlaySourceGeneration != nil &&
             overlayDisabledGeneration != nil && error == nil &&
             ![alternateRevision.manifest.themeID
                 isEqualToString:revision.manifest.themeID] &&
             [mixedGeneration.descriptor.themeID
                 isEqualToString:revision.manifest.themeID] &&
             [mixedGeneration.descriptor.libraryRevisionIdentifier
                 isEqualToString:revision.revisionIdentifier] &&
             hasAlternateBadge && hasAlternateOverlay && hasStaticIcons &&
             !hasDisabledStatusBar &&
             [mixedGeneration.descriptor.moduleIDs
                 containsObject:MTBadgesModuleID] &&
             ![mixedGeneration.descriptor.moduleIDs
                 containsObject:MTStatusBarModuleID] &&
             !overlayDisabledGenerationHasOverlay &&
             ![overlayDisabledGeneration.descriptor.moduleIDs
                 containsObject:MTIconOverlayModuleID] &&
             allDisabledGeneration != nil &&
             allDisabledGeneration.index.recordCount == 0 &&
             allDisabledGeneration.descriptor.resourceCount == 0 &&
             allDisabledGeneration.descriptor.moduleIDs.count == 0 &&
             cancelledMixGeneration == nil &&
             [mixCancellationError.domain isEqualToString:
                 MTStaticIconCompilerErrorDomain] &&
             mixCancellationError.code == MTStaticIconCompilerErrorCancelled &&
             mixPreprocessingCancellation.readCount ==
                 7 + revision.manifest.resources.count &&
             savedMix && recordedMix && [loadedMix isEqual:mixSelection] &&
             [partiallyRevalidatedMix isEqual:mixSelection] &&
             [appliedMix isEqual:mixSelection] &&
             [roundTripMix isEqual:mixSelection] &&
             [badgeDisabledMix.referencedThemeIdentifiers
                 containsObject:alternateRevision.manifest.themeID] &&
             ![badgeDisabledMix.effectiveThemeIdentifiers
                 containsObject:alternateRevision.manifest.themeID] &&
             badgeDisabledGeneration != nil &&
             ![badgeDisabledMix
                 isEqual:badgeDisabledWithoutRememberedSource] &&
             [badgeDisabledMix isRuntimeEquivalentToSelection:
                 badgeDisabledWithoutRememberedSource] &&
             [badgeDisabledGeneration.descriptor.generationIdentifier
                 isEqualToString:badgeDisabledWithoutSourceGeneration
                     .descriptor.generationIdentifier] &&
             [badgeDisabledMix.effectiveCanonicalDictionary[@"sourceThemes"]
                 count] == 0 &&
             [badgeDisabledMix.effectiveCanonicalDictionary[@"revisions"]
                 count] == 1,
        [NSString stringWithFormat:
            @"feature mix must use alternate Badge and overlay assets, remove disabled overlay content, keep base icons, omit disabled features and their source revisions, round-trip exact applied identity, and compare Runtime by effective identity (generation=%@ modules=%@ error=%@)",
            mixedGeneration.descriptor.generationIdentifier,
            mixedGeneration.descriptor.moduleIDs,
            error.localizedDescription ?: @"none"]);

    NSMutableSet<NSString *> *alternateFeaturesWithoutBadge =
        [mixAvailableFeatures[alternateRevision.manifest.themeID] mutableCopy];
    [alternateFeaturesWithoutBadge removeObject:MTThemeFeatureBadges];
    NSDictionary<NSString *, NSSet<NSString *> *> *unavailableBadgeFeatures = @{
        revision.manifest.themeID :
            mixAvailableFeatures[revision.manifest.themeID],
        alternateRevision.manifest.themeID :
            [alternateFeaturesWithoutBadge copy],
    };
    MTThemeMixSelection *repairedUnavailableMix = [selectionStore
        mixSelectionForBaseThemeIdentifier:revision.manifest.themeID
        revisionIdentifiersByThemeIdentifier:mixRevisionIdentifiers
        componentSelectionsByThemeIdentifier:mixComponents
        availableFeatureIdentifiersByThemeIdentifier:unavailableBadgeFeatures];
    MTThemeMixSelection *persistedRepairedMix = [selectionStore
        mixSelectionForBaseThemeIdentifier:revision.manifest.themeID
        revisionIdentifiersByThemeIdentifier:mixRevisionIdentifiers
        componentSelectionsByThemeIdentifier:mixComponents
        availableFeatureIdentifiersByThemeIdentifier:mixAvailableFeatures];
    MTAssert(repairedUnavailableMix != nil &&
             [repairedUnavailableMix.sourceThemeIdentifiersByFeature[
                 MTThemeFeatureBadges]
                 isEqualToString:alternateRevision.manifest.themeID] &&
             ![repairedUnavailableMix
                 isFeatureEnabled:MTThemeFeatureBadges] &&
             ![repairedUnavailableMix.effectiveThemeIdentifiers
                 containsObject:alternateRevision.manifest.themeID] &&
             ![persistedRepairedMix
                 isFeatureEnabled:MTThemeFeatureBadges],
        @"an explicit source that loses its selected feature must be retained as a preference, safely disabled, excluded from the effective source set, and stay disabled after the source becomes available again");

    NSError *missingSourceRepairError = nil;
    BOOL resetMixForMissingSource = [selectionStore
        saveMixSelection:mixSelection error:&missingSourceRepairError];
    MTThemeMixSelection *missingSourceMix = [selectionStore
        mixSelectionForBaseThemeIdentifier:revision.manifest.themeID
        revisionIdentifiersByThemeIdentifier:@{
            revision.manifest.themeID : revision.revisionIdentifier,
        }
        componentSelectionsByThemeIdentifier:@{
            revision.manifest.themeID : customSelection,
        }
        availableFeatureIdentifiersByThemeIdentifier:@{
            revision.manifest.themeID :
                mixAvailableFeatures[revision.manifest.themeID],
        }];
    MTThemeMixSelection *restoredMissingSourceMix = [selectionStore
        mixSelectionForBaseThemeIdentifier:revision.manifest.themeID
        revisionIdentifiersByThemeIdentifier:mixRevisionIdentifiers
        componentSelectionsByThemeIdentifier:mixComponents
        availableFeatureIdentifiersByThemeIdentifier:mixAvailableFeatures];
    MTAssert(resetMixForMissingSource && missingSourceRepairError == nil &&
             missingSourceMix != nil &&
             ![missingSourceMix isFeatureEnabled:MTThemeFeatureBadges] &&
             missingSourceMix.sourceThemeIdentifiersByFeature[
                 MTThemeFeatureBadges] == nil &&
             [restoredMissingSourceMix.sourceThemeIdentifiersByFeature[
                 MTThemeFeatureBadges]
                 isEqualToString:alternateRevision.manifest.themeID] &&
             ![restoredMissingSourceMix
                 isFeatureEnabled:MTThemeFeatureBadges],
        @"a temporarily missing source theme must safely disable its feature while retaining the source preference for a later reinstall");
    NSError *unsupportedMixError = nil;
    MTThemeMixSelection *unsupportedMix = [MTThemeMixSelection
        selectionWithBaseThemeIdentifier:revision.manifest.themeID
        sourceThemeIdentifiersByFeature:@{}
        disabledFeatureIdentifiers:@[MTThemeFeatureIconPattern]
        revisionIdentifiersByThemeIdentifier:mixRevisionIdentifiers
        componentSelectionsByThemeIdentifier:mixComponents
        error:&unsupportedMixError];
    BOOL savedUnsupportedMix = [selectionStore
        saveMixSelection:unsupportedMix error:&unsupportedMixError];
    MTAssert(unsupportedMix != nil && !savedUnsupportedMix &&
             [unsupportedMixError.domain isEqualToString:
                 MTThemeComponentSelectionStoreErrorDomain],
        @"mix preferences must reject display-only capabilities that cannot be switched independently");
    [NSFileManager.defaultManager removeItemAtPath:alternateSourceRoot
                                             error:NULL];
    [defaults removePersistentDomainForName:defaultsSuite];

    [NSFileManager.defaultManager removeItemAtPath:sourceRoot error:NULL];
    [NSFileManager.defaultManager removeItemAtPath:workflowRoot error:NULL];
}

static void MTTestFolderComponentSelectionDependency(void) {
    NSString *sourceRoot = MTCreateTemporaryDirectory(
        @"folder-component-selection-source");
    NSString *workflowRoot = MTCreateTemporaryDirectory(
        @"folder-component-selection-workflow");
    NSData *png = MTPNGFixtureData(87, 87, 8, 6, 0, YES, @[], @[]);
    NSData *metadata = MTPropertyListFixtureData(@{
        @"CFBundleDisplayName" : @"Folder Selection Fixture",
    }, NSPropertyListBinaryFormat_v1_0);
    NSDictionary<NSString *, NSData *> *files = @{
        @"Fixture.theme/Info.plist" : metadata,
        @"Fixture.theme/IconBundles/com.example.App.png" : png,
        @"Fixture - Folder Base.theme/IconBundles/icon_folder.png" : png,
        @"Fixture - Folder Light.theme/IconBundles/icon_folder_light.png" : png,
    };
    NSError *error = nil;
    for (NSString *relativePath in files) {
        NSString *path = [sourceRoot
            stringByAppendingPathComponent:relativePath];
        MTAssert([NSFileManager.defaultManager
            createDirectoryAtPath:path.stringByDeletingLastPathComponent
      withIntermediateDirectories:YES
                       attributes:@{NSFilePosixPermissions : @0700}
                            error:&error] &&
            [files[relativePath] writeToFile:path options:0 error:&error],
            @"Folder component selection fixture must write its theme suite");
    }

    MTThemeImportPipeline *pipeline = [[MTThemeImportPipeline alloc]
        initWithConfiguration:MTWorkflowFixtureConfiguration(workflowRoot)];
    MTPreparedThemeImport *prepared = [pipeline
        prepareDirectoryThemeAtURL:
            [NSURL fileURLWithPath:sourceRoot isDirectory:YES]
        sourceName:@"Fixture"
        cancellationToken:nil progressHandler:nil error:&error];
    MTThemeLibraryRevision *revision = [pipeline
        commitPreparedImport:prepared cancellationToken:nil
        progressHandler:nil error:&error];
    MTThemeComponentCatalog *catalog = revision == nil ? nil :
        [MTThemeComponentCatalog catalogForManifest:revision.manifest
                                               error:&error];
    MTThemeComponentSelection *selection = catalog.defaultSelection;
    selection = [selection
        selectionBySettingComponentIdentifier:@"fixture-folder-base"
                                       enabled:NO
                                       catalog:catalog
                                         error:&error];
    MTCompiledGeneration *generation = revision == nil ? nil :
        [[MTStaticIconCompiler defaultCompiler]
            compileLibraryRevision:revision
            componentSelection:selection
            cancellationToken:nil error:&error];
    MTAssert(prepared != nil && revision != nil && catalog != nil &&
             selection != nil && generation != nil && error == nil &&
             [revision.manifest.capabilities
                 containsObject:MTFolderIconsModuleID] &&
             generation.index.recordCount == 1 &&
             [generation.descriptor.moduleIDs
                 isEqualToArray:@[@"icons.static"]],
        @"disabling the Folder base component must also exclude its orphaned light companion without blocking the remaining theme");

    [NSFileManager.defaultManager removeItemAtPath:sourceRoot error:NULL];
    [NSFileManager.defaultManager removeItemAtPath:workflowRoot error:NULL];
}

static NSUInteger MTWorkflowDirectoryEntryCount(NSString *path) {
    return [[NSFileManager.defaultManager contentsOfDirectoryAtPath:path
                                                              error:NULL] count];
}

static NSString *MTWorkflowValidArchive(NSString *root,
                                        NSString *name) {
    NSData *firstPNG = MTPNGFixtureData(180, 180, 8, 6, 0, YES, @[], @[]);
    NSData *secondPNG = MTPNGFixtureData(240, 240, 8, 6, 0, YES, @[], @[]);
    NSData *metadata = MTPropertyListFixtureData(@{
        @"CFBundleDisplayName" : @"Workflow Theme",
        @"CFBundleShortVersionString" : @"7.2",
    }, NSPropertyListBinaryFormat_v1_0);
    return MTWriteZIPFixture(root, name, @[
        @{@"name" : @"尺玉/", @"flags" : @0,
          @"mode" : @(S_IFDIR | 0755)},
        @{@"name" : @"尺玉/IconBundles/", @"flags" : @0,
          @"mode" : @(S_IFDIR | 0755)},
        @{@"name" : @"尺玉/Bundles/", @"flags" : @0,
          @"mode" : @(S_IFDIR | 0755)},
        @{@"name" : @"尺玉/Bundles/com.apple.Preferences/", @"flags" : @0,
          @"mode" : @(S_IFDIR | 0755)},
        @{@"name" : @"尺玉/Bundles/com.apple.SharingUIService/",
          @"flags" : @0, @"mode" : @(S_IFDIR | 0755)},
        @{@"name" : @"尺玉/Info.plist", @"flags" : @0,
          @"data" : metadata},
        @{@"name" : @"尺玉/IconBundles/com.example.Primary@3x.png",
          @"flags" : @0, @"data" : firstPNG, @"method" : @8},
        @{@"name" : @"尺玉/IconBundles/com.example.Duplicate@3x.png",
          @"flags" : @0, @"data" : firstPNG},
        @{@"name" : @"尺玉/IconBundles/com.example.Secondary@2x.png",
          @"flags" : @0, @"data" : secondPNG, @"method" : @8},
        @{@"name" : @"尺玉/Bundles/com.apple.Preferences/WiFi@3x.png",
          @"flags" : @0, @"data" : firstPNG, @"method" : @8},
        @{@"name" : @"尺玉/Bundles/com.apple.SharingUIService/UIMessageActivity@3x.png",
          @"flags" : @0, @"data" : firstPNG, @"method" : @8},
        @{@"name" : @"尺玉/README.txt", @"flags" : @0,
          @"data" : [@"ignored" dataUsingEncoding:NSUTF8StringEncoding]},
    ]);
}

static NSString *MTShareSheetGateArchive(NSString *root,
                                         NSString *name) {
    NSData *metadata = MTPropertyListFixtureData(@{
        @"CFBundleDisplayName" : @"MarkTheme Share Gate",
        @"CFBundleShortVersionString" : @"1.0",
    }, NSPropertyListBinaryFormat_v1_0);
    return MTWriteZIPFixture(root, name, @[
        @{@"name" : @"MarkThemeShareGate.theme/", @"flags" : @0,
          @"mode" : @(S_IFDIR | 0755)},
        @{@"name" : @"MarkThemeShareGate.theme/Bundles/", @"flags" : @0,
          @"mode" : @(S_IFDIR | 0755)},
        @{@"name" :
              @"MarkThemeShareGate.theme/Bundles/com.apple.SharingUIService/",
          @"flags" : @0, @"mode" : @(S_IFDIR | 0755)},
        @{@"name" : @"MarkThemeShareGate.theme/Info.plist", @"flags" : @0,
          @"data" : metadata},
        @{@"name" :
              @"MarkThemeShareGate.theme/Bundles/com.apple.SharingUIService/"
               @"UIMessageActivity@3x.png",
          @"flags" : @0, @"data" : MTHighContrastShareActivityPNGData(),
          @"method" : @8},
    ]);
}

static NSString *MTWorkflowValidDirectory(NSString *root,
                                          NSString *name) {
    NSString *directory = [root stringByAppendingPathComponent:name];
    NSString *icons = [directory stringByAppendingPathComponent:@"IconBundles"];
    NSString *settings = [directory stringByAppendingPathComponent:
        @"Bundles/com.apple.Preferences"];
    NSString *share = [directory stringByAppendingPathComponent:
        @"Bundles/com.apple.SharingUIService"];
    NSError *error = nil;
    MTAssert([NSFileManager.defaultManager
        createDirectoryAtPath:icons withIntermediateDirectories:YES
        attributes:@{NSFilePosixPermissions : @0700} error:&error] &&
        [NSFileManager.defaultManager
        createDirectoryAtPath:settings withIntermediateDirectories:YES
        attributes:@{NSFilePosixPermissions : @0700} error:&error] &&
        [NSFileManager.defaultManager
        createDirectoryAtPath:share withIntermediateDirectories:YES
        attributes:@{NSFilePosixPermissions : @0700} error:&error],
        @"workflow directory fixture must create its theme resource trees");
    NSData *firstPNG = MTPNGFixtureData(180, 180, 8, 6, 0, YES, @[], @[]);
    NSData *secondPNG = MTPNGFixtureData(240, 240, 8, 6, 0, YES, @[], @[]);
    NSData *metadata = MTPropertyListFixtureData(@{
        @"CFBundleDisplayName" : @"Workflow Theme",
        @"CFBundleShortVersionString" : @"7.2",
    }, NSPropertyListBinaryFormat_v1_0);
    NSDictionary<NSString *, NSData *> *files = @{
        @"Info.plist" : metadata,
        @"IconBundles/com.example.Primary@3x.png" : firstPNG,
        @"IconBundles/com.example.Duplicate@3x.png" : firstPNG,
        @"IconBundles/com.example.Secondary@2x.png" : secondPNG,
        @"Bundles/com.apple.Preferences/WiFi@3x.png" : firstPNG,
        @"Bundles/com.apple.SharingUIService/UIMessageActivity@3x.png" :
            firstPNG,
        @"README.txt" : [@"ignored" dataUsingEncoding:NSUTF8StringEncoding],
    };
    for (NSString *relativePath in files) {
        MTAssert([files[relativePath] writeToFile:
            [directory stringByAppendingPathComponent:relativePath]
            options:0 error:&error],
            @"workflow directory fixture files must be written");
    }
    return directory;
}

static NSString *MTWorkflowInvalidImageArchive(NSString *root,
                                               NSString *name) {
    NSData *metadata = MTPropertyListFixtureData(@{
        @"CFBundleDisplayName" : @"Bad Image",
    }, NSPropertyListXMLFormat_v1_0);
    return MTWriteZIPFixture(root, name, @[
        @{@"name" : @"IconBundles/", @"mode" : @(S_IFDIR | 0755)},
        @{@"name" : @"Info.plist", @"data" : metadata},
        @{@"name" : @"IconBundles/com.example.Bad@3x.png",
          @"data" : MTSyntheticPNGData(@"not-a-real-png")},
    ]);
}

static NSString *MTWorkflowPartiallyInvalidImageArchive(NSString *root,
                                                        NSString *name) {
    NSData *metadata = MTPropertyListFixtureData(@{
        @"CFBundleDisplayName" : @"Partially Valid Theme",
    }, NSPropertyListXMLFormat_v1_0);
    return MTWriteZIPFixture(root, name, @[
        @{ @"name" : @"IconBundles/", @"mode" : @(S_IFDIR | 0755) },
        @{ @"name" : @"Info.plist", @"data" : metadata },
        @{ @"name" : @"IconBundles/com.example.Good.png",
           @"data" : MTPNGFixtureData(87, 87, 8, 6, 0, YES, @[], @[]) },
        @{ @"name" : @"IconBundles/com.example.Bad.png",
           @"data" : MTSyntheticPNGData(@"not-a-real-png") },
    ]);
}

static NSString *MTWorkflowInvalidFolderBaseArchive(NSString *root,
                                                    NSString *name) {
    NSData *metadata = MTPropertyListFixtureData(@{
        @"CFBundleDisplayName" : @"Folder Validation Theme",
    }, NSPropertyListXMLFormat_v1_0);
    NSData *validPNG = MTPNGFixtureData(
        87, 87, 8, 6, 0, YES, @[], @[]);
    return MTWriteZIPFixture(root, name, @[
        @{ @"name" : @"IconBundles/", @"mode" : @(S_IFDIR | 0755) },
        @{ @"name" : @"Info.plist", @"data" : metadata },
        @{ @"name" : @"IconBundles/com.example.FolderGuard.png",
           @"data" : validPNG },
        @{ @"name" : @"IconBundles/icon_folder.png",
           @"data" : MTSyntheticPNGData(@"not-a-real-folder-png") },
        @{ @"name" : @"IconBundles/icon_folder_light.png",
           @"data" : validPNG },
    ]);
}

static NSString *MTWorkflowInvalidImageDirectory(NSString *root,
                                                 NSString *name) {
    NSString *directory = [root stringByAppendingPathComponent:name];
    NSString *icons = [directory stringByAppendingPathComponent:@"IconBundles"];
    NSError *error = nil;
    MTAssert([NSFileManager.defaultManager
        createDirectoryAtPath:icons withIntermediateDirectories:YES
        attributes:@{NSFilePosixPermissions : @0700} error:&error],
        @"invalid directory fixture must create its IconBundles tree");
    NSData *metadata = MTPropertyListFixtureData(@{
        @"CFBundleDisplayName" : @"Bad Image",
    }, NSPropertyListXMLFormat_v1_0);
    MTAssert([metadata writeToFile:
        [directory stringByAppendingPathComponent:@"Info.plist"]
        options:0 error:&error] &&
             [MTSyntheticPNGData(@"not-a-real-png") writeToFile:
        [icons stringByAppendingPathComponent:@"com.example.Bad@3x.png"]
        options:0 error:&error],
        @"invalid directory fixture files must be written");
    return directory;
}

// Store packages are ordinary Debian archives whose payload lives under a
// filesystem path such as /Library/Themes/Name.theme. Both the container and
// that path prefix have to survive import.
// A theme installed by a package manager is already a directory on disk, so
// locating it is all that stands between the user and the ordinary directory
// import path.
static void MTTestInstalledThemeLocator(void) {
    NSString *root = MTCreateTemporaryDirectory(@"installed-themes");
    NSString *themesRoot = [root stringByAppendingPathComponent:@"Themes"];
    NSData *icon = MTPNGFixtureData(1, 1, 8, 6, 0, YES, @[], @[]);
    NSError *error = nil;
    NSArray<NSString *> *bundles = @[@"Zeta.theme", @"alpha.theme"];
    for (NSString *bundle in bundles) {
        NSString *iconBundles = [themesRoot stringByAppendingPathComponent:
            [bundle stringByAppendingPathComponent:@"IconBundles"]];
        MTAssert([NSFileManager.defaultManager
            createDirectoryAtPath:iconBundles
      withIntermediateDirectories:YES
                       attributes:@{NSFilePosixPermissions : @0755}
                            error:&error],
            @"installed theme fixture directories must initialize");
        MTAssert([icon writeToFile:[iconBundles
            stringByAppendingPathComponent:@"com.example.App.png"]
            options:0 error:&error],
            @"installed theme fixture icons must be written");
    }
    // Neither a plain directory nor a hidden entry is an installed theme.
    MTAssert([NSFileManager.defaultManager
        createDirectoryAtPath:[themesRoot
            stringByAppendingPathComponent:@"NotATheme"]
  withIntermediateDirectories:YES attributes:nil error:&error],
        @"installed theme fixture noise must initialize");

    MTInstalledThemeLocator *locator = [[MTInstalledThemeLocator alloc]
        initWithSearchRootPaths:@[themesRoot,
            [root stringByAppendingPathComponent:@"Missing"]]];
    NSArray<MTInstalledTheme *> *found = [locator locateInstalledThemes];
    MTAssert(found.count == 2 &&
             [found[0].displayName isEqualToString:@"alpha"] &&
             [found[1].displayName isEqualToString:@"Zeta"],
        @"the locator must find .theme bundles by name and skip other entries");

    // The located directory must import through the ordinary directory path.
    MTSafeDirectoryScan *scan = [[[MTSafeDirectoryScanner alloc]
        initWithLimits:MTImportLimits.defaultLimits]
        scanDirectorySourceAtURL:found.firstObject.directoryURL
        error:&error];
    id<MTAuditedSource> themeRoot = scan == nil ? nil :
        [MTThemeSourceRoot sourceByResolvingThemeRootInSource:scan
                                                        error:&error];
    MTIconBundlesImportResult *result = themeRoot == nil ? nil :
        [[[MTIconBundlesImporter alloc] init]
            importSourceInventory:themeRoot.inventory
                       sourceName:found.firstObject.displayName
                            error:&error];
    MTAssert(result != nil && result.manifest.resources.count == 1,
        @"a located installed theme must import through the directory path");

    // The default search roots are the whole feature on a real device, and on
    // the host they resolve to bare logical paths, so the scheme-dependent
    // path math has to be checked against an explicit resolver. jbroot()
    // prefixes unconditionally: without the literal roots below, a package
    // manager's themes under /var/mobile are unreachable on BOTH rootless
    // (/var/jb/var/mobile/...) and RootHide, and the locator returns nothing
    // while reporting no error at all.
    NSArray<NSDictionary<NSString *, id> *> *schemes = @[
        @{ @"prefix" : @"/var/jb",
           @"scheme" : @(MTPackageSchemeRootless) },
        @{ @"prefix" : @"/private/preboot/SYNTHETIC/procursus",
           @"scheme" : @(MTPackageSchemeRootHide) },
    ];
    for (NSDictionary<NSString *, id> *scheme in schemes) {
        NSString *prefix = scheme[@"prefix"];
        MTBootstrapPathResolver *resolver = [MTBootstrapPathResolver
            resolverForTestingScheme:
                (MTPackageScheme)[scheme[@"scheme"] unsignedIntegerValue]
                       physicalPrefix:prefix];
        NSArray<NSString *> *roots = [[[MTInstalledThemeLocator alloc]
            initWithBootstrapResolver:resolver] searchRootPaths];
        MTAssert([roots containsObject:@"/var/mobile/Library/Themes"],
            @"the real-rootfs user theme root must be searched literally");
        MTAssert([roots containsObject:
            [prefix stringByAppendingString:@"/Library/Themes"]],
            @"the bootstrap theme root must still be searched at its prefix");
        MTAssert(roots.count == [NSSet setWithArray:roots].count,
            @"default search roots must not repeat a path");
    }

    // A resolver that yields nothing must still leave the literal roots, so a
    // rootful or otherwise unusual install is not silently unsupported.
    NSArray<NSString *> *literalOnly = [[[MTInstalledThemeLocator alloc]
        initWithBootstrapResolver:nil] searchRootPaths];
    MTAssert([literalOnly containsObject:@"/var/mobile/Library/Themes"] &&
             [literalOnly containsObject:@"/Library/Themes"],
        @"literal theme roots must survive an unavailable bootstrap resolver");

    [NSFileManager.defaultManager removeItemAtPath:root error:NULL];
}

static void MTTestDebianPackageThemeImport(void) {
    NSString *root = MTCreateTemporaryDirectory(@"deb-import");
    NSData *icon = MTPNGFixtureData(1, 1, 8, 6, 0, YES, @[], @[]);
    NSData *deb = MTDebFixtureData(MTGzipFixtureData(MTTarFixtureData(@[@{
        @"name" : @"./Library/Themes/Store.theme/IconBundles/com.example.App.png",
        @"data" : icon,
    }])));
    // A package delivered through a share sheet often loses its extension, so
    // the same bytes must import under a name that reveals nothing.
    NSArray<NSString *> *names = @[@"Store.deb", @"Store-no-extension"];
    for (NSString *name in names) {
        NSString *path = MTWriteDataFixture(root, name, deb);
        NSURL *sessionsRootURL = [NSURL fileURLWithPath:
            [root stringByAppendingPathComponent:
                [name stringByAppendingString:@"-sessions"]]
            isDirectory:YES];
        MTSafeDirectoryScanner *scanner = [[MTSafeDirectoryScanner alloc]
            initWithLimits:MTImportLimits.defaultLimits];
        NSError *error = nil;
        MTExpandedArchiveSession *session = [MTExpandedArchiveSession
            sessionByExpandingArchiveAtURL:[NSURL fileURLWithPath:path]
            format:MTExpandedArchiveFormatDebianPackage
            sessionsRootURL:sessionsRootURL
            limits:MTImportLimits.defaultLimits
            cancellationToken:nil
            auditor:^id<MTAuditedSource>(NSURL *directoryURL,
                                         NSError **auditError) {
                return [scanner scanDirectorySourceAtURL:directoryURL
                                       cancellationToken:nil
                                                   error:auditError];
            }
            error:&error];
        MTAssert(session != nil && error == nil,
            @"a Debian theme package must expand into an audited source");
        id<MTAuditedSource> themeRoot = session == nil ? nil :
            [MTThemeSourceRoot
                sourceByResolvingThemeRootInSource:session.auditedSource
                                             error:&error];
        MTIconBundlesImportResult *result = themeRoot == nil ? nil :
            [[[MTIconBundlesImporter alloc] init]
                importSourceInventory:themeRoot.inventory
                           sourceName:@"Store.theme"
                                error:&error];
        MTAssert(result != nil && result.manifest.resources.count == 1,
            @"a Debian package payload under /Library/Themes must import");
        [session discard:NULL];
    }
    [NSFileManager.defaultManager removeItemAtPath:root error:NULL];
}

static void MTTestExpandedArchiveChunkCancellation(void) {
    NSString *root = MTCreateTemporaryDirectory(
        @"expanded-archive-chunk-cancellation");
    NSData *largePayload = [NSMutableData dataWithLength:256 * 1024];
    NSData *completeTar = MTTarFixtureData(@[@{
        @"name" : @"Cancelled.theme/IconBundles/com.example.Cancel.png",
        @"data" : largePayload,
    }]);
    NSData *truncatedTar = [completeTar subdataWithRange:
        NSMakeRange(0, 512 + 64 * 1024)];
    NSString *archivePath = MTWriteDataFixture(root,
        @"Cancelled.theme.tar", truncatedTar);
    NSURL *sessionsRootURL = [NSURL fileURLWithPath:
        [root stringByAppendingPathComponent:@"sessions"]
        isDirectory:YES];
    MTThresholdCancellationToken *token =
        [[MTThresholdCancellationToken alloc] initWithThreshold:3];
    __block BOOL auditorCalled = NO;
    NSError *error = nil;
    MTExpandedArchiveSession *session = [MTExpandedArchiveSession
        sessionByExpandingArchiveAtURL:[NSURL fileURLWithPath:archivePath]
        format:MTExpandedArchiveFormatTar
        sessionsRootURL:sessionsRootURL
        limits:MTImportLimits.defaultLimits
        cancellationToken:token
        auditor:^id<MTAuditedSource>(__unused NSURL *directoryURL,
                                     __unused NSError **auditError) {
            auditorCalled = YES;
            return nil;
        }
        error:&error];
    NSArray<NSURL *> *remainingSessions = [NSFileManager.defaultManager
        contentsOfDirectoryAtURL:sessionsRootURL
        includingPropertiesForKeys:nil options:0 error:NULL];
    MTAssert(session == nil &&
             [error.domain
                 isEqualToString:MTExpandedArchiveSessionErrorDomain] &&
             error.code == 6 && token.readCount == 3 && !auditorCalled &&
             remainingSessions.count == 0,
        @"tar expansion must observe cancellation inside a file data loop before a truncated stream is decoded and must clean its private session");
    [NSFileManager.defaultManager removeItemAtPath:root error:NULL];
}

// A theme downloaded from the wild is rarely a clean tree: it is wrapped in a
// folder, carries a README and a screenshot, often ships a spare copy of
// itself as a nested archive, and may include a symlink left over from the
// filesystem it was zipped on. None of that is theme content and none of it
// is a reason to refuse the import -- the recognizable parts must come
// through and everything else must be dropped quietly.
static void MTTestPermissiveRealWorldArchiveImport(void) {
    NSString *root = MTCreateTemporaryDirectory(@"permissive-import");
    NSData *icon = MTPNGFixtureData(180, 180, 8, 6, 0, YES, @[], @[]);
    const unsigned char gzipBytes[] = {0x1f, 0x8b, 0x08, 0x00, 0x09, 0x09};
    NSString *archivePath = MTWriteZIPFixture(root, @"wild.zip", @[
        @{ @"name" : @"Wild Pack/Wild.theme/IconBundles/com.example.App.png",
           @"data" : icon },
        @{ @"name" : @"Wild Pack/Wild.theme/IconBundles/com.example.Other.png",
           @"data" : icon, @"method" : @0 },
        @{ @"name" : @"Wild Pack/README.md",
           @"data" : [@"# notes" dataUsingEncoding:NSUTF8StringEncoding] },
        @{ @"name" : @"Wild Pack/preview.jpg",
           @"data" : [@"jpeg bytes" dataUsingEncoding:NSUTF8StringEncoding] },
        @{ @"name" : @"Wild Pack/spare-copy.zip",
           @"data" : [@"PK\x03\x04spare" dataUsingEncoding:NSUTF8StringEncoding] },
        @{ @"name" : @"Wild Pack/opaque.bin",
           @"data" : [NSData dataWithBytes:gzipBytes length:sizeof(gzipBytes)] },
        @{ @"name" : @"Wild Pack/dangling",
           @"data" : [@"../../elsewhere" dataUsingEncoding:NSUTF8StringEncoding],
           @"mode" : @(S_IFLNK | 0777) },
        @{ @"name" : @"Wild Pack/Wild.theme/odd-mode.png",
           @"data" : icon, @"mode" : @(S_IFREG | 04755) },
        @{ @"name" : @"__MACOSX/._Wild.theme",
           @"data" : [@"apple double" dataUsingEncoding:NSUTF8StringEncoding] },
        @{ @"name" : @".DS_Store",
           @"data" : [@"finder" dataUsingEncoding:NSUTF8StringEncoding] },
    ]);
    MTThemeImportConfiguration *configuration =
        MTWorkflowFixtureConfiguration(root);
    MTThemeImportPipeline *pipeline = [[MTThemeImportPipeline alloc]
        initWithConfiguration:configuration];
    NSError *error = nil;
    MTPreparedThemeImport *prepared = [pipeline
        prepareZIPThemeAtURL:[NSURL fileURLWithPath:archivePath]
                  sourceName:@"Wild.theme"
           cancellationToken:nil
             progressHandler:nil
                       error:&error];
    MTAssert(prepared != nil && error == nil && prepared.isActive,
        @"a messy real-world archive must still reach an active import");
    MTAssert(prepared.manifest.resources.count >= 2,
        @"the recognizable icons of a messy archive must be imported");
    MTThemeLibraryRevision *revision = [pipeline
        commitPreparedImport:prepared cancellationToken:nil
             progressHandler:nil error:&error];
    MTAssert(revision != nil && error == nil,
        @"a messy real-world archive must commit into the Library");
    [NSFileManager.defaultManager removeItemAtPath:root error:NULL];
}

static void MTTestThemeImportWorkflow(void) {
    NSString *root = MTCreateTemporaryDirectory(@"theme-import-workflow");
    NSString *archivePath = MTWorkflowValidArchive(root,
                                                    @"Workflow.theme.zip");
    MTThemeImportConfiguration *configuration =
        MTWorkflowFixtureConfiguration(root);
    NSError *error = nil;
    MTAssert([MTThemeImportPipeline
        recoverAbandonedStateWithConfiguration:configuration error:&error] &&
        error == nil,
        @"workflow startup recovery must tolerate completely absent private roots");
    MTThemeImportPipeline *pipeline = [[MTThemeImportPipeline alloc]
        initWithConfiguration:configuration];
    error = nil;
    MTPreparedThemeImport *invalidArchiveRequest = [pipeline
        prepareArchiveThemeAtURL:(NSURL *)(id)@"not-a-file-url"
        sourceName:@"Invalid.theme" cancellationToken:nil
        progressHandler:nil error:&error];
    MTAssert(invalidArchiveRequest == nil &&
             [error.domain isEqualToString:MTThemeImportErrorDomain] &&
             error.code == MTThemeImportErrorInvalidRequest,
        @"the generic archive entry point must validate object type before reading URL properties");
    error = nil;
    NSMutableArray<NSString *> *progress = [NSMutableArray array];
    MTPreparedThemeImport *prepared = [pipeline
        prepareZIPThemeAtURL:[NSURL fileURLWithPath:archivePath]
                  sourceName:@"Workflow.theme"
           cancellationToken:nil
             progressHandler:^(MTThemeImportStage stage,
                               NSUInteger completed,
                               NSUInteger total) {
        [progress addObject:[NSString stringWithFormat:@"%lu:%lu:%lu",
            (unsigned long)stage, (unsigned long)completed,
            (unsigned long)total]];
    }
                       error:&error];
    NSData *firstPNG = MTPNGFixtureData(180, 180, 8, 6, 0, YES, @[], @[]);
    NSData *secondPNG = MTPNGFixtureData(240, 240, 8, 6, 0, YES, @[], @[]);
    uint64_t expectedBytes = firstPNG.length + secondPNG.length;
    NSString *importSessionsPath = configuration.importSessionsRootURL.path;
    NSString *assetSessionsPath = configuration.assetSessionsRootURL.path;
    NSString *currentBeforeCommit = [configuration.libraryRootURL.path
        stringByAppendingPathComponent:@"themes"];
    MTAssert(prepared != nil && error == nil && prepared.isActive,
        @"a valid ZIP must reach an active Import Review transaction");
    MTAssert([prepared.manifest.displayName isEqualToString:@"Workflow Theme"] &&
             [prepared.manifest.themeVersion isEqualToString:@"7.2"] &&
             prepared.manifest.importerVersion == 106 &&
             prepared.manifest.resources.count == 5 &&
             prepared.recognizedFileCount == 5 &&
             prepared.ignoredFileCount == 2 &&
             prepared.rejectedFileCount == 0 &&
             [prepared.manifest.capabilities
                 containsObject:MTUIResourcesModuleID],
        @"Import Review must preserve metadata, counts, and UI resource capability");
    MTThemeResource *shareActivityResource = nil;
    for (MTThemeResource *resource in prepared.manifest.resources) {
        if ([resource.resourceKey.surface isEqualToString:@"share.activity"]) {
            shareActivityResource = resource;
            break;
        }
    }
    MTAssert(shareActivityResource != nil &&
             [shareActivityResource.resourceKey.subject
                 isEqualToString:@"UIMessageActivity"] &&
             shareActivityResource.resourceKey.scale == 3 &&
             [shareActivityResource.resourceKey.trait
                 isEqualToString:@"any"] &&
             [shareActivityResource.resourceKey.variant
                 isEqualToString:MTStaticIconSourceVariantScale] &&
             [shareActivityResource.sourceFormat
                 isEqualToString:@"snowboard.share.scale"] &&
             [shareActivityResource.relativeAssetPath
                 isEqualToString:@"ShareSheet/UIMessageActivity@3x.png"],
        @"Share activity resources must keep their useful filename and source semantics while entering the MarkTheme directory standard");
    MTAssert(prepared.sourceFileCount == 7 &&
             prepared.uniqueAssetCount == 2 &&
             prepared.assetByteCount == expectedBytes &&
             prepared.previewArtifacts.count == 2,
        @"duplicate resource bytes must stage and preview once by digest");
    MTAssert([prepared.previewArtifacts.firstObject.decodeResult.pixelFormat
                isEqualToString:
                    MTSafeImagePixelFormatRGBA8PremultipliedLast] &&
             prepared.previewArtifacts.firstObject.decodeResult
                 .thumbnailPixelData.length <= 16U * 16U * 4U,
        @"Import Review previews must use the bounded normalized pixel contract");
    MTAssert([progress containsObject:@"1:0:1"] &&
             [progress containsObject:@"1:1:1"] &&
             [progress containsObject:@"4:2:2"] &&
             [progress containsObject:@"5:2:2"],
        @"the synchronous pipeline must report deterministic stage progress");
    MTAssert(MTWorkflowDirectoryEntryCount(importSessionsPath) == 0 &&
             MTWorkflowDirectoryEntryCount(assetSessionsPath) == 1 &&
             [NSFileManager.defaultManager fileExistsAtPath:archivePath] &&
             ![NSFileManager.defaultManager fileExistsAtPath:currentBeforeCommit],
        @"Review must release the private source copy, retain one provisional asset session, preserve the user ZIP, and not commit early");

    NSString *directoryRoot = MTCreateTemporaryDirectory(
        @"theme-import-directory-workflow");
    NSString *directoryPath = MTWorkflowValidDirectory(
        directoryRoot, @"Workflow.theme");
    MTThemeImportConfiguration *directoryConfiguration =
        MTWorkflowFixtureConfiguration(directoryRoot);
    MTThemeImportPipeline *directoryPipeline = [[MTThemeImportPipeline alloc]
        initWithConfiguration:directoryConfiguration];
    error = nil;
    MTPreparedThemeImport *directoryPrepared = [directoryPipeline
        prepareDirectoryThemeAtURL:
            [NSURL fileURLWithPath:directoryPath isDirectory:YES]
        sourceName:@"Workflow.theme" cancellationToken:nil
        progressHandler:nil error:&error];
    NSString *zipManifestDigest = [prepared.manifest
        contentDigestWithError:&error];
    NSString *directoryManifestDigest = [directoryPrepared.manifest
        contentDigestWithError:&error];
    MTAssert(directoryPrepared != nil && error == nil &&
             directoryPrepared.isActive &&
             [directoryManifestDigest isEqualToString:zipManifestDigest] &&
             directoryPrepared.sourceFileCount == prepared.sourceFileCount &&
             directoryPrepared.uniqueAssetCount == prepared.uniqueAssetCount &&
             directoryPrepared.assetByteCount == prepared.assetByteCount &&
             MTWorkflowDirectoryEntryCount(
                 directoryConfiguration.importSessionsRootURL.path) == 0 &&
             MTWorkflowDirectoryEntryCount(
                 directoryConfiguration.assetSessionsRootURL.path) == 1 &&
             [NSFileManager.defaultManager fileExistsAtPath:directoryPath],
        @"owned directory snapshot and ZIP inputs must converge on one prepared manifest without retaining source sessions");
    MTThemeLibraryRevision *directoryRevision = [directoryPipeline
        commitPreparedImport:directoryPrepared cancellationToken:nil
        progressHandler:nil error:&error];
    MTAssert(directoryRevision != nil && error == nil &&
             !directoryPrepared.isActive &&
             directoryRevision.assetCount == 2 &&
             MTWorkflowDirectoryEntryCount(
                 directoryConfiguration.assetSessionsRootURL.path) == 0,
        @"directory prepare must reuse the same explicit formal Library commit boundary");
    NSURL *resourcesURL = directoryRevision.resourcesDirectoryURL;
    BOOL standardTreeValid = resourcesURL != nil;
    for (MTThemeResource *resource in directoryRevision.manifest.resources) {
        NSData *data = [NSData dataWithContentsOfURL:[resourcesURL
            URLByAppendingPathComponent:resource.relativeAssetPath
                             isDirectory:NO]];
        standardTreeValid = standardTreeValid && data != nil &&
            [MTSHA256HexDigestForData(data)
                isEqualToString:resource.contentSHA256];
    }
    MTAssert(standardTreeValid &&
             [NSFileManager.defaultManager fileExistsAtPath:[resourcesURL.path
                 stringByAppendingPathComponent:
                     @"IconBundles/com.example.Primary@3x.png"]] &&
             [NSFileManager.defaultManager fileExistsAtPath:[resourcesURL.path
                 stringByAppendingPathComponent:@"Settings/WiFi@3x.png"]] &&
             [NSFileManager.defaultManager fileExistsAtPath:[resourcesURL.path
                 stringByAppendingPathComponent:
                     @"ShareSheet/UIMessageActivity@3x.png"]],
        @"a committed revision must contain an exact, readable MarkTheme resources tree in addition to digest objects");
    MTStaticIconCompiler *generationCompiler =
        MTStaticIconCompiler.defaultCompiler;
    MTCompiledGeneration *directoryGeneration = [generationCompiler
        compileLibraryRevision:directoryRevision
        cancellationToken:nil
        error:&error];
    MTAssert(directoryGeneration != nil && error == nil &&
             directoryGeneration.index.recordCount == 5 &&
             directoryGeneration.descriptor.assetCount == 2 &&
             directoryGeneration.descriptor.assetByteCount == expectedBytes &&
             [directoryGeneration.descriptor.moduleIDs
                 containsObject:MTUIResourcesModuleID],
        @"a mixed icon/UI Directory revision must compile into generation v1 contracts");
    NSData *directoryGenerationIndex =
        [directoryGeneration.index.encodedData copy];
    NSData *directoryGenerationDescriptor =
        [directoryGeneration.descriptor.canonicalData copy];
    NSOperationQueue *directoryCallbacks = [[NSOperationQueue alloc] init];
    directoryCallbacks.maxConcurrentOperationCount = 1;
    MTImportCoordinator *directoryCoordinator = [[MTImportCoordinator alloc]
        initWithPipeline:[[MTThemeImportPipeline alloc]
            initWithConfiguration:directoryConfiguration]
        callbackQueue:directoryCallbacks];
    dispatch_semaphore_t directoryReady = dispatch_semaphore_create(0);
    dispatch_semaphore_t directoryCancelled = dispatch_semaphore_create(0);
    directoryCoordinator.stateDidChangeHandler =
        ^(MTImportWorkflowSnapshot *snapshot) {
        if (snapshot.phase == MTImportWorkflowPhaseReadyForReview) {
            dispatch_semaphore_signal(directoryReady);
        } else if (snapshot.phase == MTImportWorkflowPhaseCancelled) {
            dispatch_semaphore_signal(directoryCancelled);
        }
    };
    error = nil;
    MTAssert([directoryCoordinator startDirectoryImportAtURL:
        [NSURL fileURLWithPath:directoryPath isDirectory:YES]
        sourceName:@"Workflow.theme" error:&error] && error == nil &&
             directoryCoordinator.snapshot.canChooseSource == NO,
        @"the shared coordinator must accept a directory workflow through the non-UI API");
    MTAssert(dispatch_semaphore_wait(directoryReady,
        dispatch_time(DISPATCH_TIME_NOW, 15LL * NSEC_PER_SEC)) == 0 &&
             directoryCoordinator.snapshot.canConfirm,
        @"the directory coordinator must reach the same review state as ZIP");
    [directoryCoordinator cancel];
    MTAssert(dispatch_semaphore_wait(directoryCancelled,
        dispatch_time(DISPATCH_TIME_NOW, 15LL * NSEC_PER_SEC)) == 0,
        @"directory review cancellation must publish the common Cancelled state");
    [directoryCoordinator.workerQueue waitUntilAllOperationsAreFinished];
    [directoryCallbacks waitUntilAllOperationsAreFinished];
    directoryCoordinator.stateDidChangeHandler = nil;
    MTAssert(MTWorkflowDirectoryEntryCount(
                 directoryConfiguration.importSessionsRootURL.path) == 0 &&
             MTWorkflowDirectoryEntryCount(
                 directoryConfiguration.assetSessionsRootURL.path) == 0,
        @"directory coordinator cancellation must leave no snapshot or provisional assets");
    [NSFileManager.defaultManager removeItemAtPath:directoryRoot error:NULL];

    NSData *archiveContainerInfo = MTPropertyListFixtureData(@{
        @"CFBundleDisplayName" : @"Archive Container Theme",
    }, NSPropertyListBinaryFormat_v1_0);
    NSData *archiveContainerTar = MTTarFixtureData(@[
        @{ @"name" : @"./IconBundles/", @"directory" : @YES },
        @{ @"name" : @"./Info.plist", @"data" : archiveContainerInfo },
        @{ @"name" : @"./IconBundles/com.example.Root.png",
           @"data" : firstPNG },
        @{ @"name" : @"./Package.theme/", @"directory" : @YES },
        @{ @"name" : @"./Package.theme/IconBundles/",
           @"directory" : @YES },
        @{ @"name" : @"./Package.theme/Info.plist",
           @"data" : archiveContainerInfo },
        @{ @"name" : @"./Package.theme/IconBundles/com.example.Tar.png",
           @"data" : firstPNG },
        @{ @"name" : @"./Elsewhere/Different.theme/",
           @"directory" : @YES },
        @{ @"name" : @"./Elsewhere/Different.theme/IconBundles/",
           @"directory" : @YES },
        @{ @"name" :
               @"./Elsewhere/Different.theme/IconBundles/com.example.Deb.png",
           @"data" : firstPNG },
    ]);
    NSData *archiveContainerGzip = MTGzipFixtureData(archiveContainerTar);
    NSArray<NSDictionary<NSString *, id> *> *containerFixtures = @[
        @{ @"name" : @"Container.theme.tar.gz",
           @"data" : archiveContainerGzip },
        @{ @"name" : @"Container.theme.deb",
           @"data" : MTDebFixtureData(archiveContainerGzip) },
    ];
    for (NSDictionary<NSString *, id> *fixture in containerFixtures) {
        NSString *containerRoot = MTCreateTemporaryDirectory(
            @"theme-import-container-workflow");
        NSString *containerPath = MTWriteDataFixture(containerRoot,
            fixture[@"name"], fixture[@"data"]);
        MTThemeImportConfiguration *containerConfiguration =
            MTWorkflowFixtureConfiguration(containerRoot);
        MTThemeImportPipeline *containerPipeline =
            [[MTThemeImportPipeline alloc]
                initWithConfiguration:containerConfiguration];
        error = nil;
        MTPreparedThemeImport *containerPrepared = [containerPipeline
            prepareArchiveThemeAtURL:[NSURL fileURLWithPath:containerPath]
            sourceName:@"Container.theme"
            cancellationToken:nil progressHandler:nil error:&error];
        BOOL hasDifferentComponent = NO;
        BOOL hasPackageComponent = NO;
        BOOL hasRootResource = NO;
        for (MTThemeResource *resource in containerPrepared.manifest.resources) {
            hasDifferentComponent = hasDifferentComponent ||
                [resource.relativeAssetPath hasPrefix:
                    @"Components/Different.theme/"];
            hasPackageComponent = hasPackageComponent ||
                [resource.relativeAssetPath hasPrefix:
                    @"Components/Package.theme/"];
            hasRootResource = hasRootResource ||
                [resource.relativeAssetPath isEqualToString:
                    @"IconBundles/com.example.Root.png"];
        }
        NSString *containerMessage = [NSString stringWithFormat:
            @"tar/gzip and Debian data.tar inputs must retain a root theme and merge every .theme directory through one audited theme workflow (prepared=%@ error=%@ source=%lu recognized=%lu ignored=%lu rejected=%lu resources=%lu unique=%lu root=%d package=%d different=%d)",
            containerPrepared == nil ? @"no" : @"yes",
            error.localizedDescription ?: @"none",
            (unsigned long)containerPrepared.sourceFileCount,
            (unsigned long)containerPrepared.recognizedFileCount,
            (unsigned long)containerPrepared.ignoredFileCount,
            (unsigned long)containerPrepared.rejectedFileCount,
            (unsigned long)containerPrepared.manifest.resources.count,
            (unsigned long)containerPrepared.uniqueAssetCount,
            hasRootResource, hasPackageComponent, hasDifferentComponent];
        MTAssert(containerPrepared != nil && error == nil &&
                 [containerPrepared.manifest.displayName
                     isEqualToString:@"Archive Container Theme"] &&
                 containerPrepared.sourceFileCount == 5 &&
                 containerPrepared.recognizedFileCount == 3 &&
                 containerPrepared.ignoredFileCount == 2 &&
                 containerPrepared.rejectedFileCount == 0 &&
                 containerPrepared.manifest.resources.count == 3 &&
                 containerPrepared.uniqueAssetCount == 1 &&
                 hasDifferentComponent && hasPackageComponent &&
                 hasRootResource &&
                 MTWorkflowDirectoryEntryCount(
                     containerConfiguration.importSessionsRootURL.path) == 0 &&
                 [NSFileManager.defaultManager
                     fileExistsAtPath:containerPath],
            containerMessage);
        MTThemeLibraryRevision *containerRevision = [containerPipeline
            commitPreparedImport:containerPrepared cancellationToken:nil
            progressHandler:nil error:&error];
        MTAssert(containerRevision != nil && error == nil &&
                 containerRevision.assetCount == 1 &&
                 containerRevision.manifest.resources.count == 3,
            @"non-ZIP archive inputs must reach the same formal Library commit boundary");
        [NSFileManager.defaultManager removeItemAtPath:containerRoot
                                                 error:NULL];
    }

    NSString *uiOnlyRoot = MTCreateTemporaryDirectory(
        @"theme-import-ui-only-workflow");
    NSString *uiOnlyThemePath = [uiOnlyRoot
        stringByAppendingPathComponent:@"UIOnly.theme"];
    NSString *uiOnlySettingsPath = [uiOnlyThemePath
        stringByAppendingPathComponent:@"Bundles/com.apple.Preferences"];
    MTAssert([NSFileManager.defaultManager
        createDirectoryAtPath:uiOnlySettingsPath
        withIntermediateDirectories:YES
        attributes:@{NSFilePosixPermissions : @0700}
        error:&error] &&
        [firstPNG writeToFile:[uiOnlySettingsPath
            stringByAppendingPathComponent:@"WiFi@3x.png"]
            options:0 error:&error],
        @"UI-only theme fixture must create one Settings resource");
    MTThemeImportConfiguration *uiOnlyConfiguration =
        MTWorkflowFixtureConfiguration(uiOnlyRoot);
    MTThemeImportPipeline *uiOnlyPipeline = [[MTThemeImportPipeline alloc]
        initWithConfiguration:uiOnlyConfiguration];
    MTPreparedThemeImport *uiOnlyPrepared = [uiOnlyPipeline
        prepareDirectoryThemeAtURL:
            [NSURL fileURLWithPath:uiOnlyThemePath isDirectory:YES]
        sourceName:@"UIOnly.theme"
        cancellationToken:nil
        progressHandler:nil
        error:&error];
    MTThemeLibraryRevision *uiOnlyRevision = [uiOnlyPipeline
        commitPreparedImport:uiOnlyPrepared
        cancellationToken:nil
        progressHandler:nil
        error:&error];
    MTCompiledGeneration *uiOnlyGeneration = [generationCompiler
        compileLibraryRevision:uiOnlyRevision
        cancellationToken:nil
        error:&error];
    MTAssert(uiOnlyPrepared != nil && uiOnlyRevision != nil &&
             uiOnlyGeneration != nil && error == nil &&
             [uiOnlyRevision.manifest.capabilities
                 isEqualToArray:@[MTUIResourcesModuleID]] &&
             uiOnlyGeneration.index.recordCount == 1 &&
             [uiOnlyGeneration.descriptor.moduleIDs
                 isEqualToArray:@[MTUIResourcesModuleID]],
        @"a Settings-only theme must compile without a synthetic static-icon dependency");
    [NSFileManager.defaultManager removeItemAtPath:uiOnlyRoot error:NULL];

    NSString *wrappedUIRoot = MTCreateTemporaryDirectory(
        @"theme-import-wrapped-ui-only-workflow");
    NSData *wrappedUIMetadata = MTPropertyListFixtureData(@{
        @"CFBundleDisplayName" : @"Wrapped UI Theme",
    }, NSPropertyListBinaryFormat_v1_0);
    NSString *wrappedUIArchive = MTWriteZIPFixture(
        wrappedUIRoot, @"WrappedUI.theme.zip", @[
        @{@"name" : @"WrappedUI.theme/", @"flags" : @0,
          @"mode" : @(S_IFDIR | 0755)},
        @{@"name" : @"WrappedUI.theme/Bundles/", @"flags" : @0,
          @"mode" : @(S_IFDIR | 0755)},
        @{@"name" : @"WrappedUI.theme/Bundles/com.apple.Preferences/",
          @"flags" : @0, @"mode" : @(S_IFDIR | 0755)},
        @{@"name" : @"WrappedUI.theme/Info.plist", @"flags" : @0,
          @"data" : wrappedUIMetadata},
        @{@"name" : @"WrappedUI.theme/Bundles/com.apple.Preferences/WiFi@3x.png",
          @"flags" : @0, @"data" : firstPNG, @"method" : @8},
    ]);
    MTThemeImportConfiguration *wrappedUIConfiguration =
        MTWorkflowFixtureConfiguration(wrappedUIRoot);
    MTThemeImportPipeline *wrappedUIPipeline = [[MTThemeImportPipeline alloc]
        initWithConfiguration:wrappedUIConfiguration];
    error = nil;
    MTPreparedThemeImport *wrappedUIPrepared = [wrappedUIPipeline
        prepareZIPThemeAtURL:[NSURL fileURLWithPath:wrappedUIArchive]
        sourceName:@"WrappedUI.theme"
        cancellationToken:nil
        progressHandler:nil
        error:&error];
    MTThemeLibraryRevision *wrappedUIRevision = [wrappedUIPipeline
        commitPreparedImport:wrappedUIPrepared
        cancellationToken:nil
        progressHandler:nil
        error:&error];
    MTCompiledGeneration *wrappedUIGeneration = [generationCompiler
        compileLibraryRevision:wrappedUIRevision
        cancellationToken:nil
        error:&error];
    MTAssert(wrappedUIPrepared != nil && wrappedUIRevision != nil &&
             wrappedUIGeneration != nil && error == nil &&
             [wrappedUIPrepared.manifest.displayName
                 isEqualToString:@"Wrapped UI Theme"] &&
             wrappedUIPrepared.recognizedFileCount == 1 &&
             wrappedUIPrepared.rejectedFileCount == 0 &&
             [wrappedUIRevision.manifest.capabilities
                 isEqualToArray:@[MTUIResourcesModuleID]] &&
             wrappedUIGeneration.index.recordCount == 1 &&
             [wrappedUIGeneration.descriptor.moduleIDs
                 isEqualToArray:@[MTUIResourcesModuleID]],
        @"a wrapped Settings-only ZIP must resolve Bundles as its logical theme root");
    [NSFileManager.defaultManager removeItemAtPath:wrappedUIRoot error:NULL];

    MTThemeLibraryRevision *revision = [pipeline
        commitPreparedImport:prepared
           cancellationToken:nil
             progressHandler:nil
                       error:&error];
    MTAssert(revision != nil && error == nil && !prepared.isActive &&
             revision.assetCount == 2 &&
             revision.assetByteCount == expectedBytes &&
             revision.manifest.resources.count == 5 &&
             MTWorkflowDirectoryEntryCount(assetSessionsPath) == 0,
        @"explicit confirmation must commit the exact unique assets and consume provisional ownership");
    MTCompiledGeneration *compiledGeneration = [generationCompiler
        compileLibraryRevision:revision
        cancellationToken:nil
        error:&error];
    MTAssert(compiledGeneration != nil && error == nil &&
             [compiledGeneration.index.encodedData
                isEqualToData:directoryGenerationIndex] &&
             [compiledGeneration.descriptor.canonicalData
                isEqualToData:directoryGenerationDescriptor] &&
             [compiledGeneration.descriptor.manifestDigest
                isEqualToString:revision.manifestDigest] &&
             [compiledGeneration.descriptor.libraryRevisionIdentifier
                isEqualToString:revision.revisionIdentifier],
        @"equivalent Directory and ZIP revisions must compile byte-identical generations");
    MTAssertionCount += MTRunGenerationWriterTests(compiledGeneration);
    MTAssertionCount += MTRunGenerationReaderTests(compiledGeneration);
    MTAssertionCount += MTRunRuntimeStoreTests(compiledGeneration);
    MTAssertionCount += MTRunRuntimeWeakObjectMapSnapshotTests();
    MTAssertionCount += MTRunRuntimeKernelTests();
    MTAssertionCount += MTRunRuntimeProfileTests();
    MTAssertionCount += MTRunIconServiceRuntimeTests();
    MTAssertionCount += MTRunRuntimeReplacementTests();
    MTAssertionCount += MTRunRuntimeSnapshotResourceTests();
    MTThemeLibraryStore *applyLibraryStore = [[MTThemeLibraryStore alloc]
        initWithRootURL:pipeline.configuration.libraryRootURL];
    MTAssertionCount += MTRunThemeApplyServiceTests(
        applyLibraryStore, revision, compiledGeneration);
    for (MTThemeResource *resource in revision.manifest.resources) {
        error = nil;
        MTGenerationIndexRecord *record = [compiledGeneration.index
            recordForCanonicalResourceKey:resource.resourceKey.canonicalString
            error:&error];
        MTAssert(record != nil && error == nil &&
                 [record.contentSHA256
                    isEqualToString:resource.contentSHA256] &&
                 record.assetByteCount ==
                    [revision.assetByteCountsByContentSHA256[
                        resource.contentSHA256] unsignedLongLongValue],
            @"compiled generation lookup must resolve every manifest resource exactly");
    }
    MTImportCancellationToken *compileCancellation =
        [[MTImportCancellationToken alloc] init];
    [compileCancellation cancel];
    error = nil;
    MTAssert([generationCompiler compileLibraryRevision:revision
            cancellationToken:compileCancellation error:&error] == nil &&
             [error.domain isEqualToString:
                MTStaticIconCompilerErrorDomain] &&
             error.code == MTStaticIconCompilerErrorCancelled,
        @"generation compilation must honor pre-cancellation without output");
    error = nil;
    MTAssert([prepared discard:&error] && error == nil,
        @"discard after a committed review must be harmless");
    error = nil;
    MTAssert([pipeline commitPreparedImport:prepared
            cancellationToken:nil progressHandler:nil error:&error] == nil &&
             [error.domain isEqualToString:MTThemeImportErrorDomain] &&
             error.code == MTThemeImportErrorInvalidState,
        @"a reviewed import must not commit twice");

    NSString *cancelRoot = MTCreateTemporaryDirectory(@"workflow-cancel");
    NSString *cancelArchive = MTWorkflowValidArchive(cancelRoot,
                                                      @"Cancel.theme.zip");
    MTThemeImportConfiguration *cancelConfiguration =
        MTWorkflowFixtureConfiguration(cancelRoot);
    MTThemeImportPipeline *cancelPipeline = [[MTThemeImportPipeline alloc]
        initWithConfiguration:cancelConfiguration];
    MTImportCancellationToken *cancellationToken =
        [[MTImportCancellationToken alloc] init];
    error = nil;
    MTPreparedThemeImport *cancelled = [cancelPipeline
        prepareZIPThemeAtURL:[NSURL fileURLWithPath:cancelArchive]
                  sourceName:@"Cancel.theme"
           cancellationToken:cancellationToken
             progressHandler:^(MTThemeImportStage stage,
                               NSUInteger completed,
                               __unused NSUInteger total) {
        if (stage == MTThemeImportStageStaging && completed == 1) {
            [cancellationToken cancel];
        }
    }
                       error:&error];
    MTAssert(cancelled == nil &&
             [error.domain isEqualToString:MTThemeImportErrorDomain] &&
             error.code == MTThemeImportErrorCancelled &&
             MTWorkflowDirectoryEntryCount(
                 cancelConfiguration.importSessionsRootURL.path) == 0 &&
             MTWorkflowDirectoryEntryCount(
                 cancelConfiguration.assetSessionsRootURL.path) == 0 &&
             [NSFileManager.defaultManager fileExistsAtPath:cancelArchive],
        @"mid-stage cancellation must clean both private transactions and preserve the selected ZIP");

    NSString *partialRoot = MTCreateTemporaryDirectory(
        @"workflow-partial-bad-image");
    NSString *partialArchive = MTWorkflowPartiallyInvalidImageArchive(
        partialRoot, @"Partial.theme.zip");
    MTThemeImportConfiguration *partialConfiguration =
        MTWorkflowFixtureConfiguration(partialRoot);
    MTThemeImportPipeline *partialPipeline = [[MTThemeImportPipeline alloc]
        initWithConfiguration:partialConfiguration];
    error = nil;
    MTPreparedThemeImport *partialPrepared = [partialPipeline
        prepareZIPThemeAtURL:[NSURL fileURLWithPath:partialArchive]
        sourceName:@"Partial.theme" cancellationToken:nil
        progressHandler:nil error:&error];
    BOOL hasSkippedImageDiagnostic = NO;
    for (MTDiagnostic *diagnostic in partialPrepared.diagnostics) {
        hasSkippedImageDiagnostic = hasSkippedImageDiagnostic ||
            [diagnostic.code isEqualToString:
                @"import.image.invalid-resource-skipped"];
    }
    MTThemeLibraryRevision *partialRevision = [partialPipeline
        commitPreparedImport:partialPrepared cancellationToken:nil
        progressHandler:nil error:&error];
    MTAssert(partialPrepared != nil && partialRevision != nil && error == nil &&
             [partialPrepared.manifest.displayName
                 isEqualToString:@"Partially Valid Theme"] &&
             partialPrepared.manifest.resources.count == 1 &&
             partialPrepared.recognizedFileCount == 1 &&
             partialPrepared.rejectedFileCount == 1 &&
             partialPrepared.uniqueAssetCount == 1 &&
             partialRevision.assetCount == 1 &&
             hasSkippedImageDiagnostic &&
             MTWorkflowDirectoryEntryCount(
                 partialConfiguration.importSessionsRootURL.path) == 0 &&
             MTWorkflowDirectoryEntryCount(
                 partialConfiguration.assetSessionsRootURL.path) == 0,
        @"one corrupt recognized PNG must be skipped without blocking the remaining valid theme");
    [NSFileManager.defaultManager removeItemAtPath:partialRoot error:NULL];

    NSString *folderValidationRoot = MTCreateTemporaryDirectory(
        @"workflow-invalid-folder-base");
    NSString *folderValidationArchive =
        MTWorkflowInvalidFolderBaseArchive(
            folderValidationRoot, @"FolderValidation.theme.zip");
    MTThemeImportConfiguration *folderValidationConfiguration =
        MTWorkflowFixtureConfiguration(folderValidationRoot);
    MTThemeImportPipeline *folderValidationPipeline =
        [[MTThemeImportPipeline alloc]
            initWithConfiguration:folderValidationConfiguration];
    error = nil;
    MTPreparedThemeImport *folderValidationPrepared =
        [folderValidationPipeline prepareZIPThemeAtURL:
            [NSURL fileURLWithPath:folderValidationArchive]
            sourceName:@"FolderValidation.theme"
            cancellationToken:nil progressHandler:nil error:&error];
    BOOL hasInvalidFolderBaseDiagnostic = NO;
    BOOL hasDependentFolderDiagnostic = NO;
    for (MTDiagnostic *diagnostic in folderValidationPrepared.diagnostics) {
        hasInvalidFolderBaseDiagnostic = hasInvalidFolderBaseDiagnostic ||
            [diagnostic.code isEqualToString:
                @"import.image.invalid-resource-skipped"];
        hasDependentFolderDiagnostic = hasDependentFolderDiagnostic ||
            [diagnostic.code isEqualToString:
                @"import.image.dependent-resource-skipped"];
    }
    MTThemeLibraryRevision *folderValidationRevision =
        [folderValidationPipeline
            commitPreparedImport:folderValidationPrepared
            cancellationToken:nil progressHandler:nil error:&error];
    MTCompiledGeneration *folderValidationGeneration =
        [generationCompiler
            compileLibraryRevision:folderValidationRevision
            cancellationToken:nil error:&error];
    MTAssert(folderValidationPrepared != nil &&
             folderValidationRevision != nil &&
             folderValidationGeneration != nil && error == nil &&
             folderValidationPrepared.manifest.resources.count == 1 &&
             folderValidationPrepared.recognizedFileCount == 1 &&
             folderValidationPrepared.rejectedFileCount == 1 &&
             folderValidationPrepared.ignoredFileCount == 2 &&
             [folderValidationPrepared.manifest.capabilities
                 isEqualToArray:@[@"icons.static"]] &&
             [folderValidationGeneration.descriptor.moduleIDs
                 isEqualToArray:@[@"icons.static"]] &&
             hasInvalidFolderBaseDiagnostic &&
             hasDependentFolderDiagnostic,
        @"strict rejection of a Folder base must also remove its light companion while preserving unrelated applicable content");
    [NSFileManager.defaultManager
        removeItemAtPath:folderValidationRoot error:NULL];

    NSString *badRoot = MTCreateTemporaryDirectory(@"workflow-bad-image");
    NSString *badArchive = MTWorkflowInvalidImageArchive(badRoot,
                                                          @"Bad.theme.zip");
    MTThemeImportConfiguration *badConfiguration =
        MTWorkflowFixtureConfiguration(badRoot);
    error = nil;
    MTAssert([[[MTThemeImportPipeline alloc]
            initWithConfiguration:badConfiguration]
            prepareZIPThemeAtURL:[NSURL fileURLWithPath:badArchive]
                      sourceName:@"Bad.theme"
               cancellationToken:nil progressHandler:nil error:&error] == nil &&
             error.code == MTThemeImportErrorImageValidation &&
             MTWorkflowDirectoryEntryCount(
                 badConfiguration.importSessionsRootURL.path) == 0 &&
             MTWorkflowDirectoryEntryCount(
                 badConfiguration.assetSessionsRootURL.path) == 0,
        @"PNG-signature-only input must fail the strict pixel gate without residue");

    NSString *badDirectoryRoot = MTCreateTemporaryDirectory(
        @"workflow-bad-directory-image");
    NSString *badDirectory = MTWorkflowInvalidImageDirectory(
        badDirectoryRoot, @"Bad.theme");
    MTThemeImportConfiguration *badDirectoryConfiguration =
        MTWorkflowFixtureConfiguration(badDirectoryRoot);
    error = nil;
    MTAssert([[[MTThemeImportPipeline alloc]
            initWithConfiguration:badDirectoryConfiguration]
            prepareDirectoryThemeAtURL:
                [NSURL fileURLWithPath:badDirectory isDirectory:YES]
            sourceName:@"Bad.theme" cancellationToken:nil
            progressHandler:nil error:&error] == nil &&
             error.code == MTThemeImportErrorImageValidation &&
             MTWorkflowDirectoryEntryCount(
                 badDirectoryConfiguration.importSessionsRootURL.path) == 0 &&
             MTWorkflowDirectoryEntryCount(
                 badDirectoryConfiguration.assetSessionsRootURL.path) == 0 &&
             [NSFileManager.defaultManager fileExistsAtPath:badDirectory],
        @"invalid directory image input must clean both snapshot and provisional assets while preserving the external tree");
    [NSFileManager.defaultManager removeItemAtPath:badDirectoryRoot
                                             error:NULL];

    NSString *coordinatorRoot = MTCreateTemporaryDirectory(@"workflow-coordinator");
    NSString *coordinatorArchive = MTWorkflowValidArchive(
        coordinatorRoot, @"Coordinator.theme.zip");
    MTThemeImportPipeline *coordinatorPipeline = [[MTThemeImportPipeline alloc]
        initWithConfiguration:MTWorkflowFixtureConfiguration(coordinatorRoot)];
    NSOperationQueue *callbackQueue = [[NSOperationQueue alloc] init];
    callbackQueue.maxConcurrentOperationCount = 1;
    MTImportCoordinator *coordinator = [[MTImportCoordinator alloc]
        initWithPipeline:coordinatorPipeline callbackQueue:callbackQueue];
    dispatch_semaphore_t readySemaphore = dispatch_semaphore_create(0);
    dispatch_semaphore_t completedSemaphore = dispatch_semaphore_create(0);
    NSMutableArray<NSString *> *phases = [NSMutableArray array];
    coordinator.stateDidChangeHandler = ^(MTImportWorkflowSnapshot *snapshot) {
        @synchronized (phases) {
            [phases addObject:MTImportWorkflowPhaseName(snapshot.phase)];
        }
        if (snapshot.phase == MTImportWorkflowPhaseReadyForReview) {
            dispatch_semaphore_signal(readySemaphore);
        } else if (snapshot.phase == MTImportWorkflowPhaseCompleted) {
            dispatch_semaphore_signal(completedSemaphore);
        }
    };
    error = nil;
    MTAssert([coordinator confirmPreparedImport:&error] == NO &&
             [error.domain isEqualToString:MTImportCoordinatorErrorDomain],
        @"the coordinator must reject confirmation before review");
    error = nil;
    MTAssert([coordinator startZIPImportAtURL:
                [NSURL fileURLWithPath:coordinatorArchive]
                                  sourceName:@"Coordinator.theme"
                                       error:&error] && error == nil,
        @"the coordinator must accept one idle ZIP workflow");
    long readyWait = dispatch_semaphore_wait(readySemaphore,
        dispatch_time(DISPATCH_TIME_NOW, 15LL * NSEC_PER_SEC));
    MTAssert(readyWait == 0 &&
             coordinator.snapshot.phase ==
                 MTImportWorkflowPhaseReadyForReview &&
             coordinator.snapshot.canConfirm &&
             coordinator.snapshot.preparedImport.uniqueAssetCount == 2,
        @"the async coordinator must reach a real review snapshot");
    error = nil;
    MTAssert([coordinator confirmPreparedImport:&error] && error == nil,
        @"the reviewed coordinator state must allow explicit confirmation");
    long completedWait = dispatch_semaphore_wait(completedSemaphore,
        dispatch_time(DISPATCH_TIME_NOW, 15LL * NSEC_PER_SEC));
    [coordinator.workerQueue waitUntilAllOperationsAreFinished];
    [callbackQueue waitUntilAllOperationsAreFinished];
    MTAssert(completedWait == 0 &&
             coordinator.snapshot.phase == MTImportWorkflowPhaseCompleted &&
             coordinator.snapshot.libraryRevision != nil &&
             !coordinator.snapshot.canCancel,
        @"the coordinator must publish a completed immutable Library revision");
    @synchronized (phases) {
        NSArray<NSString *> *requiredPhases = @[
            @"idle", @"acquiring", @"auditing", @"parsing", @"staging",
            @"validating", @"ready-for-review", @"committing", @"completed"
        ];
        NSUInteger cursor = 0;
        for (NSString *phase in phases) {
            if (cursor < requiredPhases.count &&
                [phase isEqualToString:requiredPhases[cursor]]) {
                cursor++;
            }
        }
        MTAssert(cursor == requiredPhases.count,
            @"coordinator callbacks must preserve the user-visible phase order");
    }
    coordinator.stateDidChangeHandler = nil;

    NSString *discardRoot = MTCreateTemporaryDirectory(@"workflow-discard");
    NSString *discardArchive = MTWorkflowValidArchive(discardRoot,
                                                       @"Discard.theme.zip");
    MTThemeImportConfiguration *discardConfiguration =
        MTWorkflowFixtureConfiguration(discardRoot);
    NSOperationQueue *discardCallbacks = [[NSOperationQueue alloc] init];
    discardCallbacks.maxConcurrentOperationCount = 1;
    MTImportCoordinator *discardCoordinator = [[MTImportCoordinator alloc]
        initWithPipeline:[[MTThemeImportPipeline alloc]
            initWithConfiguration:discardConfiguration]
             callbackQueue:discardCallbacks];
    dispatch_semaphore_t discardReady = dispatch_semaphore_create(0);
    dispatch_semaphore_t discardedSemaphore = dispatch_semaphore_create(0);
    discardCoordinator.stateDidChangeHandler =
        ^(MTImportWorkflowSnapshot *snapshot) {
        if (snapshot.phase == MTImportWorkflowPhaseReadyForReview) {
            dispatch_semaphore_signal(discardReady);
        } else if (snapshot.phase == MTImportWorkflowPhaseCancelled) {
            dispatch_semaphore_signal(discardedSemaphore);
        }
    };
    error = nil;
    MTAssert([discardCoordinator startZIPImportAtURL:
                [NSURL fileURLWithPath:discardArchive]
                                         sourceName:@"Discard.theme"
                                              error:&error],
        @"the discard coordinator fixture must start");
    MTAssert(dispatch_semaphore_wait(discardReady,
        dispatch_time(DISPATCH_TIME_NOW, 15LL * NSEC_PER_SEC)) == 0,
        @"the discard coordinator fixture must reach review");
    [discardCoordinator cancel];
    MTAssert(dispatch_semaphore_wait(discardedSemaphore,
        dispatch_time(DISPATCH_TIME_NOW, 15LL * NSEC_PER_SEC)) == 0,
        @"cancelling from review must publish Cancelled after cleanup");
    [discardCoordinator.workerQueue waitUntilAllOperationsAreFinished];
    [discardCallbacks waitUntilAllOperationsAreFinished];
    MTAssert(discardCoordinator.snapshot.preparedImport == nil &&
             MTWorkflowDirectoryEntryCount(
                 discardConfiguration.assetSessionsRootURL.path) == 0 &&
             ![NSFileManager.defaultManager fileExistsAtPath:
                 [discardConfiguration.libraryRootURL.path
                    stringByAppendingPathComponent:@"themes"]],
        @"review cancellation must discard provisional assets without touching Library");
    error = nil;
    MTAssert([discardCoordinator reset:&error] &&
             discardCoordinator.snapshot.phase == MTImportWorkflowPhaseIdle,
        @"a cleaned terminal workflow must reset to Idle");
    discardCoordinator.stateDidChangeHandler = nil;

    NSURL *corruptedGenerationSource =
        revision.assetURLsByContentSHA256.allValues.firstObject;
    int corruptionDescriptor = open(
        corruptedGenerationSource.fileSystemRepresentation,
        O_WRONLY | O_CLOEXEC | O_NOFOLLOW);
    const uint8_t corruptedByte = 0xff;
    MTAssert(corruptionDescriptor >= 0 &&
             pwrite(corruptionDescriptor, &corruptedByte, 1, 16) == 1 &&
             close(corruptionDescriptor) == 0,
        @"generation compiler corruption fixture must mutate only its disposable Library");
    error = nil;
    MTAssert([generationCompiler compileLibraryRevision:revision
            cancellationToken:nil error:&error] == nil &&
             [error.domain isEqualToString:
                MTStaticIconCompilerErrorDomain] &&
             error.code == MTStaticIconCompilerErrorIntegrity,
        @"generation compiler must rehash and reject a mutated Library asset");

    [NSFileManager.defaultManager removeItemAtPath:root error:NULL];
    [NSFileManager.defaultManager removeItemAtPath:cancelRoot error:NULL];
    [NSFileManager.defaultManager removeItemAtPath:badRoot error:NULL];
    [NSFileManager.defaultManager removeItemAtPath:coordinatorRoot error:NULL];
    [NSFileManager.defaultManager removeItemAtPath:discardRoot error:NULL];
}

static void MTRealThemeReportFailure(NSString *stage, NSError *error) {
    fprintf(stderr,
        "REAL-THEME-SMOKE: FAIL stage=%s domain=%s code=%ld description=%s\n",
        stage.UTF8String ?: "unknown",
        error.domain.UTF8String ?: "unknown",
        (long)error.code,
        error.localizedDescription.UTF8String ?: "unknown");
    NSError *underlying = error.userInfo[NSUnderlyingErrorKey];
    for (NSUInteger depth = 0; underlying != nil && depth < 4; depth++) {
        fprintf(stderr,
            "UNDERLYING-%lu: domain=%s code=%ld description=%s\n",
            (unsigned long)(depth + 1),
            underlying.domain.UTF8String ?: "unknown",
            (long)underlying.code,
            underlying.localizedDescription.UTF8String ?: "unknown");
        underlying = underlying.userInfo[NSUnderlyingErrorKey];
    }
}

static int MTProcessRealThemeZIP(NSString *archivePath,
                                 NSString *destinationPath) {
    NSString *root = MTCreateTemporaryDirectory(@"real-theme-smoke");
    MTThemeImportConfiguration *configuration =
        MTWorkflowFixtureConfiguration(root);
    MTThemeImportPipeline *pipeline = [[MTThemeImportPipeline alloc]
        initWithConfiguration:configuration];
    NSString *sourceName = archivePath.lastPathComponent.stringByDeletingPathExtension;
    if (sourceName.length == 0) sourceName = @"Imported Theme";

    NSError *error = nil;
    NSTimeInterval prepareStart = NSDate.timeIntervalSinceReferenceDate;
    MTPreparedThemeImport *prepared = [pipeline
        prepareZIPThemeAtURL:[NSURL fileURLWithPath:archivePath]
                  sourceName:sourceName
           cancellationToken:nil
             progressHandler:nil
                       error:&error];
    NSTimeInterval prepareSeconds =
        NSDate.timeIntervalSinceReferenceDate - prepareStart;
    if (prepared == nil) {
        MTRealThemeReportFailure(@"prepare", error);
        [NSFileManager.defaultManager removeItemAtPath:root error:NULL];
        return 1;
    }

    NSTimeInterval commitStart = NSDate.timeIntervalSinceReferenceDate;
    MTThemeLibraryRevision *revision = [pipeline
        commitPreparedImport:prepared
           cancellationToken:nil
             progressHandler:nil
                       error:&error];
    NSTimeInterval commitSeconds =
        NSDate.timeIntervalSinceReferenceDate - commitStart;
    if (revision == nil) {
        MTRealThemeReportFailure(@"commit", error);
        [prepared discard:NULL];
        [NSFileManager.defaultManager removeItemAtPath:root error:NULL];
        return 1;
    }

    NSTimeInterval compileStart = NSDate.timeIntervalSinceReferenceDate;
    MTCompiledGeneration *generation = [MTStaticIconCompiler.defaultCompiler
        compileLibraryRevision:revision cancellationToken:nil error:&error];
    NSTimeInterval compileSeconds =
        NSDate.timeIntervalSinceReferenceDate - compileStart;
    if (generation == nil) {
        MTRealThemeReportFailure(@"compile", error);
        [NSFileManager.defaultManager removeItemAtPath:root error:NULL];
        return 1;
    }

    MTGenerationWriteResult *writeResult = nil;
    MTGeneration *validatedGeneration = nil;
    NSUInteger runtimeDecodeAttempts = 0;
    NSUInteger runtimeDecodeSuccesses = 0;
    NSUInteger runtimeDecodeUniqueAssets = 0;
    NSMutableSet<NSString *> *clockVariants = [NSMutableSet set];
    NSTimeInterval writeSeconds = 0;
    if (destinationPath != nil) {
        struct stat destinationStatus = {0};
        if (lstat(destinationPath.fileSystemRepresentation,
                  &destinationStatus) == 0 || errno != ENOENT) {
            fprintf(stderr,
                "REAL-THEME-SMOKE: FAIL stage=write description="
                "destination must not already exist\n");
            [NSFileManager.defaultManager removeItemAtPath:root error:NULL];
            return 1;
        }
        NSURL *destinationURL = [NSURL fileURLWithPath:
            destinationPath.stringByStandardizingPath isDirectory:YES];
        MTGenerationWriterConfiguration *writerConfiguration =
            [[MTGenerationWriterConfiguration alloc]
                initWithRootURL:destinationURL
                maximumAssetCount:20000
                maximumGenerationByteCount:1024ULL * 1024ULL * 1024ULL
                minimumFreeSpaceReserveBytes:0
                maximumRecoveryNodeCount:25000];
        NSTimeInterval writeStart = NSDate.timeIntervalSinceReferenceDate;
        writeResult = [[[MTGenerationWriter alloc]
            initWithConfiguration:writerConfiguration]
            writeCompiledGeneration:generation
            cancellationToken:nil
            error:&error];
        writeSeconds = NSDate.timeIntervalSinceReferenceDate - writeStart;
        MTGenerationReaderConfiguration *readerConfiguration =
            [[MTGenerationReaderConfiguration alloc]
                initWithRootURL:destinationURL
                maximumAssetCount:20000
                maximumGenerationByteCount:1024ULL * 1024ULL * 1024ULL
                ownershipProfile:MTGenerationReaderOwnershipProfilePrivate];
        validatedGeneration = writeResult == nil ? nil :
            [[[MTGenerationReader alloc]
                initWithConfiguration:readerConfiguration]
                readGenerationWithIdentifier:writeResult.generationIdentifier
                cancellationToken:nil
                error:&error];
        if (validatedGeneration == nil ||
            writeResult.reusedExistingGeneration ||
            ![validatedGeneration.generationIdentifier
                isEqualToString:generation.descriptor.generationIdentifier] ||
            validatedGeneration.index.recordCount !=
                generation.index.recordCount ||
            validatedGeneration.descriptor.assetCount !=
                generation.descriptor.assetCount ||
            validatedGeneration.descriptor.assetByteCount !=
                generation.descriptor.assetByteCount) {
            MTRealThemeReportFailure(@"write", error);
            [NSFileManager.defaultManager removeItemAtPath:root error:NULL];
            return 1;
        }

        NSMutableSet<NSString *> *attemptedDigests = [NSMutableSet set];
        NSMutableSet<NSString *> *decodedDigests = [NSMutableSet set];
        MTRuntimePublishedImageLoader *loader =
            MTRuntimePublishedImageLoader.staticIconLoader;
        for (NSUInteger index = 0;
             index < validatedGeneration.index.recordCount &&
                 runtimeDecodeSuccesses < 16;
             index++) {
            @autoreleasepool {
                MTGenerationIndexRecord *record =
                    [validatedGeneration.index recordAtIndex:index];
                if (record == nil ||
                    [attemptedDigests containsObject:record.contentSHA256]) {
                    continue;
                }
                [attemptedDigests addObject:record.contentSHA256];
                runtimeDecodeAttempts++;
                NSError *decodeError = nil;
                MTGenerationResource *resource = [validatedGeneration
                    resourceForCanonicalResourceKey:
                        record.canonicalResourceKey
                    error:&decodeError];
                MTRuntimeDecodedImage *decoded = resource == nil ? nil :
                    [loader loadImageForGeneration:validatedGeneration
                                          resource:resource
                                  targetPixelWidth:180
                                 targetPixelHeight:180
                                             error:&decodeError];
                if (decoded != nil) {
                    runtimeDecodeSuccesses++;
                    [decodedDigests addObject:record.contentSHA256];
                }
            }
        }
        for (NSString *variant in MTClockIconResourceVariants()) {
            NSError *clockError = nil;
            MTResourceKey *clockKey = [[MTResourceKey alloc]
                initWithModuleID:MTClockIconsModuleID
                         surface:@"springboard.home"
                         subject:MTClockIconTargetBundleIdentifier
                         variant:variant
                           scale:0
                           trait:@"any"
                           error:&clockError];
            MTGenerationResource *resource = clockKey == nil ? nil :
                [validatedGeneration resourceForCanonicalResourceKey:
                    clockKey.canonicalString error:&clockError];
            MTRuntimeDecodedImage *decoded = resource == nil ? nil :
                [loader loadImageForGeneration:validatedGeneration
                                      resource:resource
                              targetPixelWidth:180
                             targetPixelHeight:180
                                         error:&clockError];
            if (decoded != nil) [clockVariants addObject:variant];
        }
        runtimeDecodeUniqueAssets = decodedDigests.count;
        NSUInteger requiredSamples = MIN((NSUInteger)8,
            MIN(validatedGeneration.index.recordCount,
                validatedGeneration.descriptor.assetCount));
        if (runtimeDecodeSuccesses < requiredSamples ||
            runtimeDecodeUniqueAssets < requiredSamples) {
            fprintf(stderr,
                "REAL-THEME-SMOKE: FAIL stage=runtime-decode "
                "attempts=%lu successes=%lu unique-assets=%lu\n",
                (unsigned long)runtimeDecodeAttempts,
                (unsigned long)runtimeDecodeSuccesses,
                (unsigned long)runtimeDecodeUniqueAssets);
            [NSFileManager.defaultManager
                removeItemAtPath:destinationPath error:NULL];
            [NSFileManager.defaultManager removeItemAtPath:root error:NULL];
            return 1;
        }
        BOOL clockDeclared = [validatedGeneration.descriptor.moduleIDs
            containsObject:MTClockIconsModuleID];
        if (clockDeclared &&
            ![clockVariants containsObject:@"background"]) {
            fprintf(stderr,
                "REAL-THEME-SMOKE: FAIL stage=clock-runtime-decode "
                "variants=%s\n",
                [[clockVariants.allObjects
                    sortedArrayUsingSelector:@selector(compare:)]
                    componentsJoinedByString:@","].UTF8String);
            [NSFileManager.defaultManager
                removeItemAtPath:destinationPath error:NULL];
            [NSFileManager.defaultManager removeItemAtPath:root error:NULL];
            return 1;
        }
    }

    NSUInteger informationCount = 0;
    NSUInteger warningCount = 0;
    NSUInteger errorCount = 0;
    NSMutableDictionary<NSString *, NSNumber *> *diagnosticCounts =
        [NSMutableDictionary dictionary];
    for (MTDiagnostic *diagnostic in prepared.diagnostics) {
        if (diagnostic.severity == MTDiagnosticSeverityInformation) {
            informationCount++;
        } else if (diagnostic.severity == MTDiagnosticSeverityWarning) {
            warningCount++;
        } else {
            errorCount++;
        }
        diagnosticCounts[diagnostic.code] =
            @([diagnosticCounts[diagnostic.code] unsignedIntegerValue] + 1);
    }

    printf("REAL-THEME-SMOKE: PASS\n");
    printf("DISPLAY-NAME: %s\n", prepared.manifest.displayName.UTF8String);
    printf("THEME-ID: %s\n", prepared.manifest.themeID.UTF8String);
    printf("SOURCE-FILES: %lu\n", (unsigned long)prepared.sourceFileCount);
    printf("RECOGNIZED-FILES: %lu\n",
        (unsigned long)prepared.recognizedFileCount);
    printf("IGNORED-FILES: %lu\n", (unsigned long)prepared.ignoredFileCount);
    printf("REJECTED-FILES: %lu\n", (unsigned long)prepared.rejectedFileCount);
    printf("UNIQUE-ASSETS: %lu\n", (unsigned long)prepared.uniqueAssetCount);
    printf("ASSET-BYTES: %llu\n", prepared.assetByteCount);
    printf("DIAGNOSTICS: info=%lu warning=%lu error=%lu\n",
        (unsigned long)informationCount,
        (unsigned long)warningCount,
        (unsigned long)errorCount);
    for (NSString *code in [diagnosticCounts.allKeys
            sortedArrayUsingSelector:@selector(compare:)]) {
        printf("DIAGNOSTIC-CODE: %s=%lu\n", code.UTF8String,
            (unsigned long)[diagnosticCounts[code] unsignedIntegerValue]);
    }
    printf("LIBRARY-REVISION: %s\n", revision.revisionIdentifier.UTF8String);
    printf("MANIFEST-DIGEST: %s\n", revision.manifestDigest.UTF8String);
    printf("GENERATION: %s\n",
        generation.descriptor.generationIdentifier.UTF8String);
    printf("GENERATION-RECORDS: %lu\n",
        (unsigned long)generation.index.recordCount);
    printf("GENERATION-ASSETS: %lu\n",
        (unsigned long)generation.descriptor.assetCount);
    printf("GENERATION-ASSET-BYTES: %llu\n",
        generation.descriptor.assetByteCount);
    printf("GENERATION-MODULES: %s\n",
        [generation.descriptor.moduleIDs
            componentsJoinedByString:@","].UTF8String);
    printf("GENERATION-MODULE-CONFIGURATIONS: %lu\n",
        (unsigned long)generation.descriptor.moduleConfigurations.count);
    printf("TIMING-SECONDS: prepare=%.3f commit=%.3f compile=%.3f\n",
        prepareSeconds, commitSeconds, compileSeconds);
    if (writeResult != nil) {
        printf("REAL-THEME-RUNTIME-FIXTURE: %s\n",
            destinationPath.fileSystemRepresentation);
        printf("REAL-THEME-WRITTEN-GENERATION: %s\n",
            writeResult.generationIdentifier.UTF8String);
        printf("REAL-THEME-WRITE-SECONDS: %.3f\n", writeSeconds);
        printf("REAL-THEME-RUNTIME-DECODE: attempts=%lu successes=%lu "
               "unique-assets=%lu target=180x180\n",
            (unsigned long)runtimeDecodeAttempts,
            (unsigned long)runtimeDecodeSuccesses,
            (unsigned long)runtimeDecodeUniqueAssets);
        printf("REAL-THEME-CLOCK-VARIANTS: %s\n",
            [[clockVariants.allObjects
                sortedArrayUsingSelector:@selector(compare:)]
                componentsJoinedByString:@","].UTF8String);
    }

    NSError *cleanupError = nil;
    if (![NSFileManager.defaultManager removeItemAtPath:root
                                                  error:&cleanupError]) {
        MTRealThemeReportFailure(@"cleanup", cleanupError);
        return 1;
    }
    return 0;
}

static int MTInspectRealThemeZIP(NSString *archivePath) {
    return MTProcessRealThemeZIP(archivePath, nil);
}

static int MTEmitRealThemeRuntimeFixture(NSString *archivePath,
                                         NSString *destinationPath) {
    return MTProcessRealThemeZIP(archivePath, destinationPath);
}

static int MTEmitShareSheetRuntimeFixture(NSString *archivePath,
                                          NSString *destinationPath) {
    struct stat archiveStatus = {0};
    if (lstat(archivePath.fileSystemRepresentation, &archiveStatus) == 0 ||
        errno != ENOENT) {
        fprintf(stderr,
            "FAIL: Share fixture ZIP destination must not already exist.\n");
        return 73;
    }
    NSString *parent = archivePath.stringByDeletingLastPathComponent;
    BOOL parentIsDirectory = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:parent
                                            isDirectory:&parentIsDirectory] ||
        !parentIsDirectory) {
        fprintf(stderr,
            "FAIL: Share fixture ZIP parent directory must already exist.\n");
        return 73;
    }
    NSString *written = MTShareSheetGateArchive(
        parent, archivePath.lastPathComponent);
    if (![written isEqualToString:archivePath] ||
        chmod(archivePath.fileSystemRepresentation, 0600) != 0) {
        fprintf(stderr, "FAIL: unable to write private Share fixture ZIP.\n");
        return 1;
    }
    return MTProcessRealThemeZIP(archivePath, destinationPath);
}

static void MTTestSyntheticFixture(NSString *fixturePath) {
    NSData *data = [NSData dataWithContentsOfFile:fixturePath];
    MTAssert(data != nil, @"synthetic fixture must be readable");
    NSError *error = nil;
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    MTAssert([object isKindOfClass:NSDictionary.class] && error == nil,
             @"synthetic fixture must be valid JSON");
    NSDictionary *fixture = object;
    MTAssert([fixture[@"schemaVersion"] unsignedIntegerValue] ==
                 MTThemeManifestVersion,
             @"fixture schema must match the manifest contract");
    MTAssert(MTIdentifierIsValid(fixture[@"themeID"]),
             @"fixture theme ID must be canonical");

    NSArray<NSDictionary *> *resources = fixture[@"resources"];
    MTAssert([resources isKindOfClass:NSArray.class] && resources.count == 3,
             @"fixture must contain its three deterministic candidates");
    NSDictionary *first = resources.firstObject;
    MTResourceKey *key = [[MTResourceKey alloc]
        initWithModuleID:first[@"moduleID"]
                 surface:first[@"surface"]
                 subject:first[@"subject"]
                 variant:first[@"variant"]
                   scale:[first[@"scale"] unsignedIntegerValue]
                   trait:first[@"trait"]
                   error:&error];
    MTAssert(key != nil && error == nil,
             @"fixture must map to a canonical resource key");
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        BOOL inspectsRealTheme = argc == 3 &&
            strcmp(argv[1], "--inspect-theme-zip") == 0;
        if (inspectsRealTheme) {
            NSString *archivePath = [NSString stringWithUTF8String:argv[2]];
            if (archivePath.length == 0 || !archivePath.isAbsolutePath) {
                fprintf(stderr,
                    "FAIL: real-theme smoke input must be an absolute path.\n");
                return 64;
            }
            return MTInspectRealThemeZIP(archivePath);
        }
        BOOL emitsRealThemeRuntimeFixture = argc == 4 &&
            strcmp(argv[1], "--emit-real-theme-runtime-fixture") == 0;
        if (emitsRealThemeRuntimeFixture) {
            NSString *archivePath = [NSString stringWithUTF8String:argv[2]];
            NSString *destinationPath =
                [NSString stringWithUTF8String:argv[3]];
            if (archivePath.length == 0 || !archivePath.isAbsolutePath ||
                destinationPath.length == 0 ||
                !destinationPath.isAbsolutePath) {
                fprintf(stderr,
                    "FAIL: real-theme Runtime fixture paths must be absolute.\n");
                return 64;
            }
            return MTEmitRealThemeRuntimeFixture(archivePath,
                                                 destinationPath);
        }
        BOOL emitsShareSheetRuntimeFixture = argc == 4 &&
            strcmp(argv[1], "--emit-share-sheet-runtime-fixture") == 0;
        if (emitsShareSheetRuntimeFixture) {
            NSString *archivePath = [NSString stringWithUTF8String:argv[2]];
            NSString *destinationPath =
                [NSString stringWithUTF8String:argv[3]];
            if (archivePath.length == 0 || !archivePath.isAbsolutePath ||
                destinationPath.length == 0 ||
                !destinationPath.isAbsolutePath) {
                fprintf(stderr,
                    "FAIL: Share Runtime fixture paths must be absolute.\n");
                return 64;
            }
            return MTEmitShareSheetRuntimeFixture(archivePath,
                                                  destinationPath);
        }
        BOOL emitsRuntimeStressFixture = argc == 3 &&
            strcmp(argv[1], "--emit-runtime-stress-fixture") == 0;
        BOOL emitsRuntimeSnapshotFixture = argc == 3 &&
            strcmp(argv[1], "--emit-runtime-snapshot-fixture") == 0;
        BOOL emitsRuntimeSwapFixture = argc == 3 &&
            strcmp(argv[1], "--emit-runtime-swap-fixture") == 0;
        BOOL emitsRuntimeFallbackFixture = argc == 3 &&
            strcmp(argv[1], "--emit-runtime-fallback-fixture") == 0;
        BOOL emitsRuntimePerformanceFixture = argc == 3 &&
            strcmp(argv[1], "--emit-runtime-performance-fixture") == 0;
        if (emitsRuntimePerformanceFixture) {
            NSURL *destinationURL = [NSURL fileURLWithPath:
                [NSString stringWithUTF8String:argv[2]] isDirectory:YES];
            NSError *error = nil;
            NSDictionary<NSString *, id> *result =
                MTRuntimePerformanceFixtureWrite(destinationURL, &error);
            if (result == nil) {
                fprintf(stderr,
                    "FAIL: unable to emit Runtime performance fixture: %s\n",
                    error.description.UTF8String ?: "unknown error");
                return 1;
            }
            printf("RUNTIME-PERFORMANCE-FIXTURE: %s\n",
                destinationURL.fileSystemRepresentation);
            printf("RUNTIME-GENERATION: %s\n",
                [result[@"generationIdentifier"] UTF8String]);
            printf("RUNTIME-SUBJECT: %s\n",
                [result[@"subject"] UTF8String]);
            printf("RUNTIME-RESOURCES: %lu\n",
                (unsigned long)[result[@"resourceCount"] unsignedIntegerValue]);
            printf("RUNTIME-ASSETS: %lu\n",
                (unsigned long)[result[@"assetCount"] unsignedIntegerValue]);
            printf("RUNTIME-ASSET-BYTES: %llu\n",
                [result[@"assetByteCount"] unsignedLongLongValue]);
            return 0;
        }
        if (emitsRuntimeFallbackFixture) {
            NSURL *destinationURL = [NSURL fileURLWithPath:
                [NSString stringWithUTF8String:argv[2]] isDirectory:YES];
            NSError *error = nil;
            NSDictionary<NSString *, id> *result =
                MTRuntimeFallbackFixtureWrite(destinationURL, &error);
            if (result == nil) {
                fprintf(stderr,
                    "FAIL: unable to emit Runtime fallback fixture: %s\n",
                    error.description.UTF8String ?: "unknown error");
                return 1;
            }
            printf("RUNTIME-FALLBACK-FIXTURE: %s\n",
                destinationURL.fileSystemRepresentation);
            printf("RUNTIME-CORRUPT-GENERATION: %s\n",
                [result[@"corruptGeneration"] UTF8String]);
            printf("RUNTIME-CORRUPT-ASSET: %s\n",
                [result[@"corruptAsset"] UTF8String]);
            printf("RUNTIME-CORRUPT-ASSET-BYTES: %llu\n",
                [result[@"corruptAssetByteCount"] unsignedLongLongValue]);
            printf("RUNTIME-MODULE-OFF-GENERATION: %s\n",
                [result[@"moduleOffGeneration"] UTF8String]);
            printf("RUNTIME-SUBJECT: %s\n",
                [result[@"subject"] UTF8String]);
            return 0;
        }
        if (emitsRuntimeSwapFixture) {
            NSURL *destinationURL = [NSURL fileURLWithPath:
                [NSString stringWithUTF8String:argv[2]] isDirectory:YES];
            NSError *error = nil;
            NSDictionary<NSString *, id> *result =
                MTRuntimeSnapshotSwapFixtureWrite(destinationURL, &error);
            if (result == nil) {
                fprintf(stderr,
                    "FAIL: unable to emit Runtime swap fixture: %s\n",
                    error.description.UTF8String ?: "unknown error");
                return 1;
            }
            printf("RUNTIME-SWAP-FIXTURE: %s\n",
                destinationURL.fileSystemRepresentation);
            printf("RUNTIME-GENERATION-A: %s\n",
                [result[@"generationA"] UTF8String]);
            printf("RUNTIME-GENERATION-B: %s\n",
                [result[@"generationB"] UTF8String]);
            printf("RUNTIME-ASSET-A: %s\n",
                [result[@"assetA"] UTF8String]);
            printf("RUNTIME-ASSET-B: %s\n",
                [result[@"assetB"] UTF8String]);
            printf("RUNTIME-SUBJECT: %s\n",
                [result[@"subject"] UTF8String]);
            return 0;
        }
        if (emitsRuntimeSnapshotFixture) {
            NSURL *destinationURL = [NSURL fileURLWithPath:
                [NSString stringWithUTF8String:argv[2]] isDirectory:YES];
            NSError *error = nil;
            NSDictionary<NSString *, id> *result =
                MTRuntimeSnapshotFixtureWrite(destinationURL, &error);
            if (result == nil) {
                fprintf(stderr,
                    "FAIL: unable to emit Runtime snapshot fixture: %s\n",
                    error.localizedDescription.UTF8String ?: "unknown error");
                return 1;
            }
            printf("RUNTIME-SNAPSHOT-FIXTURE: %s\n",
                destinationURL.fileSystemRepresentation);
            printf("RUNTIME-GENERATION: %s\n",
                [result[@"generationIdentifier"] UTF8String]);
            printf("RUNTIME-SUBJECT: %s\n",
                [result[@"subject"] UTF8String]);
            printf("RUNTIME-RESOURCES: %lu\n",
                (unsigned long)[result[@"resourceCount"] unsignedIntegerValue]);
            printf("RUNTIME-ASSETS: %lu\n",
                (unsigned long)[result[@"assetCount"] unsignedIntegerValue]);
            printf("RUNTIME-ASSET-BYTES: %llu\n",
                [result[@"assetByteCount"] unsignedLongLongValue]);
            return 0;
        }
        if (emitsRuntimeStressFixture) {
            NSURL *destinationURL = [NSURL fileURLWithPath:
                [NSString stringWithUTF8String:argv[2]] isDirectory:YES];
            NSError *error = nil;
            NSDictionary<NSString *, id> *result =
                MTRuntimeStressFixtureWrite(destinationURL, &error);
            if (result == nil) {
                fprintf(stderr,
                    "FAIL: unable to emit Runtime stress fixture: %s\n",
                    error.localizedDescription.UTF8String ?: "unknown error");
                return 1;
            }
            printf("RUNTIME-STRESS-FIXTURE: %s\n",
                destinationURL.fileSystemRepresentation);
            printf("RUNTIME-GENERATION: %s\n",
                [result[@"generationIdentifier"] UTF8String]);
            printf("RUNTIME-RESOURCES: %lu\n",
                (unsigned long)[result[@"resourceCount"] unsignedIntegerValue]);
            printf("RUNTIME-ASSETS: %lu\n",
                (unsigned long)[result[@"assetCount"] unsignedIntegerValue]);
            printf("RUNTIME-ASSET-BYTES: %llu\n",
                [result[@"assetByteCount"] unsignedLongLongValue]);
            return 0;
        }
        BOOL emitsWorkflowFixture = argc == 3 &&
            strcmp(argv[1], "--emit-workflow-zip") == 0;
        BOOL emitsInvalidImageFixture = argc == 3 &&
            strcmp(argv[1], "--emit-invalid-image-zip") == 0;
        if (emitsWorkflowFixture || emitsInvalidImageFixture) {
            NSString *destination = [NSString stringWithUTF8String:argv[2]];
            NSString *parent = destination.stringByDeletingLastPathComponent;
            NSError *error = nil;
            if (![NSFileManager.defaultManager
                    createDirectoryAtPath:parent
              withIntermediateDirectories:YES
                               attributes:nil
                                    error:&error]) {
                fprintf(stderr, "FAIL: unable to create fixture directory: %s\n",
                        error.localizedDescription.UTF8String);
                return 1;
            }
            NSString *temporaryRoot = MTCreateTemporaryDirectory(
                emitsWorkflowFixture ? @"simulator-workflow-fixture"
                                     : @"simulator-invalid-image-fixture");
            NSString *archivePath = emitsWorkflowFixture
                ? MTWorkflowValidArchive(temporaryRoot, @"Workflow.theme.zip")
                : MTWorkflowInvalidImageArchive(temporaryRoot,
                                                @"Bad-Image.theme.zip");
            NSData *archive = [NSData dataWithContentsOfFile:archivePath];
            BOOL wrote = archive != nil && [archive writeToFile:destination
                                                        options:NSDataWritingAtomic
                                                          error:&error];
            [NSFileManager.defaultManager removeItemAtPath:temporaryRoot
                                                     error:NULL];
            if (!wrote) {
                fprintf(stderr, "FAIL: unable to emit Simulator fixture: %s\n",
                        error.localizedDescription.UTF8String);
                return 1;
            }
            printf("FIXTURE: %s\n", destination.fileSystemRepresentation);
            return 0;
        }
        if (argc != 3) {
            fprintf(stderr,
                "Usage: marktheme-core-tests <fixture.json> <golden.sha256>\n"
                "       marktheme-core-tests --inspect-theme-zip <input.zip>\n"
                "       marktheme-core-tests --emit-real-theme-runtime-fixture <input.zip> <output-directory>\n"
                "       marktheme-core-tests --emit-share-sheet-runtime-fixture <output.zip> <output-directory>\n"
                "       marktheme-core-tests --emit-runtime-stress-fixture <output-directory>\n"
                "       marktheme-core-tests --emit-runtime-performance-fixture <output-directory>\n"
                "       marktheme-core-tests --emit-runtime-fallback-fixture <output-directory>\n"
                "       marktheme-core-tests --emit-workflow-zip <output.zip>\n"
                "       marktheme-core-tests --emit-invalid-image-zip <output.zip>\n");
            return 64;
        }
        MTTestIdentifiersAndContracts();
        MTTestCanonicalJSON();
        MTTestResourceKeys();
        MTTestLayerResolution();
        MTAssertionCount += MTRunCalendarRuntimeTests();
        MTTestModuleRegistry();
        MTTestPlatformPaths();
        MTTestImportSession();
        MTTestDirectorySnapshotSession();
        MTTestSafeImageInspector();
        MTTestSafeImageDecoder();
        MTTestSafePropertyListReader();
        MTThemeImportMetadata *importMetadata =
            MTTestThemeInfoMetadataMapper();
        MTTestSyntheticFixture([NSString stringWithUTF8String:argv[1]]);
        MTTestSafeZIPArchiveReader();
        MTTestLegacyAppIconMaskImport();
        MTTestLegacyIconOverlayImport();
        MTTestAssetStagingSession();
        MTTestAuditedMetadataFallbacks();
        MTIconBundlesImportResult *importResult = MTTestDirectoryScanAndImporter(
            [NSString stringWithUTF8String:argv[2]], importMetadata);
        MTTestTolerantThemeLayoutImport();
        MTTestClockComponentImport();
        MTTestGlobalIconSurfaceImport();
        MTTestThemeLibrary(importResult.manifest);
        MTTestFormalThemeLibraryTransaction();
        MTTestThemeLibraryCatalog();
        MTTestSemanticLayoutCompatibilityMatrix();
        MTTestSnowBoardThemeSuiteImport();
        MTTestFolderComponentSelectionDependency();
        MTTestInstalledThemeLocator();
        MTTestDebianPackageThemeImport();
        MTTestExpandedArchiveChunkCancellation();
        MTTestThemeImportWorkflow();
        MTTestPermissiveRealWorldArchiveImport();
        MTAssertionCount += MTRunGenerationIndexCodecTests();
        MTAssertionCount += MTRunGenerationDescriptorTests();
        printf("PASS: %lu MarkTheme foundation assertions\n",
               (unsigned long)MTAssertionCount);
        printf("CANONICAL-DIGEST: %s\n", MTGoldenManifestDigest.UTF8String);
    }
    return 0;
}
