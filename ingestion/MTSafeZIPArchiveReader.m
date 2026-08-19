#import "MTSafeZIPArchiveReader.h"

#import <CommonCrypto/CommonDigest.h>
#import <dlfcn.h>
#import <errno.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <sys/types.h>
#import <unistd.h>

#import "MTAuditedZIPEntryStreamer.h"
#import "MTImportSession.h"

NSString *const MTSafeZIPArchiveReaderErrorDomain =
    @"com.hmmzzz.marktheme.safe-zip-archive-reader";

static const uint32_t MTZIPLocalHeaderSignature = 0x04034b50;
static const uint32_t MTZIPCentralHeaderSignature = 0x02014b50;
static const uint32_t MTZIPEndSignature = 0x06054b50;
static const uint64_t MTZIPMaximumEndSearchBytes = 22ULL + UINT16_MAX;
static const uint16_t MTZIPFlagEncrypted = 1U << 0;
static const uint16_t MTZIPFlagDataDescriptor = 1U << 3;
static const uint16_t MTZIPFlagStrongEncryption = 1U << 6;
static const uint16_t MTZIPFlagUTF8 = 1U << 11;
static const uint16_t MTZIPFlagMaskedHeader = 1U << 13;
static const uint16_t MTZIPMethodStored = 0;
static const uint16_t MTZIPMethodDeflate = 8;
static const uint16_t MTZIPExtraZIP64 = 0x0001;
static const uint16_t MTZIPExtraAES = 0x9901;

typedef struct archive MTArchive;
typedef struct archive_entry MTArchiveEntry;

typedef struct {
    void *handle;
    MTArchive *(*readNew)(void);
    int (*readSupportFilterNone)(MTArchive *archive);
    int (*readSupportFormatZIP)(MTArchive *archive);
    int (*readOpenFD)(MTArchive *archive, int descriptor, size_t blockSize);
    int (*readNextHeader)(MTArchive *archive, MTArchiveEntry **entry);
    ssize_t (*readData)(MTArchive *archive, void *buffer, size_t length);
    int (*readDataSkip)(MTArchive *archive);
    const char *(*errorString)(MTArchive *archive);
    int (*readFree)(MTArchive *archive);
    const char *(*entryPathnameUTF8)(MTArchiveEntry *entry);
    const char *(*entryPathname)(MTArchiveEntry *entry);
    mode_t (*entryFiletype)(MTArchiveEntry *entry);
    mode_t (*entryMode)(MTArchiveEntry *entry);
    int64_t (*entrySize)(MTArchiveEntry *entry);
    int (*entryIsEncrypted)(MTArchiveEntry *entry);
} MTArchiveAPI;

@class MTZIPPlanEntry;

@interface MTSafeZIPArchiveScan ()
- (instancetype)initWithInventory:(MTSourceInventory *)inventory
                 archiveEntryCount:(NSUInteger)archiveEntryCount
              totalCompressedBytes:(uint64_t)totalCompressedBytes
                         archiveURL:(NSURL *)archiveURL
                             limits:(MTImportLimits *)limits
                              plans:(NSArray<MTZIPPlanEntry *> *)plans
                       sourceStatus:(const struct stat *)sourceStatus;
@end

@interface MTZIPPlanEntry : NSObject
@property(nonatomic, copy) NSString *relativePath;
@property(nonatomic, assign, getter=isDirectory) BOOL directory;
@property(nonatomic, assign) uint16_t method;
@property(nonatomic, assign) uint32_t crc32;
@property(nonatomic, assign) uint64_t compressedBytes;
@property(nonatomic, assign) uint64_t expandedBytes;
@property(nonatomic, assign) mode_t mode;
@property(nonatomic, assign) uint64_t localStart;
@property(nonatomic, assign) uint64_t localDataStart;
@property(nonatomic, assign) uint64_t localDataEnd;
@property(nonatomic, assign, getter=isPackagingArtifact) BOOL packagingArtifact;
@end

@implementation MTZIPPlanEntry
@end

@interface MTZIPPathState : NSObject
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *rawPaths;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *directoryByKey;
@property(nonatomic, strong) NSMutableSet<NSString *> *keysWithDescendants;
@end

@implementation MTZIPPathState
- (instancetype)init {
    self = [super init];
    if (self == nil) return nil;
    _rawPaths = [NSMutableDictionary dictionary];
    _directoryByKey = [NSMutableDictionary dictionary];
    _keysWithDescendants = [NSMutableSet set];
    return self;
}
@end

static BOOL MTZIPSetError(NSError **error,
                          MTSafeZIPArchiveReaderErrorCode code,
                          NSString *description,
                          NSString *_Nullable relativePath,
                          NSError *_Nullable underlying) {
    if (error != NULL) {
        NSMutableDictionary *userInfo = [NSMutableDictionary
            dictionaryWithObject:description forKey:NSLocalizedDescriptionKey];
        if (relativePath.length > 0) userInfo[@"relativePath"] = relativePath;
        if (underlying != nil) userInfo[NSUnderlyingErrorKey] = underlying;
        *error = [NSError errorWithDomain:MTSafeZIPArchiveReaderErrorDomain
                                     code:code
                                 userInfo:userInfo];
    }
    return NO;
}

static NSError *MTZIPPOSIXError(int value) {
    return [NSError errorWithDomain:NSPOSIXErrorDomain code:value userInfo:nil];
}

static void MTZIPSetAuditedReadError(
    NSError **error,
    MTAuditedSourceErrorCode code,
    NSString *description,
    NSString *_Nullable relativePath,
    NSError *_Nullable underlying) {
    if (error == NULL) return;
    NSMutableDictionary *userInfo = [NSMutableDictionary
        dictionaryWithObject:description forKey:NSLocalizedDescriptionKey];
    if (relativePath.length > 0) userInfo[@"relativePath"] = relativePath;
    if (underlying != nil) userInfo[NSUnderlyingErrorKey] = underlying;
    *error = [NSError errorWithDomain:MTAuditedSourceErrorDomain
                                 code:code
                             userInfo:userInfo];
}

static uint16_t MTZIPReadLE16(const unsigned char *bytes) {
    return (uint16_t)bytes[0] | ((uint16_t)bytes[1] << 8);
}

static uint32_t MTZIPReadLE32(const unsigned char *bytes) {
    return (uint32_t)bytes[0] |
        ((uint32_t)bytes[1] << 8) |
        ((uint32_t)bytes[2] << 16) |
        ((uint32_t)bytes[3] << 24);
}

static BOOL MTZIPReadExactly(int descriptor,
                             void *buffer,
                             size_t length,
                             uint64_t offset,
                             NSError **error) {
    unsigned char *cursor = buffer;
    size_t remaining = length;
    while (remaining > 0) {
        ssize_t count = pread(descriptor, cursor, remaining, (off_t)offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) {
            return MTZIPSetError(error, MTSafeZIPArchiveReaderErrorIO,
                @"Unable to read the private archive copy.", nil,
                MTZIPPOSIXError(count == 0 ? EIO : errno));
        }
        cursor += (size_t)count;
        remaining -= (size_t)count;
        offset += (uint64_t)count;
    }
    return YES;
}

static BOOL MTZIPStatIsStable(const struct stat *before,
                              const struct stat *after) {
    return before->st_dev == after->st_dev &&
        before->st_ino == after->st_ino &&
        before->st_mode == after->st_mode &&
        before->st_size == after->st_size &&
        before->st_mtimespec.tv_sec == after->st_mtimespec.tv_sec &&
        before->st_mtimespec.tv_nsec == after->st_mtimespec.tv_nsec &&
        before->st_ctimespec.tv_sec == after->st_ctimespec.tv_sec &&
        before->st_ctimespec.tv_nsec == after->st_ctimespec.tv_nsec;
}

static NSString *MTZIPFoldedPath(NSString *path) {
    return [path stringByFoldingWithOptions:NSCaseInsensitiveSearch
                                     locale:[NSLocale
        localeWithLocaleIdentifier:@"en_US_POSIX"]];
}

static BOOL MTZIPPathIsPackagingArtifact(NSString *path) {
    NSArray<NSString *> *components = [path componentsSeparatedByString:@"/"];
    for (NSString *component in components) {
        if ([component caseInsensitiveCompare:@"__MACOSX"] ==
                NSOrderedSame) {
            return YES;
        }
    }
    NSString *name = components.lastObject ?: @"";
    return [name hasPrefix:@"._"] ||
        [name caseInsensitiveCompare:@".DS_Store"] == NSOrderedSame;
}

static NSString *_Nullable MTZIPNormalizedPath(NSString *rawPath,
                                                BOOL directory,
                                                MTImportLimits *limits,
                                                NSError **error) {
    if (![rawPath isKindOfClass:NSString.class] || rawPath.length == 0 ||
        [rawPath hasPrefix:@"/"] || [rawPath containsString:@"\\"] ||
        [rawPath rangeOfString:@"\0"].location != NSNotFound) {
        MTZIPSetError(error, MTSafeZIPArchiveReaderErrorUnsafePath,
            @"Archive contains an absolute or malformed path.", nil, nil);
        return nil;
    }
    NSArray<NSString *> *rawComponents =
        [rawPath componentsSeparatedByString:@"/"];
    if (directory && rawComponents.count > 0 &&
        rawComponents.lastObject.length == 0) {
        rawComponents = [rawComponents
            subarrayWithRange:NSMakeRange(0, rawComponents.count - 1)];
    }
    if (rawComponents.count == 0 ||
        rawComponents.count > limits.maximumPathDepth) {
        MTZIPSetError(error, MTSafeZIPArchiveReaderErrorLimitExceeded,
            @"Archive path exceeds the configured depth limit.", nil, nil);
        return nil;
    }
    NSMutableArray<NSString *> *normalizedComponents =
        [NSMutableArray arrayWithCapacity:rawComponents.count];
    for (NSString *component in rawComponents) {
        NSString *normalized =
            [component precomposedStringWithCanonicalMapping];
        if (normalized.length == 0 || [normalized isEqualToString:@"."] ||
            [normalized isEqualToString:@".."] ||
            [normalized containsString:@"/"] ||
            [normalized containsString:@"\\"]) {
            MTZIPSetError(error, MTSafeZIPArchiveReaderErrorUnsafePath,
                @"Archive contains an empty or unsafe path component.", nil,
                nil);
            return nil;
        }
        for (NSUInteger index = 0; index < normalized.length; index++) {
            unichar character = [normalized characterAtIndex:index];
            if (character == 0 || character < 0x20 || character == 0x7f) {
                MTZIPSetError(error, MTSafeZIPArchiveReaderErrorUnsafePath,
                    @"Archive path contains a control character.", nil, nil);
                return nil;
            }
        }
        [normalizedComponents addObject:normalized];
    }
    NSString *path = [normalizedComponents componentsJoinedByString:@"/"];
    if ([path lengthOfBytesUsingEncoding:NSUTF8StringEncoding] >
            limits.maximumPathUTF8Bytes) {
        MTZIPSetError(error, MTSafeZIPArchiveReaderErrorLimitExceeded,
            @"Archive path exceeds the configured UTF-8 byte limit.", nil,
            nil);
        return nil;
    }
    return path;
}

static BOOL MTZIPRegisterPath(NSString *path,
                              NSString *rawPath,
                              BOOL directory,
                              MTZIPPathState *state,
                              NSError **error) {
    NSString *folded = MTZIPFoldedPath(path);
    if (state.rawPaths[folded] != nil) {
        return MTZIPSetError(error,
            MTSafeZIPArchiveReaderErrorCanonicalCollision,
            @"Archive paths collide after Unicode normalization or case folding.",
            path, nil);
    }
    NSArray<NSString *> *components = [path componentsSeparatedByString:@"/"];
    NSMutableArray<NSString *> *ancestors = [NSMutableArray array];
    for (NSUInteger index = 0; index + 1 < components.count; index++) {
        [ancestors addObject:components[index]];
        NSString *ancestorKey = MTZIPFoldedPath(
            [ancestors componentsJoinedByString:@"/"]);
        NSNumber *ancestorDirectory = state.directoryByKey[ancestorKey];
        if (ancestorDirectory != nil && !ancestorDirectory.boolValue) {
            return MTZIPSetError(error,
                MTSafeZIPArchiveReaderErrorCanonicalCollision,
                @"Archive treats a regular file as a parent directory.", path,
                nil);
        }
        [state.keysWithDescendants addObject:ancestorKey];
    }
    if (!directory && [state.keysWithDescendants containsObject:folded]) {
        return MTZIPSetError(error,
            MTSafeZIPArchiveReaderErrorCanonicalCollision,
            @"Archive path collides with an existing child path.", path, nil);
    }
    state.rawPaths[folded] = rawPath;
    state.directoryByKey[folded] = @(directory);
    return YES;
}

static BOOL MTZIPPathLooksLikeNestedArchive(NSString *path) {
    static NSSet<NSString *> *extensions;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        extensions = [NSSet setWithArray:@[
            @"zip", @"7z", @"rar", @"tar", @"tgz", @"tbz", @"tbz2",
            @"txz", @"gz", @"bz2", @"xz", @"lzh", @"cab", @"ipa",
            @"deb",
        ]];
    });
    return [extensions containsObject:path.pathExtension.lowercaseString];
}

static BOOL MTZIPPrefixLooksLikeNestedArchive(NSData *prefix) {
    const unsigned char *bytes = prefix.bytes;
    NSUInteger length = prefix.length;
    if (length >= 4 && bytes[0] == 0x50 && bytes[1] == 0x4b &&
        ((bytes[2] == 0x03 && bytes[3] == 0x04) ||
         (bytes[2] == 0x05 && bytes[3] == 0x06) ||
         (bytes[2] == 0x07 && bytes[3] == 0x08))) return YES;
    if (length >= 6 && memcmp(bytes, "7z\xbc\xaf\x27\x1c", 6) == 0) return YES;
    if (length >= 7 && memcmp(bytes, "Rar!\x1a\x07", 6) == 0) return YES;
    if (length >= 3 && bytes[0] == 0x1f && bytes[1] == 0x8b &&
        bytes[2] == 0x08) return YES;
    if (length >= 3 && memcmp(bytes, "BZh", 3) == 0) return YES;
    static const unsigned char xz[] = {0xfd, '7', 'z', 'X', 'Z', 0x00};
    return length >= sizeof(xz) && memcmp(bytes, xz, sizeof(xz)) == 0;
}

static BOOL MTZIPExpansionRatioExceeded(uint64_t expanded,
                                        uint64_t compressed,
                                        uint64_t maximumRatio) {
    if (expanded == 0) return NO;
    if (compressed == 0) return YES;
    if (compressed > UINT64_MAX / maximumRatio) return NO;
    return expanded > compressed * maximumRatio;
}

static BOOL MTZIPValidateExtraFields(NSData *extra, NSError **error) {
    const unsigned char *bytes = extra.bytes;
    NSUInteger offset = 0;
    while (offset < extra.length) {
        if (extra.length - offset < 4) {
            return MTZIPSetError(error,
                MTSafeZIPArchiveReaderErrorCorruptArchive,
                @"Archive contains a truncated ZIP extra field.", nil, nil);
        }
        uint16_t identifier = MTZIPReadLE16(bytes + offset);
        uint16_t length = MTZIPReadLE16(bytes + offset + 2);
        offset += 4;
        if (length > extra.length - offset) {
            return MTZIPSetError(error,
                MTSafeZIPArchiveReaderErrorCorruptArchive,
                @"Archive contains an invalid ZIP extra-field length.", nil,
                nil);
        }
        if (identifier == MTZIPExtraZIP64 || identifier == MTZIPExtraAES) {
            return MTZIPSetError(error,
                MTSafeZIPArchiveReaderErrorUnsupportedFeature,
                @"ZIP64 and encrypted ZIP extensions are not supported.", nil,
                nil);
        }
        offset += length;
    }
    return YES;
}

static NSString *_Nullable MTZIPDecodeName(NSData *nameData,
                                            uint16_t flags,
                                            NSError **error) {
    if (nameData.length == 0) {
        MTZIPSetError(error, MTSafeZIPArchiveReaderErrorUnsafePath,
            @"Archive contains an empty entry name.", nil, nil);
        return nil;
    }
    const unsigned char *bytes = nameData.bytes;
    BOOL ascii = YES;
    for (NSUInteger index = 0; index < nameData.length; index++) {
        if (bytes[index] == 0) {
            MTZIPSetError(error, MTSafeZIPArchiveReaderErrorUnsafePath,
                @"Archive entry name contains NUL.", nil, nil);
            return nil;
        }
        if (bytes[index] >= 0x80) ascii = NO;
    }
    NSStringEncoding encoding = ascii
        ? NSASCIIStringEncoding : NSUTF8StringEncoding;
    NSString *name = [[NSString alloc] initWithData:nameData encoding:encoding];
    if (name == nil) {
        BOOL declaredUTF8 = (flags & MTZIPFlagUTF8) != 0;
        MTZIPSetError(error,
            declaredUTF8 ? MTSafeZIPArchiveReaderErrorUnsafePath
                         : MTSafeZIPArchiveReaderErrorUnsupportedFeature,
            declaredUTF8
                ? @"Archive entry name is not valid UTF-8."
                : @"Legacy ZIP names must contain ASCII or strict UTF-8 bytes.",
            nil, nil);
    }
    return name;
}

static BOOL MTZIPValidateLocalHeader(int descriptor,
                                     uint64_t centralOffset,
                                     NSData *centralName,
                                     uint16_t flags,
                                     uint16_t method,
                                     uint32_t crc32,
                                     uint32_t compressedBytes,
                                     uint32_t expandedBytes,
                                     uint32_t localOffset,
                                     MTZIPPlanEntry *plan,
                                     NSError **error) {
    unsigned char header[30];
    if ((uint64_t)localOffset + sizeof(header) > centralOffset ||
        !MTZIPReadExactly(descriptor, header, sizeof(header), localOffset,
                          error)) {
        if (error != NULL && *error == nil) {
            MTZIPSetError(error, MTSafeZIPArchiveReaderErrorCorruptArchive,
                @"ZIP local header lies outside the payload region.", nil,
                nil);
        }
        return NO;
    }
    if (MTZIPReadLE32(header) != MTZIPLocalHeaderSignature) {
        return MTZIPSetError(error,
            MTSafeZIPArchiveReaderErrorCorruptArchive,
            @"ZIP local-header signature is invalid.", plan.relativePath,
            nil);
    }
    uint16_t localFlags = MTZIPReadLE16(header + 6);
    uint16_t localMethod = MTZIPReadLE16(header + 8);
    uint32_t localCRC = MTZIPReadLE32(header + 14);
    uint32_t localCompressed = MTZIPReadLE32(header + 18);
    uint32_t localExpanded = MTZIPReadLE32(header + 22);
    uint16_t nameLength = MTZIPReadLE16(header + 26);
    uint16_t extraLength = MTZIPReadLE16(header + 28);
    uint64_t variableStart = (uint64_t)localOffset + sizeof(header);
    uint64_t dataStart = variableStart + nameLength + extraLength;
    uint64_t dataEnd = dataStart + compressedBytes;
    if (localFlags != flags || localMethod != method ||
        nameLength != centralName.length || dataStart < variableStart ||
        dataEnd < dataStart || dataEnd > centralOffset) {
        return MTZIPSetError(error,
            MTSafeZIPArchiveReaderErrorCorruptArchive,
            @"ZIP local and central headers disagree.", plan.relativePath,
            nil);
    }
    NSMutableData *localName = [NSMutableData dataWithLength:nameLength];
    if (!MTZIPReadExactly(descriptor, localName.mutableBytes, nameLength,
                          variableStart, error) ||
        ![localName isEqualToData:centralName]) {
        if (error != NULL && *error == nil) {
            MTZIPSetError(error, MTSafeZIPArchiveReaderErrorCorruptArchive,
                @"ZIP local and central entry names disagree.",
                plan.relativePath, nil);
        }
        return NO;
    }
    NSMutableData *localExtra = [NSMutableData dataWithLength:extraLength];
    if (extraLength > 0 &&
        (!MTZIPReadExactly(descriptor, localExtra.mutableBytes, extraLength,
                          variableStart + nameLength, error) ||
         !MTZIPValidateExtraFields(localExtra, error))) {
        return NO;
    }
    if ((flags & MTZIPFlagDataDescriptor) == 0 &&
        (localCRC != crc32 || localCompressed != compressedBytes ||
         localExpanded != expandedBytes)) {
        return MTZIPSetError(error,
            MTSafeZIPArchiveReaderErrorCorruptArchive,
            @"ZIP local size or checksum metadata is inconsistent.",
            plan.relativePath, nil);
    }
    plan.localStart = localOffset;
    plan.localDataStart = dataStart;
    plan.localDataEnd = dataEnd;
    return YES;
}

static NSArray<MTZIPPlanEntry *> *_Nullable MTZIPBuildPlan(
    int descriptor,
    uint64_t fileSize,
    MTImportLimits *limits,
    MTImportCancellationToken *_Nullable cancellationToken,
    uint64_t *totalCompressedBytes,
    NSError **error) {
    if (cancellationToken.isCancelled) {
        MTZIPSetError(error, MTSafeZIPArchiveReaderErrorCancelled,
            @"Archive inspection was cancelled before preflight.", nil, nil);
        return nil;
    }
    uint64_t tailLength = MIN(fileSize, MTZIPMaximumEndSearchBytes);
    uint64_t tailStart = fileSize - tailLength;
    NSMutableData *tail = [NSMutableData dataWithLength:(NSUInteger)tailLength];
    if (!MTZIPReadExactly(descriptor, tail.mutableBytes, tail.length, tailStart,
                          error)) return nil;
    const unsigned char *tailBytes = tail.bytes;
    uint64_t endOffset = UINT64_MAX;
    for (NSInteger index = (NSInteger)tail.length - 22; index >= 0; index--) {
        if (MTZIPReadLE32(tailBytes + index) != MTZIPEndSignature) continue;
        uint16_t commentLength = MTZIPReadLE16(tailBytes + index + 20);
        uint64_t candidate = tailStart + (uint64_t)index;
        if (candidate + 22 + commentLength == fileSize) {
            endOffset = candidate;
            break;
        }
    }
    if (endOffset == UINT64_MAX) {
        MTZIPSetError(error, MTSafeZIPArchiveReaderErrorCorruptArchive,
            @"ZIP end record is missing or has trailing data.", nil, nil);
        return nil;
    }
    const unsigned char *end = tailBytes + (NSUInteger)(endOffset - tailStart);
    uint16_t diskNumber = MTZIPReadLE16(end + 4);
    uint16_t centralDisk = MTZIPReadLE16(end + 6);
    uint16_t diskEntries = MTZIPReadLE16(end + 8);
    uint16_t entryCount = MTZIPReadLE16(end + 10);
    uint32_t centralSize = MTZIPReadLE32(end + 12);
    uint32_t centralOffset = MTZIPReadLE32(end + 16);
    if (diskNumber != 0 || centralDisk != 0 || diskEntries != entryCount ||
        entryCount == UINT16_MAX || centralSize == UINT32_MAX ||
        centralOffset == UINT32_MAX) {
        MTZIPSetError(error,
            MTSafeZIPArchiveReaderErrorUnsupportedFeature,
            @"Multi-disk and ZIP64 archives are not supported.", nil, nil);
        return nil;
    }
    if (entryCount == 0 || entryCount > limits.maximumArchiveEntries) {
        MTZIPSetError(error, MTSafeZIPArchiveReaderErrorLimitExceeded,
            @"Archive entry count is empty or exceeds the configured limit.",
            nil, nil);
        return nil;
    }
    uint64_t centralEnd = (uint64_t)centralOffset + centralSize;
    if (centralEnd < centralOffset || centralEnd != endOffset) {
        MTZIPSetError(error, MTSafeZIPArchiveReaderErrorCorruptArchive,
            @"ZIP central directory has an invalid boundary.", nil, nil);
        return nil;
    }

    NSMutableArray<MTZIPPlanEntry *> *plans =
        [NSMutableArray arrayWithCapacity:entryCount];
    MTZIPPathState *pathState = [[MTZIPPathState alloc] init];
    uint64_t totalCompressed = 0;
    uint64_t totalExpanded = 0;
    NSUInteger regularFiles = 0;
    NSUInteger contentRegularFiles = 0;
    uint64_t cursor = centralOffset;
    for (NSUInteger index = 0; index < entryCount; index++) {
        if (cancellationToken.isCancelled) {
            MTZIPSetError(error, MTSafeZIPArchiveReaderErrorCancelled,
                @"Archive inspection was cancelled during preflight.", nil,
                nil);
            return nil;
        }
        unsigned char header[46];
        if (cursor + sizeof(header) > centralEnd ||
            !MTZIPReadExactly(descriptor, header, sizeof(header), cursor,
                              error)) return nil;
        if (MTZIPReadLE32(header) != MTZIPCentralHeaderSignature) {
            MTZIPSetError(error, MTSafeZIPArchiveReaderErrorCorruptArchive,
                @"ZIP central-directory signature is invalid.", nil, nil);
            return nil;
        }
        uint16_t madeBy = MTZIPReadLE16(header + 4);
        uint16_t needed = MTZIPReadLE16(header + 6);
        uint16_t flags = MTZIPReadLE16(header + 8);
        uint16_t method = MTZIPReadLE16(header + 10);
        uint32_t crc32 = MTZIPReadLE32(header + 16);
        uint32_t compressed = MTZIPReadLE32(header + 20);
        uint32_t expanded = MTZIPReadLE32(header + 24);
        uint16_t nameLength = MTZIPReadLE16(header + 28);
        uint16_t extraLength = MTZIPReadLE16(header + 30);
        uint16_t commentLength = MTZIPReadLE16(header + 32);
        uint16_t diskStart = MTZIPReadLE16(header + 34);
        uint32_t externalAttributes = MTZIPReadLE32(header + 38);
        uint32_t localOffset = MTZIPReadLE32(header + 42);
        uint64_t recordLength = sizeof(header) + (uint64_t)nameLength +
            extraLength + commentLength;
        if (recordLength < sizeof(header) || recordLength > centralEnd - cursor) {
            MTZIPSetError(error, MTSafeZIPArchiveReaderErrorCorruptArchive,
                @"ZIP central-directory record is truncated.", nil, nil);
            return nil;
        }
        uint16_t allowedFlags = MTZIPFlagDataDescriptor | MTZIPFlagUTF8;
        if (method == MTZIPMethodDeflate) allowedFlags |= 0x0006;
        if ((flags & (MTZIPFlagEncrypted | MTZIPFlagStrongEncryption |
                      MTZIPFlagMaskedHeader)) != 0 ||
            (flags & ~allowedFlags) != 0) {
            MTZIPSetError(error,
                MTSafeZIPArchiveReaderErrorUnsupportedFeature,
                @"Encrypted or unsupported ZIP entry flags were found.", nil,
                nil);
            return nil;
        }
        if ((method != MTZIPMethodStored && method != MTZIPMethodDeflate) ||
            needed > 63 || diskStart != 0 || compressed == UINT32_MAX ||
            expanded == UINT32_MAX || localOffset == UINT32_MAX) {
            MTZIPSetError(error,
                MTSafeZIPArchiveReaderErrorUnsupportedFeature,
                @"Archive uses an unsupported ZIP feature or compression method.",
                nil, nil);
            return nil;
        }
        if (method == MTZIPMethodStored && compressed != expanded) {
            MTZIPSetError(error, MTSafeZIPArchiveReaderErrorCorruptArchive,
                @"Stored ZIP entry has inconsistent sizes.", nil, nil);
            return nil;
        }
        NSMutableData *nameData = [NSMutableData dataWithLength:nameLength];
        NSMutableData *extraData = [NSMutableData dataWithLength:extraLength];
        uint64_t variableOffset = cursor + sizeof(header);
        if (!MTZIPReadExactly(descriptor, nameData.mutableBytes, nameLength,
                              variableOffset, error) ||
            (extraLength > 0 && !MTZIPReadExactly(descriptor,
                extraData.mutableBytes, extraLength,
                variableOffset + nameLength, error)) ||
            !MTZIPValidateExtraFields(extraData, error)) return nil;
        NSString *rawPath = MTZIPDecodeName(nameData, flags, error);
        if (rawPath == nil) return nil;

        mode_t unixMode = ((madeBy >> 8) == 3)
            ? (mode_t)(externalAttributes >> 16) : 0;
        mode_t unixType = unixMode & S_IFMT;
        BOOL trailingDirectory = [rawPath hasSuffix:@"/"];
        BOOL dosDirectory = (externalAttributes & 0x10) != 0;
        if (unixType != 0 && unixType != S_IFREG && unixType != S_IFDIR) {
            MTZIPSetError(error, MTSafeZIPArchiveReaderErrorUnsupportedNode,
                @"Archive contains a link or special filesystem node.", nil,
                nil);
            return nil;
        }
        if (unixType == S_IFREG && (trailingDirectory || dosDirectory)) {
            MTZIPSetError(error, MTSafeZIPArchiveReaderErrorCorruptArchive,
                @"Archive entry type metadata is inconsistent.", nil, nil);
            return nil;
        }
        BOOL directory = unixType == S_IFDIR || trailingDirectory || dosDirectory;
        NSString *path = MTZIPNormalizedPath(rawPath, directory, limits, error);
        if (path == nil || !MTZIPRegisterPath(path, rawPath, directory,
                                               pathState, error)) return nil;
        BOOL packagingArtifact = MTZIPPathIsPackagingArtifact(path);
        if (directory && (compressed != 0 || expanded != 0)) {
            MTZIPSetError(error, MTSafeZIPArchiveReaderErrorUnsupportedNode,
                @"Archive directory entry unexpectedly contains data.", path,
                nil);
            return nil;
        }
        if (!directory && (unixMode & (S_ISUID | S_ISGID)) != 0) {
            MTZIPSetError(error, MTSafeZIPArchiveReaderErrorUnsupportedNode,
                @"Archive contains set-user-ID or set-group-ID permissions.",
                path, nil);
            return nil;
        }
        if (!directory && !packagingArtifact &&
            MTZIPPathLooksLikeNestedArchive(path)) {
            MTZIPSetError(error, MTSafeZIPArchiveReaderErrorNestedArchive,
                @"Nested archives are not accepted as theme content.", path,
                nil);
            return nil;
        }
        if (!directory) {
            regularFiles++;
            if (!packagingArtifact) contentRegularFiles++;
            if (regularFiles > limits.maximumRegularFiles ||
                expanded > limits.maximumSingleFileBytes ||
                expanded > limits.maximumExpandedBytes - totalExpanded ||
                compressed > UINT64_MAX - totalCompressed ||
                MTZIPExpansionRatioExceeded(expanded, compressed,
                    limits.maximumArchiveExpansionRatio)) {
                MTZIPSetError(error,
                    MTSafeZIPArchiveReaderErrorLimitExceeded,
                    @"Archive exceeds a file-count, byte, or expansion-ratio limit.",
                    path, nil);
                return nil;
            }
            totalExpanded += expanded;
            totalCompressed += compressed;
        }
        MTZIPPlanEntry *plan = [[MTZIPPlanEntry alloc] init];
        plan.relativePath = path;
        plan.directory = directory;
        plan.method = method;
        plan.crc32 = crc32;
        plan.compressedBytes = compressed;
        plan.expandedBytes = expanded;
        plan.mode = unixMode;
        plan.packagingArtifact = packagingArtifact;
        if (!MTZIPValidateLocalHeader(descriptor, centralOffset, nameData,
                flags, method, crc32, compressed, expanded, localOffset, plan,
                error)) return nil;
        [plans addObject:plan];
        cursor += recordLength;
    }
    if (cursor != centralEnd || regularFiles == 0 || contentRegularFiles == 0 ||
        MTZIPExpansionRatioExceeded(totalExpanded, totalCompressed,
            limits.maximumArchiveExpansionRatio)) {
        MTZIPSetError(error, MTSafeZIPArchiveReaderErrorLimitExceeded,
            @"Archive is empty, malformed, or exceeds the total expansion ratio.",
            nil, nil);
        return nil;
    }
    NSArray<MTZIPPlanEntry *> *byLocalOffset = [plans
        sortedArrayUsingComparator:^NSComparisonResult(MTZIPPlanEntry *left,
                                                       MTZIPPlanEntry *right) {
            if (left.localStart < right.localStart) return NSOrderedAscending;
            if (left.localStart > right.localStart) return NSOrderedDescending;
            return NSOrderedSame;
        }];
    uint64_t priorEnd = 0;
    for (MTZIPPlanEntry *plan in byLocalOffset) {
        if (plan.localStart < priorEnd) {
            MTZIPSetError(error, MTSafeZIPArchiveReaderErrorCorruptArchive,
                @"ZIP local entry regions overlap.", plan.relativePath, nil);
            return nil;
        }
        priorEnd = plan.localDataEnd;
    }
    if (totalCompressedBytes != NULL) *totalCompressedBytes = totalCompressed;
    return plans;
}

static BOOL MTZIPLoadArchiveSymbol(void *handle,
                                   const char *name,
                                   void *destination,
                                   size_t destinationSize) {
    void *symbol = dlsym(handle, name);
    if (symbol == NULL || destinationSize != sizeof(symbol)) return NO;
    memcpy(destination, &symbol, sizeof(symbol));
    return YES;
}

static BOOL MTZIPLoadArchiveAPI(MTArchiveAPI *api, NSError **error) {
    memset(api, 0, sizeof(*api));
    api->handle = dlopen("/usr/lib/libarchive.2.dylib", RTLD_LOCAL | RTLD_LAZY);
    if (api->handle == NULL) {
        return MTZIPSetError(error,
            MTSafeZIPArchiveReaderErrorUnsupportedFeature,
            @"The system ZIP reader is unavailable.", nil, nil);
    }
#define MTZIP_LOAD(field, symbol) \
    MTZIPLoadArchiveSymbol(api->handle, symbol, &api->field, sizeof(api->field))
    BOOL loaded =
        MTZIP_LOAD(readNew, "archive_read_new") &&
        MTZIP_LOAD(readSupportFilterNone, "archive_read_support_filter_none") &&
        MTZIP_LOAD(readSupportFormatZIP, "archive_read_support_format_zip") &&
        MTZIP_LOAD(readOpenFD, "archive_read_open_fd") &&
        MTZIP_LOAD(readNextHeader, "archive_read_next_header") &&
        MTZIP_LOAD(readData, "archive_read_data") &&
        MTZIP_LOAD(readDataSkip, "archive_read_data_skip") &&
        MTZIP_LOAD(errorString, "archive_error_string") &&
        MTZIP_LOAD(readFree, "archive_read_free") &&
        MTZIP_LOAD(entryPathnameUTF8, "archive_entry_pathname_utf8") &&
        MTZIP_LOAD(entryPathname, "archive_entry_pathname") &&
        MTZIP_LOAD(entryFiletype, "archive_entry_filetype") &&
        MTZIP_LOAD(entryMode, "archive_entry_mode") &&
        MTZIP_LOAD(entrySize, "archive_entry_size") &&
        MTZIP_LOAD(entryIsEncrypted, "archive_entry_is_encrypted");
#undef MTZIP_LOAD
    if (!loaded) {
        dlclose(api->handle);
        memset(api, 0, sizeof(*api));
        return MTZIPSetError(error,
            MTSafeZIPArchiveReaderErrorUnsupportedFeature,
            @"The system ZIP reader lacks required streaming symbols.", nil,
            nil);
    }
    return YES;
}

static void MTZIPCloseArchiveAPI(MTArchiveAPI *api) {
    if (api->handle != NULL) dlclose(api->handle);
    memset(api, 0, sizeof(*api));
}

static NSString *MTZIPHexDigest(const unsigned char *digest) {
    static const char digits[] = "0123456789abcdef";
    char output[CC_SHA256_DIGEST_LENGTH * 2 + 1] = {0};
    for (NSUInteger index = 0; index < CC_SHA256_DIGEST_LENGTH; index++) {
        output[index * 2] = digits[(digest[index] >> 4) & 0x0f];
        output[index * 2 + 1] = digits[digest[index] & 0x0f];
    }
    return [NSString stringWithUTF8String:output];
}

static MTSourceInventory *_Nullable MTZIPStreamInventory(
    int descriptor,
    NSArray<MTZIPPlanEntry *> *plans,
    MTImportLimits *limits,
    MTImportCancellationToken *_Nullable cancellationToken,
    NSError **error) {
    MTArchiveAPI api;
    if (!MTZIPLoadArchiveAPI(&api, error)) return nil;
    MTArchive *archive = api.readNew();
    if (archive == NULL) {
        MTZIPCloseArchiveAPI(&api);
        MTZIPSetError(error, MTSafeZIPArchiveReaderErrorIO,
            @"Unable to create a streaming ZIP reader.", nil, nil);
        return nil;
    }
    BOOL opened = api.readSupportFilterNone(archive) >= -20 &&
        api.readSupportFormatZIP(archive) >= -20 &&
        lseek(descriptor, 0, SEEK_SET) >= 0 &&
        api.readOpenFD(archive, descriptor, 64 * 1024) == 0;
    if (!opened) {
        api.readFree(archive);
        MTZIPCloseArchiveAPI(&api);
        MTZIPSetError(error, MTSafeZIPArchiveReaderErrorCorruptArchive,
            @"Unable to open the preflighted ZIP stream.", nil, nil);
        return nil;
    }
    NSMutableDictionary<NSString *, MTZIPPlanEntry *> *plansByPath =
        [NSMutableDictionary dictionaryWithCapacity:plans.count];
    for (MTZIPPlanEntry *plan in plans) plansByPath[plan.relativePath] = plan;
    NSMutableSet<NSString *> *seen = [NSMutableSet setWithCapacity:plans.count];
    NSMutableArray<MTSourceFile *> *files = [NSMutableArray array];
    uint64_t actualTotal = 0;
    BOOL success = YES;
    while (success) {
        if (cancellationToken.isCancelled) {
            success = MTZIPSetError(error,
                MTSafeZIPArchiveReaderErrorCancelled,
                @"Archive inspection was cancelled while streaming data.", nil,
                nil);
            break;
        }
        MTArchiveEntry *entry = NULL;
        int result = api.readNextHeader(archive, &entry);
        if (result == 1) break;
        if (result != 0 || entry == NULL) {
            success = MTZIPSetError(error,
                MTSafeZIPArchiveReaderErrorCorruptArchive,
                @"System ZIP reader rejected an archive entry.", nil, nil);
            break;
        }
        const char *pathBytes = api.entryPathnameUTF8(entry);
        if (pathBytes == NULL) pathBytes = api.entryPathname(entry);
        NSString *rawPath = pathBytes == NULL ? nil
            : [NSString stringWithUTF8String:pathBytes];
        mode_t type = api.entryFiletype(entry);
        if (type == 0) type = api.entryMode(entry) & S_IFMT;
        BOOL directory = type == S_IFDIR;
        if (type != S_IFREG && type != S_IFDIR) {
            success = MTZIPSetError(error,
                MTSafeZIPArchiveReaderErrorUnsupportedNode,
                @"Decoded archive contains a link or special node.", nil, nil);
            break;
        }
        NSError *pathError = nil;
        NSString *path = MTZIPNormalizedPath(rawPath, directory, limits,
                                              &pathError);
        MTZIPPlanEntry *plan = path == nil ? nil : plansByPath[path];
        if (path == nil || plan == nil || [seen containsObject:path] ||
            plan.isDirectory != directory) {
            success = MTZIPSetError(error,
                pathError == nil ? MTSafeZIPArchiveReaderErrorCorruptArchive
                                 : (MTSafeZIPArchiveReaderErrorCode)pathError.code,
                @"Decoded ZIP entries do not match the preflight plan.", path,
                pathError);
            break;
        }
        [seen addObject:path];
        int64_t declaredSize = api.entrySize(entry);
        mode_t decodedMode = api.entryMode(entry);
        if (api.entryIsEncrypted(entry) > 0 || declaredSize < 0 ||
            (uint64_t)declaredSize != plan.expandedBytes ||
            (!directory && (decodedMode & (S_ISUID | S_ISGID)) != 0)) {
            success = MTZIPSetError(error,
                MTSafeZIPArchiveReaderErrorUnsupportedNode,
                @"Decoded ZIP type, size, encryption, or mode is unsafe.", path,
                nil);
            break;
        }
        CC_SHA256_CTX digestContext;
        CC_SHA256_Init(&digestContext);
        NSMutableData *prefix = [NSMutableData dataWithCapacity:16];
        uint64_t actualBytes = 0;
        unsigned char buffer[64 * 1024];
        while (success) {
            if (cancellationToken.isCancelled) {
                success = MTZIPSetError(error,
                    MTSafeZIPArchiveReaderErrorCancelled,
                    @"Archive inspection was cancelled while decoding an entry.",
                    path, nil);
                break;
            }
            ssize_t count = api.readData(archive, buffer, sizeof(buffer));
            if (count < 0) {
                success = MTZIPSetError(error,
                    MTSafeZIPArchiveReaderErrorCorruptArchive,
                    @"ZIP entry data or checksum is corrupt.", path, nil);
                break;
            }
            if (count == 0) break;
            if (directory || (uint64_t)count > plan.expandedBytes - actualBytes ||
                (uint64_t)count > limits.maximumExpandedBytes - actualTotal) {
                success = MTZIPSetError(error,
                    MTSafeZIPArchiveReaderErrorLimitExceeded,
                    @"Decoded ZIP data exceeded its audited byte limit.", path,
                    nil);
                break;
            }
            NSUInteger prefixCount = MIN((NSUInteger)count,
                (NSUInteger)(16 - prefix.length));
            if (prefixCount > 0) [prefix appendBytes:buffer length:prefixCount];
            CC_SHA256_Update(&digestContext, buffer, (CC_LONG)count);
            actualBytes += (uint64_t)count;
            actualTotal += (uint64_t)count;
        }
        if (!success) break;
        if (actualBytes != plan.expandedBytes) {
            success = MTZIPSetError(error,
                MTSafeZIPArchiveReaderErrorCorruptArchive,
                @"Decoded ZIP entry size differs from its central directory.",
                path, nil);
            break;
        }
        if (directory) continue;
        if (!plan.isPackagingArtifact &&
            MTZIPPrefixLooksLikeNestedArchive(prefix)) {
            success = MTZIPSetError(error,
                MTSafeZIPArchiveReaderErrorNestedArchive,
                @"Nested archive content was detected by file signature.", path,
                nil);
            break;
        }
        unsigned char digest[CC_SHA256_DIGEST_LENGTH];
        CC_SHA256_Final(digest, &digestContext);
        if (!plan.isPackagingArtifact) {
            [files addObject:[[MTSourceFile alloc]
                initWithRelativePath:path
                           byteCount:actualBytes
                       contentSHA256:MTZIPHexDigest(digest)
                          prefixData:prefix]];
        }
    }
    if (success) {
        for (MTZIPPlanEntry *plan in plans) {
            if (!plan.isPackagingArtifact &&
                ![seen containsObject:plan.relativePath]) {
                success = MTZIPSetError(error,
                    MTSafeZIPArchiveReaderErrorCorruptArchive,
                    @"Decoded ZIP stream omitted a required preflighted entry.",
                    plan.relativePath, nil);
                break;
            }
        }
    }
    if (success && actualTotal > limits.maximumExpandedBytes) {
        success = MTZIPSetError(error,
            MTSafeZIPArchiveReaderErrorLimitExceeded,
            @"Decoded ZIP stream exceeded the audited byte limit.", nil,
            nil);
    }
    api.readFree(archive);
    MTZIPCloseArchiveAPI(&api);
    if (!success) return nil;
    NSError *inventoryError = nil;
    MTSourceInventory *inventory =
        [MTSourceInventory inventoryWithFiles:files error:&inventoryError];
    if (inventory == nil) {
        MTZIPSetError(error, MTSafeZIPArchiveReaderErrorIO,
            @"Unable to finalize the archive source inventory.", nil,
            inventoryError);
    }
    return inventory;
}

@implementation MTSafeZIPArchiveScan {
    NSURL *_archiveURL;
    MTImportLimits *_limits;
    NSDictionary<NSString *, MTZIPPlanEntry *> *_plansByPath;
    NSData *_sourceStatusData;
}

- (instancetype)initWithInventory:(MTSourceInventory *)inventory
                 archiveEntryCount:(NSUInteger)archiveEntryCount
              totalCompressedBytes:(uint64_t)totalCompressedBytes
                         archiveURL:(NSURL *)archiveURL
                             limits:(MTImportLimits *)limits
                              plans:(NSArray<MTZIPPlanEntry *> *)plans
                       sourceStatus:(const struct stat *)sourceStatus {
    self = [super init];
    if (self == nil) return nil;
    _inventory = inventory;
    _archiveEntryCount = archiveEntryCount;
    _totalCompressedBytes = totalCompressedBytes;
    _archiveURL = [archiveURL copy];
    _limits = limits;
    NSMutableDictionary<NSString *, MTZIPPlanEntry *> *plansByPath =
        [NSMutableDictionary dictionaryWithCapacity:plans.count];
    for (MTZIPPlanEntry *plan in plans) {
        plansByPath[plan.relativePath] = plan;
    }
    _plansByPath = [plansByPath copy];
    _sourceStatusData = [NSData dataWithBytes:sourceStatus
                                       length:sizeof(*sourceStatus)];
    return self;
}

- (NSData *)readFileDataAtRelativePath:(NSString *)relativePath
                       maximumByteCount:(uint64_t)maximumByteCount
                      cancellationToken:
                          (MTImportCancellationToken *)cancellationToken
                                  error:(NSError **)error {
    __block NSMutableData *data = [NSMutableData data];
    BOOL success = [self
        streamFileAtRelativePath:relativePath
                maximumByteCount:maximumByteCount
               cancellationToken:cancellationToken
                    byteConsumer:^BOOL(const void *bytes, NSUInteger length,
                                       NSError **consumerError) {
        if (length > NSUIntegerMax - data.length) {
            MTZIPSetAuditedReadError(consumerError,
                MTAuditedSourceErrorLimitExceeded,
                @"The audited file cannot fit in an immutable data snapshot.",
                relativePath, nil);
            return NO;
        }
        [data appendBytes:bytes length:length];
        return YES;
    }
                           error:error];
    return success ? [data copy] : nil;
}

- (BOOL)streamFileAtRelativePath:(NSString *)relativePath
                 maximumByteCount:(uint64_t)maximumByteCount
                cancellationToken:
                    (MTImportCancellationToken *)cancellationToken
                     byteConsumer:(MTAuditedSourceByteConsumer)byteConsumer
                            error:(NSError **)error {
    if (![relativePath isKindOfClass:NSString.class] ||
        relativePath.length == 0 || byteConsumer == nil) {
        MTZIPSetAuditedReadError(error,
            MTAuditedSourceErrorInvalidRequest,
            @"Audited source streams require a path and byte consumer.", nil,
            nil);
        return NO;
    }
    MTSourceFile *expected =
        [self.inventory fileAtRelativePath:relativePath];
    if (expected == nil) {
        MTZIPSetAuditedReadError(error,
            MTAuditedSourceErrorNotInventoried,
            @"The requested path was not admitted by the source audit.", nil,
            nil);
        return NO;
    }
    if (expected.byteCount > maximumByteCount ||
        expected.byteCount > _limits.maximumSingleFileBytes) {
        MTZIPSetAuditedReadError(error,
            MTAuditedSourceErrorLimitExceeded,
            @"The inventoried file exceeds the caller's stream limit.",
            expected.relativePath, nil);
        return NO;
    }
    MTZIPPlanEntry *targetPlan = _plansByPath[expected.relativePath];
    if (targetPlan == nil || targetPlan.isDirectory ||
        targetPlan.expandedBytes != expected.byteCount ||
        targetPlan.localDataEnd < targetPlan.localDataStart ||
        targetPlan.localDataEnd - targetPlan.localDataStart !=
            targetPlan.compressedBytes) {
        MTZIPSetAuditedReadError(error,
            MTAuditedSourceErrorCorruptSource,
            @"The source audit no longer has a valid archive-plan binding.",
            expected.relativePath, nil);
        return NO;
    }
    if (cancellationToken.isCancelled) {
        MTZIPSetAuditedReadError(error, MTAuditedSourceErrorCancelled,
            @"The audited source stream was cancelled before opening data.",
            expected.relativePath, nil);
        return NO;
    }

    int descriptor = open(_archiveURL.path.fileSystemRepresentation,
        O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (descriptor < 0) {
        int savedError = errno;
        MTZIPSetAuditedReadError(error,
            MTAuditedSourceErrorSourceChanged,
            @"The audited archive is no longer available.",
            expected.relativePath, MTZIPPOSIXError(savedError));
        return NO;
    }
    struct stat auditedStatus = {0};
    struct stat openedStatus = {0};
    [_sourceStatusData getBytes:&auditedStatus length:sizeof(auditedStatus)];
    if (fstat(descriptor, &openedStatus) != 0 ||
        !S_ISREG(openedStatus.st_mode) || openedStatus.st_nlink != 1 ||
        openedStatus.st_uid != geteuid() ||
        !MTZIPStatIsStable(&auditedStatus, &openedStatus)) {
        close(descriptor);
        MTZIPSetAuditedReadError(error,
            MTAuditedSourceErrorSourceChanged,
            @"The audited archive identity changed before the stream.",
            expected.relativePath, nil);
        return NO;
    }

    BOOL success = MTAuditedZIPStreamEntry(descriptor,
        targetPlan.relativePath,
        (MTAuditedZIPCompressionMethod)targetPlan.method,
        targetPlan.crc32, targetPlan.compressedBytes,
        targetPlan.expandedBytes, targetPlan.localDataStart,
        expected.contentSHA256, maximumByteCount, cancellationToken,
        byteConsumer, error);
    struct stat finalStatus = {0};
    BOOL sourceStable = fstat(descriptor, &finalStatus) == 0 &&
        MTZIPStatIsStable(&auditedStatus, &finalStatus);
    close(descriptor);
    if (!sourceStable || cancellationToken.isCancelled) {
        MTZIPSetAuditedReadError(error,
            cancellationToken.isCancelled ? MTAuditedSourceErrorCancelled
                                           : MTAuditedSourceErrorSourceChanged,
            cancellationToken.isCancelled
                ? @"The audited source stream was cancelled before validation."
                : @"The audited archive changed while data was being streamed.",
            expected.relativePath, nil);
        return NO;
    }
    if (!success) {
        if (error == NULL || *error == nil) {
            MTZIPSetAuditedReadError(error, MTAuditedSourceErrorIO,
                @"The byte consumer rejected audited source data.",
                expected.relativePath, nil);
        }
        return NO;
    }
    return YES;
}

@end

@implementation MTSafeZIPArchiveReader

- (instancetype)initWithLimits:(MTImportLimits *)limits {
    NSParameterAssert(limits != nil);
    self = [super init];
    if (self == nil) return nil;
    _limits = limits;
    return self;
}

- (MTSafeZIPArchiveScan *)scanArchiveAtURL:(NSURL *)archiveURL
                         cancellationToken:
                             (MTImportCancellationToken *)cancellationToken
                                     error:(NSError **)error {
    if (![archiveURL isKindOfClass:NSURL.class] || !archiveURL.isFileURL ||
        archiveURL.path.length == 0) {
        MTZIPSetError(error, MTSafeZIPArchiveReaderErrorInvalidInput,
            @"Archive input must be a local file URL.", nil, nil);
        return nil;
    }
    int descriptor = open(archiveURL.path.fileSystemRepresentation,
        O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (descriptor < 0) {
        MTZIPSetError(error, MTSafeZIPArchiveReaderErrorInvalidInput,
            @"Archive input is not a safely readable regular file.", nil,
            MTZIPPOSIXError(errno));
        return nil;
    }
    struct stat before = {0};
    if (fstat(descriptor, &before) != 0 || !S_ISREG(before.st_mode) ||
        before.st_nlink != 1 || before.st_uid != geteuid() ||
        before.st_size < 22 ||
        (uint64_t)before.st_size > self.limits.maximumSourceBytes) {
        int savedError = errno;
        close(descriptor);
        MTZIPSetError(error, MTSafeZIPArchiveReaderErrorInvalidInput,
            @"Archive copy has an unsafe identity, owner, size, or node type.",
            nil, savedError == 0 ? nil : MTZIPPOSIXError(savedError));
        return nil;
    }
    uint64_t totalCompressed = 0;
    NSArray<MTZIPPlanEntry *> *plans = MTZIPBuildPlan(descriptor,
        (uint64_t)before.st_size, self.limits, cancellationToken,
        &totalCompressed, error);
    MTSourceInventory *inventory = plans == nil ? nil
        : MTZIPStreamInventory(descriptor, plans, self.limits,
                               cancellationToken, error);
    struct stat after = {0};
    BOOL statOK = fstat(descriptor, &after) == 0;
    close(descriptor);
    if (plans == nil || inventory == nil) return nil;
    if (!statOK || !MTZIPStatIsStable(&before, &after)) {
        MTZIPSetError(error, MTSafeZIPArchiveReaderErrorIO,
            @"Archive copy changed while it was being inspected.", nil, nil);
        return nil;
    }
    return [[MTSafeZIPArchiveScan alloc]
        initWithInventory:inventory
        archiveEntryCount:plans.count
        totalCompressedBytes:totalCompressed
        archiveURL:archiveURL
        limits:self.limits
        plans:plans
        sourceStatus:&after];
}

@end
