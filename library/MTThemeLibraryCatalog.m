#import "MTThemeLibraryCatalog.h"

#import <errno.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <unistd.h>

#import "MTCanonicalJSON.h"
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
@property(nonatomic, assign, readwrite) MTThemeLibraryRevisionFormat format;
@property(nonatomic, assign, readwrite, getter=isCurrent) BOOL current;

- (instancetype)initWithRevisionIdentifier:(NSString *)revisionIdentifier
                             manifestDigest:(NSString *)manifestDigest
                                    manifest:(MTThemeManifest *)manifest
                                  assetCount:(NSUInteger)assetCount
                              assetByteCount:(uint64_t)assetByteCount
                                      format:(MTThemeLibraryRevisionFormat)format
                                     current:(BOOL)current;

@end

@interface MTThemeLibraryThemeSummary ()

@property(nonatomic, copy, readwrite) NSString *themeID;
@property(nonatomic, strong, readwrite)
    MTThemeLibraryRevisionSummary *currentRevision;
@property(nonatomic, copy, readwrite)
    NSArray<MTThemeLibraryRevisionSummary *> *revisionHistory;
@property(nonatomic, assign, readwrite) NSUInteger revisionCount;
@property(nonatomic, assign, readwrite) NSUInteger formalRevisionCount;
@property(nonatomic, assign, readwrite) NSUInteger legacyRevisionCount;

- (instancetype)initWithCurrentRevision:
        (MTThemeLibraryRevisionSummary *)currentRevision
    revisionHistory:
        (NSArray<MTThemeLibraryRevisionSummary *> *)revisionHistory
    revisionCount:(NSUInteger)revisionCount
    formalRevisionCount:(NSUInteger)formalRevisionCount
    legacyRevisionCount:(NSUInteger)legacyRevisionCount;

@end

@implementation MTThemeLibraryRevisionSummary

- (instancetype)initWithRevisionIdentifier:(NSString *)revisionIdentifier
                             manifestDigest:(NSString *)manifestDigest
                                    manifest:(MTThemeManifest *)manifest
                                  assetCount:(NSUInteger)assetCount
                              assetByteCount:(uint64_t)assetByteCount
                                      format:(MTThemeLibraryRevisionFormat)format
                                     current:(BOOL)current {
    self = [super init];
    if (self == nil) return nil;
    _revisionIdentifier = [revisionIdentifier copy];
    _manifestDigest = [manifestDigest copy];
    _manifest = manifest;
    _assetCount = assetCount;
    _assetByteCount = assetByteCount;
    _format = format;
    _current = current;
    return self;
}

- (BOOL)requiresReimport {
    return self.format == MTThemeLibraryRevisionFormatLegacyManifestOnly;
}

@end

@implementation MTThemeLibraryThemeSummary

- (instancetype)initWithCurrentRevision:
        (MTThemeLibraryRevisionSummary *)currentRevision
    revisionHistory:
        (NSArray<MTThemeLibraryRevisionSummary *> *)revisionHistory
    revisionCount:(NSUInteger)revisionCount
    formalRevisionCount:(NSUInteger)formalRevisionCount
    legacyRevisionCount:(NSUInteger)legacyRevisionCount {
    self = [super init];
    if (self == nil) return nil;
    _themeID = [currentRevision.manifest.themeID copy];
    _currentRevision = currentRevision;
    _revisionHistory = [revisionHistory copy];
    _revisionCount = revisionCount;
    _formalRevisionCount = formalRevisionCount;
    _legacyRevisionCount = legacyRevisionCount;
    return self;
}

- (BOOL)requiresReimport {
    return self.currentRevision.requiresReimport;
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
    BOOL current,
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
        [topLevelNames isEqualToArray:@[
            @"assets", @"manifest.json", @"revision.json"
        ]];
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
                      assetByteCount:totalBytes
                              format:MTThemeLibraryRevisionFormatFormalV1
                             current:current];
}

static MTThemeLibraryRevisionSummary *_Nullable
MTLibraryInspectLegacyRevisionMetadata(
    MTLibraryThemeDirectories *directories,
    NSString *storageIdentifier,
    NSString *_Nullable expectedThemeID,
    NSString *revisionIdentifier,
    BOOL current,
    MTImportCancellationToken *_Nullable cancellationToken,
    NSError **error) {
    if (!MTStringIsLowercaseSHA256Digest(revisionIdentifier) ||
        !MTLibraryCatalogCheckCancellation(cancellationToken, error)) {
        if (!MTStringIsLowercaseSHA256Digest(revisionIdentifier) &&
            (error == NULL || *error == nil)) {
            MTLibrarySetError(error, MTThemeLibraryStoreErrorVerification,
                @"A legacy Library revision identifier is malformed.", nil);
        }
        return nil;
    }
    int revisionDescriptor = -1;
    if (!MTLibraryOpenPrivateDirectoryAt(directories->revisionsDescriptor,
            revisionIdentifier, &revisionDescriptor, error)) {
        return nil;
    }
    NSArray<NSString *> *names = nil;
    BOOL success = MTLibraryListDirectoryNames(revisionDescriptor, &names,
                                               error) &&
        [names isEqualToArray:@[@"manifest.json"]];
    if (!success && (error == NULL || *error == nil)) {
        MTLibrarySetError(error, MTThemeLibraryStoreErrorVerification,
            @"A legacy Library revision has a non-exact manifest-only tree.",
            nil);
    }
    NSData *manifestData = success
        ? MTLibraryReadPrivateFileAt(revisionDescriptor, @"manifest.json",
            MTLibraryMaximumManifestBytes, error) : nil;
    MTThemeManifest *manifest = manifestData != nil
        ? MTLibraryCatalogParseManifest(manifestData, revisionIdentifier,
            expectedThemeID, storageIdentifier, error) : nil;
    success = manifest != nil && MTLibraryDirectoryDescriptorMatchesPath(
        directories->revisionsDescriptor, revisionIdentifier,
        revisionDescriptor, error);
    close(revisionDescriptor);
    if (!success || manifest == nil) return nil;
    return [[MTThemeLibraryRevisionSummary alloc]
        initWithRevisionIdentifier:revisionIdentifier
                     manifestDigest:revisionIdentifier
                            manifest:manifest
                          assetCount:0
                      assetByteCount:0
                              format:
                                  MTThemeLibraryRevisionFormatLegacyManifestOnly
                             current:current];
}

static MTThemeLibraryRevisionSummary *_Nullable
MTLibraryInspectRevisionMetadata(
    MTLibraryThemeDirectories *directories,
    NSString *storageIdentifier,
    NSString *_Nullable expectedThemeID,
    NSString *revisionIdentifier,
    BOOL current,
    MTImportCancellationToken *_Nullable cancellationToken,
    NSError **error) {
    if (MTLibraryRevisionIdentifierIsCanonical(revisionIdentifier)) {
        return MTLibraryInspectFormalRevisionMetadata(directories,
            storageIdentifier, expectedThemeID, revisionIdentifier, current,
            cancellationToken, error);
    }
    if (MTStringIsLowercaseSHA256Digest(revisionIdentifier)) {
        return MTLibraryInspectLegacyRevisionMetadata(directories,
            storageIdentifier, expectedThemeID, revisionIdentifier, current,
            cancellationToken, error);
    }
    MTLibrarySetError(error, MTThemeLibraryStoreErrorVerification,
        @"The revisions directory contains an unsupported published name.", nil);
    return nil;
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

static NSArray<MTThemeLibraryRevisionSummary *> *_Nullable
MTLibraryLoadRevisionHistoryLocked(
    MTThemeLibraryStore *store,
    MTLibraryThemeDirectories *directories,
    NSString *storageIdentifier,
    NSString *_Nullable expectedThemeID,
    MTImportCancellationToken *_Nullable cancellationToken,
    NSError **error) {
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
        return MTLibraryThemeDirectoriesAreStable(store.configuration,
                                                   directories, error)
            ? @[] : nil;
    }
    if (!MTLibraryValidateThemeTopLevel(directories, error)) return nil;
    NSData *pointerData = MTLibraryReadPrivateFileAt(
        directories->themeDescriptor, @"current.json",
        MTLibraryMaximumCurrentPointerBytes, error);
    uint64_t schemaVersion = 0;
    NSString *currentIdentifier = nil;
    NSString *currentDigest = nil;
    if (pointerData == nil || !MTLibraryParseCurrentPointerData(pointerData,
            &schemaVersion, &currentIdentifier, &currentDigest, error)) {
        return nil;
    }
    MTThemeLibraryRevisionSummary *currentSummary =
        MTLibraryInspectRevisionMetadata(directories, storageIdentifier,
            expectedThemeID, currentIdentifier, YES, cancellationToken, error);
    if (currentSummary == nil ||
        ![currentSummary.manifestDigest isEqualToString:currentDigest] ||
        (schemaVersion == 1 && currentSummary.format !=
            MTThemeLibraryRevisionFormatLegacyManifestOnly) ||
        (schemaVersion == 2 && currentSummary.format !=
            MTThemeLibraryRevisionFormatFormalV1)) {
        if (currentSummary != nil && (error == NULL || *error == nil)) {
            MTLibrarySetError(error, MTThemeLibraryStoreErrorVerification,
                @"The current pointer and revision format do not agree.", nil);
        }
        return nil;
    }
    NSString *resolvedThemeID = currentSummary.manifest.themeID;
    NSArray<NSString *> *revisionNames = nil;
    if (!MTLibraryListDirectoryNames(directories->revisionsDescriptor,
                                     &revisionNames, error)) {
        return nil;
    }
    NSMutableArray<MTThemeLibraryRevisionSummary *> *history =
        [NSMutableArray arrayWithObject:currentSummary];
    BOOL foundCurrent = NO;
    for (NSString *name in revisionNames) {
        if (!MTLibraryCatalogCheckCancellation(cancellationToken, error)) {
            return nil;
        }
        if ([name isEqualToString:currentIdentifier]) {
            foundCurrent = YES;
            continue;
        }
        if ([name hasPrefix:@".transaction-"] ||
            [name hasPrefix:@".deletion-"]) {
            MTLibrarySetError(error, MTThemeLibraryStoreErrorRecovery,
                @"The Library contains an abandoned operation that requires recovery.",
                nil);
            return nil;
        }
        MTThemeLibraryRevisionSummary *summary =
            MTLibraryInspectRevisionMetadata(directories, storageIdentifier,
                resolvedThemeID, name, NO, cancellationToken, error);
        if (summary == nil) return nil;
        [history addObject:summary];
    }
    if (!foundCurrent) {
        MTLibrarySetError(error, MTThemeLibraryStoreErrorVerification,
            @"The current Library revision is absent from its revision set.",
            nil);
        return nil;
    }
    [history sortUsingComparator:^NSComparisonResult(
        MTThemeLibraryRevisionSummary *left,
        MTThemeLibraryRevisionSummary *right) {
        if (left.isCurrent != right.isCurrent) {
            return left.isCurrent ? NSOrderedAscending : NSOrderedDescending;
        }
        return [left.revisionIdentifier compare:right.revisionIdentifier
                                         options:NSLiteralSearch];
    }];
    if (!MTLibraryThemeDirectoriesAreStable(store.configuration, directories,
                                            error)) {
        return nil;
    }
    return [history copy];
}

static MTThemeLibraryThemeSummary *MTLibraryCreateThemeSummary(
    NSArray<MTThemeLibraryRevisionSummary *> *history) {
    MTThemeLibraryRevisionSummary *current = history.firstObject;
    NSUInteger formalCount = 0;
    NSUInteger legacyCount = 0;
    for (MTThemeLibraryRevisionSummary *revision in history) {
        if (revision.format == MTThemeLibraryRevisionFormatFormalV1) {
            formalCount++;
        } else {
            legacyCount++;
        }
    }
    return [[MTThemeLibraryThemeSummary alloc]
        initWithCurrentRevision:current
                  revisionHistory:history
                  revisionCount:history.count
            formalRevisionCount:formalCount
            legacyRevisionCount:legacyCount];
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
        NSArray<MTThemeLibraryRevisionSummary *> *history = nil;
        if (lockDescriptor >= 0) {
            history = MTLibraryLoadRevisionHistoryLocked(self, &directories,
                storageIdentifier, nil, cancellationToken, error);
            close(lockDescriptor);
        }
        MTLibraryThemeDirectoriesClose(&directories);
        if (history == nil) {
            success = NO;
            break;
        }
        if (history.count == 0) continue;
        MTThemeLibraryThemeSummary *summary =
            MTLibraryCreateThemeSummary(history);
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

- (NSArray<MTThemeLibraryRevisionSummary *> *)
    loadRevisionHistoryForThemeID:(NSString *)themeID
    cancellationToken:(MTImportCancellationToken *)cancellationToken
    error:(NSError **)error {
    NSString *normalizedThemeID = MTNormalizeIdentifier(themeID, NULL);
    NSString *storageIdentifier =
        MTLibraryStorageIdentifierForThemeID(themeID);
    if (normalizedThemeID == nil || storageIdentifier == nil) {
        MTLibrarySetError(error, MTThemeLibraryStoreErrorInvalidRequest,
            @"The requested Library theme identifier is invalid.", nil);
        return nil;
    }
    if (!MTLibraryCatalogCheckCancellation(cancellationToken, error)) return nil;
    MTLibraryThemeDirectories directories;
    if (!MTOpenLibraryThemeDirectories(self.configuration,
            storageIdentifier, NO, &directories, error)) {
        return nil;
    }
    int lockDescriptor = MTLibraryAcquireThemeReadLock(
        directories.themeDescriptor, error);
    NSArray<MTThemeLibraryRevisionSummary *> *history = nil;
    if (lockDescriptor >= 0) {
        history = MTLibraryLoadRevisionHistoryLocked(self, &directories,
            storageIdentifier, normalizedThemeID, cancellationToken, error);
        close(lockDescriptor);
    }
    MTLibraryThemeDirectoriesClose(&directories);
    return history;
}

- (MTThemeLibraryRevision *)
    switchCurrentRevisionForThemeID:(NSString *)themeID
    revisionIdentifier:(NSString *)revisionIdentifier
    cancellationToken:(MTImportCancellationToken *)cancellationToken
    error:(NSError **)error {
    NSString *normalizedThemeID = MTNormalizeIdentifier(themeID, NULL);
    NSString *storageIdentifier =
        MTLibraryStorageIdentifierForThemeID(themeID);
    if (normalizedThemeID == nil || storageIdentifier == nil ||
        !MTLibraryRevisionIdentifierIsCanonical(revisionIdentifier)) {
        MTLibrarySetError(error,
            MTLibraryRevisionIdentifierIsCanonical(revisionIdentifier)
                ? MTThemeLibraryStoreErrorInvalidRequest
                : MTThemeLibraryStoreErrorUnsupportedVersion,
            @"Only a canonical formal Library revision can become current.",
            nil);
        return nil;
    }
    if (!MTLibraryCatalogCheckCancellation(cancellationToken, error)) return nil;
    MTLibraryThemeDirectories directories;
    if (!MTOpenLibraryThemeDirectories(self.configuration,
            storageIdentifier, NO, &directories, error)) {
        return nil;
    }
    int lockDescriptor = MTLibraryAcquireThemeTransactionLock(
        directories.themeDescriptor, error);
    if (lockDescriptor < 0) {
        MTLibraryThemeDirectoriesClose(&directories);
        return nil;
    }
    BOOL success = MTLibraryRecoverAbandonedTransactions(
        directories.themeDescriptor, directories.revisionsDescriptor, error) &&
        MTLibraryValidateThemeTopLevel(&directories, error);
    NSData *existingPointer = success ? MTLibraryReadPrivateFileAt(
        directories.themeDescriptor, @"current.json",
        MTLibraryMaximumCurrentPointerBytes, error) : nil;
    if (success) {
        success = MTLibraryParseCurrentPointerData(existingPointer, NULL, NULL,
                                                   NULL, error);
    }
    NSString *manifestDigest = [revisionIdentifier substringFromIndex:3];
    MTThemeLibraryRevision *revision = success
        ? MTLibraryLoadRevision(self, &directories, storageIdentifier,
            normalizedThemeID, revisionIdentifier, manifestDigest, nil,
            cancellationToken, error) : nil;
    success = success && revision != nil &&
        MTLibraryCatalogCheckCancellation(cancellationToken, error) &&
        MTLibraryThemeDirectoriesAreStable(self.configuration, &directories,
                                            error);
    NSError *encodingError = nil;
    NSData *pointerData = success ? MTCanonicalJSONData(@{
        @"manifestDigest" : manifestDigest,
        @"revisionID" : revisionIdentifier,
        @"schemaVersion" : @2,
    }, &encodingError) : nil;
    if (success && pointerData == nil) {
        success = MTLibrarySetError(error,
            MTThemeLibraryStoreErrorStorage,
            @"Unable to encode the selected formal current revision pointer.",
            encodingError);
    }
    if (success && pointerData != nil) {
        success = MTLibraryReplaceCurrentData(directories.themeDescriptor,
                                              pointerData, error) &&
            MTLibraryThemeDirectoriesAreStable(self.configuration,
                                                &directories, error);
    }
    close(lockDescriptor);
    MTLibraryThemeDirectoriesClose(&directories);
    return success ? revision : nil;
}

- (BOOL)removeRevisionForThemeID:(NSString *)themeID
    revisionIdentifier:(NSString *)revisionIdentifier
    cancellationToken:(MTImportCancellationToken *)cancellationToken
    error:(NSError **)error {
    NSString *normalizedThemeID = MTNormalizeIdentifier(themeID, NULL);
    NSString *storageIdentifier =
        MTLibraryStorageIdentifierForThemeID(themeID);
    if (normalizedThemeID == nil || storageIdentifier == nil ||
        !MTLibraryRevisionIdentifierIsCanonical(revisionIdentifier)) {
        return MTLibrarySetError(error,
            MTLibraryRevisionIdentifierIsCanonical(revisionIdentifier)
                ? MTThemeLibraryStoreErrorInvalidRequest
                : MTThemeLibraryStoreErrorUnsupportedVersion,
            @"Only a canonical formal Library revision can be removed.", nil);
    }
    if (!MTLibraryCatalogCheckCancellation(cancellationToken, error)) return NO;
    MTLibraryThemeDirectories directories;
    if (!MTOpenLibraryThemeDirectories(self.configuration,
            storageIdentifier, NO, &directories, error)) {
        return NO;
    }
    int lockDescriptor = MTLibraryAcquireThemeTransactionLock(
        directories.themeDescriptor, error);
    if (lockDescriptor < 0) {
        MTLibraryThemeDirectoriesClose(&directories);
        return NO;
    }
    BOOL success = MTLibraryRecoverAbandonedTransactions(
        directories.themeDescriptor, directories.revisionsDescriptor, error) &&
        MTLibraryValidateThemeTopLevel(&directories, error);
    NSData *pointerData = success ? MTLibraryReadPrivateFileAt(
        directories.themeDescriptor, @"current.json",
        MTLibraryMaximumCurrentPointerBytes, error) : nil;
    NSString *currentIdentifier = nil;
    if (success) {
        success = MTLibraryParseCurrentPointerData(pointerData, NULL,
            &currentIdentifier, NULL, error);
    }
    if (success && [currentIdentifier isEqualToString:revisionIdentifier]) {
        success = MTLibrarySetError(error,
            MTThemeLibraryStoreErrorCurrentRevision,
            @"The current Library revision cannot be removed.", nil);
    }
    MTThemeLibraryRevisionSummary *target = success
        ? MTLibraryInspectFormalRevisionMetadata(&directories,
            storageIdentifier, normalizedThemeID, revisionIdentifier, NO,
            cancellationToken, error) : nil;
    success = success && target != nil;
    if (success) {
        success = MTLibraryThemeDirectoriesAreStable(self.configuration,
            &directories, error) &&
            MTLibraryCatalogCheckCancellation(cancellationToken, error);
    }
    NSString *deletionName = success ? MTLibraryCreateDeletionName() : nil;
    if (success) {
        success = MTLibraryQuarantineRevisionForDeletion(
            directories.revisionsDescriptor, revisionIdentifier,
            deletionName, error);
    }
    // The revision is no longer published after the rename. Do not observe
    // cancellation beyond this point; finish or leave a recoverable quarantine.
    if (success) {
        success = MTLibraryDiscardDeletion(directories.revisionsDescriptor,
                                           deletionName, error) &&
            MTLibraryThemeDirectoriesAreStable(self.configuration,
                                                &directories, error);
    }
    close(lockDescriptor);
    MTLibraryThemeDirectoriesClose(&directories);
    return success;
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
            error) && MTLibraryThemeDirectoriesAreStable(
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
