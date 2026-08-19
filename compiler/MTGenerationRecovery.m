#import "MTGenerationFilesystem.h"
#import "MTGenerationFilesystemInternal.h"

#import <errno.h>
#import <sys/stat.h>
#import <unistd.h>

#import "MTDigest.h"
#import "MTGenerationDescriptor.h"
#import "MTGenerationIndexCodec.h"

static NSString *const MTGenerationTransactionPrefix = @".transaction-";
static NSString *const MTGenerationDirectoryName = @"generations";
static NSString *const MTGenerationLockName = @"transaction.lock";

static BOOL MTGenerationConsumeRecoveryNode(
    NSUInteger *remainingNodes,
    NSError **error) {
    if (*remainingNodes == 0) {
        return MTGenerationWriterSetError(error,
            MTGenerationWriterErrorRecovery,
            @"Generation recovery exceeded its node budget.", nil);
    }
    (*remainingNodes)--;
    return YES;
}

static BOOL MTGenerationConsumeRecoveryBytes(
    uint64_t byteCount,
    uint64_t *remainingBytes,
    NSError **error) {
    if (byteCount > *remainingBytes) {
        return MTGenerationWriterSetError(error,
            MTGenerationWriterErrorRecovery,
            @"Generation recovery exceeded its byte budget.", nil);
    }
    *remainingBytes -= byteCount;
    return YES;
}

static BOOL MTGenerationValidateRecoveryFile(
    int directoryDescriptor,
    NSString *name,
    uint64_t maximumBytes,
    NSUInteger *remainingNodes,
    uint64_t *remainingBytes,
    NSError **error) {
    struct stat status = {0};
    if (!MTGenerationConsumeRecoveryNode(remainingNodes, error) ||
        fstatat(directoryDescriptor, name.fileSystemRepresentation, &status,
                AT_SYMLINK_NOFOLLOW) != 0 ||
        !MTGenerationPrivateFileStatusIsValid(&status, maximumBytes) ||
        !MTGenerationConsumeRecoveryBytes((uint64_t)status.st_size,
                                          remainingBytes, error)) {
        if (error == NULL || *error == nil) {
            MTGenerationWriterSetError(error,
                MTGenerationWriterErrorRecovery,
                @"A Generation recovery directory contains an unsafe file.",
                nil);
        }
        return NO;
    }
    return YES;
}

static BOOL MTGenerationDiscardTransactionWithBudget(
    int generationsDescriptor,
    NSString *transactionName,
    MTGenerationWriterConfiguration *configuration,
    NSUInteger *remainingNodes,
    uint64_t *remainingBytes,
    NSError **error) {
    if (!MTGenerationTransactionNameIsCanonical(transactionName)) {
        return MTGenerationWriterSetError(error,
            MTGenerationWriterErrorRecovery,
            @"Refusing to clean a non-canonical Generation transaction.", nil);
    }
    struct stat pathStatus = {0};
    if (fstatat(generationsDescriptor,
                transactionName.fileSystemRepresentation, &pathStatus,
                AT_SYMLINK_NOFOLLOW) != 0) {
        return errno == ENOENT ? YES : MTGenerationWriterSetError(error,
            MTGenerationWriterErrorRecovery,
            @"Unable to inspect a Generation recovery transaction.",
            MTGenerationPOSIXError(errno));
    }
    if (!MTGenerationConsumeRecoveryNode(remainingNodes, error)) return NO;
    int transaction = -1;
    if (!MTGenerationOpenPrivateDirectoryAt(
            generationsDescriptor, transactionName, &transaction, error)) {
        return NO;
    }
    struct stat openedStatus = {0};
    if (fstat(transaction, &openedStatus) != 0 ||
        !MTGenerationStatIdentityMatches(&pathStatus, &openedStatus)) {
        close(transaction);
        return MTGenerationWriterSetError(error,
            MTGenerationWriterErrorRecovery,
            @"A Generation recovery transaction changed before cleanup.", nil);
    }
    NSArray<NSString *> *entries = nil;
    BOOL success = MTGenerationListDirectoryNames(transaction, &entries, error);
    NSSet<NSString *> *allowed = [NSSet setWithArray:@[
        @"assets", @"index.mtg", @"generation.json"
    ]];
    for (NSString *entry in entries) {
        if (![allowed containsObject:entry]) {
            success = MTGenerationWriterSetError(error,
                MTGenerationWriterErrorRecovery,
                @"Refusing to delete a Generation transaction with an unknown entry.",
                nil);
            break;
        }
    }
    int assets = -1;
    if (success && [entries containsObject:@"assets"]) {
        if (!MTGenerationConsumeRecoveryNode(remainingNodes, error)) {
            success = NO;
        } else {
            success = MTGenerationOpenPrivateDirectoryAt(
                transaction, @"assets", &assets, error);
        }
    }
    NSArray<NSString *> *assetNames = nil;
    if (success && assets >= 0) {
        success = MTGenerationListDirectoryNames(assets, &assetNames, error);
        if (success && assetNames.count > configuration.maximumAssetCount) {
            success = MTGenerationWriterSetError(error,
                MTGenerationWriterErrorRecovery,
                @"Generation recovery found too many transaction assets.", nil);
        }
        for (NSString *name in assetNames) {
            if (!success) break;
            if (!MTStringIsLowercaseSHA256Digest(name) ||
                !MTGenerationValidateRecoveryFile(
                    assets, name, configuration.maximumGenerationByteCount,
                    remainingNodes, remainingBytes, error)) {
                if (error == NULL || *error == nil) {
                    MTGenerationWriterSetError(error,
                        MTGenerationWriterErrorRecovery,
                        @"Refusing to delete an unsafe Generation recovery asset.",
                        nil);
                }
                success = NO;
            }
        }
    }
    if (success && [entries containsObject:@"index.mtg"]) {
        success = MTGenerationValidateRecoveryFile(
            transaction, @"index.mtg", MTGenerationIndexMaximumByteCount,
            remainingNodes, remainingBytes, error);
    }
    if (success && [entries containsObject:@"generation.json"]) {
        success = MTGenerationValidateRecoveryFile(
            transaction, @"generation.json",
            MTGenerationDescriptorMaximumByteCount,
            remainingNodes, remainingBytes, error);
    }
    if (assets >= 0) {
        if (success) {
            for (NSString *name in assetNames) {
                if (unlinkat(assets, name.fileSystemRepresentation, 0) != 0) {
                    success = MTGenerationWriterSetError(error,
                        MTGenerationWriterErrorRecovery,
                        @"Unable to remove a Generation recovery asset.",
                        MTGenerationPOSIXError(errno));
                    break;
                }
            }
        }
        if (success) success = MTGenerationSynchronizeDirectory(assets, error);
        close(assets);
        if (success && unlinkat(transaction, "assets", AT_REMOVEDIR) != 0) {
            success = MTGenerationWriterSetError(error,
                MTGenerationWriterErrorRecovery,
                @"Unable to remove a Generation recovery asset directory.",
                MTGenerationPOSIXError(errno));
        }
    }
    if (success) {
        for (NSString *name in @[@"index.mtg", @"generation.json"]) {
            if ([entries containsObject:name] &&
                unlinkat(transaction, name.fileSystemRepresentation, 0) != 0) {
                success = MTGenerationWriterSetError(error,
                    MTGenerationWriterErrorRecovery,
                    @"Unable to remove Generation recovery metadata.",
                    MTGenerationPOSIXError(errno));
                break;
            }
        }
    }
    if (success) success = MTGenerationSynchronizeDirectory(transaction, error);
    struct stat pathAfter = {0};
    if (success) {
        success = fstatat(generationsDescriptor,
            transactionName.fileSystemRepresentation, &pathAfter,
            AT_SYMLINK_NOFOLLOW) == 0 &&
            MTGenerationStatIdentityMatches(&openedStatus, &pathAfter);
        if (!success) {
            MTGenerationWriterSetError(error,
                MTGenerationWriterErrorRecovery,
                @"A Generation recovery transaction changed during cleanup.",
                nil);
        }
    }
    close(transaction);
    if (success && unlinkat(generationsDescriptor,
            transactionName.fileSystemRepresentation, AT_REMOVEDIR) != 0) {
        success = MTGenerationWriterSetError(error,
            MTGenerationWriterErrorRecovery,
            @"Unable to remove a Generation recovery transaction.",
            MTGenerationPOSIXError(errno));
    }
    if (success) {
        success = MTGenerationSynchronizeDirectory(generationsDescriptor,
                                                   error);
    }
    return success;
}

BOOL MTGenerationDiscardTransaction(
    int generationsDescriptor,
    NSString *transactionName,
    MTGenerationWriterConfiguration *configuration,
    NSError **error) {
    NSUInteger remainingNodes = configuration.maximumRecoveryNodeCount;
    uint64_t remainingBytes = configuration.maximumGenerationByteCount;
    return MTGenerationDiscardTransactionWithBudget(
        generationsDescriptor, transactionName, configuration,
        &remainingNodes, &remainingBytes, error);
}

BOOL MTGenerationRecoverAbandonedTransactions(
    int rootDescriptor,
    int generationsDescriptor,
    MTGenerationWriterConfiguration *configuration,
    NSError **error) {
    NSArray<NSString *> *rootNames = nil;
    if (!MTGenerationListDirectoryNames(rootDescriptor, &rootNames, error)) {
        return NO;
    }
    NSSet<NSString *> *expectedRootNames = [NSSet setWithArray:@[
        MTGenerationDirectoryName, MTGenerationLockName
    ]];
    if (![[NSSet setWithArray:rootNames] isEqualToSet:expectedRootNames] ||
        !MTGenerationVerifyPrivateFileAt(rootDescriptor,
            MTGenerationLockName, 0, nil, nil, error)) {
        if (error == NULL || *error == nil) {
            MTGenerationWriterSetError(error,
                MTGenerationWriterErrorRecovery,
                @"The Generation store root contains an unknown or unsafe node.",
                nil);
        }
        return NO;
    }

    NSArray<NSString *> *names = nil;
    if (!MTGenerationListDirectoryNames(generationsDescriptor, &names, error)) {
        return NO;
    }
    if (names.count > configuration.maximumRecoveryNodeCount) {
        return MTGenerationWriterSetError(error,
            MTGenerationWriterErrorRecovery,
            @"Generation recovery exceeded its first-level node budget.", nil);
    }
    NSUInteger remainingNodes = configuration.maximumRecoveryNodeCount;
    uint64_t remainingBytes = configuration.maximumGenerationByteCount;
    for (NSString *name in names) {
        if ([name hasPrefix:MTGenerationTransactionPrefix]) {
            if (!MTGenerationTransactionNameIsCanonical(name) ||
                !MTGenerationDiscardTransactionWithBudget(
                    generationsDescriptor, name, configuration,
                    &remainingNodes, &remainingBytes, error)) {
                if (error == NULL || *error == nil) {
                    MTGenerationWriterSetError(error,
                        MTGenerationWriterErrorRecovery,
                        @"The Generation store contains an unsafe transaction.",
                        nil);
                }
                return NO;
            }
            continue;
        }
        if (!MTGenerationIdentifierIsCanonical(name) ||
            !MTGenerationConsumeRecoveryNode(&remainingNodes, error)) {
            if (error == NULL || *error == nil) {
                MTGenerationWriterSetError(error,
                    MTGenerationWriterErrorRecovery,
                    @"The Generation store contains an unknown final node.",
                    nil);
            }
            return NO;
        }
        int finalDescriptor = -1;
        if (!MTGenerationOpenPrivateDirectoryAt(
                generationsDescriptor, name, &finalDescriptor, error)) {
            return NO;
        }
        close(finalDescriptor);
    }
    return YES;
}
