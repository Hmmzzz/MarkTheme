#import "MTThemeLibraryStore.h"

#import <CoreFoundation/CoreFoundation.h>
#import <errno.h>
#import <fcntl.h>
#import <stdio.h>
#import <sys/stat.h>
#import <unistd.h>

#import "MTAssetStagingSession.h"
#import "MTAssetStagingSessionInternal.h"
#import "MTCanonicalJSON.h"
#import "MTDigest.h"
#import "MTIdentifier.h"
#import "MTImportLimits.h"
#import "MTImportSession.h"
#import "MTThemeLibraryFilesystem.h"
#import "MTThemeLibraryStoreInternal.h"
#import "MTThemeManifest.h"

const uint64_t MTLibraryMaximumManifestBytes = 16ULL * 1024ULL * 1024ULL;
const uint64_t MTLibraryMaximumRevisionMetadataBytes =
    8ULL * 1024ULL * 1024ULL;
const uint64_t MTLibraryMaximumCurrentPointerBytes = 4096;
static const uint64_t MTLibraryMaximumPreviewAssetBytes =
    32ULL * 1024ULL * 1024ULL;
static const uint64_t MTLibraryMaximumPreviewTotalBytes =
    64ULL * 1024ULL * 1024ULL;
static const NSUInteger MTLibraryMaximumPreviewAssetCount = 4;

BOOL MTLibraryDictionaryHasExactlyKeys(NSDictionary *dictionary,
                                       NSArray<NSString *> *keys) {
    return dictionary.count == keys.count &&
        [[NSSet setWithArray:dictionary.allKeys]
            isEqualToSet:[NSSet setWithArray:keys]];
}

BOOL MTLibraryReadUnsignedInteger(id value,
                                  uint64_t maximum,
                                  uint64_t *result) {
    if (![value isKindOfClass:NSNumber.class] ||
        CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) {
        return NO;
    }
    NSNumber *number = value;
    double doubleValue = number.doubleValue;
    uint64_t integerValue = number.unsignedLongLongValue;
    if (doubleValue < 0 || doubleValue != (double)integerValue ||
        integerValue > maximum) {
        return NO;
    }
    if (result != NULL) *result = integerValue;
    return YES;
}

NSDictionary *_Nullable MTLibraryCanonicalDictionaryFromData(
    NSData *data,
    NSError **error) {
    NSError *parseError = nil;
    id object = [NSJSONSerialization JSONObjectWithData:data
                                                 options:0
                                                   error:&parseError];
    NSData *roundTrip = [object isKindOfClass:NSDictionary.class]
        ? MTCanonicalJSONData(object, &parseError) : nil;
    if (![object isKindOfClass:NSDictionary.class] ||
        ![roundTrip isEqualToData:data]) {
        MTLibrarySetError(error, MTThemeLibraryStoreErrorVerification,
            @"Library metadata is not a canonical JSON dictionary.",
            parseError);
        return nil;
    }
    return object;
}

NSArray<NSString *> *MTLibraryRequiredAssetDigests(
    MTThemeManifest *manifest) {
    NSMutableSet<NSString *> *digests = [NSMutableSet set];
    for (MTThemeResource *resource in manifest.resources) {
        [digests addObject:resource.contentSHA256];
    }
    return [digests.allObjects sortedArrayUsingSelector:@selector(compare:)];
}

static NSMutableDictionary *_Nullable MTLibraryResourceTreeDescription(
    MTThemeManifest *manifest,
    NSError **error) {
    NSMutableDictionary *root = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSString *> *pathsByFoldedPath =
        [NSMutableDictionary dictionary];
    for (MTThemeResource *resource in manifest.resources) {
        NSString *foldedPath = resource.relativeAssetPath.lowercaseString;
        NSString *existingPath = pathsByFoldedPath[foldedPath];
        if (existingPath != nil &&
            ![existingPath isEqualToString:resource.relativeAssetPath]) {
            MTLibrarySetError(error, MTThemeLibraryStoreErrorVerification,
                @"Two MarkTheme resource paths collide after case folding.",
                nil);
            return nil;
        }
        pathsByFoldedPath[foldedPath] = resource.relativeAssetPath;
        NSArray<NSString *> *components = [resource.relativeAssetPath
            componentsSeparatedByString:@"/"];
        if (components.count < 2) {
            MTLibrarySetError(error, MTThemeLibraryStoreErrorVerification,
                @"A MarkTheme resource path has no standard directory.", nil);
            return nil;
        }
        NSMutableDictionary *directory = root;
        for (NSUInteger index = 0; index + 1 < components.count; index++) {
            NSString *component = components[index];
            id existing = directory[component];
            if (existing != nil &&
                ![existing isKindOfClass:NSMutableDictionary.class]) {
                MTLibrarySetError(error,
                    MTThemeLibraryStoreErrorVerification,
                    @"A MarkTheme resource path collides with a file.", nil);
                return nil;
            }
            if (existing == nil) {
                existing = [NSMutableDictionary dictionary];
                directory[component] = existing;
            }
            directory = existing;
        }
        NSString *filename = components.lastObject;
        id existing = directory[filename];
        if (existing != nil &&
            (![existing isKindOfClass:NSString.class] ||
             ![existing isEqualToString:resource.contentSHA256])) {
            MTLibrarySetError(error, MTThemeLibraryStoreErrorVerification,
                @"Two MarkTheme resources collide at one standard path.", nil);
            return nil;
        }
        directory[filename] = resource.contentSHA256;
    }
    return root;
}

static BOOL MTLibraryVerifyStandardResourceDirectory(
    int directoryDescriptor,
    NSDictionary *tree,
    NSDictionary<NSString *, NSNumber *> *byteCounts,
    MTImportCancellationToken *token,
    NSError **error) {
    NSArray<NSString *> *actualNames = nil;
    NSArray<NSString *> *expectedNames = [tree.allKeys
        sortedArrayUsingSelector:@selector(compare:)];
    if (!MTLibraryListDirectoryNames(directoryDescriptor, &actualNames,
                                     error) ||
        ![actualNames isEqualToArray:expectedNames]) {
        if (error == NULL || *error == nil) {
            MTLibrarySetError(error, MTThemeLibraryStoreErrorVerification,
                @"The MarkTheme resources directory is not an exact manifest tree.",
                nil);
        }
        return NO;
    }
    for (NSString *name in expectedNames) {
        if (token.isCancelled) {
            return MTLibrarySetError(error,
                MTThemeLibraryStoreErrorCancelled,
                @"MarkTheme resource verification was cancelled.", nil);
        }
        id value = tree[name];
        if ([value isKindOfClass:NSDictionary.class]) {
            int child = -1;
            BOOL success = MTLibraryOpenPrivateDirectoryAt(
                directoryDescriptor, name, &child, error) &&
                MTLibraryVerifyStandardResourceDirectory(child, value,
                    byteCounts, token, error);
            if (child >= 0) close(child);
            if (!success) return NO;
            continue;
        }
        NSString *digest = [value isKindOfClass:NSString.class] ? value : nil;
        uint64_t expectedBytes = byteCounts[digest].unsignedLongLongValue;
        NSData *data = digest != nil && expectedBytes > 0
            ? MTLibraryReadPrivateFileAt(directoryDescriptor, name,
                expectedBytes, error) : nil;
        if (data == nil || data.length != expectedBytes ||
            ![MTSHA256HexDigestForData(data) isEqualToString:digest]) {
            if (error == NULL || *error == nil) {
                MTLibrarySetError(error,
                    MTThemeLibraryStoreErrorVerification,
                    @"A standardized MarkTheme resource failed its digest check.",
                    nil);
            }
            return NO;
        }
    }
    return YES;
}

static BOOL MTLibraryCreateStandardResourceFiles(
    int sourceObjectsDescriptor,
    int transactionDescriptor,
    MTThemeManifest *manifest,
    NSDictionary<NSString *, NSNumber *> *byteCounts,
    MTImportCancellationToken *token,
    int *resourcesDescriptor,
    NSError **error) {
    NSMutableDictionary *tree = MTLibraryResourceTreeDescription(manifest,
                                                                  error);
    int resources = -1;
    if (tree == nil || !MTLibraryCreatePrivateDirectoryAt(
            transactionDescriptor, @"resources", &resources, error)) {
        return NO;
    }
    NSArray<MTThemeResource *> *ordered = [manifest.resources
        sortedArrayUsingComparator:^NSComparisonResult(MTThemeResource *left,
                                                       MTThemeResource *right) {
        return [left.relativeAssetPath compare:right.relativeAssetPath
                                       options:NSLiteralSearch];
    }];
    NSMutableSet<NSString *> *writtenPaths = [NSMutableSet set];
    BOOL success = YES;
    for (MTThemeResource *resource in ordered) {
        if ([writtenPaths containsObject:resource.relativeAssetPath]) continue;
        [writtenPaths addObject:resource.relativeAssetPath];
        if (token.isCancelled) {
            success = MTLibrarySetError(error,
                MTThemeLibraryStoreErrorCancelled,
                @"MarkTheme resource organization was cancelled.", nil);
            break;
        }
        NSArray<NSString *> *components = [resource.relativeAssetPath
            componentsSeparatedByString:@"/"];
        int parent = dup(resources);
        if (parent < 0) {
            success = MTLibrarySetError(error,
                MTThemeLibraryStoreErrorStorage,
                @"Unable to retain the MarkTheme resources directory.",
                MTLibraryPOSIXError(errno));
            break;
        }
        for (NSUInteger index = 0; success && index + 1 < components.count;
             index++) {
            int child = -1;
            success = MTLibraryCreatePrivateDirectoryAt(parent,
                components[index], &child, error);
            close(parent);
            parent = child;
        }
        NSString *digest = resource.contentSHA256;
        NSString *filename = components.lastObject;
        uint64_t bytes = byteCounts[digest].unsignedLongLongValue;
        if (success) {
            success = MTLibraryCopyVerifiedAsset(sourceObjectsDescriptor,
                parent, digest, bytes, token, NULL, error);
        }
        if (success && renameat(parent, digest.fileSystemRepresentation,
                parent, filename.fileSystemRepresentation) != 0) {
            success = MTLibrarySetError(error,
                MTThemeLibraryStoreErrorStorage,
                @"Unable to publish a standardized MarkTheme resource name.",
                MTLibraryPOSIXError(errno));
        }
        if (success) {
            success = MTLibrarySynchronizeDirectoryDescriptor(parent, error);
        }
        close(parent);
        if (!success) break;
    }
    if (success) {
        success = MTLibraryVerifyStandardResourceDirectory(resources, tree,
            byteCounts, token, error) &&
            MTLibrarySynchronizeDirectoryDescriptor(resources, error);
    }
    if (!success) {
        close(resources);
        return NO;
    }
    *resourcesDescriptor = resources;
    return YES;
}

static BOOL MTLibraryBuildRevisionMetadata(
    NSString *manifestDigest,
    NSArray<NSString *> *requiredDigests,
    NSDictionary<NSString *, MTStagedAsset *> *stagedAssets,
    MTImportLimits *limits,
    NSData **metadataData,
    NSDictionary<NSString *, NSNumber *> **byteCounts,
    uint64_t *totalBytes,
    NSError **error) {
    if (requiredDigests.count == 0 ||
        requiredDigests.count > limits.maximumRegularFiles ||
        stagedAssets.count != requiredDigests.count) {
        return MTLibrarySetError(error,
            MTThemeLibraryStoreErrorLimitExceeded,
            @"The formal revision exceeds its asset-count policy.", nil);
    }
    NSMutableArray<NSDictionary *> *entries =
        [NSMutableArray arrayWithCapacity:requiredDigests.count];
    NSMutableDictionary<NSString *, NSNumber *> *counts =
        [NSMutableDictionary dictionaryWithCapacity:requiredDigests.count];
    uint64_t aggregate = 0;
    for (NSString *digest in requiredDigests) {
        MTStagedAsset *asset = stagedAssets[digest];
        if (![asset isKindOfClass:MTStagedAsset.class] ||
            ![asset.contentSHA256 isEqualToString:digest] ||
            asset.byteCount == 0 ||
            asset.byteCount > limits.maximumSingleFileBytes ||
            asset.byteCount > limits.maximumExpandedBytes - aggregate) {
            return MTLibrarySetError(error,
                MTThemeLibraryStoreErrorLimitExceeded,
                @"A staged asset exceeds the formal Library byte policy.", nil);
        }
        aggregate += asset.byteCount;
        counts[digest] = @(asset.byteCount);
        [entries addObject:@{
            @"byteCount" : @(asset.byteCount),
            @"digest" : digest,
        }];
    }
    NSError *canonicalError = nil;
    NSData *data = MTCanonicalJSONData(@{
        @"assetByteCount" : @(aggregate),
        @"assetCount" : @(entries.count),
        @"assets" : entries,
        @"manifestDigest" : manifestDigest,
        @"schemaVersion" : @1,
    }, &canonicalError);
    if (data == nil || data.length > MTLibraryMaximumRevisionMetadataBytes) {
        return MTLibrarySetError(error,
            MTThemeLibraryStoreErrorLimitExceeded,
            @"Formal revision metadata exceeds its canonical byte limit.",
            canonicalError);
    }
    *metadataData = data;
    *byteCounts = [counts copy];
    *totalBytes = aggregate;
    return YES;
}

NSDictionary<NSString *, NSNumber *> *_Nullable
MTLibraryParseRevisionMetadata(
    NSData *data,
    NSString *expectedManifestDigest,
    NSArray<NSString *> *expectedDigests,
    uint64_t *totalBytes,
    NSError **error) {
    NSDictionary *dictionary = MTLibraryCanonicalDictionaryFromData(data,
                                                                    error);
    if (dictionary == nil ||
        !MTLibraryDictionaryHasExactlyKeys(dictionary, @[
            @"assetByteCount", @"assetCount", @"assets",
            @"manifestDigest", @"schemaVersion"
        ]) ||
        ![dictionary[@"schemaVersion"] isEqual:@1] ||
        ![dictionary[@"manifestDigest"] isEqual:expectedManifestDigest] ||
        ![dictionary[@"assets"] isKindOfClass:NSArray.class]) {
        if (dictionary != nil) {
            MTLibrarySetError(error,
                MTThemeLibraryStoreErrorVerification,
                @"Formal revision metadata has an invalid schema.", nil);
        }
        return nil;
    }
    uint64_t declaredCount = 0;
    uint64_t declaredBytes = 0;
    NSArray *entries = dictionary[@"assets"];
    if (!MTLibraryReadUnsignedInteger(dictionary[@"assetCount"],
                                      NSUIntegerMax, &declaredCount) ||
        !MTLibraryReadUnsignedInteger(dictionary[@"assetByteCount"],
                                      UINT64_MAX, &declaredBytes) ||
        declaredCount != entries.count ||
        declaredCount != expectedDigests.count) {
        MTLibrarySetError(error, MTThemeLibraryStoreErrorVerification,
            @"Formal revision asset totals are inconsistent.", nil);
        return nil;
    }
    NSMutableDictionary<NSString *, NSNumber *> *counts =
        [NSMutableDictionary dictionaryWithCapacity:entries.count];
    uint64_t aggregate = 0;
    NSString *previousDigest = nil;
    for (id object in entries) {
        if (![object isKindOfClass:NSDictionary.class] ||
            !MTLibraryDictionaryHasExactlyKeys(object,
                @[@"byteCount", @"digest"])) {
            MTLibrarySetError(error,
                MTThemeLibraryStoreErrorVerification,
                @"A formal revision asset entry is malformed.", nil);
            return nil;
        }
        NSString *digest = object[@"digest"];
        uint64_t count = 0;
        if (!MTStringIsLowercaseSHA256Digest(digest) ||
            !MTLibraryReadUnsignedInteger(object[@"byteCount"],
                                          UINT64_MAX, &count) || count == 0 ||
            (previousDigest != nil &&
             [previousDigest compare:digest options:NSLiteralSearch] !=
                 NSOrderedAscending) ||
            aggregate > UINT64_MAX - count) {
            MTLibrarySetError(error,
                MTThemeLibraryStoreErrorVerification,
                @"A formal revision asset digest, size, or order is invalid.",
                nil);
            return nil;
        }
        aggregate += count;
        counts[digest] = @(count);
        previousDigest = digest;
    }
    if (aggregate != declaredBytes ||
        ![[counts.allKeys sortedArrayUsingSelector:@selector(compare:)]
            isEqualToArray:expectedDigests]) {
        MTLibrarySetError(error, MTThemeLibraryStoreErrorVerification,
            @"Formal revision assets do not exactly match the manifest.", nil);
        return nil;
    }
    if (totalBytes != NULL) *totalBytes = aggregate;
    return [counts copy];
}

BOOL MTLibraryParseCurrentPointerData(
    NSData *data,
    uint64_t *schemaVersion,
    NSString **revisionIdentifier,
    NSString **manifestDigest,
    NSError **error) {
    NSDictionary *pointer = MTLibraryCanonicalDictionaryFromData(data, error);
    uint64_t version = 0;
    if (pointer == nil ||
        !MTLibraryReadUnsignedInteger(pointer[@"schemaVersion"], UINT64_MAX,
                                      &version)) {
        if (pointer != nil && (error == NULL || *error == nil)) {
            MTLibrarySetError(error, MTThemeLibraryStoreErrorVerification,
                @"The current revision pointer has an invalid schema version.",
                nil);
        }
        return NO;
    }
    NSString *identifier = nil;
    NSString *digest = nil;
    if (version == 1) {
        digest = pointer[@"digest"];
        identifier = digest;
        if (!MTLibraryDictionaryHasExactlyKeys(pointer,
                @[@"digest", @"schemaVersion"]) ||
            !MTStringIsLowercaseSHA256Digest(digest)) {
            return MTLibrarySetError(error,
                MTThemeLibraryStoreErrorVerification,
                @"The schema-one current revision pointer is malformed.", nil);
        }
    } else if (version == 2) {
        identifier = pointer[@"revisionID"];
        digest = pointer[@"manifestDigest"];
        if (!MTLibraryDictionaryHasExactlyKeys(pointer, @[
                @"manifestDigest", @"revisionID", @"schemaVersion"
            ]) ||
            !MTStringIsLowercaseSHA256Digest(digest) ||
            !MTLibraryRevisionIdentifierIsCanonical(identifier) ||
            ![identifier isEqualToString:
                MTLibraryRevisionIdentifierForManifestDigest(digest)]) {
            return MTLibrarySetError(error,
                MTThemeLibraryStoreErrorVerification,
                @"The schema-two current revision pointer is malformed.", nil);
        }
    } else {
        return MTLibrarySetError(error,
            MTThemeLibraryStoreErrorUnsupportedVersion,
            @"The current revision pointer uses an unsupported schema version.",
            nil);
    }
    if (schemaVersion != NULL) *schemaVersion = version;
    if (revisionIdentifier != NULL) *revisionIdentifier = identifier;
    if (manifestDigest != NULL) *manifestDigest = digest;
    return YES;
}

NSURL *MTLibraryRevisionURL(MTThemeLibraryStore *store,
                            NSString *storageIdentifier,
                            NSString *revisionIdentifier) {
    return [[[[store.rootURL URLByAppendingPathComponent:@"themes"
                                             isDirectory:YES]
        URLByAppendingPathComponent:storageIdentifier isDirectory:YES]
        URLByAppendingPathComponent:@"revisions" isDirectory:YES]
        URLByAppendingPathComponent:revisionIdentifier isDirectory:YES];
}

MTThemeLibraryRevision *_Nullable MTLibraryLoadRevision(
    MTThemeLibraryStore *store,
    MTLibraryThemeDirectories *directories,
    NSString *storageIdentifier,
    NSString *requestedThemeID,
    NSString *revisionIdentifier,
    NSString *expectedManifestDigest,
    NSDictionary<NSString *, NSNumber *> *_Nullable expectedByteCounts,
    MTImportCancellationToken *_Nullable cancellationToken,
    NSError **error) {
    NSString *identifierDigest = MTLibraryRevisionIdentifierIsCanonical(
        revisionIdentifier)
        ? [revisionIdentifier substringFromIndex:3] : nil;
    if (![identifierDigest isEqualToString:expectedManifestDigest]) {
        MTLibrarySetError(error, MTThemeLibraryStoreErrorVerification,
            @"The formal revision identifier does not match its manifest digest.",
            nil);
        return nil;
    }
    int revisionDescriptor = -1;
    if (!MTLibraryOpenPrivateDirectoryAt(directories->revisionsDescriptor,
            revisionIdentifier, &revisionDescriptor, error)) {
        return nil;
    }
    NSArray<NSString *> *revisionNames = nil;
    BOOL listedRevision = MTLibraryListDirectoryNames(revisionDescriptor,
                                                      &revisionNames, error);
    NSSet<NSString *> *revisionSet = listedRevision
        ? [NSSet setWithArray:revisionNames] : nil;
    NSSet<NSString *> *legacySet = [NSSet setWithArray:@[
        @"assets", @"manifest.json", @"revision.json"
    ]];
    NSSet<NSString *> *standardSet = [NSSet setWithArray:@[
        @"assets", @"manifest.json", @"resources", @"revision.json"
    ]];
    BOOL hasStandardResources = [revisionSet isEqualToSet:standardSet];
    BOOL success = listedRevision &&
        (hasStandardResources || [revisionSet isEqualToSet:legacySet]);
    if (!success && (error == NULL || *error == nil)) {
        MTLibrarySetError(error, MTThemeLibraryStoreErrorVerification,
            @"A formal revision contains missing or unknown top-level entries.",
            nil);
    }
    NSData *manifestData = success
        ? MTLibraryReadPrivateFileAt(revisionDescriptor, @"manifest.json",
            MTLibraryMaximumManifestBytes, error) : nil;
    NSData *metadataData = manifestData != nil
        ? MTLibraryReadPrivateFileAt(revisionDescriptor, @"revision.json",
            MTLibraryMaximumRevisionMetadataBytes, error) : nil;
    success = metadataData != nil;

    NSError *parseError = nil;
    NSDictionary *manifestDictionary = success
        ? MTLibraryCanonicalDictionaryFromData(manifestData, &parseError) : nil;
    MTThemeManifest *manifest = manifestDictionary != nil
        ? [[MTThemeManifest alloc] initWithDictionary:manifestDictionary
                                                error:&parseError]
        : nil;
    NSData *manifestRoundTrip =
        [manifest canonicalDataWithError:&parseError];
    NSString *normalizedThemeID = MTNormalizeIdentifier(requestedThemeID, NULL);
    if (success && (manifest == nil ||
        ![manifestRoundTrip isEqualToData:manifestData] ||
        ![MTSHA256HexDigestForData(manifestData)
            isEqualToString:expectedManifestDigest] ||
        ![manifest.themeID isEqualToString:normalizedThemeID])) {
        success = MTLibrarySetError(error,
            MTThemeLibraryStoreErrorVerification,
            @"The formal revision manifest failed canonical identity validation.",
            parseError);
    }
    NSArray<NSString *> *requiredDigests = success && manifest != nil
        ? MTLibraryRequiredAssetDigests(manifest) : nil;
    success = success && requiredDigests != nil;
    uint64_t totalBytes = 0;
    NSDictionary<NSString *, NSNumber *> *byteCounts = success
        ? MTLibraryParseRevisionMetadata(metadataData, expectedManifestDigest,
            requiredDigests, &totalBytes, error) : nil;
    success = byteCounts != nil;
    if (success && expectedByteCounts != nil &&
        ![byteCounts isEqualToDictionary:expectedByteCounts]) {
        success = MTLibrarySetError(error,
            MTThemeLibraryStoreErrorVerification,
            @"An existing formal revision conflicts with the staged asset sizes.",
            nil);
    }

    int assetsDescriptor = -1;
    if (success) {
        success = MTLibraryOpenPrivateDirectoryAt(revisionDescriptor, @"assets",
                                                  &assetsDescriptor, error);
    }
    NSArray<NSString *> *assetNames = nil;
    if (success) {
        success = MTLibraryListDirectoryNames(assetsDescriptor,
                                              &assetNames, error) &&
            [assetNames isEqualToArray:requiredDigests];
        if (!success && (error == NULL || *error == nil)) {
            MTLibrarySetError(error,
                MTThemeLibraryStoreErrorVerification,
                @"The formal revision asset directory is not an exact manifest set.",
                nil);
        }
    }
    if (success) {
        for (NSString *digest in requiredDigests) {
            if (!MTLibraryVerifyAsset(assetsDescriptor, digest,
                    byteCounts[digest].unsignedLongLongValue,
                    cancellationToken, error)) {
                success = NO;
                break;
            }
        }
    }

    int resourcesDescriptor = -1;
    if (success && hasStandardResources) {
        NSMutableDictionary *resourceTree =
            MTLibraryResourceTreeDescription(manifest, error);
        success = resourceTree != nil &&
            MTLibraryOpenPrivateDirectoryAt(revisionDescriptor, @"resources",
                                             &resourcesDescriptor, error) &&
            MTLibraryVerifyStandardResourceDirectory(resourcesDescriptor,
                resourceTree, byteCounts, cancellationToken, error);
    }

    NSMutableDictionary<NSString *, NSURL *> *assetURLs =
        [NSMutableDictionary dictionaryWithCapacity:requiredDigests.count];
    if (success) {
        NSURL *assetsURL = [MTLibraryRevisionURL(store, storageIdentifier,
            revisionIdentifier) URLByAppendingPathComponent:@"assets"
                                                isDirectory:YES];
        for (NSString *digest in requiredDigests) {
            assetURLs[digest] = [assetsURL URLByAppendingPathComponent:digest
                                                           isDirectory:NO];
        }
    }
    if (assetsDescriptor >= 0) close(assetsDescriptor);
    if (resourcesDescriptor >= 0) close(resourcesDescriptor);
    close(revisionDescriptor);
    if (!success) return nil;
    if (manifest == nil || byteCounts == nil) {
        MTLibrarySetError(error, MTThemeLibraryStoreErrorVerification,
            @"A validated formal revision lost required metadata.", nil);
        return nil;
    }
    return [[MTThemeLibraryRevision alloc]
        initWithRevisionIdentifier:revisionIdentifier
                     manifestDigest:expectedManifestDigest
                            manifest:manifest
             assetURLsByContentSHA256:assetURLs
       assetByteCountsByContentSHA256:byteCounts
                    resourcesDirectoryURL:hasStandardResources
        ? [[MTLibraryRevisionURL(store, storageIdentifier,
             revisionIdentifier) URLByAppendingPathComponent:@"resources"
                                                  isDirectory:YES] copy]
        : nil
                     assetByteCount:totalBytes];
}

static MTThemeLibraryRevision *MTLibraryCreateCommittedRevisionResult(
    MTThemeLibraryStore *store,
    NSString *storageIdentifier,
    NSString *revisionIdentifier,
    NSString *manifestDigest,
    MTThemeManifest *manifest,
    NSArray<NSString *> *requiredDigests,
    NSDictionary<NSString *, NSNumber *> *byteCounts,
    uint64_t totalBytes) {
    NSURL *assetsURL = [MTLibraryRevisionURL(store, storageIdentifier,
        revisionIdentifier) URLByAppendingPathComponent:@"assets"
                                            isDirectory:YES];
    NSMutableDictionary<NSString *, NSURL *> *assetURLs =
        [NSMutableDictionary dictionaryWithCapacity:requiredDigests.count];
    for (NSString *digest in requiredDigests) {
        assetURLs[digest] = [assetsURL URLByAppendingPathComponent:digest
                                                       isDirectory:NO];
    }
    return [[MTThemeLibraryRevision alloc]
        initWithRevisionIdentifier:revisionIdentifier
                     manifestDigest:manifestDigest
                            manifest:manifest
             assetURLsByContentSHA256:assetURLs
       assetByteCountsByContentSHA256:byteCounts
                    resourcesDirectoryURL:[[MTLibraryRevisionURL(store,
        storageIdentifier, revisionIdentifier)
        URLByAppendingPathComponent:@"resources" isDirectory:YES] copy]
                     assetByteCount:totalBytes];
}

static NSError *MTLibraryWrapStagingAdoptionError(NSError *error) {
    if (error == nil ||
        [error.domain isEqualToString:MTThemeLibraryStoreErrorDomain]) {
        return error;
    }
    MTThemeLibraryStoreErrorCode code = MTThemeLibraryStoreErrorStorage;
    if ([error.domain isEqualToString:MTAssetStagingSessionErrorDomain]) {
        switch ((MTAssetStagingSessionErrorCode)error.code) {
            case MTAssetStagingSessionErrorNotInventoried:
                code = MTThemeLibraryStoreErrorAssetSetMismatch;
                break;
            case MTAssetStagingSessionErrorInactive:
            case MTAssetStagingSessionErrorInvalidRequest:
                code = MTThemeLibraryStoreErrorInvalidRequest;
                break;
            case MTAssetStagingSessionErrorCancelled:
                code = MTThemeLibraryStoreErrorCancelled;
                break;
            case MTAssetStagingSessionErrorLimitExceeded:
                code = MTThemeLibraryStoreErrorLimitExceeded;
                break;
            case MTAssetStagingSessionErrorVerification:
                code = MTThemeLibraryStoreErrorVerification;
                break;
            default:
                code = MTThemeLibraryStoreErrorStorage;
                break;
        }
    }
    return MTLibraryError(code,
        @"The provisional asset session could not be adopted by the Library.",
        error);
}

@implementation MTThemeLibraryStore (FormalTransaction)

- (MTThemeLibraryRevision *)
    commitManifest:(MTThemeManifest *)manifest
    fromAssetStagingSession:(MTAssetStagingSession *)assetStagingSession
    cancellationToken:(MTImportCancellationToken *)cancellationToken
    error:(NSError **)error {
    if (![manifest isKindOfClass:MTThemeManifest.class] ||
        ![assetStagingSession isKindOfClass:MTAssetStagingSession.class]) {
        MTLibrarySetError(error, MTThemeLibraryStoreErrorInvalidRequest,
            @"A formal Library commit requires a manifest and asset session.",
            nil);
        return nil;
    }
    NSError *canonicalError = nil;
    NSData *canonicalManifest = [manifest
        canonicalDataWithError:&canonicalError];
    if (canonicalManifest == nil ||
        canonicalManifest.length > MTLibraryMaximumManifestBytes) {
        MTLibrarySetError(error, MTThemeLibraryStoreErrorLimitExceeded,
            @"The canonical manifest exceeds the formal Library limit.",
            canonicalError);
        return nil;
    }
    NSString *manifestDigest = MTSHA256HexDigestForData(canonicalManifest);
    NSString *storageIdentifier =
        MTLibraryStorageIdentifierForThemeID(manifest.themeID);
    NSString *revisionIdentifier =
        MTLibraryRevisionIdentifierForManifestDigest(manifestDigest);
    NSArray<NSString *> *requiredDigests =
        MTLibraryRequiredAssetDigests(manifest);
    if (storageIdentifier == nil || revisionIdentifier == nil ||
        requiredDigests.count == 0) {
        MTLibrarySetError(error, MTThemeLibraryStoreErrorInvalidRequest,
            @"The manifest cannot identify a formal Library revision.", nil);
        return nil;
    }
    if (cancellationToken.isCancelled) {
        MTLibrarySetError(error, MTThemeLibraryStoreErrorCancelled,
            @"The formal Library commit was cancelled before locking.", nil);
        return nil;
    }

    __block MTLibraryThemeDirectories directories;
    if (!MTOpenLibraryThemeDirectories(self.configuration,
            storageIdentifier, YES, &directories, error)) {
        return nil;
    }
    int lockDescriptor = MTLibraryAcquireThemeTransactionLock(
        directories.themeDescriptor, error);
    if (lockDescriptor < 0) {
        MTLibraryThemeDirectoriesClose(&directories);
        return nil;
    }
    if (!MTLibraryRecoverAbandonedTransactions(
            directories.themeDescriptor, directories.revisionsDescriptor,
            error)) {
        close(lockDescriptor);
        MTLibraryThemeDirectoriesClose(&directories);
        return nil;
    }

    __block MTThemeLibraryRevision *committedRevision = nil;
    __block NSError *operationError = nil;
    NSSet<NSString *> *requiredSet = [NSSet setWithArray:requiredDigests];
    BOOL adopted = [assetStagingSession
        performLockedLibraryAdoptionForRequiredDigests:requiredSet
        consumer:^BOOL(
            int sourceObjectsDescriptor,
            NSDictionary<NSString *, MTStagedAsset *> *stagedAssets,
            NSError **consumerError) {
        NSData *metadataData = nil;
        NSDictionary<NSString *, NSNumber *> *byteCounts = nil;
        uint64_t totalAssetBytes = 0;
        if (!MTLibraryBuildRevisionMetadata(manifestDigest,
                requiredDigests, stagedAssets, self.configuration.limits,
                &metadataData, &byteCounts, &totalAssetBytes,
                consumerError) || metadataData == nil || byteCounts == nil) {
            if (consumerError != NULL && *consumerError == nil) {
                MTLibrarySetError(consumerError,
                    MTThemeLibraryStoreErrorVerification,
                    @"Formal revision metadata construction was incomplete.",
                    nil);
            }
            return NO;
        }
        if (cancellationToken.isCancelled) {
            return MTLibrarySetError(consumerError,
                MTThemeLibraryStoreErrorCancelled,
                @"The formal Library commit was cancelled before publication.",
                nil);
        }

        struct stat revisionStatus = {0};
        int revisionResult = fstatat(directories.revisionsDescriptor,
            revisionIdentifier.fileSystemRepresentation, &revisionStatus,
            AT_SYMLINK_NOFOLLOW);
        int revisionError = errno;
        if (revisionResult == 0) {
            committedRevision = MTLibraryLoadRevision(self, &directories,
                storageIdentifier, manifest.themeID, revisionIdentifier,
                manifestDigest, byteCounts, cancellationToken, consumerError);
            if (committedRevision == nil) return NO;
        } else if (revisionError != ENOENT) {
            return MTLibrarySetError(consumerError,
                MTThemeLibraryStoreErrorStorage,
                @"Unable to inspect the formal revision destination.",
                MTLibraryPOSIXError(revisionError));
        } else {
            uint64_t requiredBytes = totalAssetBytes;
            uint64_t standardizedResourceBytes = 0;
            NSMutableSet<NSString *> *resourcePaths = [NSMutableSet set];
            for (MTThemeResource *resource in manifest.resources) {
                if ([resourcePaths containsObject:resource.relativeAssetPath]) {
                    continue;
                }
                if (resourcePaths.count >=
                        self.configuration.limits.maximumRegularFiles) {
                    return MTLibrarySetError(consumerError,
                        MTThemeLibraryStoreErrorLimitExceeded,
                        @"The MarkTheme resources tree has too many files.",
                        nil);
                }
                [resourcePaths addObject:resource.relativeAssetPath];
                uint64_t count = byteCounts[resource.contentSHA256]
                    .unsignedLongLongValue;
                if (count == 0 || count > UINT64_MAX -
                        standardizedResourceBytes ||
                    count > self.configuration.limits.maximumExpandedBytes -
                        MIN(standardizedResourceBytes,
                            self.configuration.limits.maximumExpandedBytes)) {
                    return MTLibrarySetError(consumerError,
                        MTThemeLibraryStoreErrorLimitExceeded,
                        @"The standardized MarkTheme resource total exceeds its policy.",
                        nil);
                }
                standardizedResourceBytes += count;
            }
            if (canonicalManifest.length > UINT64_MAX - requiredBytes ||
                metadataData.length > UINT64_MAX - requiredBytes -
                    canonicalManifest.length ||
                standardizedResourceBytes > UINT64_MAX - requiredBytes -
                    canonicalManifest.length - metadataData.length) {
                return MTLibrarySetError(consumerError,
                    MTThemeLibraryStoreErrorLimitExceeded,
                    @"The formal revision byte total overflowed.", nil);
            }
            requiredBytes += canonicalManifest.length + metadataData.length +
                standardizedResourceBytes;
            if (!MTLibraryCheckAvailableSpace(directories.revisionsDescriptor,
                    requiredBytes,
                    self.configuration.minimumFreeSpaceReserveBytes,
                    consumerError)) {
                return NO;
            }

            NSString *transactionName = MTLibraryCreateTransactionName();
            int transactionDescriptor = -1;
            int assetsDescriptor = -1;
            int resourcesDescriptor = -1;
            BOOL success = MTLibraryCreateTransactionDirectories(
                directories.revisionsDescriptor, transactionName,
                &transactionDescriptor, &assetsDescriptor, consumerError);
            if (success) {
                success = MTLibraryWriteDataExclusivelyAt(
                    transactionDescriptor, @"manifest.json",
                    canonicalManifest, consumerError);
            }
            if (success) {
                for (NSString *digest in requiredDigests) {
                    if (!MTLibraryCopyVerifiedAsset(sourceObjectsDescriptor,
                            assetsDescriptor, digest,
                            byteCounts[digest].unsignedLongLongValue,
                            cancellationToken, NULL, consumerError)) {
                        success = NO;
                        break;
                    }
                }
            }
            if (success) {
                success = MTLibraryCreateStandardResourceFiles(
                    sourceObjectsDescriptor, transactionDescriptor, manifest,
                    byteCounts, cancellationToken, &resourcesDescriptor,
                    consumerError);
            }
            if (success) {
                success = MTLibraryWriteDataExclusivelyAt(
                    transactionDescriptor, @"revision.json", metadataData,
                    consumerError) &&
                    MTLibrarySynchronizeDirectoryDescriptor(assetsDescriptor,
                                                             consumerError) &&
                    MTLibrarySynchronizeDirectoryDescriptor(
                        resourcesDescriptor, consumerError) &&
                    MTLibrarySynchronizeDirectoryDescriptor(
                        transactionDescriptor, consumerError);
            }
            struct stat transactionStatus = {0};
            if (success) {
                NSArray<NSString *> *transactionNames = nil;
                NSArray<NSString *> *assetNames = nil;
                success = fstat(transactionDescriptor, &transactionStatus) == 0 &&
                    MTLibraryListDirectoryNames(transactionDescriptor,
                                                &transactionNames,
                                                consumerError) &&
                    [[NSSet setWithArray:transactionNames]
                        isEqualToSet:[NSSet setWithArray:@[
                            @"assets", @"manifest.json", @"resources",
                            @"revision.json"
                        ]]] &&
                    MTLibraryListDirectoryNames(assetsDescriptor,
                                                &assetNames, consumerError) &&
                    [assetNames isEqualToArray:requiredDigests];
                if (!success &&
                    (consumerError == NULL || *consumerError == nil)) {
                    MTLibrarySetError(consumerError,
                        MTThemeLibraryStoreErrorVerification,
                        @"The unpublished formal revision tree is incomplete.",
                        nil);
                }
            }
            if (resourcesDescriptor >= 0) close(resourcesDescriptor);
            if (assetsDescriptor >= 0) close(assetsDescriptor);
            if (transactionDescriptor >= 0) close(transactionDescriptor);
            if (success && cancellationToken.isCancelled) {
                success = MTLibrarySetError(consumerError,
                    MTThemeLibraryStoreErrorCancelled,
                    @"The formal Library commit was cancelled before its revision rename.",
                    nil);
            }
            BOOL published = NO;
            if (success) {
                int renameResult = renameatx_np(
                    directories.revisionsDescriptor,
                    transactionName.fileSystemRepresentation,
                    directories.revisionsDescriptor,
                    revisionIdentifier.fileSystemRepresentation,
                    RENAME_EXCL);
                if (renameResult == 0) {
                    published = YES;
                } else if (errno == EEXIST) {
                    success = MTLibraryDiscardTransaction(
                        directories.revisionsDescriptor, transactionName,
                        consumerError);
                    if (success) {
                        committedRevision = MTLibraryLoadRevision(self,
                            &directories, storageIdentifier, manifest.themeID,
                            revisionIdentifier, manifestDigest, byteCounts,
                            cancellationToken, consumerError);
                        success = committedRevision != nil;
                    }
                } else {
                    success = MTLibrarySetError(consumerError,
                        MTThemeLibraryStoreErrorStorage,
                        @"Unable to atomically publish the formal revision.",
                        MTLibraryPOSIXError(errno));
                }
            }
            if (success && published) {
                struct stat publishedStatus = {0};
                success = fstatat(directories.revisionsDescriptor,
                    revisionIdentifier.fileSystemRepresentation,
                    &publishedStatus, AT_SYMLINK_NOFOLLOW) == 0 &&
                    publishedStatus.st_dev == transactionStatus.st_dev &&
                    publishedStatus.st_ino == transactionStatus.st_ino &&
                    MTLibrarySynchronizeDirectoryDescriptor(
                        directories.revisionsDescriptor, consumerError);
                if (!success &&
                    (consumerError == NULL || *consumerError == nil)) {
                    MTLibrarySetError(consumerError,
                        MTThemeLibraryStoreErrorVerification,
                        @"The published formal revision changed identity.", nil);
                }
                if (success) {
                    committedRevision =
                        MTLibraryCreateCommittedRevisionResult(self,
                            storageIdentifier, revisionIdentifier,
                            manifestDigest, manifest, requiredDigests,
                            byteCounts, totalAssetBytes);
                }
            }
            if (!success) {
                MTLibraryDiscardTransaction(directories.revisionsDescriptor,
                                            transactionName, NULL);
                return NO;
            }
        }

        if (cancellationToken.isCancelled) {
            committedRevision = nil;
            return MTLibrarySetError(consumerError,
                MTThemeLibraryStoreErrorCancelled,
                @"The formal Library commit was cancelled before switching current.",
                nil);
        }
        NSError *pointerError = nil;
        NSData *pointerData = MTCanonicalJSONData(@{
            @"manifestDigest" : manifestDigest,
            @"revisionID" : revisionIdentifier,
            @"schemaVersion" : @2,
        }, &pointerError);
        if (pointerData == nil ||
            !MTLibraryReplaceCurrentData(directories.themeDescriptor,
                                         pointerData, consumerError)) {
            if (pointerData == nil) {
                MTLibrarySetError(consumerError,
                    MTThemeLibraryStoreErrorStorage,
                    @"Unable to encode the formal current revision pointer.",
                    pointerError);
            }
            committedRevision = nil;
            return NO;
        }
        if (!MTLibraryThemeDirectoriesAreStable(self.configuration,
                                                &directories,
                                                consumerError)) {
            committedRevision = nil;
            return NO;
        }
        return YES;
    }
        error:&operationError];

    close(lockDescriptor);
    MTLibraryThemeDirectoriesClose(&directories);
    if (!adopted || committedRevision == nil) {
        NSError *finalError = MTLibraryWrapStagingAdoptionError(operationError);
        if (error != NULL) *error = finalError;
        return nil;
    }
    return committedRevision;
}

- (MTThemeLibraryRevision *)
    loadCurrentRevisionForThemeID:(NSString *)themeID
                            error:(NSError **)error {
    return [self loadCurrentRevisionForThemeID:themeID
                             cancellationToken:nil
                                         error:error];
}

- (MTThemeLibraryRevision *)
    loadCurrentRevisionForThemeID:(NSString *)themeID
                cancellationToken:
                    (MTImportCancellationToken *)cancellationToken
                            error:(NSError **)error {
    if (cancellationToken.isCancelled) {
        MTLibrarySetError(error, MTThemeLibraryStoreErrorCancelled,
            @"The current Library revision load was cancelled.", nil);
        return nil;
    }
    NSString *storageIdentifier =
        MTLibraryStorageIdentifierForThemeID(themeID);
    if (storageIdentifier == nil) {
        MTLibrarySetError(error, MTThemeLibraryStoreErrorInvalidRequest,
            @"The requested theme identifier is invalid.", nil);
        return nil;
    }
    MTLibraryThemeDirectories directories;
    if (!MTOpenLibraryThemeDirectories(self.configuration,
            storageIdentifier, NO, &directories, error)) {
        return nil;
    }
    int lockDescriptor = MTLibraryAcquireThemeReadLock(
        directories.themeDescriptor, error);
    if (lockDescriptor < 0) {
        MTLibraryThemeDirectoriesClose(&directories);
        return nil;
    }
    NSData *pointerData = MTLibraryReadPrivateFileAt(
        directories.themeDescriptor, @"current.json",
        MTLibraryMaximumCurrentPointerBytes, error);
    uint64_t schemaVersion = 0;
    NSString *revisionIdentifier = nil;
    NSString *manifestDigest = nil;
    BOOL parsed = pointerData != nil && MTLibraryParseCurrentPointerData(
        pointerData, &schemaVersion, &revisionIdentifier, &manifestDigest,
        error);
    if (parsed && schemaVersion != 2) {
        MTLibrarySetError(error, MTThemeLibraryStoreErrorUnsupportedVersion,
            @"The current Library revision is legacy manifest-only data and must be reimported.",
            nil);
        parsed = NO;
    }
    if (!parsed) {
        close(lockDescriptor);
        MTLibraryThemeDirectoriesClose(&directories);
        return nil;
    }
    MTThemeLibraryRevision *revision = MTLibraryLoadRevision(self,
        &directories, storageIdentifier, themeID, revisionIdentifier,
        manifestDigest, nil, cancellationToken, error);
    if (revision != nil &&
        !MTLibraryThemeDirectoriesAreStable(self.configuration, &directories,
                                            error)) {
        revision = nil;
    }
    close(lockDescriptor);
    MTLibraryThemeDirectoriesClose(&directories);
    return revision;
}

- (NSDictionary<NSString *, NSData *> *)
    loadPreviewAssetDataForThemeID:(NSString *)themeID
        expectedRevisionIdentifier:(NSString *)revisionIdentifier
                  expectedManifest:(MTThemeManifest *)manifest
             contentSHA256Digests:(NSArray<NSString *> *)contentSHA256Digests
                              error:(NSError **)error {
    return [self loadPreviewAssetDataForThemeID:themeID
        expectedRevisionIdentifier:revisionIdentifier
        expectedManifest:manifest
        contentSHA256Digests:contentSHA256Digests
        cancellationToken:nil
        error:error];
}

- (NSDictionary<NSString *, NSData *> *)
    loadPreviewAssetDataForThemeID:(NSString *)themeID
        expectedRevisionIdentifier:(NSString *)revisionIdentifier
                  expectedManifest:(MTThemeManifest *)manifest
             contentSHA256Digests:(NSArray<NSString *> *)contentSHA256Digests
               cancellationToken:
                   (MTImportCancellationToken *)cancellationToken
                              error:(NSError **)error {
    if (cancellationToken.isCancelled) {
        MTLibrarySetError(error, MTThemeLibraryStoreErrorCancelled,
            @"The bounded Library preview read was cancelled.", nil);
        return nil;
    }
    NSString *normalizedThemeID = MTNormalizeIdentifier(themeID, NULL);
    NSString *storageIdentifier = MTLibraryStorageIdentifierForThemeID(themeID);
    NSString *manifestDigest = MTLibraryRevisionIdentifierIsCanonical(
        revisionIdentifier) ? [revisionIdentifier substringFromIndex:3] : nil;
    NSError *manifestError = nil;
    NSData *manifestData = [manifest canonicalDataWithError:&manifestError];
    NSArray<NSString *> *requiredDigests = manifest != nil
        ? MTLibraryRequiredAssetDigests(manifest) : nil;
    NSSet<NSString *> *requiredDigestSet = requiredDigests != nil
        ? [NSSet setWithArray:requiredDigests] : nil;
    NSSet<NSString *> *requestedDigestSet =
        [NSSet setWithArray:contentSHA256Digests ?: @[]];
    BOOL requestIsValid = normalizedThemeID != nil &&
        storageIdentifier != nil && manifestDigest != nil &&
        manifestData != nil &&
        [manifest.themeID isEqualToString:normalizedThemeID] &&
        [MTSHA256HexDigestForData(manifestData)
            isEqualToString:manifestDigest] &&
        contentSHA256Digests.count > 0 &&
        contentSHA256Digests.count <= MTLibraryMaximumPreviewAssetCount &&
        requestedDigestSet.count == contentSHA256Digests.count &&
        [requestedDigestSet isSubsetOfSet:requiredDigestSet];
    if (!requestIsValid) {
        MTLibrarySetError(error, MTThemeLibraryStoreErrorInvalidRequest,
            @"The bounded Library preview request is invalid.",
            manifestError);
        return nil;
    }
    if (cancellationToken.isCancelled) {
        MTLibrarySetError(error, MTThemeLibraryStoreErrorCancelled,
            @"The bounded Library preview read was cancelled.", nil);
        return nil;
    }

    MTLibraryThemeDirectories directories;
    if (!MTOpenLibraryThemeDirectories(self.configuration,
            storageIdentifier, NO, &directories, error)) {
        return nil;
    }
    int lockDescriptor = MTLibraryAcquireThemeReadLock(
        directories.themeDescriptor, error);
    if (lockDescriptor < 0) {
        MTLibraryThemeDirectoriesClose(&directories);
        return nil;
    }

    NSData *pointerData = MTLibraryReadPrivateFileAt(
        directories.themeDescriptor, @"current.json",
        MTLibraryMaximumCurrentPointerBytes, error);
    uint64_t schemaVersion = 0;
    NSString *currentRevisionIdentifier = nil;
    NSString *currentManifestDigest = nil;
    BOOL success = pointerData != nil && MTLibraryParseCurrentPointerData(
        pointerData, &schemaVersion, &currentRevisionIdentifier,
        &currentManifestDigest, error) && schemaVersion == 2 &&
        [currentRevisionIdentifier isEqualToString:revisionIdentifier] &&
        [currentManifestDigest isEqualToString:manifestDigest];
    if (!success && pointerData != nil && (error == NULL || *error == nil)) {
        MTLibrarySetError(error, MTThemeLibraryStoreErrorCurrentRevision,
            @"The requested preview revision is no longer current.", nil);
    }

    int revisionDescriptor = -1;
    int assetsDescriptor = -1;
    if (success) {
        success = MTLibraryOpenPrivateDirectoryAt(
            directories.revisionsDescriptor, revisionIdentifier,
            &revisionDescriptor, error) &&
            MTLibraryOpenPrivateDirectoryAt(revisionDescriptor, @"assets",
                                             &assetsDescriptor, error);
    }
    NSMutableDictionary<NSString *, NSData *> *result =
        [NSMutableDictionary dictionaryWithCapacity:contentSHA256Digests.count];
    uint64_t totalBytes = 0;
    for (NSString *digest in contentSHA256Digests) {
        if (!success) break;
        if (cancellationToken.isCancelled) {
            MTLibrarySetError(error, MTThemeLibraryStoreErrorCancelled,
                @"The bounded Library preview read was cancelled.", nil);
            success = NO;
            break;
        }
        NSData *data = MTLibraryReadPrivateFileAt(assetsDescriptor, digest,
            MTLibraryMaximumPreviewAssetBytes, error);
        if (data == nil ||
            ![MTSHA256HexDigestForData(data) isEqualToString:digest] ||
            data.length > MTLibraryMaximumPreviewTotalBytes - totalBytes) {
            if (data != nil && (error == NULL || *error == nil)) {
                MTLibrarySetError(error,
                    data.length > MTLibraryMaximumPreviewTotalBytes - totalBytes
                        ? MTThemeLibraryStoreErrorLimitExceeded
                        : MTThemeLibraryStoreErrorVerification,
                    @"A requested preview asset failed its bounded digest or size check.",
                    nil);
            }
            success = NO;
            break;
        }
        totalBytes += data.length;
        result[digest] = data;
    }
    if (success && cancellationToken.isCancelled) {
        MTLibrarySetError(error, MTThemeLibraryStoreErrorCancelled,
            @"The bounded Library preview read was cancelled.", nil);
        success = NO;
    }
    if (success) {
        success = MTLibraryThemeDirectoriesAreStable(
            self.configuration, &directories, error);
    }
    if (assetsDescriptor >= 0) close(assetsDescriptor);
    if (revisionDescriptor >= 0) close(revisionDescriptor);
    close(lockDescriptor);
    MTLibraryThemeDirectoriesClose(&directories);
    return success ? [result copy] : nil;
}

@end
