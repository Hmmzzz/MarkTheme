#import "MTThemeLibraryCatalog.h"

#import <sys/stat.h>
#import <unistd.h>

#import "MTDigest.h"
#import "MTIdentifier.h"
#import "MTImportSession.h"
#import "MTThemeLibraryFilesystem.h"
#import "MTThemeLibraryStoreInternal.h"
#import "MTThemeManifest.h"

@interface MTThemeLibraryRevisionSummary ()

@property(nonatomic, copy, readwrite) NSString *revisionIdentifier;
@property(nonatomic, copy, readwrite) NSString *manifestDigest;
@property(nonatomic, strong, readwrite) MTThemeManifest *manifest;
@property(nonatomic, assign, readwrite) NSUInteger assetCount;
@property(nonatomic, assign, readwrite) uint64_t assetByteCount;

- (instancetype)initWithRevisionIdentifier:(NSString *)revisionIdentifier
                             manifestDigest:(NSString *)manifestDigest
                                    manifest:(MTThemeManifest *)manifest
                                  assetCount:(NSUInteger)assetCount
                              assetByteCount:(uint64_t)assetByteCount;

@end

@interface MTThemeLibraryThemeSummary ()

@property(nonatomic, copy, readwrite) NSString *themeID;
@property(nonatomic, strong, readwrite)
    MTThemeLibraryRevisionSummary *currentRevision;

- (instancetype)initWithCurrentRevision:
        (MTThemeLibraryRevisionSummary *)currentRevision;

@end

@implementation MTThemeLibraryRevisionSummary

- (instancetype)initWithRevisionIdentifier:(NSString *)revisionIdentifier
                             manifestDigest:(NSString *)manifestDigest
                                    manifest:(MTThemeManifest *)manifest
                                  assetCount:(NSUInteger)assetCount
                              assetByteCount:(uint64_t)assetByteCount {
    self = [super init];
    if (self == nil) return nil;
    _revisionIdentifier = [revisionIdentifier copy];
    _manifestDigest = [manifestDigest copy];
    _manifest = manifest;
    _assetCount = assetCount;
    _assetByteCount = assetByteCount;
    return self;
}

@end

@implementation MTThemeLibraryThemeSummary

- (instancetype)initWithCurrentRevision:
        (MTThemeLibraryRevisionSummary *)currentRevision {
    self = [super init];
    if (self == nil) return nil;
    _themeID = [currentRevision.manifest.themeID copy];
    _currentRevision = currentRevision;
    return self;
}

@end

static BOOL MTLibraryCatalogCheckCancellation(
    MTImportCancellationToken *token,
    NSError **error) {
    return !token.isCancelled || MTLibrarySetError(error,
        MTThemeLibraryStoreErrorCancelled,
        @"The Library catalog operation was cancelled.", nil);
}

static BOOL MTLibraryDirectoryDescriptorMatchesPath(
    int parentDescriptor,
    NSString *name,
    int descriptor,
    NSError **error) {
    struct stat pathStatus = {0};
    struct stat openedStatus = {0};
    BOOL stable = fstatat(parentDescriptor, name.fileSystemRepresentation,
                          &pathStatus, AT_SYMLINK_NOFOLLOW) == 0 &&
        fstat(descriptor, &openedStatus) == 0 &&
        pathStatus.st_dev == openedStatus.st_dev &&
        pathStatus.st_ino == openedStatus.st_ino &&
        S_ISDIR(openedStatus.st_mode) && openedStatus.st_uid == geteuid() &&
        (openedStatus.st_mode & 0777) == 0700;
    return stable ? YES : MTLibrarySetError(error,
        MTThemeLibraryStoreErrorVerification,
        @"A Library revision directory changed during metadata inspection.",
        nil);
}

static MTThemeManifest *_Nullable MTLibraryCatalogParseManifest(
    NSData *manifestData,
    NSString *expectedDigest,
    NSString *_Nullable expectedThemeID,
    NSString *storageIdentifier,
    NSError **error) {
    NSError *parseError = nil;
    NSDictionary *dictionary = MTLibraryCanonicalDictionaryFromData(
        manifestData, error);
    MTThemeManifest *manifest = dictionary != nil
        ? [[MTThemeManifest alloc] initWithDictionary:dictionary
                                                error:&parseError]
        : nil;
    NSData *roundTrip = [manifest canonicalDataWithError:&parseError];
    NSString *normalizedExpected = expectedThemeID != nil
        ? MTNormalizeIdentifier(expectedThemeID, NULL) : nil;
    BOOL valid = manifest != nil && [roundTrip isEqualToData:manifestData] &&
        [MTSHA256HexDigestForData(manifestData) isEqualToString:expectedDigest] &&
        (normalizedExpected == nil ||
         [manifest.themeID isEqualToString:normalizedExpected]) &&
        [MTLibraryStorageIdentifierForThemeID(manifest.themeID)
            isEqualToString:storageIdentifier];
    if (!valid) {
        if (error == NULL || *error == nil) {
            MTLibrarySetError(error, MTThemeLibraryStoreErrorVerification,
                @"A Library revision manifest failed canonical identity validation.",
                parseError);
        }
        return nil;
    }
    return manifest;
}

static MTThemeLibraryRevisionSummary *_Nullable
MTLibraryInspectFormalRevisionMetadata(
    MTLibraryThemeDirectories *directories,
    NSString *storageIdentifier,
    NSString *_Nullable expectedThemeID,
    NSString *revisionIdentifier,
    MTImportCancellationToken *_Nullable cancellationToken,
    NSError **error) {
    if (!MTLibraryRevisionIdentifierIsCanonical(revisionIdentifier) ||
        !MTLibraryCatalogCheckCancellation(cancellationToken, error)) {
        if (!MTLibraryRevisionIdentifierIsCanonical(revisionIdentifier) &&
            (error == NULL || *error == nil)) {
            MTLibrarySetError(error, MTThemeLibraryStoreErrorVerification,
                @"A formal Library revision identifier is malformed.", nil);
        }
        return nil;
    }
    NSString *manifestDigest = [revisionIdentifier substringFromIndex:3];
    int revisionDescriptor = -1;
    if (!MTLibraryOpenPrivateDirectoryAt(directories->revisionsDescriptor,
            revisionIdentifier, &revisionDescriptor, error)) {
        return nil;
    }
    NSArray<NSString *> *topLevelNames = nil;
    BOOL success = MTLibraryListDirectoryNames(revisionDescriptor,
                                               &topLevelNames, error) &&
        ([topLevelNames isEqualToArray:@[
            @"assets", @"manifest.json", @"revision.json"
        ]] || [topLevelNames isEqualToArray:@[
            @"assets", @"manifest.json", @"resources", @"revision.json"
        ]]);
    if (!success && (error == NULL || *error == nil)) {
        MTLibrarySetError(error, MTThemeLibraryStoreErrorVerification,
            @"A formal Library revision has a non-exact top-level tree.", nil);
    }
    NSData *manifestData = success
        ? MTLibraryReadPrivateFileAt(revisionDescriptor, @"manifest.json",
            MTLibraryMaximumManifestBytes, error) : nil;
    NSData *metadataData = manifestData != nil
        ? MTLibraryReadPrivateFileAt(revisionDescriptor, @"revision.json",
            MTLibraryMaximumRevisionMetadataBytes, error) : nil;
    MTThemeManifest *manifest = metadataData != nil
        ? MTLibraryCatalogParseManifest(manifestData, manifestDigest,
            expectedThemeID, storageIdentifier, error) : nil;
    success = manifest != nil;
    NSArray<NSString *> *requiredDigests = success
        ? MTLibraryRequiredAssetDigests(manifest) : nil;
    uint64_t totalBytes = 0;
    NSDictionary<NSString *, NSNumber *> *byteCounts = success
        ? MTLibraryParseRevisionMetadata(metadataData, manifestDigest,
            requiredDigests, &totalBytes, error) : nil;
    success = byteCounts != nil;

    int assetsDescriptor = -1;
    if (success) {
        success = MTLibraryOpenPrivateDirectoryAt(revisionDescriptor, @"assets",
                                                  &assetsDescriptor, error);
    }
    NSArray<NSString *> *assetNames = nil;
    if (success) {
        success = MTLibraryListDirectoryNames(assetsDescriptor, &assetNames,
                                              error) &&
            [assetNames isEqualToArray:requiredDigests];
        if (!success && (error == NULL || *error == nil)) {
            MTLibrarySetError(error, MTThemeLibraryStoreErrorVerification,
                @"A formal Library revision has a non-exact asset set.", nil);
        }
    }
    if (success) {
        for (NSString *digest in requiredDigests) {
            if (!MTLibraryCatalogCheckCancellation(cancellationToken, error) ||
                !MTLibraryInspectAssetMetadata(assetsDescriptor, digest,
                    byteCounts[digest].unsignedLongLongValue, error)) {
                success = NO;
                break;
            }
        }
    }
    if (success) {
        success = MTLibraryDirectoryDescriptorMatchesPath(revisionDescriptor,
                @"assets", assetsDescriptor, error) &&
            MTLibraryDirectoryDescriptorMatchesPath(
                directories->revisionsDescriptor, revisionIdentifier,
                revisionDescriptor, error);
    }
    if (assetsDescriptor >= 0) close(assetsDescriptor);
    close(revisionDescriptor);
    if (!success || manifest == nil || byteCounts == nil) return nil;
    return [[MTThemeLibraryRevisionSummary alloc]
        initWithRevisionIdentifier:revisionIdentifier
                     manifestDigest:manifestDigest
                            manifest:manifest
                          assetCount:requiredDigests.count
                      assetByteCount:totalBytes];
}

static BOOL MTLibraryValidateThemeTopLevel(
    MTLibraryThemeDirectories *directories,
    NSError **error) {
    NSArray<NSString *> *names = nil;
    if (!MTLibraryListDirectoryNames(directories->themeDescriptor, &names,
                                     error)) {
        return NO;
    }
    NSSet<NSString *> *expected = [NSSet setWithArray:@[
        @"current.json", @"revisions", @"transaction.lock"
    ]];
    return [[NSSet setWithArray:names] isEqualToSet:expected] &&
        names.count == expected.count
        ? YES : MTLibrarySetError(error,
            MTThemeLibraryStoreErrorVerification,
            @"A Library theme directory has missing or unknown entries.", nil);
}

static BOOL MTLibraryDiscardSupersededSnapshots(
    MTLibraryThemeDirectories *directories,
    NSError **error) {
    NSArray<NSString *> *themeNames = nil;
    if (!MTLibraryListDirectoryNames(directories->themeDescriptor, &themeNames,
                                     error)) {
        return NO;
    }
    if (![themeNames containsObject:@"current.json"]) return YES;
    NSData *pointerData = MTLibraryReadPrivateFileAt(
        directories->themeDescriptor, @"current.json",
        MTLibraryMaximumCurrentPointerBytes, error);
    NSString *currentIdentifier = nil;
    if (pointerData == nil || !MTLibraryParseCurrentPointerData(pointerData,
            &currentIdentifier, NULL, error)) {
        return NO;
    }
    return MTLibraryDiscardRevisionsExcept(
        directories->revisionsDescriptor, currentIdentifier, error);
}

static MTThemeLibraryRevisionSummary *_Nullable
MTLibraryLoadCurrentSummaryLocked(
    MTThemeLibraryStore *store,
    MTLibraryThemeDirectories *directories,
    NSString *storageIdentifier,
    NSString *_Nullable expectedThemeID,
    MTImportCancellationToken *_Nullable cancellationToken,
    BOOL *empty,
    NSError **error) {
    if (empty != NULL) *empty = NO;
    if (!MTLibraryCatalogCheckCancellation(cancellationToken, error)) {
        return nil;
    }
    NSArray<NSString *> *themeNames = nil;
    if (!MTLibraryListDirectoryNames(directories->themeDescriptor, &themeNames,
                                     error)) {
        return nil;
    }
    NSSet<NSString *> *actualThemeNames = [NSSet setWithArray:themeNames];
    NSSet<NSString *> *emptyShellNames = [NSSet setWithArray:@[
        @"revisions", @"transaction.lock"
    ]];
    if (themeNames.count == emptyShellNames.count &&
        [actualThemeNames isEqualToSet:emptyShellNames]) {
        NSArray<NSString *> *emptyRevisionNames = nil;
        if (!MTLibraryListDirectoryNames(directories->revisionsDescriptor,
                                         &emptyRevisionNames, error)) {
            return nil;
        }
        if (emptyRevisionNames.count != 0) {
            MTLibrarySetError(error, MTThemeLibraryStoreErrorVerification,
                @"A Library theme has revisions but no current pointer.", nil);
            return nil;
        }
        if (!MTLibraryThemeDirectoriesAreStable(store.configuration,
                                                directories, error)) {
            return nil;
        }
        if (empty != NULL) *empty = YES;
        return nil;
    }
    if (!MTLibraryValidateThemeTopLevel(directories, error)) return nil;
    NSData *pointerData = MTLibraryReadPrivateFileAt(
        directories->themeDescriptor, @"current.json",
        MTLibraryMaximumCurrentPointerBytes, error);
    NSString *currentIdentifier = nil;
    NSString *currentDigest = nil;
    if (pointerData == nil || !MTLibraryParseCurrentPointerData(pointerData,
            &currentIdentifier, &currentDigest, error)) {
        return nil;
    }
    MTThemeLibraryRevisionSummary *currentSummary =
        MTLibraryInspectFormalRevisionMetadata(directories, storageIdentifier,
            expectedThemeID, currentIdentifier, cancellationToken, error);
    if (currentSummary == nil ||
        ![currentSummary.manifestDigest isEqualToString:currentDigest]) {
        if (currentSummary != nil && (error == NULL || *error == nil)) {
            MTLibrarySetError(error, MTThemeLibraryStoreErrorVerification,
                @"The current pointer and revision format do not agree.", nil);
        }
        return nil;
    }
    NSArray<NSString *> *revisionNames = nil;
    if (!MTLibraryListDirectoryNames(directories->revisionsDescriptor,
                                     &revisionNames, error)) {
        return nil;
    }
    if (![revisionNames containsObject:currentIdentifier]) {
        MTLibrarySetError(error, MTThemeLibraryStoreErrorVerification,
            @"The current Library revision is absent from its revision set.",
            nil);
        return nil;
    }
    if (!MTLibraryThemeDirectoriesAreStable(store.configuration, directories,
                                            error)) {
        return nil;
    }
    return currentSummary;
}

static MTThemeLibraryThemeSummary *MTLibraryCreateThemeSummary(
    MTThemeLibraryRevisionSummary *current) {
    return [[MTThemeLibraryThemeSummary alloc]
        initWithCurrentRevision:current];
}

@implementation MTThemeLibraryStore (Catalog)

- (NSArray<MTThemeLibraryThemeSummary *> *)
    loadThemeCatalogWithCancellationToken:
        (MTImportCancellationToken *)cancellationToken
    error:(NSError **)error {
    if (!MTLibraryCatalogCheckCancellation(cancellationToken, error)) return nil;
    MTLibraryRootDirectories rootDirectories;
    NSError *openError = nil;
    if (!MTOpenLibraryRootDirectories(self.configuration, NO,
                                      &rootDirectories, &openError)) {
        if ([openError.domain isEqualToString:MTThemeLibraryStoreErrorDomain] &&
            openError.code == MTThemeLibraryStoreErrorNotFound) {
            return @[];
        }
        if (error != NULL) *error = openError;
        return nil;
    }
    NSArray<NSString *> *initialNames = nil;
    BOOL success = MTLibraryListDirectoryNames(
        rootDirectories.themesDescriptor, &initialNames, error);
    NSMutableArray<MTThemeLibraryThemeSummary *> *catalog =
        [NSMutableArray arrayWithCapacity:initialNames.count];
    NSMutableSet<NSString *> *themeIDs = [NSMutableSet set];
    for (NSString *storageIdentifier in initialNames) {
        if (!success) break;
        if (!MTLibraryCatalogCheckCancellation(cancellationToken, error)) {
            success = NO;
            break;
        }
        if (!MTLibraryStorageIdentifierIsCanonical(storageIdentifier)) {
            success = MTLibrarySetError(error,
                MTThemeLibraryStoreErrorVerification,
                @"The Library themes directory contains an unsupported name.",
                nil);
            break;
        }
        MTLibraryThemeDirectories directories;
        if (!MTOpenLibraryThemeDirectories(self.configuration,
                storageIdentifier, NO, &directories, error)) {
            success = NO;
            break;
        }
        int lockDescriptor = MTLibraryAcquireThemeReadLock(
            directories.themeDescriptor, error);
        MTThemeLibraryRevisionSummary *current = nil;
        BOOL empty = NO;
        if (lockDescriptor >= 0) {
            current = MTLibraryLoadCurrentSummaryLocked(self, &directories,
                storageIdentifier, nil, cancellationToken, &empty, error);
            close(lockDescriptor);
        }
        MTLibraryThemeDirectoriesClose(&directories);
        if (current == nil && !empty) {
            success = NO;
            break;
        }
        if (empty) continue;
        MTThemeLibraryThemeSummary *summary =
            MTLibraryCreateThemeSummary(current);
        if ([themeIDs containsObject:summary.themeID]) {
            success = MTLibrarySetError(error,
                MTThemeLibraryStoreErrorVerification,
                @"The Library catalog contains a duplicate theme identity.", nil);
            break;
        }
        [themeIDs addObject:summary.themeID];
        [catalog addObject:summary];
    }
    NSArray<NSString *> *finalNames = nil;
    if (success) {
        success = MTLibraryListDirectoryNames(rootDirectories.themesDescriptor,
            &finalNames, error) && [initialNames isEqualToArray:finalNames];
        if (!success && (error == NULL || *error == nil)) {
            MTLibrarySetError(error, MTThemeLibraryStoreErrorBusy,
                @"The Library theme set changed during catalog enumeration.",
                nil);
        }
    }
    if (success) {
        success = MTLibraryRootDirectoriesAreStable(self.configuration,
                                                    &rootDirectories, error);
    }
    MTLibraryRootDirectoriesClose(&rootDirectories);
    if (!success) return nil;
    [catalog sortUsingComparator:^NSComparisonResult(
        MTThemeLibraryThemeSummary *left,
        MTThemeLibraryThemeSummary *right) {
        return [left.themeID compare:right.themeID options:NSLiteralSearch];
    }];
    return [catalog copy];
}

- (BOOL)removeThemeWithID:(NSString *)themeID
        cancellationToken:(MTImportCancellationToken *)cancellationToken
                    error:(NSError **)error {
    NSString *normalizedThemeID = MTNormalizeIdentifier(themeID, NULL);
    NSString *storageIdentifier =
        MTLibraryStorageIdentifierForThemeID(themeID);
    if (normalizedThemeID == nil || storageIdentifier == nil) {
        return MTLibrarySetError(error,
            MTThemeLibraryStoreErrorInvalidRequest,
            @"Only a canonical Library theme can be removed.", nil);
    }
    if (!MTLibraryCatalogCheckCancellation(cancellationToken, error)) return NO;

    MTLibraryRootDirectories rootDirectories;
    NSError *openError = nil;
    if (!MTOpenLibraryRootDirectories(self.configuration, NO,
                                      &rootDirectories, &openError)) {
        if (error != NULL) *error = openError;
        return NO;
    }

    // Hold the theme's own transaction lock while quarantining it so a
    // concurrent import or revision switch cannot publish into a directory
    // that is about to leave the namespace.
    MTLibraryThemeDirectories directories;
    BOOL success = MTOpenLibraryThemeDirectories(self.configuration,
        storageIdentifier, NO, &directories, error);
    int lockDescriptor = -1;
    if (success) {
        lockDescriptor = MTLibraryAcquireThemeTransactionLock(
            directories.themeDescriptor, error);
        success = lockDescriptor >= 0;
    }
    if (success) {
        success = MTLibraryRecoverAbandonedTransactions(
            directories.themeDescriptor, directories.revisionsDescriptor,
            error) && MTLibraryCatalogCheckCancellation(cancellationToken,
                                                        error);
    }
    NSString *deletionName = success ? MTLibraryCreateDeletionName() : nil;
    if (success) {
        success = MTLibraryQuarantineThemeForDeletion(
            rootDirectories.themesDescriptor, storageIdentifier, deletionName,
            error);
    }
    if (lockDescriptor >= 0) close(lockDescriptor);
    MTLibraryThemeDirectoriesClose(&directories);

    // The theme is unpublished once the rename succeeds. Like revision
    // deletion, stop observing cancellation here so cleanup either finishes or
    // leaves a recoverable quarantine.
    if (success) {
        success = MTLibraryDiscardThemeDeletion(
            rootDirectories.themesDescriptor, deletionName, error) &&
            MTLibraryRootDirectoriesAreStable(self.configuration,
                                              &rootDirectories, error);
    }
    MTLibraryRootDirectoriesClose(&rootDirectories);
    return success;
}

- (BOOL)recoverAbandonedLibraryOperationsWithError:(NSError **)error {
    MTLibraryRootDirectories rootDirectories;
    NSError *openError = nil;
    if (!MTOpenLibraryRootDirectories(self.configuration, NO,
                                      &rootDirectories, &openError)) {
        if ([openError.domain isEqualToString:MTThemeLibraryStoreErrorDomain] &&
            openError.code == MTThemeLibraryStoreErrorNotFound) {
            return YES;
        }
        if (error != NULL) *error = openError;
        return NO;
    }
    NSArray<NSString *> *storageIdentifiers = nil;
    BOOL success = MTLibraryListDirectoryNames(
        rootDirectories.themesDescriptor, &storageIdentifiers, error);
    for (NSString *storageIdentifier in storageIdentifiers) {
        if (!success) break;
        // A theme deletion that was interrupted after its quarantine rename
        // leaves a deletion-named directory here. Finish it rather than
        // treating it as corruption.
        if (MTLibraryDeletionNameIsCanonical(storageIdentifier)) {
            success = MTLibraryDiscardThemeDeletion(
                rootDirectories.themesDescriptor, storageIdentifier, error);
            continue;
        }
        if (!MTLibraryStorageIdentifierIsCanonical(storageIdentifier)) {
            success = MTLibrarySetError(error,
                MTThemeLibraryStoreErrorRecovery,
                @"Recovery found an unsupported Library theme directory.", nil);
            break;
        }
        MTLibraryThemeDirectories directories;
        if (!MTOpenLibraryThemeDirectories(self.configuration,
                storageIdentifier, NO, &directories, error)) {
            success = NO;
            break;
        }
        int lockDescriptor = MTLibraryAcquireThemeTransactionLock(
            directories.themeDescriptor, error);
        if (lockDescriptor < 0) {
            MTLibraryThemeDirectoriesClose(&directories);
            success = NO;
            break;
        }
        success = MTLibraryRecoverAbandonedTransactions(
            directories.themeDescriptor, directories.revisionsDescriptor,
            error) && MTLibraryDiscardSupersededSnapshots(&directories,
                                                          error) &&
            MTLibraryThemeDirectoriesAreStable(
                self.configuration, &directories, error);
        close(lockDescriptor);
        MTLibraryThemeDirectoriesClose(&directories);
    }
    if (success) {
        success = MTLibraryRootDirectoriesAreStable(self.configuration,
                                                    &rootDirectories, error);
    }
    MTLibraryRootDirectoriesClose(&rootDirectories);
    return success;
}

@end
