#import <Foundation/Foundation.h>

#import <sys/stat.h>

#import "MTGenerationReader.h"

@class MTImportCancellationToken;

NS_ASSUME_NONNULL_BEGIN

typedef struct MTGenerationReaderDirectories {
    int rootDescriptor;
    int generationsDescriptor;
    int generationDescriptor;
    struct stat rootStatus;
    struct stat generationsStatus;
    struct stat generationStatus;
} MTGenerationReaderDirectories;

NSError *MTGenerationReaderError(MTGenerationReaderErrorCode code,
                                 NSString *description,
                                 NSError *_Nullable underlying);
BOOL MTGenerationReaderSetError(NSError **error,
                                MTGenerationReaderErrorCode code,
                                NSString *description,
                                NSError *_Nullable underlying);
NSError *MTGenerationReaderPOSIXError(int value);

BOOL MTGenerationReaderIdentifierIsCanonical(NSString *identifier);
BOOL MTGenerationReaderCancelled(
    MTImportCancellationToken *_Nullable token,
    NSString *description,
    NSError **error);

void MTGenerationReaderDirectoriesInitialize(
    MTGenerationReaderDirectories *directories);
void MTGenerationReaderDirectoriesClose(
    MTGenerationReaderDirectories *directories);
BOOL MTGenerationReaderOpenDirectories(
    MTGenerationReaderConfiguration *configuration,
    NSString *generationIdentifier,
    MTGenerationReaderDirectories *directories,
    NSError **error);
BOOL MTGenerationReaderDirectoriesAreStable(
    MTGenerationReaderConfiguration *configuration,
    NSString *generationIdentifier,
    MTGenerationReaderDirectories *directories,
    NSError **error);

BOOL MTGenerationReaderOpenDirectoryAt(
    int parentDescriptor,
    NSString *name,
    MTGenerationReaderOwnershipProfile ownershipProfile,
    int *descriptor,
    struct stat *status,
    NSError **error);
BOOL MTGenerationReaderDirectoryIsStableAt(
    int parentDescriptor,
    NSString *name,
    int descriptor,
    const struct stat *originalStatus,
    MTGenerationReaderOwnershipProfile ownershipProfile,
    NSError **error);
BOOL MTGenerationReaderDirectoryDescriptorIsStable(
    int descriptor,
    const struct stat *originalStatus,
    MTGenerationReaderOwnershipProfile ownershipProfile,
    NSError **error);
BOOL MTGenerationReaderListDirectoryNames(
    int descriptor,
    NSUInteger maximumEntryCount,
    MTImportCancellationToken *_Nullable token,
    NSArray<NSString *> *_Nullable *_Nonnull names,
    NSError **error);

NSData *_Nullable MTGenerationReaderReadFileAt(
    int directoryDescriptor,
    NSString *name,
    uint64_t maximumBytes,
    MTImportCancellationToken *_Nullable token,
    MTGenerationReaderOwnershipProfile ownershipProfile,
    struct stat *status,
    NSError **error);
BOOL MTGenerationReaderFileIsStableAt(
    int directoryDescriptor,
    NSString *name,
    const struct stat *originalStatus,
    uint64_t expectedBytes,
    MTGenerationReaderOwnershipProfile ownershipProfile,
    NSError **error);
BOOL MTGenerationReaderVerifyAssetAt(
    int assetsDescriptor,
    NSString *digest,
    uint64_t expectedBytes,
    MTImportCancellationToken *_Nullable token,
    MTGenerationReaderOwnershipProfile ownershipProfile,
    struct stat *status,
    NSError **error);

NS_ASSUME_NONNULL_END
