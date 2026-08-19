#import "MTExpandedArchiveSession.h"

#import <dlfcn.h>
#import <errno.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <sys/types.h>
#import <unistd.h>

#import "MTImportSession.h"

NSString *const MTExpandedArchiveSessionErrorDomain =
    @"com.hmmzzz.marktheme.expanded-archive-session";

typedef struct archive MTExpandedArchive;
typedef struct archive_entry MTExpandedArchiveEntry;

typedef struct {
    void *handle;
    MTExpandedArchive *(*readNew)(void);
    int (*readSupportFilterAll)(MTExpandedArchive *archive);
    int (*readSupportFilterNone)(MTExpandedArchive *archive);
    int (*readSupportFormatTar)(MTExpandedArchive *archive);
    int (*readSupportFormatAr)(MTExpandedArchive *archive);
    int (*readOpenFD)(MTExpandedArchive *archive, int descriptor,
                      size_t blockSize);
    int (*readOpenMemory)(MTExpandedArchive *archive, const void *buffer,
                          size_t length);
    int (*readNextHeader)(MTExpandedArchive *archive,
                          MTExpandedArchiveEntry **entry);
    ssize_t (*readData)(MTExpandedArchive *archive, void *buffer,
                        size_t length);
    int (*readDataSkip)(MTExpandedArchive *archive);
    const char *(*errorString)(MTExpandedArchive *archive);
    int (*readFree)(MTExpandedArchive *archive);
    const char *(*entryPathnameUTF8)(MTExpandedArchiveEntry *entry);
    const char *(*entryPathname)(MTExpandedArchiveEntry *entry);
    mode_t (*entryFiletype)(MTExpandedArchiveEntry *entry);
    mode_t (*entryMode)(MTExpandedArchiveEntry *entry);
    int64_t (*entrySize)(MTExpandedArchiveEntry *entry);
    const char *(*entryHardlink)(MTExpandedArchiveEntry *entry);
    const char *(*entrySymlink)(MTExpandedArchiveEntry *entry);
} MTExpandedArchiveAPI;

static BOOL MTExpandedArchiveSetError(NSError **error,
                                      NSInteger code,
                                      NSString *description,
                                      NSString *_Nullable path,
                                      NSError *_Nullable underlying) {
    if (error != NULL) {
        NSMutableDictionary *userInfo = [NSMutableDictionary
            dictionaryWithObject:description forKey:NSLocalizedDescriptionKey];
        if (path.length > 0) userInfo[@"relativePath"] = path;
        if (underlying != nil) userInfo[NSUnderlyingErrorKey] = underlying;
        *error = [NSError errorWithDomain:MTExpandedArchiveSessionErrorDomain
                                     code:code
                                 userInfo:userInfo];
    }
    return NO;
}

static NSError *MTExpandedArchivePOSIXError(int value) {
    return [NSError errorWithDomain:NSPOSIXErrorDomain
                               code:value userInfo:nil];
}

static BOOL MTExpandedArchiveLoadSymbol(void *handle,
                                        const char *name,
                                        void *destination,
                                        size_t destinationSize) {
    void *symbol = dlsym(handle, name);
    if (symbol == NULL || destinationSize != sizeof(symbol)) return NO;
    memcpy(destination, &symbol, sizeof(symbol));
    return YES;
}

#define MT_EXPANDED_LOAD(api, field, symbol) \
    MTExpandedArchiveLoadSymbol((api)->handle, symbol, &(api)->field, \
                                sizeof((api)->field))

static BOOL MTExpandedArchiveLoadAPI(MTExpandedArchiveAPI *api,
                                     NSError **error) {
    memset(api, 0, sizeof(*api));
    api->handle = dlopen("/usr/lib/libarchive.2.dylib",
                         RTLD_LOCAL | RTLD_LAZY);
    if (api->handle == NULL ||
        !MT_EXPANDED_LOAD(api, readNew, "archive_read_new") ||
        !MT_EXPANDED_LOAD(api, readSupportFilterAll,
                          "archive_read_support_filter_all") ||
        !MT_EXPANDED_LOAD(api, readSupportFilterNone,
                          "archive_read_support_filter_none") ||
        !MT_EXPANDED_LOAD(api, readSupportFormatTar,
                          "archive_read_support_format_tar") ||
        !MT_EXPANDED_LOAD(api, readSupportFormatAr,
                          "archive_read_support_format_ar") ||
        !MT_EXPANDED_LOAD(api, readOpenFD, "archive_read_open_fd") ||
        !MT_EXPANDED_LOAD(api, readOpenMemory,
                          "archive_read_open_memory") ||
        !MT_EXPANDED_LOAD(api, readNextHeader,
                          "archive_read_next_header") ||
        !MT_EXPANDED_LOAD(api, readData, "archive_read_data") ||
        !MT_EXPANDED_LOAD(api, readDataSkip,
                          "archive_read_data_skip") ||
        !MT_EXPANDED_LOAD(api, errorString, "archive_error_string") ||
        !MT_EXPANDED_LOAD(api, readFree, "archive_read_free") ||
        !MT_EXPANDED_LOAD(api, entryPathnameUTF8,
                          "archive_entry_pathname_utf8") ||
        !MT_EXPANDED_LOAD(api, entryPathname,
                          "archive_entry_pathname") ||
        !MT_EXPANDED_LOAD(api, entryFiletype,
                          "archive_entry_filetype") ||
        !MT_EXPANDED_LOAD(api, entryMode, "archive_entry_mode") ||
        !MT_EXPANDED_LOAD(api, entrySize, "archive_entry_size") ||
        !MT_EXPANDED_LOAD(api, entryHardlink,
                          "archive_entry_hardlink") ||
        !MT_EXPANDED_LOAD(api, entrySymlink,
                          "archive_entry_symlink")) {
        if (api->handle != NULL) dlclose(api->handle);
        memset(api, 0, sizeof(*api));
        return MTExpandedArchiveSetError(error, 2,
            @"The system archive reader is unavailable.", nil, nil);
    }
    return YES;
}

static void MTExpandedArchiveCloseAPI(MTExpandedArchiveAPI *api) {
    if (api->handle != NULL) dlclose(api->handle);
    memset(api, 0, sizeof(*api));
}

static NSString *_Nullable MTExpandedArchiveNormalizedPath(
    NSString *rawPath,
    BOOL directory,
    MTImportLimits *limits,
    NSError **error) {
    if (![rawPath isKindOfClass:NSString.class] || rawPath.length == 0 ||
        [rawPath hasPrefix:@"/"] || [rawPath containsString:@"\\"] ||
        [rawPath rangeOfString:@"\0"].location != NSNotFound) {
        MTExpandedArchiveSetError(error, 3,
            @"Archive contains an absolute or malformed path.", rawPath, nil);
        return nil;
    }
    NSMutableArray<NSString *> *components = [[rawPath
        componentsSeparatedByString:@"/"] mutableCopy];
    while (components.count > 0 &&
           [components.firstObject isEqualToString:@"."]) {
        [components removeObjectAtIndex:0];
    }
    if (directory && components.count > 0 &&
        components.lastObject.length == 0) {
        [components removeLastObject];
    }
    if (components.count == 0) return directory ? @"" : nil;
    if (components.count > limits.maximumPathDepth) {
        MTExpandedArchiveSetError(error, 4,
            @"Archive path exceeds the configured depth limit.", rawPath,
            nil);
        return nil;
    }
    NSMutableArray<NSString *> *normalized = [NSMutableArray
        arrayWithCapacity:components.count];
    for (NSString *component in components) {
        NSString *value = [component
            precomposedStringWithCanonicalMapping];
        if (value.length == 0 || [value isEqualToString:@"."] ||
            [value isEqualToString:@".."] ||
            [value containsString:@"/"] || [value containsString:@"\\"]) {
            MTExpandedArchiveSetError(error, 3,
                @"Archive contains an unsafe path component.", rawPath, nil);
            return nil;
        }
        for (NSUInteger index = 0; index < value.length; index++) {
            unichar character = [value characterAtIndex:index];
            if (character == 0 || character < 0x20 || character == 0x7f) {
                MTExpandedArchiveSetError(error, 3,
                    @"Archive path contains a control character.", rawPath,
                    nil);
                return nil;
            }
        }
        [normalized addObject:value];
    }
    NSString *path = [normalized componentsJoinedByString:@"/"];
    if ([path lengthOfBytesUsingEncoding:NSUTF8StringEncoding] >
        limits.maximumPathUTF8Bytes) {
        MTExpandedArchiveSetError(error, 4,
            @"Archive path exceeds the configured UTF-8 byte limit.", path,
            nil);
        return nil;
    }
    return path;
}

static BOOL MTExpandedArchivePathIsPackagingArtifact(NSString *path) {
    NSArray<NSString *> *components = [path componentsSeparatedByString:@"/"];
    for (NSString *component in components) {
        if ([component caseInsensitiveCompare:@"__MACOSX"] ==
                NSOrderedSame) return YES;
    }
    NSString *name = components.lastObject ?: @"";
    return [name hasPrefix:@"._"] ||
        [name caseInsensitiveCompare:@".DS_Store"] == NSOrderedSame;
}

static NSString *_Nullable MTExpandedArchiveEntryPath(
    MTExpandedArchiveAPI *api,
    MTExpandedArchiveEntry *entry) {
    const char *bytes = api->entryPathnameUTF8(entry);
    if (bytes == NULL) bytes = api->entryPathname(entry);
    return bytes == NULL ? nil :
        [NSString stringWithUTF8String:bytes];
}

static NSData *_Nullable MTExpandedArchiveDebianDataMember(
    MTExpandedArchiveAPI *api,
    int descriptor,
    MTImportLimits *limits,
    MTImportCancellationToken *_Nullable cancellationToken,
    NSError **error) {
    MTExpandedArchive *archive = api->readNew();
    if (archive == NULL || api->readSupportFilterNone(archive) < -20 ||
        api->readSupportFormatAr(archive) < -20 ||
        lseek(descriptor, 0, SEEK_SET) < 0 ||
        api->readOpenFD(archive, descriptor, 64 * 1024) != 0) {
        if (archive != NULL) api->readFree(archive);
        MTExpandedArchiveSetError(error, 5,
            @"The Debian package container is malformed or unsupported.",
            nil, nil);
        return nil;
    }
    NSMutableData *selected = nil;
    BOOL success = YES;
    while (success) {
        if (cancellationToken.isCancelled) {
            success = MTExpandedArchiveSetError(error, 6,
                @"Archive expansion was cancelled.", nil, nil);
            break;
        }
        MTExpandedArchiveEntry *entry = NULL;
        int result = api->readNextHeader(archive, &entry);
        if (result == 1) break;
        if (result != 0 || entry == NULL) {
            success = MTExpandedArchiveSetError(error, 5,
                @"The Debian package member table is corrupt.", nil, nil);
            break;
        }
        NSString *name = MTExpandedArchiveEntryPath(api, entry);
        BOOL dataMember = [name isEqualToString:@"data.tar"] ||
            [name hasPrefix:@"data.tar."];
        if (!dataMember) {
            if (api->readDataSkip(archive) < -20) success = NO;
            continue;
        }
        if (selected != nil) {
            success = MTExpandedArchiveSetError(error, 5,
                @"The Debian package contains multiple data archives.", name,
                nil);
            break;
        }
        int64_t declaredSize = api->entrySize(entry);
        if (declaredSize < 0 ||
            (uint64_t)declaredSize > limits.maximumSingleFileBytes) {
            success = MTExpandedArchiveSetError(error, 4,
                @"The Debian data archive exceeds the in-memory member limit.",
                name, nil);
            break;
        }
        selected = [NSMutableData dataWithCapacity:(NSUInteger)declaredSize];
        unsigned char buffer[64 * 1024];
        while (success) {
            if (cancellationToken.isCancelled) {
                success = MTExpandedArchiveSetError(error, 6,
                    @"Archive expansion was cancelled.", name, nil);
                break;
            }
            ssize_t count = api->readData(archive, buffer, sizeof(buffer));
            if (count < 0) {
                success = MTExpandedArchiveSetError(error, 5,
                    @"The Debian data archive is corrupt.", name, nil);
                break;
            }
            if (count == 0) break;
            if ((uint64_t)count > limits.maximumSingleFileBytes -
                    selected.length) {
                success = MTExpandedArchiveSetError(error, 4,
                    @"The Debian data archive exceeds the in-memory member limit.",
                    name, nil);
                break;
            }
            [selected appendBytes:buffer length:(NSUInteger)count];
        }
        if (success && selected.length != (NSUInteger)declaredSize) {
            success = MTExpandedArchiveSetError(error, 5,
                @"The Debian data archive size is inconsistent.", name, nil);
        }
    }
    api->readFree(archive);
    if (!success) return nil;
    if (selected.length == 0) {
        MTExpandedArchiveSetError(error, 5,
            @"The Debian package has no supported data.tar member.", nil, nil);
        return nil;
    }
    return [selected copy];
}

static BOOL MTExpandedArchiveWriteAll(int descriptor,
                                      const void *bytes,
                                      size_t length,
                                      NSError **error,
                                      NSString *path) {
    const unsigned char *cursor = bytes;
    size_t remaining = length;
    while (remaining > 0) {
        ssize_t written = write(descriptor, cursor, remaining);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) {
            return MTExpandedArchiveSetError(error, 7,
                @"Unable to write a private expanded file.", path,
                MTExpandedArchivePOSIXError(written == 0 ? EIO : errno));
        }
        cursor += (size_t)written;
        remaining -= (size_t)written;
    }
    return YES;
}

static BOOL MTExpandedArchiveExtractTar(
    MTExpandedArchiveAPI *api,
    int descriptor,
    NSData *_Nullable memoryData,
    NSURL *destinationURL,
    uint64_t sourceByteCount,
    MTImportLimits *limits,
    MTImportCancellationToken *_Nullable cancellationToken,
    NSUInteger *archiveEntryCount,
    NSUInteger *regularFileCount,
    uint64_t *expandedByteCount,
    NSError **error) {
    MTExpandedArchive *archive = api->readNew();
    BOOL opened = archive != NULL &&
        api->readSupportFilterAll(archive) >= -20 &&
        api->readSupportFormatTar(archive) >= -20;
    if (opened) {
        if (memoryData != nil) {
            opened = api->readOpenMemory(archive, memoryData.bytes,
                                          memoryData.length) == 0;
        } else {
            opened = lseek(descriptor, 0, SEEK_SET) >= 0 &&
                api->readOpenFD(archive, descriptor, 64 * 1024) == 0;
        }
    }
    if (!opened) {
        if (archive != NULL) api->readFree(archive);
        return MTExpandedArchiveSetError(error, 5,
            @"The selected tar/compressed-tar archive is unsupported or corrupt.",
            nil, nil);
    }

    NSFileManager *manager = NSFileManager.defaultManager;
    NSUInteger entries = 0;
    NSUInteger files = 0;
    uint64_t total = 0;
    BOOL success = YES;
    while (success) {
        if (cancellationToken.isCancelled) {
            success = MTExpandedArchiveSetError(error, 6,
                @"Archive expansion was cancelled.", nil, nil);
            break;
        }
        MTExpandedArchiveEntry *entry = NULL;
        int result = api->readNextHeader(archive, &entry);
        if (result == 1) break;
        if (result != 0 || entry == NULL) {
            success = MTExpandedArchiveSetError(error, 5,
                @"The archive member table or compressed stream is corrupt.",
                nil, nil);
            break;
        }
        entries++;
        if (entries > limits.maximumArchiveEntries) {
            success = MTExpandedArchiveSetError(error, 4,
                @"The archive contains too many entries.", nil, nil);
            break;
        }
        mode_t type = api->entryFiletype(entry);
        if (type == 0) type = api->entryMode(entry) & S_IFMT;
        BOOL directory = type == S_IFDIR;
        NSString *rawPath = MTExpandedArchiveEntryPath(api, entry);
        NSError *pathError = nil;
        NSString *path = MTExpandedArchiveNormalizedPath(
            rawPath, directory, limits, &pathError);
        if (directory && path.length == 0) {
            api->readDataSkip(archive);
            continue;
        }
        if (path == nil) {
            if (error != NULL) *error = pathError;
            success = NO;
            break;
        }
        BOOL link = api->entryHardlink(entry) != NULL ||
            api->entrySymlink(entry) != NULL;
        if (MTExpandedArchivePathIsPackagingArtifact(path) || link ||
            (type != S_IFREG && type != S_IFDIR)) {
            if (api->readDataSkip(archive) < -20) {
                success = MTExpandedArchiveSetError(error, 5,
                    @"An ignored archive entry could not be skipped.", path,
                    nil);
            }
            continue;
        }
        NSURL *destination = [destinationURL
            URLByAppendingPathComponent:path isDirectory:directory];
        if (directory) {
            NSError *directoryError = nil;
            if (![manager createDirectoryAtURL:destination
                    withIntermediateDirectories:YES
                    attributes:@{ NSFilePosixPermissions : @0700 }
                    error:&directoryError]) {
                success = MTExpandedArchiveSetError(error, 7,
                    @"Unable to create a private expanded directory.", path,
                    directoryError);
            }
            api->readDataSkip(archive);
            continue;
        }
        int64_t declaredSize = api->entrySize(entry);
        if (declaredSize < 0 ||
            (uint64_t)declaredSize > limits.maximumSingleFileBytes ||
            files >= limits.maximumRegularFiles) {
            success = MTExpandedArchiveSetError(error, 4,
                @"An archive file exceeds its count or byte limit.", path,
                nil);
            break;
        }
        NSError *directoryError = nil;
        if (![manager createDirectoryAtURL:
                destination.URLByDeletingLastPathComponent
                withIntermediateDirectories:YES
                attributes:@{ NSFilePosixPermissions : @0700 }
                error:&directoryError]) {
            success = MTExpandedArchiveSetError(error, 7,
                @"Unable to create a private expanded parent directory.",
                path, directoryError);
            break;
        }
        int output = open(destination.path.fileSystemRepresentation,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
        if (output < 0) {
            success = MTExpandedArchiveSetError(error, 7,
                @"Archive entries collide at one destination path.", path,
                MTExpandedArchivePOSIXError(errno));
            break;
        }
        uint64_t actual = 0;
        unsigned char buffer[64 * 1024];
        while (success) {
            if (cancellationToken.isCancelled) {
                success = MTExpandedArchiveSetError(error, 6,
                    @"Archive expansion was cancelled.", path, nil);
                break;
            }
            ssize_t count = api->readData(archive, buffer, sizeof(buffer));
            if (count < 0) {
                success = MTExpandedArchiveSetError(error, 5,
                    @"An archive file is corrupt.", path, nil);
                break;
            }
            if (count == 0) break;
            if ((uint64_t)count > (uint64_t)declaredSize - actual ||
                (uint64_t)count > limits.maximumExpandedBytes - total) {
                success = MTExpandedArchiveSetError(error, 4,
                    @"Expanded archive data exceeded its audited limit.",
                    path, nil);
                break;
            }
            if (!MTExpandedArchiveWriteAll(output, buffer, (size_t)count,
                                             error, path)) {
                success = NO;
                break;
            }
            actual += (uint64_t)count;
            total += (uint64_t)count;
        }
        int closeResult = close(output);
        if (!success || closeResult != 0 ||
            actual != (uint64_t)declaredSize) {
            unlink(destination.path.fileSystemRepresentation);
            if (success) {
                success = MTExpandedArchiveSetError(error, 5,
                    @"An expanded file size is inconsistent.", path,
                    closeResult == 0 ? nil :
                        MTExpandedArchivePOSIXError(errno));
            }
            break;
        }
        files++;
    }
    api->readFree(archive);
    if (success && (files == 0 ||
        (sourceByteCount > 0 &&
         sourceByteCount <= UINT64_MAX /
             limits.maximumArchiveExpansionRatio &&
         total > sourceByteCount *
             limits.maximumArchiveExpansionRatio))) {
        success = MTExpandedArchiveSetError(error, 4,
            @"The archive is empty or exceeds the total expansion ratio.",
            nil, nil);
    }
    if (success) {
        *archiveEntryCount = entries;
        *regularFileCount = files;
        *expandedByteCount = total;
    }
    return success;
}

static BOOL MTExpandedArchiveSessionNameIsCanonical(NSString *name) {
    static NSString *const prefix = @"expanded-";
    if (![name hasPrefix:prefix]) return NO;
    NSString *uuid = [name substringFromIndex:prefix.length];
    return [[NSUUID alloc] initWithUUIDString:uuid] != nil;
}

@interface MTExpandedArchiveSession ()
@property(nonatomic, copy, readwrite) NSString *sessionIdentifier;
@property(nonatomic, copy, readwrite) NSURL *expandedDirectoryURL;
@property(nonatomic, strong, readwrite) id<MTAuditedSource> auditedSource;
@property(nonatomic, assign, readwrite) NSUInteger archiveEntryCount;
@property(nonatomic, assign, readwrite) NSUInteger regularFileCount;
@property(nonatomic, assign, readwrite) uint64_t expandedByteCount;
@property(nonatomic, copy) NSURL *sessionsRootURL;
@property(nonatomic, assign) BOOL discarded;
- (instancetype)initPrivate;
@end

@implementation MTExpandedArchiveSession

+ (instancetype)sessionByExpandingArchiveAtURL:(NSURL *)archiveURL
                                         format:(MTExpandedArchiveFormat)format
                                sessionsRootURL:(NSURL *)sessionsRootURL
                                         limits:(MTImportLimits *)limits
                              cancellationToken:
                                  (MTImportCancellationToken *)cancellationToken
                                        auditor:(MTExpandedArchiveAuditor)auditor
                                          error:(NSError **)error {
    if (![archiveURL isKindOfClass:NSURL.class] || !archiveURL.isFileURL ||
        ![sessionsRootURL isKindOfClass:NSURL.class] ||
        !sessionsRootURL.isFileURL ||
        ![limits isKindOfClass:MTImportLimits.class] || auditor == nil ||
        (format != MTExpandedArchiveFormatTar &&
         format != MTExpandedArchiveFormatDebianPackage)) {
        MTExpandedArchiveSetError(error, 1,
            @"Archive expansion requires a local file, private root and policy.",
            nil, nil);
        return nil;
    }
    if (cancellationToken.isCancelled) {
        MTExpandedArchiveSetError(error, 6,
            @"Archive expansion was cancelled before opening the source.",
            nil, nil);
        return nil;
    }
    int descriptor = open(archiveURL.path.fileSystemRepresentation,
        O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    struct stat status = {0};
    if (descriptor < 0 || fstat(descriptor, &status) != 0 ||
        !S_ISREG(status.st_mode) || status.st_size <= 0 ||
        (uint64_t)status.st_size > limits.maximumSourceBytes) {
        int savedError = errno;
        if (descriptor >= 0) close(descriptor);
        MTExpandedArchiveSetError(error, 1,
            @"The private archive copy is not a supported regular file.", nil,
            savedError == 0 ? nil : MTExpandedArchivePOSIXError(savedError));
        return nil;
    }

    NSError *directoryError = nil;
    NSFileManager *manager = NSFileManager.defaultManager;
    if (![manager createDirectoryAtURL:sessionsRootURL
            withIntermediateDirectories:YES
            attributes:@{ NSFilePosixPermissions : @0700 }
            error:&directoryError]) {
        close(descriptor);
        MTExpandedArchiveSetError(error, 7,
            @"Unable to create the private archive-session root.", nil,
            directoryError);
        return nil;
    }
    NSString *identifier = [@"expanded-" stringByAppendingString:
        NSUUID.UUID.UUIDString.lowercaseString];
    NSURL *directoryURL = [sessionsRootURL
        URLByAppendingPathComponent:identifier isDirectory:YES];
    if (![manager createDirectoryAtURL:directoryURL
            withIntermediateDirectories:NO
            attributes:@{ NSFilePosixPermissions : @0700 }
            error:&directoryError]) {
        close(descriptor);
        MTExpandedArchiveSetError(error, 7,
            @"Unable to create a private archive expansion session.", nil,
            directoryError);
        return nil;
    }

    MTExpandedArchiveAPI api;
    NSError *operationError = nil;
    BOOL loaded = MTExpandedArchiveLoadAPI(&api, &operationError);
    NSData *debianData = nil;
    if (loaded && format == MTExpandedArchiveFormatDebianPackage) {
        debianData = MTExpandedArchiveDebianDataMember(&api, descriptor,
            limits, cancellationToken, &operationError);
        loaded = debianData != nil;
    }
    NSUInteger entryCount = 0;
    NSUInteger fileCount = 0;
    uint64_t byteCount = 0;
    BOOL extracted = loaded && MTExpandedArchiveExtractTar(&api, descriptor,
        debianData, directoryURL, (uint64_t)status.st_size, limits,
        cancellationToken, &entryCount, &fileCount, &byteCount,
        &operationError);
    if (loaded || api.handle != NULL) MTExpandedArchiveCloseAPI(&api);
    close(descriptor);
    id<MTAuditedSource> source = nil;
    if (extracted) source = auditor(directoryURL, &operationError);
    if (!extracted || source == nil) {
        NSError *cleanupError = nil;
        BOOL cleaned = [manager removeItemAtURL:directoryURL
                                           error:&cleanupError];
        if (error != NULL) {
            NSError *cleanupUnderlying = cleanupError ?: operationError ?:
                [NSError errorWithDomain:MTExpandedArchiveSessionErrorDomain
                                    code:8 userInfo:nil];
            *error = cleaned
                ? (operationError ?: [NSError
                    errorWithDomain:MTExpandedArchiveSessionErrorDomain
                               code:5
                           userInfo:@{NSLocalizedDescriptionKey :
                               @"The expanded archive did not pass source audit."}])
                : [NSError errorWithDomain:MTExpandedArchiveSessionErrorDomain
                                      code:8
                                  userInfo:@{
                    NSLocalizedDescriptionKey :
                        @"Archive expansion failed and cleanup also failed.",
                    NSUnderlyingErrorKey : cleanupUnderlying,
                }];
        }
        return nil;
    }
    MTExpandedArchiveSession *session = [[self alloc] initPrivate];
    session.sessionIdentifier = identifier;
    session.sessionsRootURL = sessionsRootURL;
    session.expandedDirectoryURL = directoryURL;
    session.auditedSource = source;
    session.archiveEntryCount = entryCount;
    session.regularFileCount = fileCount;
    session.expandedByteCount = byteCount;
    return session;
}

- (instancetype)initPrivate {
    return [super init];
}

+ (BOOL)discardAbandonedSessionsAtRootURL:(NSURL *)sessionsRootURL
                                    error:(NSError **)error {
    if (![sessionsRootURL isKindOfClass:NSURL.class] ||
        !sessionsRootURL.isFileURL) {
        return MTExpandedArchiveSetError(error, 1,
            @"A local archive-session root is required for recovery.", nil,
            nil);
    }
    NSError *enumerationError = nil;
    NSArray<NSURL *> *children = [NSFileManager.defaultManager
        contentsOfDirectoryAtURL:sessionsRootURL
        includingPropertiesForKeys:nil options:0 error:&enumerationError];
    if (children == nil) {
        if (![NSFileManager.defaultManager
                fileExistsAtPath:sessionsRootURL.path]) {
            return YES;
        }
        if (error != NULL) *error = enumerationError;
        return NO;
    }
    for (NSURL *child in children) {
        if (!MTExpandedArchiveSessionNameIsCanonical(
                child.lastPathComponent)) continue;
        if (![NSFileManager.defaultManager removeItemAtURL:child
                                                     error:error]) {
            return NO;
        }
    }
    return YES;
}

- (BOOL)isActive {
    @synchronized (self) { return !self.discarded; }
}

- (BOOL)discard:(NSError **)error {
    @synchronized (self) {
        if (self.discarded) return YES;
        if (!MTExpandedArchiveSessionNameIsCanonical(
                self.sessionIdentifier) ||
            ![self.expandedDirectoryURL.URLByDeletingLastPathComponent.path
                isEqualToString:self.sessionsRootURL.path]) {
            return MTExpandedArchiveSetError(error, 8,
                @"The private archive session no longer has a safe identity.",
                nil, nil);
        }
        BOOL removed = [NSFileManager.defaultManager
            removeItemAtURL:self.expandedDirectoryURL error:error];
        if (removed || ![NSFileManager.defaultManager
                fileExistsAtPath:self.expandedDirectoryURL.path]) {
            self.discarded = YES;
            return YES;
        }
        return NO;
    }
}

- (void)dealloc {
    [self discard:NULL];
}

@end
