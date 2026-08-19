#import <Foundation/Foundation.h>

#import <sys/stat.h>

#import "MTAssetStagingSession.h"

@class MTImportCancellationToken;

NS_ASSUME_NONNULL_BEGIN

// Private descriptor-relative filesystem primitives for
// MTAssetStagingSession. Keeping this surface internal makes the public
// transaction API small without generalizing security-sensitive path rules.
NSError *MTAssetError(MTAssetStagingSessionErrorCode code,
                      NSString *description,
                      NSError *_Nullable underlying);
NSError *MTAssetPOSIXError(int value);
BOOL MTAssetSetError(NSError **error,
                     MTAssetStagingSessionErrorCode code,
                     NSString *description,
                     NSError *_Nullable underlying);

BOOL MTAssetSessionIdentifierIsCanonical(NSString *identifier);
NSString *MTAssetCreatePartialName(void);
BOOL MTAssetStatIdentityMatches(const struct stat *left,
                                const struct stat *right);

BOOL MTOpenAssetSessionsRoot(
    MTAssetStagingConfiguration *configuration,
    BOOL createIfMissing,
    int *rootDescriptor,
    struct stat *_Nullable rootStatus,
    NSError **error);
BOOL MTCreateAssetSessionDirectory(
    int rootDescriptor,
    NSString * _Nullable * _Nonnull sessionIdentifier,
    struct stat *sessionStatus,
    NSError **error);
BOOL MTDiscardAssetSessionAtRootDescriptor(
    int rootDescriptor,
    NSString *sessionIdentifier,
    uint64_t expectedDevice,
    uint64_t expectedInode,
    NSError **error);
BOOL MTOpenAssetSessionDescriptors(
    MTAssetStagingConfiguration *configuration,
    NSString *sessionIdentifier,
    uint64_t rootDevice,
    uint64_t rootInode,
    uint64_t sessionDevice,
    uint64_t sessionInode,
    int *rootDescriptor,
    int *sessionDescriptor,
    int *objectsDescriptor,
    NSError **error);

BOOL MTAssetWriteAll(int descriptor,
                     const void *bytes,
                     size_t length,
                     NSError **error);
BOOL MTAssetHasAvailableSpace(int descriptor,
                              uint64_t requiredBytes,
                              NSError **error);
BOOL MTAssetSessionPathsAreStable(
    MTAssetStagingConfiguration *configuration,
    NSString *sessionIdentifier,
    uint64_t rootDevice,
    uint64_t rootInode,
    uint64_t sessionDevice,
    uint64_t sessionInode,
    int rootDescriptor,
    int sessionDescriptor,
    int objectsDescriptor,
    NSError **error);
BOOL MTAssetVerifyOwnedFile(
    int directoryDescriptor,
    const char *name,
    uint64_t expectedBytes,
    NSString *expectedDigest,
    MTImportCancellationToken *_Nullable cancellationToken,
    struct stat *_Nullable verifiedStatus,
    NSError **error);
BOOL MTAssetVerifyKnownFileIdentity(
    int directoryDescriptor,
    const char *name,
    uint64_t expectedBytes,
    const struct stat *verifiedBaseline,
    MTImportCancellationToken *_Nullable cancellationToken,
    NSError **error);

NS_ASSUME_NONNULL_END
