#import <Foundation/Foundation.h>

#import <sys/stat.h>

#import "MTGenerationWriter.h"

@class MTImportCancellationToken;

NS_ASSUME_NONNULL_BEGIN

typedef struct MTGenerationStoreDirectories {
    int rootDescriptor;
    int generationsDescriptor;
    struct stat rootStatus;
    struct stat generationsStatus;
} MTGenerationStoreDirectories;

NSError *MTGenerationWriterError(MTGenerationWriterErrorCode code,
                                 NSString *description,
                                 NSError *_Nullable underlying);
BOOL MTGenerationWriterSetError(NSError **error,
                                MTGenerationWriterErrorCode code,
                                NSString *description,
                                NSError *_Nullable underlying);
NSError *MTGenerationPOSIXError(int value);

BOOL MTGenerationIdentifierIsCanonical(NSString *identifier);
NSString *MTGenerationCreateTransactionName(void);
BOOL MTGenerationTransactionNameIsCanonical(NSString *name);

void MTGenerationStoreDirectoriesInitialize(
    MTGenerationStoreDirectories *directories);
void MTGenerationStoreDirectoriesClose(
    MTGenerationStoreDirectories *directories);
BOOL MTOpenGenerationStoreDirectories(
    MTGenerationWriterConfiguration *configuration,
    BOOL createIfMissing,
    MTGenerationStoreDirectories *directories,
    NSError **error);
BOOL MTGenerationStoreDirectoriesAreStable(
    MTGenerationWriterConfiguration *configuration,
    MTGenerationStoreDirectories *directories,
    NSError **error);

int MTGenerationAcquireTransactionLock(int rootDescriptor,
                                       NSError **error);
BOOL MTGenerationSynchronizeDirectory(int descriptor, NSError **error);
BOOL MTGenerationListDirectoryNames(int descriptor,
                                    NSArray<NSString *> *_Nullable *_Nonnull names,
                                    NSError **error);
BOOL MTGenerationOpenPrivateDirectoryAt(int parentDescriptor,
                                        NSString *name,
                                        int *descriptor,
                                        NSError **error);
BOOL MTGenerationCreatePrivateDirectoryAt(int parentDescriptor,
                                          NSString *name,
                                          int *descriptor,
                                          NSError **error);
BOOL MTGenerationWriteDataExclusivelyAt(int directoryDescriptor,
                                        NSString *name,
                                        NSData *data,
                                        NSError **error);
NSData *_Nullable MTGenerationReadPrivateFileAt(int directoryDescriptor,
                                                 NSString *name,
                                                 uint64_t maximumBytes,
                                                 NSError **error);
BOOL MTGenerationCheckAvailableSpace(int descriptor,
                                     uint64_t requiredBytes,
                                     uint64_t reserveBytes,
                                     NSError **error);
BOOL MTGenerationVerifyPrivateFileAt(int directoryDescriptor,
                                     NSString *name,
                                     uint64_t expectedBytes,
                                     NSString *_Nullable expectedDigest,
                                     MTImportCancellationToken *_Nullable token,
                                     NSError **error);
BOOL MTGenerationCopyVerifiedAssetURL(
    NSURL *sourceURL,
    int destinationDirectoryDescriptor,
    NSString *digest,
    uint64_t expectedBytes,
    MTImportCancellationToken *_Nullable token,
    BOOL *_Nullable usedCloneFastPath,
    NSError **error);

BOOL MTGenerationCreateTransactionDirectories(
    int generationsDescriptor,
    NSString *transactionName,
    int *transactionDescriptor,
    int *assetsDescriptor,
    NSError **error);
BOOL MTGenerationDiscardTransaction(
    int generationsDescriptor,
    NSString *transactionName,
    MTGenerationWriterConfiguration *configuration,
    NSError **error);
BOOL MTGenerationRecoverAbandonedTransactions(
    int rootDescriptor,
    int generationsDescriptor,
    MTGenerationWriterConfiguration *configuration,
    NSError **error);

NS_ASSUME_NONNULL_END
