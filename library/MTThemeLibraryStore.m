#import "MTThemeLibraryStore.h"

#import <errno.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <sys/types.h>
#import <unistd.h>

#import "MTCanonicalJSON.h"
#import "MTBootstrapPaths.h"
#import "MTDigest.h"
#import "MTIdentifier.h"
#import "MTImportLimits.h"
#import "MTThemeManifest.h"
#import "MTThemeLibraryStoreInternal.h"

NSString *const MTThemeLibraryStoreErrorDomain =
    @"com.hmmzzz.marktheme64e.theme-library-store";

@implementation MTThemeLibraryConfiguration

+ (instancetype)defaultConfiguration {
    NSURL *managerDataRoot = MTDefaultManagerDataRootURL();
    NSAssert(managerDataRoot != nil,
             @"Manager data storage must be available for the theme Library.");
    NSURL *rootURL = [managerDataRoot
        URLByAppendingPathComponent:@"Library" isDirectory:YES];
    return [[self alloc] initWithRootURL:rootURL
                                  limits:MTImportLimits.defaultLimits
            minimumFreeSpaceReserveBytes:64ULL * 1024ULL * 1024ULL];
}

- (instancetype)initWithRootURL:(NSURL *)rootURL
                          limits:(MTImportLimits *)limits
    minimumFreeSpaceReserveBytes:(uint64_t)minimumFreeSpaceReserveBytes {
    NSParameterAssert(rootURL.isFileURL);
    NSParameterAssert(rootURL.path.length > 0);
    NSParameterAssert(limits != nil);
    self = [super init];
    if (self == nil) return nil;
    _rootURL = [rootURL copy];
    _limits = limits;
    _minimumFreeSpaceReserveBytes = minimumFreeSpaceReserveBytes;
    return self;
}

@end

@implementation MTThemeLibraryRevision

- (instancetype)initWithRevisionIdentifier:(NSString *)revisionIdentifier
                             manifestDigest:(NSString *)manifestDigest
                                    manifest:(MTThemeManifest *)manifest
             assetURLsByContentSHA256:
                 (NSDictionary<NSString *,NSURL *> *)assetURLsByContentSHA256
       assetByteCountsByContentSHA256:
           (NSDictionary<NSString *,NSNumber *> *)assetByteCountsByContentSHA256
                             assetByteCount:(uint64_t)assetByteCount {
    self = [super init];
    if (self == nil) return nil;
    _revisionIdentifier = [revisionIdentifier copy];
    _manifestDigest = [manifestDigest copy];
    _manifest = manifest;
    _assetURLsByContentSHA256 = [assetURLsByContentSHA256 copy];
    _assetByteCountsByContentSHA256 =
        [assetByteCountsByContentSHA256 copy];
    _assetCount = _assetURLsByContentSHA256.count;
    _assetByteCount = assetByteCount;
    return self;
}

@end

static BOOL MTLibrarySetError(NSError **error,
                              MTThemeLibraryStoreErrorCode code,
                              NSString *description,
                              NSError *_Nullable underlying) {
    if (error != NULL) {
        NSMutableDictionary *userInfo = [NSMutableDictionary
            dictionaryWithObject:description forKey:NSLocalizedDescriptionKey];
        if (underlying != nil) userInfo[NSUnderlyingErrorKey] = underlying;
        *error = [NSError errorWithDomain:MTThemeLibraryStoreErrorDomain
                                     code:code
                                 userInfo:userInfo];
    }
    return NO;
}

static NSError *MTLibraryPOSIXError(void) {
    return [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
}

static BOOL MTLibraryEnsureDirectory(NSURL *url, NSError **error) {
    struct stat status;
    if (lstat(url.path.fileSystemRepresentation, &status) != 0) {
        if (errno != ENOENT) {
            return MTLibrarySetError(error, MTThemeLibraryStoreErrorStorage,
                @"Unable to inspect a library directory.",
                MTLibraryPOSIXError());
        }
        NSError *createError = nil;
        if (![NSFileManager.defaultManager createDirectoryAtURL:url
                                     withIntermediateDirectories:YES
                                                      attributes:@{
                NSFilePosixPermissions : @0700
            }
                                                           error:&createError]) {
            return MTLibrarySetError(error, MTThemeLibraryStoreErrorStorage,
                @"Unable to create a library directory.", createError);
        }
        if (lstat(url.path.fileSystemRepresentation, &status) != 0) {
            return MTLibrarySetError(error, MTThemeLibraryStoreErrorStorage,
                @"Unable to verify a library directory.",
                MTLibraryPOSIXError());
        }
    }
    if (!S_ISDIR(status.st_mode) || S_ISLNK(status.st_mode)) {
        return MTLibrarySetError(error, MTThemeLibraryStoreErrorVerification,
            @"Library path is not a safe directory.", nil);
    }
    if (chmod(url.path.fileSystemRepresentation, 0700) != 0) {
        return MTLibrarySetError(error, MTThemeLibraryStoreErrorStorage,
            @"Unable to enforce library directory permissions.",
            MTLibraryPOSIXError());
    }
    return YES;
}

static BOOL MTLibraryWriteFileExclusively(NSURL *url,
                                          NSData *data,
                                          NSError **error) {
    int descriptor = open(url.path.fileSystemRepresentation,
        O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (descriptor < 0) {
        return MTLibrarySetError(error, MTThemeLibraryStoreErrorStorage,
            @"Unable to create a library staging file.",
            MTLibraryPOSIXError());
    }
    const unsigned char *bytes = data.bytes;
    NSUInteger written = 0;
    BOOL success = YES;
    while (written < data.length) {
        ssize_t count = write(descriptor, bytes + written, data.length - written);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) {
            success = MTLibrarySetError(error,
                MTThemeLibraryStoreErrorStorage,
                @"Unable to write a library staging file.",
                MTLibraryPOSIXError());
            break;
        }
        written += (NSUInteger)count;
    }
    if (success && fsync(descriptor) != 0) {
        success = MTLibrarySetError(error, MTThemeLibraryStoreErrorStorage,
            @"Unable to synchronize a library staging file.",
            MTLibraryPOSIXError());
    }
    if (close(descriptor) != 0 && success) {
        success = MTLibrarySetError(error, MTThemeLibraryStoreErrorStorage,
            @"Unable to close a library staging file.",
            MTLibraryPOSIXError());
    }
    return success;
}

static NSData *_Nullable MTLibraryReadRegularFile(NSURL *url,
                                                   uint64_t maximumBytes,
                                                   NSError **error) {
    int descriptor = open(url.path.fileSystemRepresentation,
                          O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (descriptor < 0) {
        MTLibrarySetError(error, MTThemeLibraryStoreErrorStorage,
                          @"Unable to open a library file.",
                          MTLibraryPOSIXError());
        return nil;
    }
    struct stat status;
    if (fstat(descriptor, &status) != 0 || !S_ISREG(status.st_mode) ||
        status.st_nlink != 1 || status.st_size < 0 ||
        (uint64_t)status.st_size > maximumBytes) {
        close(descriptor);
        MTLibrarySetError(error, MTThemeLibraryStoreErrorVerification,
            @"Library file is unsafe or exceeds its byte limit.", nil);
        return nil;
    }
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)status.st_size];
    unsigned char *bytes = data.mutableBytes;
    NSUInteger offset = 0;
    while (offset < data.length) {
        ssize_t count = read(descriptor, bytes + offset, data.length - offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) {
            close(descriptor);
            MTLibrarySetError(error, MTThemeLibraryStoreErrorStorage,
                              @"Unable to read a library file.",
                              MTLibraryPOSIXError());
            return nil;
        }
        offset += (NSUInteger)count;
    }
    unsigned char extra = 0;
    ssize_t extraCount = read(descriptor, &extra, 1);
    struct stat finalStatus;
    BOOL stable = extraCount == 0 && fstat(descriptor, &finalStatus) == 0 &&
        status.st_dev == finalStatus.st_dev &&
        status.st_ino == finalStatus.st_ino &&
        status.st_size == finalStatus.st_size &&
        status.st_mtimespec.tv_sec == finalStatus.st_mtimespec.tv_sec &&
        status.st_mtimespec.tv_nsec == finalStatus.st_mtimespec.tv_nsec;
    close(descriptor);
    if (!stable) {
        MTLibrarySetError(error, MTThemeLibraryStoreErrorVerification,
            @"Library file changed while it was read.", nil);
        return nil;
    }
    return [data copy];
}

static BOOL MTLibrarySynchronizeDirectory(NSURL *url, NSError **error) {
    int descriptor = open(url.path.fileSystemRepresentation,
                          O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (descriptor < 0) {
        return MTLibrarySetError(error, MTThemeLibraryStoreErrorStorage,
            @"Unable to open a library directory for synchronization.",
            MTLibraryPOSIXError());
    }
    BOOL success = fsync(descriptor) == 0;
    int savedErrno = errno;
    close(descriptor);
    if (!success) {
        errno = savedErrno;
        return MTLibrarySetError(error, MTThemeLibraryStoreErrorStorage,
            @"Unable to synchronize a library directory.",
            MTLibraryPOSIXError());
    }
    return YES;
}

static NSString *_Nullable MTThemeStorageIdentifier(NSString *themeID) {
    NSString *normalized = MTNormalizeIdentifier(themeID, NULL);
    if (normalized == nil) return nil;
    NSData *data = [normalized dataUsingEncoding:NSUTF8StringEncoding];
    NSString *digest = MTSHA256HexDigestForData(data);
    return [@"t-" stringByAppendingString:[digest substringToIndex:32]];
}

@implementation MTThemeLibraryStore

- (instancetype)initWithRootURL:(NSURL *)rootURL {
    MTThemeLibraryConfiguration *configuration =
        [[MTThemeLibraryConfiguration alloc]
            initWithRootURL:rootURL
                     limits:MTImportLimits.defaultLimits
       minimumFreeSpaceReserveBytes:64ULL * 1024ULL * 1024ULL];
    return [self initWithConfiguration:configuration];
}

- (instancetype)initWithConfiguration:
        (MTThemeLibraryConfiguration *)configuration {
    NSParameterAssert(configuration != nil);
    self = [super init];
    if (self == nil) return nil;
    _configuration = configuration;
    _rootURL = [configuration.rootURL copy];
    return self;
}

- (BOOL)prepareThemeDirectoriesForStorageID:(NSString *)storageID
                                    themeURL:(NSURL **)themeURL
                                revisionsURL:(NSURL **)revisionsURL
                                       error:(NSError **)error {
    NSURL *themes = [self.rootURL URLByAppendingPathComponent:@"themes"
                                                  isDirectory:YES];
    NSURL *theme = [themes URLByAppendingPathComponent:storageID isDirectory:YES];
    NSURL *revisions = [theme URLByAppendingPathComponent:@"revisions"
                                               isDirectory:YES];
    if (!MTLibraryEnsureDirectory(self.rootURL, error) ||
        !MTLibraryEnsureDirectory(themes, error) ||
        !MTLibraryEnsureDirectory(theme, error) ||
        !MTLibraryEnsureDirectory(revisions, error)) {
        return NO;
    }
    if (themeURL != NULL) *themeURL = theme;
    if (revisionsURL != NULL) *revisionsURL = revisions;
    return YES;
}

- (BOOL)existingRevisionAtURL:(NSURL *)revisionURL
               matchesDigest:(NSString *)digest
                canonicalData:(NSData *)canonicalData
                        error:(NSError **)error {
    NSURL *manifestURL = [revisionURL URLByAppendingPathComponent:@"manifest.json"];
    NSData *existing = MTLibraryReadRegularFile(manifestURL, 16 * 1024 * 1024,
                                                 error);
    return existing != nil &&
        [MTSHA256HexDigestForData(existing) isEqualToString:digest] &&
        [existing isEqualToData:canonicalData];
}

- (BOOL)writeCurrentDigest:(NSString *)digest
                  themeURL:(NSURL *)themeURL
                     error:(NSError **)error {
    NSError *canonicalError = nil;
    NSData *pointer = MTCanonicalJSONData(@{
        @"digest" : digest,
        @"schemaVersion" : @1,
    }, &canonicalError);
    if (pointer == nil) {
        return MTLibrarySetError(error, MTThemeLibraryStoreErrorStorage,
            @"Unable to encode the current library revision.", canonicalError);
    }
    NSString *temporaryName = [NSString stringWithFormat:@".current-%@",
        NSUUID.UUID.UUIDString.lowercaseString];
    NSURL *temporaryURL = [themeURL URLByAppendingPathComponent:temporaryName];
    NSURL *currentURL = [themeURL URLByAppendingPathComponent:@"current.json"];
    if (!MTLibraryWriteFileExclusively(temporaryURL, pointer, error)) return NO;
    if (rename(temporaryURL.path.fileSystemRepresentation,
               currentURL.path.fileSystemRepresentation) != 0) {
        NSError *renameError = MTLibraryPOSIXError();
        [NSFileManager.defaultManager removeItemAtURL:temporaryURL error:NULL];
        return MTLibrarySetError(error, MTThemeLibraryStoreErrorStorage,
            @"Unable to atomically update the current library revision.",
            renameError);
    }
    return MTLibrarySynchronizeDirectory(themeURL, error);
}

- (NSString *)saveManifestRevision:(MTThemeManifest *)manifest
                              error:(NSError **)error {
    if (![manifest isKindOfClass:MTThemeManifest.class]) {
        MTLibrarySetError(error, MTThemeLibraryStoreErrorInvalidRequest,
                          @"Library manifest is invalid.", nil);
        return nil;
    }
    NSError *canonicalError = nil;
    NSData *canonicalData = [manifest canonicalDataWithError:&canonicalError];
    if (canonicalData == nil || canonicalData.length > 16 * 1024 * 1024) {
        MTLibrarySetError(error, MTThemeLibraryStoreErrorLimitExceeded,
            @"Canonical manifest is invalid or exceeds 16 MiB.",
            canonicalError);
        return nil;
    }
    NSString *digest = MTSHA256HexDigestForData(canonicalData);
    NSString *storageID = MTThemeStorageIdentifier(manifest.themeID);
    NSURL *themeURL = nil;
    NSURL *revisionsURL = nil;
    if (storageID == nil ||
        ![self prepareThemeDirectoriesForStorageID:storageID
                                          themeURL:&themeURL
                                      revisionsURL:&revisionsURL
                                             error:error]) {
        return nil;
    }
    NSURL *revisionURL = [revisionsURL URLByAppendingPathComponent:digest
                                                       isDirectory:YES];
    struct stat revisionStatus;
    if (lstat(revisionURL.path.fileSystemRepresentation, &revisionStatus) == 0) {
        if (!S_ISDIR(revisionStatus.st_mode) ||
            ![self existingRevisionAtURL:revisionURL
                           matchesDigest:digest
                            canonicalData:canonicalData
                                    error:error]) {
            if (error == NULL || *error == nil) {
                MTLibrarySetError(error,
                    MTThemeLibraryStoreErrorVerification,
                    @"Existing library revision failed verification.", nil);
            }
            return nil;
        }
        return [self writeCurrentDigest:digest themeURL:themeURL error:error]
            ? digest : nil;
    }
    if (errno != ENOENT) {
        MTLibrarySetError(error, MTThemeLibraryStoreErrorStorage,
            @"Unable to inspect the target library revision.",
            MTLibraryPOSIXError());
        return nil;
    }

    NSString *stagingName = [NSString stringWithFormat:@".staging-%@",
        NSUUID.UUID.UUIDString.lowercaseString];
    NSURL *stagingURL = [themeURL URLByAppendingPathComponent:stagingName
                                                 isDirectory:YES];
    if (!MTLibraryEnsureDirectory(stagingURL, error)) return nil;
    NSURL *stagedManifest = [stagingURL URLByAppendingPathComponent:@"manifest.json"];
    if (!MTLibraryWriteFileExclusively(stagedManifest, canonicalData, error) ||
        !MTLibrarySynchronizeDirectory(stagingURL, error)) {
        [NSFileManager.defaultManager removeItemAtURL:stagingURL error:NULL];
        return nil;
    }
    if (rename(stagingURL.path.fileSystemRepresentation,
               revisionURL.path.fileSystemRepresentation) != 0) {
        NSError *renameError = MTLibraryPOSIXError();
        [NSFileManager.defaultManager removeItemAtURL:stagingURL error:NULL];
        MTLibrarySetError(error, MTThemeLibraryStoreErrorStorage,
            @"Unable to atomically publish the manifest revision.",
            renameError);
        return nil;
    }
    if (!MTLibrarySynchronizeDirectory(revisionsURL, error) ||
        ![self writeCurrentDigest:digest themeURL:themeURL error:error]) {
        return nil;
    }
    return digest;
}

- (MTThemeManifest *)loadCurrentManifestForThemeID:(NSString *)themeID
                                              error:(NSError **)error {
    NSString *storageID = MTThemeStorageIdentifier(themeID);
    if (storageID == nil) {
        MTLibrarySetError(error, MTThemeLibraryStoreErrorInvalidRequest,
                          @"Theme ID is invalid.", nil);
        return nil;
    }
    NSURL *themeURL = nil;
    NSURL *revisionsURL = nil;
    if (![self prepareThemeDirectoriesForStorageID:storageID
                                          themeURL:&themeURL
                                      revisionsURL:&revisionsURL
                                             error:error]) {
        return nil;
    }
    NSData *pointerData = MTLibraryReadRegularFile(
        [themeURL URLByAppendingPathComponent:@"current.json"], 4096, error);
    if (pointerData == nil) return nil;
    NSError *parseError = nil;
    id pointer = [NSJSONSerialization JSONObjectWithData:pointerData
                                                 options:0
                                                   error:&parseError];
    NSData *canonicalPointer = [pointer isKindOfClass:NSDictionary.class]
        ? MTCanonicalJSONData(pointer, &parseError) : nil;
    if ([pointer isKindOfClass:NSDictionary.class] &&
        [pointer[@"schemaVersion"] isEqual:@2]) {
        MTThemeLibraryRevision *revision =
            [self loadCurrentRevisionForThemeID:themeID error:error];
        return revision.manifest;
    }
    NSString *digest = [pointer isKindOfClass:NSDictionary.class]
        ? pointer[@"digest"] : nil;
    if (![pointer isKindOfClass:NSDictionary.class] ||
        [(NSDictionary *)pointer count] != 2 ||
        ![pointer[@"schemaVersion"] isEqual:@1] ||
        ![canonicalPointer isEqualToData:pointerData] ||
        digest == nil ||
        !MTStringIsLowercaseSHA256Digest(digest)) {
        MTLibrarySetError(error, MTThemeLibraryStoreErrorVerification,
            @"Current library revision pointer is malformed.", parseError);
        return nil;
    }
    NSURL *manifestURL = [[[revisionsURL
        URLByAppendingPathComponent:digest isDirectory:YES]
        URLByAppendingPathComponent:@"manifest.json"] copy];
    NSData *manifestData = MTLibraryReadRegularFile(manifestURL,
                                                     16 * 1024 * 1024, error);
    if (manifestData == nil ||
        ![MTSHA256HexDigestForData(manifestData) isEqualToString:digest]) {
        if (error == NULL || *error == nil) {
            MTLibrarySetError(error, MTThemeLibraryStoreErrorVerification,
                @"Current manifest digest verification failed.", nil);
        }
        return nil;
    }
    id manifestDictionary = [NSJSONSerialization JSONObjectWithData:manifestData
                                                              options:0
                                                                error:&parseError];
    MTThemeManifest *manifest = [manifestDictionary isKindOfClass:NSDictionary.class]
        ? [[MTThemeManifest alloc] initWithDictionary:manifestDictionary
                                                error:&parseError]
        : nil;
    NSData *roundTrip = [manifest canonicalDataWithError:&parseError];
    if (manifest == nil || ![manifest.themeID isEqualToString:
            MTNormalizeIdentifier(themeID, NULL)] ||
        ![roundTrip isEqualToData:manifestData]) {
        MTLibrarySetError(error, MTThemeLibraryStoreErrorVerification,
            @"Current manifest failed canonical round-trip validation.",
            parseError);
        return nil;
    }
    return manifest;
}

@end
