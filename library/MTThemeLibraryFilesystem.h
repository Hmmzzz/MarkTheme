#import <Foundation/Foundation.h>

#import <sys/stat.h>

#import "MTThemeLibraryStore.h"

@class MTImportCancellationToken;

NS_ASSUME_NONNULL_BEGIN

typedef struct MTLibraryRootDirectories {
    int rootDescriptor;
    int themesDescriptor;
    struct stat rootStatus;
    struct stat themesStatus;
} MTLibraryRootDirectories;

typedef struct MTLibraryThemeDirectories {
    int rootDescriptor;
    int themesDescriptor;
    int themeDescriptor;
    int revisionsDescriptor;
    struct stat rootStatus;
    struct stat themesStatus;
    struct stat themeStatus;
    struct stat revisionsStatus;
} MTLibraryThemeDirectories;

NSError *MTLibraryError(MTThemeLibraryStoreErrorCode code,
                        NSString *description,
                        NSError *_Nullable underlying);
BOOL MTLibrarySetError(NSError **error,
                       MTThemeLibraryStoreErrorCode code,
                       NSString *description,
                       NSError *_Nullable underlying);
NSError *MTLibraryPOSIXError(int value);

NSString *_Nullable MTLibraryStorageIdentifierForThemeID(NSString *themeID);
BOOL MTLibraryStorageIdentifierIsCanonical(NSString *identifier);
NSString *_Nullable MTLibraryRevisionIdentifierForManifestDigest(
    NSString *manifestDigest);
BOOL MTLibraryRevisionIdentifierIsCanonical(NSString *revisionIdentifier);
NSString *MTLibraryCreateTransactionName(void);
BOOL MTLibraryTransactionNameIsCanonical(NSString *name);
NSString *MTLibraryCreateDeletionName(void);
BOOL MTLibraryDeletionNameIsCanonical(NSString *name);

void MTLibraryRootDirectoriesInitialize(MTLibraryRootDirectories *directories);
void MTLibraryRootDirectoriesClose(MTLibraryRootDirectories *directories);
BOOL MTOpenLibraryRootDirectories(
    MTThemeLibraryConfiguration *configuration,
    BOOL createIfMissing,
    MTLibraryRootDirectories *directories,
    NSError **error);
BOOL MTLibraryRootDirectoriesAreStable(
    MTThemeLibraryConfiguration *configuration,
    MTLibraryRootDirectories *directories,
    NSError **error);

void MTLibraryThemeDirectoriesInitialize(MTLibraryThemeDirectories *directories);
void MTLibraryThemeDirectoriesClose(MTLibraryThemeDirectories *directories);
BOOL MTOpenLibraryThemeDirectories(
    MTThemeLibraryConfiguration *configuration,
    NSString *storageIdentifier,
    BOOL createIfMissing,
    MTLibraryThemeDirectories *directories,
    NSError **error);
BOOL MTLibraryThemeDirectoriesAreStable(
    MTThemeLibraryConfiguration *configuration,
    MTLibraryThemeDirectories *directories,
    NSError **error);

int MTLibraryAcquireThemeTransactionLock(int themeDescriptor,
                                         NSError **error);
int MTLibraryAcquireThemeReadLock(int themeDescriptor,
                                  NSError **error);
BOOL MTLibrarySynchronizeDirectoryDescriptor(int descriptor,
                                             NSError **error);
BOOL MTLibraryListDirectoryNames(int descriptor,
                                 NSArray<NSString *> * _Nullable * _Nonnull names,
                                 NSError **error);
BOOL MTLibraryOpenPrivateDirectoryAt(int parentDescriptor,
                                     NSString *name,
                                     int *descriptor,
                                     NSError **error);
BOOL MTLibraryCreatePrivateDirectoryAt(int parentDescriptor,
                                       NSString *name,
                                       int *descriptor,
                                       NSError **error);
BOOL MTLibraryWriteDataExclusivelyAt(int directoryDescriptor,
                                     NSString *name,
                                     NSData *data,
                                     NSError **error);
NSData *_Nullable MTLibraryReadPrivateFileAt(int directoryDescriptor,
                                              NSString *name,
                                              uint64_t maximumBytes,
                                              NSError **error);
BOOL MTLibraryReplaceCurrentData(int themeDescriptor,
                                 NSData *data,
                                 NSError **error);

BOOL MTLibraryCheckAvailableSpace(int descriptor,
                                  uint64_t requiredBytes,
                                  uint64_t reserveBytes,
                                  NSError **error);
BOOL MTLibraryCopyVerifiedAsset(int sourceDirectoryDescriptor,
                                int destinationDirectoryDescriptor,
                                NSString *digest,
                                uint64_t expectedBytes,
                                MTImportCancellationToken *_Nullable token,
                                BOOL *_Nullable usedCloneFastPath,
                                NSError **error);
BOOL MTLibraryVerifyAsset(int directoryDescriptor,
                          NSString *digest,
                          uint64_t expectedBytes,
                          MTImportCancellationToken *_Nullable token,
                          NSError **error);
BOOL MTLibraryInspectAssetMetadata(int directoryDescriptor,
                                   NSString *digest,
                                   uint64_t expectedBytes,
                                   NSError **error);

BOOL MTLibraryCreateTransactionDirectories(int revisionsDescriptor,
                                           NSString *transactionName,
                                           int *transactionDescriptor,
                                           int *assetsDescriptor,
                                           NSError **error);
BOOL MTLibraryDiscardTransaction(int revisionsDescriptor,
                                 NSString *transactionName,
                                 NSError **error);
BOOL MTLibraryQuarantineRevisionForDeletion(
    int revisionsDescriptor,
    NSString *revisionIdentifier,
    NSString *deletionName,
    NSError **error);
BOOL MTLibraryDiscardDeletion(int revisionsDescriptor,
                              NSString *deletionName,
                              NSError **error);
// Removes every superseded published snapshot after current.json has already
// switched. The current snapshot is never renamed or deleted.
BOOL MTLibraryDiscardRevisionsExcept(int revisionsDescriptor,
                                     NSString *currentRevisionIdentifier,
                                     NSError **error);
// Whole-theme deletion. The theme directory is renamed out of the published
// namespace first so an interruption leaves a recoverable quarantine rather
// than a partially deleted theme.
BOOL MTLibraryQuarantineThemeForDeletion(int themesDescriptor,
                                         NSString *storageIdentifier,
                                         NSString *deletionName,
                                         NSError **error);
BOOL MTLibraryDiscardThemeDeletion(int themesDescriptor,
                                   NSString *deletionName,
                                   NSError **error);
BOOL MTLibraryRecoverAbandonedTransactions(int themeDescriptor,
                                           int revisionsDescriptor,
                                           NSError **error);

NS_ASSUME_NONNULL_END
