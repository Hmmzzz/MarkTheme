#import <Foundation/Foundation.h>

#import <sys/stat.h>

#import "MTDirectorySnapshotSession.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT const char *MTDirectorySnapshotPartialName;
FOUNDATION_EXPORT const char *MTDirectorySnapshotPublishedName;

NSError *MTDirectorySnapshotPOSIXError(int value);
NSError *MTDirectorySnapshotError(
    MTDirectorySnapshotSessionErrorCode code,
    NSString *description,
    NSError *_Nullable underlying);
BOOL MTDirectorySnapshotSetError(
    NSError **error,
    MTDirectorySnapshotSessionErrorCode code,
    NSString *description,
    NSError *_Nullable underlying);

BOOL MTDirectorySnapshotIdentifierIsCanonical(NSString *identifier);

BOOL MTOpenDirectorySnapshotRoot(
    MTDirectorySnapshotConfiguration *configuration,
    BOOL createIfMissing,
    int *rootDescriptor,
    struct stat *_Nullable rootStatus,
    NSError **error);

BOOL MTCreateDirectorySnapshotSession(
    int rootDescriptor,
    NSString * _Nullable * _Nonnull sessionIdentifier,
    int *sessionDescriptor,
    int *partialDescriptor,
    struct stat *sessionStatus,
    NSError **error);

BOOL MTDirectorySnapshotValidateInventory(
    MTSourceInventory *inventory,
    MTImportLimits *limits,
    NSError **error);

BOOL MTDirectorySnapshotHasSpace(
    int descriptor,
    uint64_t bytes,
    uint64_t reserve,
    NSError **error);

BOOL MTDirectorySnapshotCopyInventory(
    id<MTAuditedSource> source,
    int partialDescriptor,
    MTImportCancellationToken *_Nullable cancellationToken,
    NSError **error);

BOOL MTDiscardDirectorySnapshotAtRootDescriptor(
    int rootDescriptor,
    NSString *sessionIdentifier,
    uint64_t expectedDevice,
    uint64_t expectedInode,
    MTDirectorySnapshotConfiguration *configuration,
    NSError **error);

NS_ASSUME_NONNULL_END
