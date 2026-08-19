#import "MTSyntheticCorpus.h"

#import <fcntl.h>
#import <sys/stat.h>
#import <unistd.h>
#import <zlib.h>

NSString *const MTSyntheticCorpusErrorDomain =
    @"com.hmmzzz.marktheme.tests.synthetic-corpus";

static const NSUInteger MTSyntheticCorpusMaximumIconCount = 2000;
static const uint32_t MTSyntheticCorpusMaximumPixelDimension = 4096;

static BOOL MTSyntheticCorpusSetError(NSError **error,
                                      MTSyntheticCorpusErrorCode code,
                                      NSString *description,
                                      NSError *_Nullable underlyingError) {
    if (error != NULL) {
        NSMutableDictionary *userInfo = [@{
            NSLocalizedDescriptionKey : description,
        } mutableCopy];
        if (underlyingError != nil) {
            userInfo[NSUnderlyingErrorKey] = underlyingError;
        }
        *error = [NSError errorWithDomain:MTSyntheticCorpusErrorDomain
                                     code:code
                                 userInfo:userInfo];
    }
    return NO;
}

static NSError *MTSyntheticCorpusPOSIXError(int code) {
    return [NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:nil];
}

static BOOL MTSyntheticCorpusAddUnsigned(NSUInteger left,
                                         NSUInteger right,
                                         NSUInteger *result) {
    if (left > NSUIntegerMax - right) return NO;
    *result = left + right;
    return YES;
}

static void MTSyntheticCorpusAppendBE32(NSMutableData *data, uint32_t value) {
    const uint8_t bytes[] = {
        (uint8_t)(value >> 24),
        (uint8_t)(value >> 16),
        (uint8_t)(value >> 8),
        (uint8_t)value,
    };
    [data appendBytes:bytes length:sizeof(bytes)];
}

static void MTSyntheticCorpusAppendLE16(NSMutableData *data, uint16_t value) {
    const uint8_t bytes[] = {
        (uint8_t)value,
        (uint8_t)(value >> 8),
    };
    [data appendBytes:bytes length:sizeof(bytes)];
}

static void MTSyntheticCorpusAppendLE32(NSMutableData *data, uint32_t value) {
    const uint8_t bytes[] = {
        (uint8_t)value,
        (uint8_t)(value >> 8),
        (uint8_t)(value >> 16),
        (uint8_t)(value >> 24),
    };
    [data appendBytes:bytes length:sizeof(bytes)];
}

static BOOL MTSyntheticCorpusAppendPNGChunk(NSMutableData *png,
                                            const char type[4],
                                            NSData *contents,
                                            NSError **error) {
    if (contents.length > UINT32_MAX) {
        return MTSyntheticCorpusSetError(error,
            MTSyntheticCorpusErrorLimitExceeded,
            @"A synthetic PNG chunk exceeds the PNG32 limit.", nil);
    }
    MTSyntheticCorpusAppendBE32(png, (uint32_t)contents.length);
    [png appendBytes:type length:4];
    [png appendData:contents];
    uLong checksum = crc32(0L, Z_NULL, 0);
    checksum = crc32(checksum, (const Bytef *)type, 4);
    if (contents.length > 0) {
        checksum = crc32(checksum, contents.bytes, (uInt)contents.length);
    }
    MTSyntheticCorpusAppendBE32(png, (uint32_t)checksum);
    return YES;
}

static NSData *_Nullable MTSyntheticCorpusZlibData(NSData *input,
                                                    NSError **error) {
    if (input.length > UINT32_MAX) {
        MTSyntheticCorpusSetError(error,
            MTSyntheticCorpusErrorLimitExceeded,
            @"Synthetic raster bytes exceed the zlib counter limit.", nil);
        return nil;
    }
    uLongf capacity = compressBound((uLong)input.length);
    NSMutableData *output = [NSMutableData dataWithLength:(NSUInteger)capacity];
    int status = compress2(output.mutableBytes, &capacity,
                           input.bytes, (uLong)input.length, Z_BEST_SPEED);
    if (status != Z_OK) {
        MTSyntheticCorpusSetError(error,
            MTSyntheticCorpusErrorEncoding,
            @"Unable to encode the synthetic PNG raster.", nil);
        return nil;
    }
    [output setLength:(NSUInteger)capacity];
    return output;
}

NSData *MTSyntheticPNGData(uint32_t pixelDimension,
                           uint32_t seed,
                           NSError **error) {
    if (pixelDimension == 0 ||
        pixelDimension > MTSyntheticCorpusMaximumPixelDimension) {
        MTSyntheticCorpusSetError(error,
            MTSyntheticCorpusErrorInvalidRequest,
            @"Synthetic PNG dimensions are outside the benchmark policy.",
            nil);
        return nil;
    }
    NSUInteger pixelBytes = 0;
    if (__builtin_mul_overflow((NSUInteger)pixelDimension, (NSUInteger)4,
                               &pixelBytes)) {
        MTSyntheticCorpusSetError(error,
            MTSyntheticCorpusErrorLimitExceeded,
            @"Synthetic PNG row bytes overflow.", nil);
        return nil;
    }
    NSUInteger rowBytes = 0;
    NSUInteger rasterBytes = 0;
    if (!MTSyntheticCorpusAddUnsigned(pixelBytes, 1, &rowBytes) ||
        __builtin_mul_overflow(rowBytes, (NSUInteger)pixelDimension,
                               &rasterBytes) ||
        rasterBytes > UINT32_MAX) {
        MTSyntheticCorpusSetError(error,
            MTSyntheticCorpusErrorLimitExceeded,
            @"Synthetic PNG raster size exceeds the benchmark policy.",
            nil);
        return nil;
    }

    NSMutableData *raster = [NSMutableData dataWithLength:rasterBytes];
    uint8_t *bytes = raster.mutableBytes;
    for (uint32_t y = 0; y < pixelDimension; y++) {
        uint8_t *row = bytes + (NSUInteger)y * rowBytes;
        row[0] = 0;
        for (uint32_t x = 0; x < pixelDimension; x++) {
            BOOL policyEdge = pixelDimension >= 2048;
            // Keep the policy-edge 4096 px case below the 32 MiB encoded
            // admission ceiling while retaining deterministic RGBA content.
            uint32_t block = policyEdge
                ? ((x >> 5) ^ (y >> 5) ^ seed)
                : (((x >> 3) * 0x45d9f3bu) ^
                   ((y >> 3) * 0x119de1f3u) ^
                   (seed * 0x9e3779b9u));
            uint8_t *pixel = row + 1 + (NSUInteger)x * 4;
            pixel[0] = policyEdge
                ? (uint8_t)(seed * 17u + (x >> 6))
                : (uint8_t)(x + seed * 17u + (block >> 3));
            pixel[1] = policyEdge
                ? (uint8_t)(seed * 29u + (y >> 6))
                : (uint8_t)(y * 3u + seed * 29u + (block >> 11));
            pixel[2] = policyEdge
                ? (uint8_t)(seed + block)
                : (uint8_t)((x ^ y ^ seed) + (block >> 19));
            pixel[3] = policyEdge
                ? 0xff
                : (uint8_t)(224u + ((x + y + seed) & 31u));
        }
    }

    NSData *compressed = MTSyntheticCorpusZlibData(raster, error);
    if (compressed == nil) return nil;

    NSMutableData *png = [NSMutableData data];
    const uint8_t signature[] = {
        0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a,
    };
    [png appendBytes:signature length:sizeof(signature)];
    NSMutableData *header = [NSMutableData data];
    MTSyntheticCorpusAppendBE32(header, pixelDimension);
    MTSyntheticCorpusAppendBE32(header, pixelDimension);
    const uint8_t headerTail[] = {8, 6, 0, 0, 0};
    [header appendBytes:headerTail length:sizeof(headerTail)];
    if (!MTSyntheticCorpusAppendPNGChunk(png, "IHDR", header, error) ||
        !MTSyntheticCorpusAppendPNGChunk(png, "IDAT", compressed, error) ||
        !MTSyntheticCorpusAppendPNGChunk(png, "IEND", NSData.data, error)) {
        return nil;
    }
    return png;
}

static NSData *_Nullable MTSyntheticCorpusRawDeflate(NSData *input,
                                                      NSError **error) {
    if (input.length > UINT32_MAX) {
        MTSyntheticCorpusSetError(error,
            MTSyntheticCorpusErrorLimitExceeded,
            @"A synthetic ZIP entry exceeds the ZIP32 input limit.", nil);
        return nil;
    }
    z_stream stream = {0};
    int status = deflateInit2(&stream, Z_BEST_SPEED, Z_DEFLATED,
                              -MAX_WBITS, 8, Z_DEFAULT_STRATEGY);
    if (status != Z_OK) {
        MTSyntheticCorpusSetError(error,
            MTSyntheticCorpusErrorEncoding,
            @"Unable to initialize raw ZIP deflate.", nil);
        return nil;
    }
    uLong capacity = compressBound((uLong)input.length);
    NSMutableData *output = [NSMutableData dataWithLength:(NSUInteger)capacity];
    stream.next_in = (Bytef *)input.bytes;
    stream.avail_in = (uInt)input.length;
    stream.next_out = output.mutableBytes;
    stream.avail_out = (uInt)output.length;
    status = deflate(&stream, Z_FINISH);
    BOOL valid = status == Z_STREAM_END && stream.avail_in == 0;
    NSUInteger outputLength = valid ? (NSUInteger)stream.total_out : 0;
    int endStatus = deflateEnd(&stream);
    if (!valid || endStatus != Z_OK) {
        MTSyntheticCorpusSetError(error,
            MTSyntheticCorpusErrorEncoding,
            @"Unable to encode a synthetic ZIP entry.", nil);
        return nil;
    }
    [output setLength:outputLength];
    return output;
}

static BOOL MTSyntheticCorpusWriteAll(int descriptor,
                                      NSData *data,
                                      NSError **error) {
    const uint8_t *bytes = data.bytes;
    NSUInteger remaining = data.length;
    while (remaining > 0) {
        ssize_t count = write(descriptor, bytes, remaining);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) {
            return MTSyntheticCorpusSetError(error,
                MTSyntheticCorpusErrorFilesystem,
                @"Unable to write synthetic corpus bytes.",
                MTSyntheticCorpusPOSIXError(errno));
        }
        bytes += count;
        remaining -= (NSUInteger)count;
    }
    return YES;
}

static BOOL MTSyntheticCorpusWritePrivateFile(NSURL *url,
                                              NSData *data,
                                              NSError **error) {
    int descriptor = open(url.fileSystemRepresentation,
                          O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                          0600);
    if (descriptor < 0) {
        return MTSyntheticCorpusSetError(error,
            MTSyntheticCorpusErrorFilesystem,
            @"Unable to create a private synthetic corpus file.",
            MTSyntheticCorpusPOSIXError(errno));
    }
    BOOL success = MTSyntheticCorpusWriteAll(descriptor, data, error);
    if (success && fchmod(descriptor, 0600) != 0) {
        success = MTSyntheticCorpusSetError(error,
            MTSyntheticCorpusErrorFilesystem,
            @"Unable to set synthetic corpus file permissions.",
            MTSyntheticCorpusPOSIXError(errno));
    }
    if (success && fsync(descriptor) != 0) {
        success = MTSyntheticCorpusSetError(error,
            MTSyntheticCorpusErrorFilesystem,
            @"Unable to synchronize a synthetic corpus file.",
            MTSyntheticCorpusPOSIXError(errno));
    }
    int closeError = close(descriptor);
    if (success && closeError != 0) {
        success = MTSyntheticCorpusSetError(error,
            MTSyntheticCorpusErrorFilesystem,
            @"Unable to close a synthetic corpus file.",
            MTSyntheticCorpusPOSIXError(errno));
    }
    if (!success) unlink(url.fileSystemRepresentation);
    return success;
}

@interface MTSyntheticZIPWriter : NSObject
@property(nonatomic, copy) NSURL *partialURL;
@property(nonatomic, copy) NSURL *finalURL;
@property(nonatomic, assign) int descriptor;
@property(nonatomic, assign) uint64_t offset;
@property(nonatomic, strong) NSMutableArray<NSDictionary<NSString *, id> *> *entries;
- (nullable instancetype)initWithPartialURL:(NSURL *)partialURL
                                   finalURL:(NSURL *)finalURL
                                      error:(NSError **)error;
- (BOOL)appendPath:(NSString *)path data:(NSData *)data error:(NSError **)error;
- (BOOL)finish:(NSError **)error;
@end

@implementation MTSyntheticZIPWriter

- (instancetype)initWithPartialURL:(NSURL *)partialURL
                           finalURL:(NSURL *)finalURL
                              error:(NSError **)error {
    self = [super init];
    if (self == nil) return nil;
    _descriptor = open(partialURL.fileSystemRepresentation,
                       O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                       0600);
    if (_descriptor < 0) {
        MTSyntheticCorpusSetError(error,
            MTSyntheticCorpusErrorFilesystem,
            @"Unable to create the synthetic ZIP partial.",
            MTSyntheticCorpusPOSIXError(errno));
        return nil;
    }
    _partialURL = [partialURL copy];
    _finalURL = [finalURL copy];
    _entries = [NSMutableArray array];
    return self;
}

- (BOOL)writeData:(NSData *)data error:(NSError **)error {
    if (self.offset > UINT32_MAX || data.length > UINT32_MAX - self.offset) {
        return MTSyntheticCorpusSetError(error,
            MTSyntheticCorpusErrorLimitExceeded,
            @"The synthetic ZIP exceeds the ZIP32 offset limit.", nil);
    }
    if (!MTSyntheticCorpusWriteAll(self.descriptor, data, error)) return NO;
    self.offset += data.length;
    return YES;
}

- (BOOL)appendPath:(NSString *)path data:(NSData *)data error:(NSError **)error {
    NSData *name = [path dataUsingEncoding:NSUTF8StringEncoding];
    if (self.descriptor < 0 || name.length == 0 || name.length > UINT16_MAX ||
        data.length > UINT32_MAX || self.entries.count >= UINT16_MAX) {
        return MTSyntheticCorpusSetError(error,
            MTSyntheticCorpusErrorLimitExceeded,
            @"A synthetic ZIP entry exceeds the ZIP32 policy.", nil);
    }
    NSData *compressed = MTSyntheticCorpusRawDeflate(data, error);
    if (compressed == nil || compressed.length > UINT32_MAX) return NO;
    uint32_t localOffset = (uint32_t)self.offset;
    uint32_t checksum = (uint32_t)crc32(0, data.bytes, (uInt)data.length);
    NSMutableData *header = [NSMutableData data];
    MTSyntheticCorpusAppendLE32(header, 0x04034b50);
    MTSyntheticCorpusAppendLE16(header, 20);
    MTSyntheticCorpusAppendLE16(header, 0x0800);
    MTSyntheticCorpusAppendLE16(header, 8);
    MTSyntheticCorpusAppendLE16(header, 0);
    MTSyntheticCorpusAppendLE16(header, 0);
    MTSyntheticCorpusAppendLE32(header, checksum);
    MTSyntheticCorpusAppendLE32(header, (uint32_t)compressed.length);
    MTSyntheticCorpusAppendLE32(header, (uint32_t)data.length);
    MTSyntheticCorpusAppendLE16(header, (uint16_t)name.length);
    MTSyntheticCorpusAppendLE16(header, 0);
    if (![self writeData:header error:error] ||
        ![self writeData:name error:error] ||
        ![self writeData:compressed error:error]) {
        return NO;
    }
    [self.entries addObject:@{
        @"name" : name,
        @"crc" : @(checksum),
        @"compressed" : @((uint32_t)compressed.length),
        @"uncompressed" : @((uint32_t)data.length),
        @"offset" : @(localOffset),
    }];
    return YES;
}

- (BOOL)finish:(NSError **)error {
    if (self.descriptor < 0 || self.entries.count > UINT16_MAX ||
        self.offset > UINT32_MAX) {
        return MTSyntheticCorpusSetError(error,
            MTSyntheticCorpusErrorLimitExceeded,
            @"The synthetic ZIP cannot be finalized as ZIP32.", nil);
    }
    uint32_t centralOffset = (uint32_t)self.offset;
    for (NSDictionary<NSString *, id> *entry in self.entries) {
        NSData *name = entry[@"name"];
        NSMutableData *header = [NSMutableData data];
        MTSyntheticCorpusAppendLE32(header, 0x02014b50);
        MTSyntheticCorpusAppendLE16(header, 0x0314);
        MTSyntheticCorpusAppendLE16(header, 20);
        MTSyntheticCorpusAppendLE16(header, 0x0800);
        MTSyntheticCorpusAppendLE16(header, 8);
        MTSyntheticCorpusAppendLE16(header, 0);
        MTSyntheticCorpusAppendLE16(header, 0);
        MTSyntheticCorpusAppendLE32(header, [entry[@"crc"] unsignedIntValue]);
        MTSyntheticCorpusAppendLE32(header,
            [entry[@"compressed"] unsignedIntValue]);
        MTSyntheticCorpusAppendLE32(header,
            [entry[@"uncompressed"] unsignedIntValue]);
        MTSyntheticCorpusAppendLE16(header, (uint16_t)name.length);
        MTSyntheticCorpusAppendLE16(header, 0);
        MTSyntheticCorpusAppendLE16(header, 0);
        MTSyntheticCorpusAppendLE16(header, 0);
        MTSyntheticCorpusAppendLE16(header, 0);
        MTSyntheticCorpusAppendLE32(header, (S_IFREG | 0600) << 16);
        MTSyntheticCorpusAppendLE32(header, [entry[@"offset"] unsignedIntValue]);
        if (![self writeData:header error:error] ||
            ![self writeData:name error:error]) {
            return NO;
        }
    }
    uint64_t centralSize64 = self.offset - centralOffset;
    if (centralSize64 > UINT32_MAX) {
        return MTSyntheticCorpusSetError(error,
            MTSyntheticCorpusErrorLimitExceeded,
            @"The synthetic ZIP central directory exceeds ZIP32.", nil);
    }
    NSMutableData *end = [NSMutableData data];
    MTSyntheticCorpusAppendLE32(end, 0x06054b50);
    MTSyntheticCorpusAppendLE16(end, 0);
    MTSyntheticCorpusAppendLE16(end, 0);
    MTSyntheticCorpusAppendLE16(end, (uint16_t)self.entries.count);
    MTSyntheticCorpusAppendLE16(end, (uint16_t)self.entries.count);
    MTSyntheticCorpusAppendLE32(end, (uint32_t)centralSize64);
    MTSyntheticCorpusAppendLE32(end, centralOffset);
    MTSyntheticCorpusAppendLE16(end, 0);
    if (![self writeData:end error:error] ||
        fchmod(self.descriptor, 0600) != 0 || fsync(self.descriptor) != 0) {
        if (error != NULL && *error == nil) {
            MTSyntheticCorpusSetError(error,
                MTSyntheticCorpusErrorFilesystem,
                @"Unable to synchronize the synthetic ZIP.",
                MTSyntheticCorpusPOSIXError(errno));
        }
        return NO;
    }
    if (close(self.descriptor) != 0) {
        self.descriptor = -1;
        return MTSyntheticCorpusSetError(error,
            MTSyntheticCorpusErrorFilesystem,
            @"Unable to close the synthetic ZIP.",
            MTSyntheticCorpusPOSIXError(errno));
    }
    self.descriptor = -1;
    if (renameatx_np(AT_FDCWD, self.partialURL.fileSystemRepresentation,
                     AT_FDCWD, self.finalURL.fileSystemRepresentation,
                     RENAME_EXCL) != 0) {
        return MTSyntheticCorpusSetError(error,
            MTSyntheticCorpusErrorFilesystem,
            @"Unable to publish the synthetic ZIP without replacement.",
            MTSyntheticCorpusPOSIXError(errno));
    }
    int rootDescriptor = open(self.finalURL.URLByDeletingLastPathComponent
        .fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (rootDescriptor < 0 || fsync(rootDescriptor) != 0) {
        int savedError = errno;
        if (rootDescriptor >= 0) close(rootDescriptor);
        return MTSyntheticCorpusSetError(error,
            MTSyntheticCorpusErrorFilesystem,
            @"Unable to synchronize the synthetic corpus root.",
            MTSyntheticCorpusPOSIXError(savedError));
    }
    close(rootDescriptor);
    return YES;
}

- (void)dealloc {
    if (_descriptor >= 0) close(_descriptor);
    if (_partialURL != nil) unlink(_partialURL.fileSystemRepresentation);
}

@end

@interface MTSyntheticCorpus ()
- (instancetype)initWithDirectoryURL:(NSURL *)directoryURL
                           archiveURL:(NSURL *)archiveURL
                            iconCount:(NSUInteger)iconCount
                       pixelDimension:(uint32_t)pixelDimension
            directoryPayloadByteCount:(uint64_t)directoryPayloadByteCount
                     archiveByteCount:(uint64_t)archiveByteCount;
@end

@implementation MTSyntheticCorpus

- (instancetype)initWithDirectoryURL:(NSURL *)directoryURL
                           archiveURL:(NSURL *)archiveURL
                            iconCount:(NSUInteger)iconCount
                       pixelDimension:(uint32_t)pixelDimension
            directoryPayloadByteCount:(uint64_t)directoryPayloadByteCount
                     archiveByteCount:(uint64_t)archiveByteCount {
    self = [super init];
    if (self == nil) return nil;
    _directoryURL = [directoryURL copy];
    _archiveURL = [archiveURL copy];
    _iconCount = iconCount;
    _pixelDimension = pixelDimension;
    _directoryPayloadByteCount = directoryPayloadByteCount;
    _archiveByteCount = archiveByteCount;
    return self;
}

@end

static BOOL MTSyntheticCorpusCreateDirectory(NSURL *url, NSError **error) {
    NSError *operationError = nil;
    if (![NSFileManager.defaultManager createDirectoryAtURL:url
                                withIntermediateDirectories:NO
                                                 attributes:@{
            NSFilePosixPermissions : @0700,
        } error:&operationError] ||
        chmod(url.fileSystemRepresentation, 0700) != 0) {
        return MTSyntheticCorpusSetError(error,
            MTSyntheticCorpusErrorFilesystem,
            @"Unable to create a private synthetic corpus directory.",
            operationError ?: MTSyntheticCorpusPOSIXError(errno));
    }
    return YES;
}

MTSyntheticCorpus *MTSyntheticCorpusCreate(NSURL *rootURL,
                                           NSUInteger iconCount,
                                           uint32_t pixelDimension,
                                           NSError **error) {
    if (![rootURL isKindOfClass:NSURL.class] || !rootURL.isFileURL ||
        rootURL.path.length == 0 || iconCount == 0 ||
        iconCount > MTSyntheticCorpusMaximumIconCount ||
        pixelDimension == 0 ||
        pixelDimension > MTSyntheticCorpusMaximumPixelDimension) {
        MTSyntheticCorpusSetError(error,
            MTSyntheticCorpusErrorInvalidRequest,
            @"Synthetic corpus parameters are outside the benchmark policy.",
            nil);
        return nil;
    }

    NSURL *directoryURL = [rootURL
        URLByAppendingPathComponent:@"SyntheticBenchmark.theme"
                         isDirectory:YES];
    NSURL *iconsURL = [directoryURL
        URLByAppendingPathComponent:@"IconBundles" isDirectory:YES];
    NSURL *archiveURL = [rootURL
        URLByAppendingPathComponent:@"SyntheticBenchmark.theme.zip"];
    NSURL *partialArchiveURL = [rootURL
        URLByAppendingPathComponent:@".SyntheticBenchmark.theme.zip.partial"];
    if ([NSFileManager.defaultManager fileExistsAtPath:directoryURL.path] ||
        [NSFileManager.defaultManager fileExistsAtPath:archiveURL.path] ||
        [NSFileManager.defaultManager fileExistsAtPath:partialArchiveURL.path] ||
        !MTSyntheticCorpusCreateDirectory(directoryURL, error) ||
        !MTSyntheticCorpusCreateDirectory(iconsURL, error)) {
        if (error != NULL && *error == nil) {
            MTSyntheticCorpusSetError(error,
                MTSyntheticCorpusErrorFilesystem,
                @"Synthetic corpus output already exists.", nil);
        }
        return nil;
    }

    MTSyntheticZIPWriter *writer = [[MTSyntheticZIPWriter alloc]
        initWithPartialURL:partialArchiveURL finalURL:archiveURL error:error];
    if (writer == nil) return nil;

    NSDictionary *metadata = @{
        @"CFBundleDisplayName" : @"Synthetic Benchmark Theme",
        @"CFBundleShortVersionString" : @"1.0",
    };
    NSError *operationError = nil;
    NSData *metadataData = [NSPropertyListSerialization
        dataWithPropertyList:metadata format:NSPropertyListXMLFormat_v1_0
                     options:0 error:&operationError];
    NSURL *metadataURL = [directoryURL URLByAppendingPathComponent:@"Info.plist"];
    if (metadataData == nil ||
        !MTSyntheticCorpusWritePrivateFile(metadataURL, metadataData, error) ||
        ![writer appendPath:@"Info.plist" data:metadataData error:error]) {
        if (metadataData == nil) {
            MTSyntheticCorpusSetError(error,
                MTSyntheticCorpusErrorEncoding,
                @"Unable to encode synthetic theme metadata.", operationError);
        }
        return nil;
    }
    uint64_t payloadBytes = metadataData.length;

    for (NSUInteger index = 0; index < iconCount; index++) {
        @autoreleasepool {
            NSError *iconError = nil;
            NSData *png = MTSyntheticPNGData(pixelDimension,
                                             (uint32_t)index + 1,
                                             &iconError);
            NSString *filename = [NSString stringWithFormat:
                @"com.example.benchmark%04lu-large.png",
                (unsigned long)index];
            NSString *relativePath = [@"IconBundles/"
                stringByAppendingString:filename];
            NSURL *fileURL = [iconsURL URLByAppendingPathComponent:filename];
            if (png == nil || payloadBytes > UINT64_MAX - png.length ||
                !MTSyntheticCorpusWritePrivateFile(fileURL, png, &iconError) ||
                ![writer appendPath:relativePath data:png error:&iconError]) {
                if (error != NULL) {
                    *error = iconError ?: [NSError
                        errorWithDomain:MTSyntheticCorpusErrorDomain
                                   code:MTSyntheticCorpusErrorEncoding
                               userInfo:@{
                        NSLocalizedDescriptionKey :
                            @"Unable to create a synthetic icon fixture."
                    }];
                }
                return nil;
            }
            payloadBytes += png.length;
        }
    }
    if (![writer finish:error]) return nil;

    NSDictionary *archiveAttributes = [NSFileManager.defaultManager
        attributesOfItemAtPath:archiveURL.path error:&operationError];
    NSNumber *archiveSize = archiveAttributes[NSFileSize];
    if (archiveSize == nil) {
        MTSyntheticCorpusSetError(error,
            MTSyntheticCorpusErrorFilesystem,
            @"Unable to read the synthetic ZIP size.", operationError);
        return nil;
    }
    return [[MTSyntheticCorpus alloc]
        initWithDirectoryURL:directoryURL
        archiveURL:archiveURL
        iconCount:iconCount
        pixelDimension:pixelDimension
        directoryPayloadByteCount:payloadBytes
        archiveByteCount:archiveSize.unsignedLongLongValue];
}
