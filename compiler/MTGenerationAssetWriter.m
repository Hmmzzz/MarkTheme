#import "MTGenerationFilesystem.h"
#import "MTGenerationFilesystemInternal.h"

#import <CommonCrypto/CommonDigest.h>
#import <errno.h>
#import <fcntl.h>
#import <sys/clonefile.h>
#import <sys/stat.h>
#import <unistd.h>

#import "MTDigest.h"
#import "MTImportSession.h"

static BOOL MTGenerationCloneFailureAllowsStreamingFallback(int value) {
    return value == EXDEV || value == ENOTSUP || value == EINVAL ||
        value == ENOSYS || value == EPERM;
}

BOOL MTGenerationCopyVerifiedAssetURL(
    NSURL *sourceURL,
    int destinationDirectoryDescriptor,
    NSString *digest,
    uint64_t expectedBytes,
    MTImportCancellationToken *token,
    BOOL *usedCloneFastPath,
    NSError **error) {
    if (![sourceURL isKindOfClass:NSURL.class] || !sourceURL.isFileURL ||
        sourceURL.path.length == 0 ||
        ![sourceURL.path isEqualToString:
            sourceURL.path.stringByStandardizingPath] ||
        ![sourceURL.lastPathComponent isEqualToString:digest] ||
        !MTStringIsLowercaseSHA256Digest(digest) || expectedBytes == 0) {
        return MTGenerationWriterSetError(error,
            MTGenerationWriterErrorInvalidRequest,
            @"A Generation asset copy request is invalid.", nil);
    }
    if (token.isCancelled) {
        return MTGenerationWriterSetError(error,
            MTGenerationWriterErrorCancelled,
            @"Generation writing was cancelled before copying an asset.", nil);
    }
    NSString *parentPath = sourceURL.URLByDeletingLastPathComponent.path;
    int sourceDirectory = open(parentPath.fileSystemRepresentation,
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    struct stat sourceDirectoryBefore = {0};
    struct stat sourceDirectoryPath = {0};
    if (sourceDirectory < 0 ||
        !MTGenerationValidatePrivateDirectory(sourceDirectory, NO,
                                              &sourceDirectoryBefore, error) ||
        lstat(parentPath.fileSystemRepresentation, &sourceDirectoryPath) != 0 ||
        !MTGenerationStatIdentityMatches(&sourceDirectoryBefore,
                                         &sourceDirectoryPath)) {
        int savedError = errno;
        if (sourceDirectory >= 0) close(sourceDirectory);
        if (error == NULL || *error == nil) {
            MTGenerationWriterSetError(error,
                MTGenerationWriterErrorVerification,
                @"The Library asset directory is not a stable private directory.",
                savedError == 0 ? nil : MTGenerationPOSIXError(savedError));
        }
        return NO;
    }

    const char *name = digest.fileSystemRepresentation;
    int source = openat(sourceDirectory, name,
        O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    struct stat sourceBefore = {0};
    if (source < 0 || fstat(source, &sourceBefore) != 0 ||
        !MTGenerationPrivateFileStatusIsValid(&sourceBefore, expectedBytes) ||
        (uint64_t)sourceBefore.st_size != expectedBytes) {
        int savedError = errno;
        if (source >= 0) close(source);
        close(sourceDirectory);
        return MTGenerationWriterSetError(error,
            MTGenerationWriterErrorVerification,
            @"A Library source asset is not a stable private digest object.",
            savedError == 0 ? nil : MTGenerationPOSIXError(savedError));
    }

    BOOL cloned = clonefileat(sourceDirectory, name,
        destinationDirectoryDescriptor, name,
        CLONE_NOFOLLOW | CLONE_NOOWNERCOPY) == 0;
    int cloneError = cloned ? 0 : errno;
    int destination = -1;
    BOOL success = YES;
    NSString *sourceDigest = nil;
    uint64_t sourceBytes = 0;
    if (cloned) {
        destination = openat(destinationDirectoryDescriptor, name,
            O_RDWR | O_CLOEXEC | O_NOFOLLOW);
        if (destination < 0 || fchmod(destination, 0600) != 0 ||
            fsync(destination) != 0) {
            success = MTGenerationWriterSetError(error,
                MTGenerationWriterErrorStorage,
                @"Unable to protect or synchronize a cloned Generation asset.",
                MTGenerationPOSIXError(errno));
        }
        if (success) {
            sourceDigest = MTGenerationHashDescriptor(source, expectedBytes,
                token, &sourceBytes, error);
            success = sourceDigest != nil;
        }
    } else if (MTGenerationCloneFailureAllowsStreamingFallback(cloneError)) {
        unlinkat(destinationDirectoryDescriptor, name, 0);
        destination = openat(destinationDirectoryDescriptor, name,
            O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
        if (destination < 0 || fchmod(destination, 0600) != 0) {
            success = MTGenerationWriterSetError(error,
                MTGenerationWriterErrorStorage,
                @"Unable to create a streamed Generation asset destination.",
                MTGenerationPOSIXError(errno));
        }
        if (success && lseek(source, 0, SEEK_SET) < 0) {
            success = MTGenerationWriterSetError(error,
                MTGenerationWriterErrorStorage,
                @"Unable to seek a Library asset for Generation copying.",
                MTGenerationPOSIXError(errno));
        }
        CC_SHA256_CTX context;
        CC_SHA256_Init(&context);
        unsigned char buffer[64 * 1024];
        while (success) {
            if (token.isCancelled) {
                success = MTGenerationWriterSetError(error,
                    MTGenerationWriterErrorCancelled,
                    @"Generation writing was cancelled while copying an asset.",
                    nil);
                break;
            }
            ssize_t count = read(source, buffer, sizeof(buffer));
            if (count < 0 && errno == EINTR) continue;
            if (count < 0) {
                success = MTGenerationWriterSetError(error,
                    MTGenerationWriterErrorStorage,
                    @"Unable to read a Library asset while writing a Generation.",
                    MTGenerationPOSIXError(errno));
                break;
            }
            if (count == 0) break;
            if ((uint64_t)count > expectedBytes - sourceBytes) {
                success = MTGenerationWriterSetError(error,
                    MTGenerationWriterErrorVerification,
                    @"A Library asset grew while its Generation copy was written.",
                    nil);
                break;
            }
            if (!MTGenerationWriteAll(destination, buffer, (size_t)count,
                                      error)) {
                success = NO;
                break;
            }
            sourceBytes += (uint64_t)count;
            CC_SHA256_Update(&context, buffer, (CC_LONG)count);
        }
        if (success) {
            unsigned char hash[CC_SHA256_DIGEST_LENGTH];
            CC_SHA256_Final(hash, &context);
            sourceDigest = MTGenerationHexDigest(hash);
            if (destination < 0 || fsync(destination) != 0) {
                success = MTGenerationWriterSetError(error,
                    MTGenerationWriterErrorStorage,
                    @"Unable to synchronize a streamed Generation asset.",
                    MTGenerationPOSIXError(errno));
            }
        }
    } else {
        success = MTGenerationWriterSetError(error,
            MTGenerationWriterErrorStorage,
            @"Unable to clone the Library asset into the Generation store.",
            MTGenerationPOSIXError(cloneError));
    }

    struct stat sourceAfter = {0};
    struct stat sourcePath = {0};
    struct stat sourceDirectoryAfter = {0};
    if (success) {
        success = sourceBytes == expectedBytes &&
            [sourceDigest isEqualToString:digest] &&
            fstat(source, &sourceAfter) == 0 &&
            MTGenerationFileStatusIsStable(&sourceBefore, &sourceAfter) &&
            fstatat(sourceDirectory, name, &sourcePath,
                    AT_SYMLINK_NOFOLLOW) == 0 &&
            MTGenerationStatIdentityMatches(&sourceAfter, &sourcePath) &&
            fstat(sourceDirectory, &sourceDirectoryAfter) == 0 &&
            MTGenerationStatIdentityMatches(&sourceDirectoryBefore,
                                            &sourceDirectoryAfter) &&
            MTGenerationPrivateDirectoryStatusIsValid(
                &sourceDirectoryAfter) &&
            lstat(parentPath.fileSystemRepresentation,
                  &sourceDirectoryPath) == 0 &&
            MTGenerationStatIdentityMatches(&sourceDirectoryAfter,
                                            &sourceDirectoryPath);
        if (!success) {
            MTGenerationWriterSetError(error,
                MTGenerationWriterErrorVerification,
                @"A Library asset changed or failed its digest during Generation writing.",
                nil);
        }
    }
    if (destination >= 0 && close(destination) != 0 && success) {
        success = MTGenerationWriterSetError(error,
            MTGenerationWriterErrorStorage,
            @"Unable to close a Generation asset destination.",
            MTGenerationPOSIXError(errno));
    }
    close(source);
    close(sourceDirectory);
    if (success) {
        success = MTGenerationVerifyPrivateFileAt(
            destinationDirectoryDescriptor, digest, expectedBytes, digest,
            token, error);
    }
    if (!success) {
        unlinkat(destinationDirectoryDescriptor, name, 0);
        return NO;
    }
    if (usedCloneFastPath != NULL) *usedCloneFastPath = cloned;
    return YES;
}
