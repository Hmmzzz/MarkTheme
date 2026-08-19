#import "MTSafeDirectoryScanner.h"

#import <dirent.h>
#import <CommonCrypto/CommonDigest.h>
#import <errno.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <sys/types.h>
#import <unistd.h>

#import "MTDigest.h"
#import "MTImportSession.h"

NSString *const MTSafeDirectoryScannerErrorDomain =
    @"com.hmmzzz.marktheme.safe-directory-scanner";

@interface MTDirectoryScanState : NSObject
@property(nonatomic, strong) NSMutableArray<MTSourceFile *> *files;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *pathsByFoldedKey;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *rawPathsByNormalizedPath;
@property(nonatomic, assign) uint64_t totalBytes;
@end


@implementation MTDirectoryScanState
- (instancetype)init {
    self = [super init];
    if (self == nil) return nil;
    _files = [NSMutableArray array];
    _pathsByFoldedKey = [NSMutableDictionary dictionary];
    _rawPathsByNormalizedPath = [NSMutableDictionary dictionary];
    return self;
}
@end

static BOOL MTScannerSetError(NSError **error,
                              MTSafeDirectoryScannerErrorCode code,
                              NSString *description,
                              NSString *_Nullable relativePath,
                              NSError *_Nullable underlying) {
    if (error != NULL) {
        NSMutableDictionary *userInfo = [NSMutableDictionary
            dictionaryWithObject:description forKey:NSLocalizedDescriptionKey];
        if (relativePath != nil) userInfo[@"relativePath"] = relativePath;
        if (underlying != nil) userInfo[NSUnderlyingErrorKey] = underlying;
        *error = [NSError errorWithDomain:MTSafeDirectoryScannerErrorDomain
                                     code:code
                                 userInfo:userInfo];
    }
    return NO;
}

static NSError *MTScannerPOSIXError(void) {
    return [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
}

static void MTDirectorySetAuditedReadError(
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

static NSString *MTDirectoryHexDigest(const unsigned char *digest) {
    static const char digits[] = "0123456789abcdef";
    char output[CC_SHA256_DIGEST_LENGTH * 2 + 1] = {0};
    for (NSUInteger index = 0; index < CC_SHA256_DIGEST_LENGTH; index++) {
        output[index * 2] = digits[(digest[index] >> 4) & 0x0f];
        output[index * 2 + 1] = digits[digest[index] & 0x0f];
    }
    return [NSString stringWithUTF8String:output];
}

static NSString *_Nullable MTScannerDigestForFileDescriptor(
    int fileDescriptor,
    uint64_t maximumBytes,
    MTImportCancellationToken *_Nullable cancellationToken,
    uint64_t *bytesRead,
    NSError **error) {
    if (lseek(fileDescriptor, 0, SEEK_SET) < 0) {
        MTScannerSetError(error, MTSafeDirectoryScannerErrorIO,
            @"Unable to seek a source file for hashing.", nil,
            MTScannerPOSIXError());
        return nil;
    }
    CC_SHA256_CTX context;
    CC_SHA256_Init(&context);
    unsigned char buffer[64 * 1024];
    uint64_t total = 0;
    while (YES) {
        if (cancellationToken.isCancelled) {
            MTScannerSetError(error, MTSafeDirectoryScannerErrorCancelled,
                @"Directory inspection was cancelled while hashing a file.",
                nil, nil);
            return nil;
        }
        ssize_t count = read(fileDescriptor, buffer, sizeof(buffer));
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) {
            MTScannerSetError(error, MTSafeDirectoryScannerErrorIO,
                @"Unable to hash a source file.", nil,
                MTScannerPOSIXError());
            return nil;
        }
        if (count == 0) break;
        if ((uint64_t)count > maximumBytes - total) {
            MTScannerSetError(error,
                MTSafeDirectoryScannerErrorLimitExceeded,
                @"A source file exceeded its digest byte limit.", nil, nil);
            return nil;
        }
        total += (uint64_t)count;
        CC_SHA256_Update(&context, buffer, (CC_LONG)count);
    }
    if (cancellationToken.isCancelled) {
        MTScannerSetError(error, MTSafeDirectoryScannerErrorCancelled,
            @"Directory inspection was cancelled before digest completion.",
            nil, nil);
        return nil;
    }
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &context);
    if (bytesRead != NULL) *bytesRead = total;
    return MTDirectoryHexDigest(digest);
}

static BOOL MTScannerComponentIsSafe(NSString *component) {
    if (component.length == 0 || [component isEqualToString:@"."] ||
        [component isEqualToString:@".."] ||
        [component containsString:@"/"] || [component containsString:@"\\"]) {
        return NO;
    }
    for (NSUInteger index = 0; index < component.length; index++) {
        unichar character = [component characterAtIndex:index];
        if (character == 0 || character < 0x20 || character == 0x7f) return NO;
    }
    return YES;
}

static BOOL MTScannerRegisterPath(NSString *normalizedPath,
                                  NSString *rawPath,
                                  MTDirectoryScanState *state,
                                  NSError **error) {
    NSString *folded = [normalizedPath
        stringByFoldingWithOptions:NSCaseInsensitiveSearch
                            locale:[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"]];
    NSString *existing = state.pathsByFoldedKey[folded];
    if (existing != nil && ![existing isEqualToString:rawPath]) {
        return MTScannerSetError(error,
            MTSafeDirectoryScannerErrorCanonicalCollision,
            @"Two source paths collide after Unicode normalization or case folding.",
            normalizedPath, nil);
    }
    state.pathsByFoldedKey[folded] = rawPath;
    state.rawPathsByNormalizedPath[normalizedPath] = rawPath;
    return YES;
}

static BOOL MTScannerStatIsStable(const struct stat *before,
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

static BOOL MTScanDirectoryDescriptor(int directoryDescriptor,
                                      NSString *rawPrefix,
                                      NSString *normalizedPrefix,
                                      NSUInteger depth,
                                      MTImportLimits *limits,
                                      MTImportCancellationToken *_Nullable
                                          cancellationToken,
                                      MTDirectoryScanState *state,
                                      NSError **error) {
    int enumerationDescriptor = dup(directoryDescriptor);
    if (enumerationDescriptor < 0) {
        return MTScannerSetError(error, MTSafeDirectoryScannerErrorIO,
            @"Unable to duplicate the source directory descriptor.",
            normalizedPrefix, MTScannerPOSIXError());
    }
    DIR *directory = fdopendir(enumerationDescriptor);
    if (directory == NULL) {
        int savedErrno = errno;
        close(enumerationDescriptor);
        errno = savedErrno;
        return MTScannerSetError(error, MTSafeDirectoryScannerErrorIO,
            @"Unable to enumerate the source directory.", normalizedPrefix,
            MTScannerPOSIXError());
    }

    BOOL success = YES;
    struct dirent *entry = NULL;
    while (YES) {
        if (cancellationToken.isCancelled) {
            success = MTScannerSetError(error,
                MTSafeDirectoryScannerErrorCancelled,
                @"Directory inspection was cancelled during traversal.",
                normalizedPrefix, nil);
            break;
        }
        errno = 0;
        entry = readdir(directory);
        if (entry == NULL) {
            if (errno != 0) {
                success = MTScannerSetError(error,
                    MTSafeDirectoryScannerErrorIO,
                    @"Source directory enumeration failed.", normalizedPrefix,
                    MTScannerPOSIXError());
            }
            break;
        }
        if (strcmp(entry->d_name, ".") == 0 ||
            strcmp(entry->d_name, "..") == 0) {
            continue;
        }
        size_t nameLength = strlen(entry->d_name);
        NSString *rawName = [[NSString alloc] initWithBytes:entry->d_name
                                                    length:nameLength
                                                  encoding:NSUTF8StringEncoding];
        NSString *normalizedName =
            [rawName precomposedStringWithCanonicalMapping];
        if (rawName == nil || !MTScannerComponentIsSafe(normalizedName)) {
            success = MTScannerSetError(error,
                MTSafeDirectoryScannerErrorUnsafePath,
                @"Source contains an invalid path component.", normalizedPrefix,
                nil);
            break;
        }
        NSString *rawPath = rawPrefix.length == 0
            ? rawName
            : [rawPrefix stringByAppendingFormat:@"/%@", rawName];
        NSString *normalizedPath = normalizedPrefix.length == 0
            ? normalizedName
            : [normalizedPrefix stringByAppendingFormat:@"/%@", normalizedName];
        if ([normalizedPath lengthOfBytesUsingEncoding:NSUTF8StringEncoding] >
                limits.maximumPathUTF8Bytes ||
            depth > limits.maximumPathDepth ||
            !MTScannerRegisterPath(normalizedPath, rawPath, state, error)) {
            if (error == NULL || *error == nil) {
                MTScannerSetError(error, MTSafeDirectoryScannerErrorLimitExceeded,
                    @"Source path exceeds the configured depth or byte limit.",
                    normalizedPath, nil);
            }
            success = NO;
            break;
        }

        struct stat status;
        if (fstatat(directoryDescriptor, entry->d_name, &status,
                    AT_SYMLINK_NOFOLLOW) != 0) {
            success = MTScannerSetError(error, MTSafeDirectoryScannerErrorIO,
                @"Unable to inspect a source node.", normalizedPath,
                MTScannerPOSIXError());
            break;
        }
        if (S_ISDIR(status.st_mode)) {
            if (depth >= limits.maximumPathDepth) {
                success = MTScannerSetError(error,
                    MTSafeDirectoryScannerErrorLimitExceeded,
                    @"Source directory exceeds the configured depth limit.",
                    normalizedPath, nil);
                break;
            }
            int child = openat(directoryDescriptor, entry->d_name,
                               O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
            if (child < 0) {
                success = MTScannerSetError(error,
                    MTSafeDirectoryScannerErrorFileChanged,
                    @"Source directory changed during inspection.",
                    normalizedPath, MTScannerPOSIXError());
                break;
            }
            success = MTScanDirectoryDescriptor(child, rawPath, normalizedPath,
                depth + 1, limits, cancellationToken, state, error);
            close(child);
            if (!success) break;
            continue;
        }
        if (!S_ISREG(status.st_mode) || status.st_nlink != 1 ||
            (status.st_mode & (S_ISUID | S_ISGID)) != 0) {
            success = MTScannerSetError(error,
                MTSafeDirectoryScannerErrorUnsupportedNode,
                @"Source contains a link, special node, hardlink or privileged file.",
                normalizedPath, nil);
            break;
        }
        if (status.st_size < 0 ||
            (uint64_t)status.st_size > limits.maximumSingleFileBytes ||
            state.files.count >= limits.maximumRegularFiles ||
            (uint64_t)status.st_size > limits.maximumExpandedBytes - state.totalBytes) {
            success = MTScannerSetError(error,
                MTSafeDirectoryScannerErrorLimitExceeded,
                @"Source exceeds a configured file count or byte limit.",
                normalizedPath, nil);
            break;
        }

        int fileDescriptor = openat(directoryDescriptor, entry->d_name,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
        if (fileDescriptor < 0) {
            success = MTScannerSetError(error,
                MTSafeDirectoryScannerErrorFileChanged,
                @"Source file changed during inspection.", normalizedPath,
                MTScannerPOSIXError());
            break;
        }
        struct stat openedStatus;
        if (fstat(fileDescriptor, &openedStatus) != 0 ||
            !MTScannerStatIsStable(&status, &openedStatus)) {
            close(fileDescriptor);
            success = MTScannerSetError(error,
                MTSafeDirectoryScannerErrorFileChanged,
                @"Source file identity changed during inspection.",
                normalizedPath, nil);
            break;
        }

        unsigned char prefix[16];
        ssize_t prefixCount = pread(fileDescriptor, prefix, sizeof(prefix), 0);
        if (prefixCount < 0) {
            close(fileDescriptor);
            success = MTScannerSetError(error, MTSafeDirectoryScannerErrorIO,
                @"Unable to read a source file prefix.", normalizedPath,
                MTScannerPOSIXError());
            break;
        }
        uint64_t bytesRead = 0;
        NSError *digestError = nil;
        NSString *digest = MTScannerDigestForFileDescriptor(fileDescriptor,
            limits.maximumSingleFileBytes, cancellationToken, &bytesRead,
            &digestError);
        struct stat finalStatus;
        BOOL finalStatOK = fstat(fileDescriptor, &finalStatus) == 0;
        close(fileDescriptor);
        if (digest == nil &&
            [digestError.domain isEqualToString:
                MTSafeDirectoryScannerErrorDomain] &&
            digestError.code == MTSafeDirectoryScannerErrorCancelled) {
            if (error != NULL) *error = digestError;
            success = NO;
            break;
        }
        if (digest == nil || bytesRead != (uint64_t)status.st_size ||
            !finalStatOK || !MTScannerStatIsStable(&status, &finalStatus)) {
            success = MTScannerSetError(error,
                MTSafeDirectoryScannerErrorFileChanged,
                @"Source file changed while it was hashed.", normalizedPath,
                digestError);
            break;
        }

        [state.files addObject:[[MTSourceFile alloc]
            initWithRelativePath:normalizedPath
                       byteCount:bytesRead
                   contentSHA256:digest
                      prefixData:[NSData dataWithBytes:prefix
                                               length:(NSUInteger)prefixCount]]];
        state.totalBytes += bytesRead;
    }
    closedir(directory);
    return success;
}

@interface MTSafeDirectoryScan ()
- (instancetype)initWithInventory:(MTSourceInventory *)inventory
                      directoryURL:(NSURL *)directoryURL
                            limits:(MTImportLimits *)limits
              rawPathsByNormalizedPath:
                  (NSDictionary<NSString *, NSString *> *)rawPaths
                        rootStatus:(const struct stat *)rootStatus;
@end

@implementation MTSafeDirectoryScan {
    NSURL *_directoryURL;
    MTImportLimits *_limits;
    NSDictionary<NSString *, NSString *> *_rawPathsByNormalizedPath;
    NSData *_rootStatusData;
}

- (instancetype)initWithInventory:(MTSourceInventory *)inventory
                      directoryURL:(NSURL *)directoryURL
                            limits:(MTImportLimits *)limits
              rawPathsByNormalizedPath:
                  (NSDictionary<NSString *, NSString *> *)rawPaths
                        rootStatus:(const struct stat *)rootStatus {
    self = [super init];
    if (self == nil) return nil;
    _inventory = inventory;
    _directoryURL = [directoryURL copy];
    _limits = limits;
    _rawPathsByNormalizedPath = [rawPaths copy];
    _rootStatusData = [NSData dataWithBytes:rootStatus
                                     length:sizeof(*rootStatus)];
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
            MTDirectorySetAuditedReadError(consumerError,
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
        MTDirectorySetAuditedReadError(error,
            MTAuditedSourceErrorInvalidRequest,
            @"Audited source streams require a path and byte consumer.", nil,
            nil);
        return NO;
    }
    MTSourceFile *expected =
        [self.inventory fileAtRelativePath:relativePath];
    if (expected == nil) {
        MTDirectorySetAuditedReadError(error,
            MTAuditedSourceErrorNotInventoried,
            @"The requested path was not admitted by the source audit.", nil,
            nil);
        return NO;
    }
    if (expected.byteCount > maximumByteCount ||
        expected.byteCount > _limits.maximumSingleFileBytes) {
        MTDirectorySetAuditedReadError(error,
            MTAuditedSourceErrorLimitExceeded,
            @"The inventoried file exceeds the caller's stream limit.",
            expected.relativePath, nil);
        return NO;
    }
    if (cancellationToken.isCancelled) {
        MTDirectorySetAuditedReadError(error, MTAuditedSourceErrorCancelled,
            @"The audited source stream was cancelled before opening data.",
            expected.relativePath, nil);
        return NO;
    }
    NSString *rawPath =
        _rawPathsByNormalizedPath[expected.relativePath];
    if (rawPath.length == 0) {
        MTDirectorySetAuditedReadError(error,
            MTAuditedSourceErrorCorruptSource,
            @"The source audit no longer has a path binding for this file.",
            expected.relativePath, nil);
        return NO;
    }

    int root = open(_directoryURL.path.fileSystemRepresentation,
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (root < 0) {
        int savedError = errno;
        MTDirectorySetAuditedReadError(error,
            MTAuditedSourceErrorSourceChanged,
            @"The audited directory root is no longer available.",
            expected.relativePath,
            [NSError errorWithDomain:NSPOSIXErrorDomain
                                code:savedError userInfo:nil]);
        return NO;
    }
    struct stat auditedRoot = {0};
    struct stat openedRoot = {0};
    [_rootStatusData getBytes:&auditedRoot length:sizeof(auditedRoot)];
    if (fstat(root, &openedRoot) != 0 || !S_ISDIR(openedRoot.st_mode) ||
        !MTScannerStatIsStable(&auditedRoot, &openedRoot)) {
        close(root);
        MTDirectorySetAuditedReadError(error,
            MTAuditedSourceErrorSourceChanged,
            @"The audited directory identity changed before the stream.",
            expected.relativePath, nil);
        return NO;
    }

    NSArray<NSString *> *components =
        [rawPath componentsSeparatedByString:@"/"];
    int parent = dup(root);
    int fileDescriptor = -1;
    BOOL openedPath = parent >= 0;
    int pathError = parent < 0 ? errno : 0;
    for (NSUInteger index = 0; openedPath && index < components.count; index++) {
        NSString *component = components[index];
        const char *name = component.fileSystemRepresentation;
        if (name == NULL) {
            openedPath = NO;
            pathError = EINVAL;
            break;
        }
        BOOL finalComponent = index + 1 == components.count;
        int child = openat(parent, name,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW |
                (finalComponent ? 0 : O_DIRECTORY));
        if (child < 0) {
            openedPath = NO;
            pathError = errno;
            break;
        }
        if (finalComponent) {
            fileDescriptor = child;
        } else {
            close(parent);
            parent = child;
        }
    }
    if (parent >= 0) close(parent);
    if (!openedPath || fileDescriptor < 0) {
        close(root);
        MTDirectorySetAuditedReadError(error,
            MTAuditedSourceErrorSourceChanged,
            @"An audited path changed before it could be reopened safely.",
            expected.relativePath,
            [NSError errorWithDomain:NSPOSIXErrorDomain
                                code:pathError userInfo:nil]);
        return NO;
    }

    struct stat before = {0};
    if (fstat(fileDescriptor, &before) != 0 ||
        !S_ISREG(before.st_mode) || before.st_nlink != 1 ||
        (before.st_mode & (S_ISUID | S_ISGID)) != 0 ||
        before.st_size < 0 ||
        (uint64_t)before.st_size != expected.byteCount) {
        close(fileDescriptor);
        close(root);
        MTDirectorySetAuditedReadError(error,
            MTAuditedSourceErrorSourceChanged,
            @"The audited file's identity, type, or size changed.",
            expected.relativePath, nil);
        return NO;
    }

    unsigned char buffer[64 * 1024];
    uint64_t offset = 0;
    CC_SHA256_CTX digestContext;
    CC_SHA256_Init(&digestContext);
    BOOL success = YES;
    NSError *consumerFailure = nil;
    while (offset < expected.byteCount) {
        if (cancellationToken.isCancelled) {
            MTDirectorySetAuditedReadError(error,
                MTAuditedSourceErrorCancelled,
                @"The audited source stream was cancelled while reading data.",
                expected.relativePath, nil);
            success = NO;
            break;
        }
        size_t request = (size_t)MIN((uint64_t)(64 * 1024),
                                     expected.byteCount - offset);
        ssize_t count = pread(fileDescriptor, buffer, request, (off_t)offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) {
            int savedError = count < 0 ? errno : EIO;
            MTDirectorySetAuditedReadError(error,
                count == 0 ? MTAuditedSourceErrorSourceChanged
                           : MTAuditedSourceErrorIO,
                @"The audited file could not be read to its exact size.",
                expected.relativePath,
                [NSError errorWithDomain:NSPOSIXErrorDomain
                                    code:savedError userInfo:nil]);
            success = NO;
            break;
        }
        CC_SHA256_Update(&digestContext, buffer, (CC_LONG)count);
        NSError *chunkError = nil;
        if (!byteConsumer(buffer, (NSUInteger)count, &chunkError)) {
            consumerFailure = chunkError;
            success = NO;
            break;
        }
        offset += (uint64_t)count;
    }

    struct stat after = {0};
    struct stat finalRoot = {0};
    BOOL fileStable = fstat(fileDescriptor, &after) == 0 &&
        MTScannerStatIsStable(&before, &after);
    BOOL rootStable = fstat(root, &finalRoot) == 0 &&
        MTScannerStatIsStable(&auditedRoot, &finalRoot);
    close(fileDescriptor);
    close(root);
    if (!fileStable || !rootStable || cancellationToken.isCancelled) {
        MTDirectorySetAuditedReadError(error,
            cancellationToken.isCancelled ? MTAuditedSourceErrorCancelled
                                           : MTAuditedSourceErrorSourceChanged,
            cancellationToken.isCancelled
                ? @"The audited source stream was cancelled before validation."
                : @"The audited source changed while data was being streamed.",
            expected.relativePath, nil);
        return NO;
    }
    if (!success) {
        if (consumerFailure != nil && error != NULL) {
            *error = consumerFailure;
        } else if (consumerFailure == nil &&
                   (error == NULL || *error == nil)) {
            MTDirectorySetAuditedReadError(error, MTAuditedSourceErrorIO,
                @"The byte consumer rejected audited source data.",
                expected.relativePath, nil);
        }
        return NO;
    }
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &digestContext);
    if (![MTDirectoryHexDigest(digest)
            isEqualToString:expected.contentSHA256]) {
        MTDirectorySetAuditedReadError(error,
            MTAuditedSourceErrorSourceChanged,
            @"The audited file content no longer matches its inventory digest.",
            expected.relativePath, nil);
        return NO;
    }
    return YES;
}

@end

@implementation MTSafeDirectoryScanner

- (instancetype)initWithLimits:(MTImportLimits *)limits {
    NSParameterAssert(limits != nil);
    self = [super init];
    if (self == nil) return nil;
    _limits = limits;
    return self;
}

- (MTSafeDirectoryScan *)scanDirectorySourceAtURL:(NSURL *)directoryURL
                                             error:(NSError **)error {
    return [self scanDirectorySourceAtURL:directoryURL
                        cancellationToken:nil error:error];
}

- (MTSafeDirectoryScan *)scanDirectorySourceAtURL:(NSURL *)directoryURL
                                cancellationToken:
                                    (MTImportCancellationToken *)cancellationToken
                                             error:(NSError **)error {
    if (![directoryURL isKindOfClass:NSURL.class] || !directoryURL.isFileURL ||
        directoryURL.path.length == 0) {
        MTScannerSetError(error, MTSafeDirectoryScannerErrorInvalidRoot,
            @"Import source must be a local directory URL.", nil, nil);
        return nil;
    }
    int root = open(directoryURL.path.fileSystemRepresentation,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (root < 0) {
        MTScannerSetError(error, MTSafeDirectoryScannerErrorInvalidRoot,
            @"Import source is not a safe directory.", nil,
            MTScannerPOSIXError());
        return nil;
    }
    struct stat rootStatus;
    if (fstat(root, &rootStatus) != 0 || !S_ISDIR(rootStatus.st_mode)) {
        close(root);
        MTScannerSetError(error, MTSafeDirectoryScannerErrorInvalidRoot,
            @"Import source root is invalid.", nil, nil);
        return nil;
    }

    MTDirectoryScanState *state = [[MTDirectoryScanState alloc] init];
    BOOL success = MTScanDirectoryDescriptor(root, @"", @"", 1,
        self.limits, cancellationToken, state, error);
    struct stat finalRootStatus = {0};
    BOOL rootStable = fstat(root, &finalRootStatus) == 0 &&
        MTScannerStatIsStable(&rootStatus, &finalRootStatus);
    close(root);
    if (!success) return nil;
    if (cancellationToken.isCancelled) {
        MTScannerSetError(error, MTSafeDirectoryScannerErrorCancelled,
            @"Directory inspection was cancelled before publication.", nil,
            nil);
        return nil;
    }
    if (!rootStable) {
        MTScannerSetError(error, MTSafeDirectoryScannerErrorFileChanged,
            @"Source directory changed while it was being inspected.", nil,
            nil);
        return nil;
    }

    NSError *inventoryError = nil;
    MTSourceInventory *inventory =
        [MTSourceInventory inventoryWithFiles:state.files error:&inventoryError];
    if (inventory == nil) {
        MTScannerSetError(error, MTSafeDirectoryScannerErrorIO,
            @"Unable to canonicalize the source fingerprint.", nil,
            inventoryError);
        return nil;
    }
    return [[MTSafeDirectoryScan alloc]
        initWithInventory:inventory
             directoryURL:directoryURL
                   limits:self.limits
     rawPathsByNormalizedPath:state.rawPathsByNormalizedPath
               rootStatus:&finalRootStatus];
}

- (MTSourceInventory *)scanDirectoryAtURL:(NSURL *)directoryURL
                                      error:(NSError **)error {
    return [self scanDirectorySourceAtURL:directoryURL error:error].inventory;
}

@end
