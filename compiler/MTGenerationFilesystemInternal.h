#import <Foundation/Foundation.h>

#import <sys/stat.h>

@class MTImportCancellationToken;

NS_ASSUME_NONNULL_BEGIN

// Shared descriptor primitives only. Transaction recovery, source adoption,
// writer tree interpretation, and the future reader parser stay in separate
// translation units so a logic bug cannot silently couple those boundaries.
BOOL MTGenerationStatIdentityMatches(const struct stat *left,
                                     const struct stat *right);
BOOL MTGenerationFileStatusIsStable(const struct stat *before,
                                    const struct stat *after);
BOOL MTGenerationPrivateDirectoryStatusIsValid(const struct stat *status);
BOOL MTGenerationPrivateFileStatusIsValid(const struct stat *status,
                                          uint64_t maximumBytes);
BOOL MTGenerationValidatePrivateDirectory(int descriptor,
                                          BOOL normalizeMode,
                                          struct stat *_Nullable status,
                                          NSError **error);
BOOL MTGenerationWriteAll(int descriptor,
                          const void *bytes,
                          size_t length,
                          NSError **error);
NSString *MTGenerationHexDigest(const unsigned char *bytes);
NSString *_Nullable MTGenerationHashDescriptor(
    int descriptor,
    uint64_t maximumBytes,
    MTImportCancellationToken *_Nullable token,
    uint64_t *_Nullable bytesRead,
    NSError **error);

NS_ASSUME_NONNULL_END
