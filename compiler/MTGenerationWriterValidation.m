#import "MTGenerationWriterValidation.h"

#import <errno.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <unistd.h>

#import "MTDigest.h"
#import "MTGenerationDescriptor.h"
#import "MTGenerationFilesystem.h"
#import "MTGenerationIndexCodec.h"
#import "MTGenerationWriter.h"
#import "MTImportSession.h"
#import "MTStaticIconCompiler.h"

static NSString *const MTGenerationIndexFilename = @"index.mtg";
static NSString *const MTGenerationDescriptorFilename = @"generation.json";
static NSString *const MTGenerationAssetsDirectoryName = @"assets";

@implementation MTGenerationValidatedInput
@end

BOOL MTGenerationWriterCancelled(
    MTImportCancellationToken *token,
    NSString *description,
    NSError **error) {
    if (!token.isCancelled) return NO;
    MTGenerationWriterSetError(error, MTGenerationWriterErrorCancelled,
                               description, nil);
    return YES;
}

static BOOL MTGenerationWriterAddByteCount(uint64_t value,
                                           uint64_t *total,
                                           NSError **error) {
    if (value > UINT64_MAX - *total) {
        return MTGenerationWriterSetError(error,
            MTGenerationWriterErrorLimitExceeded,
            @"The Generation logical byte total overflowed.", nil);
    }
    *total += value;
    return YES;
}

MTGenerationValidatedInput *MTGenerationWriterValidateInput(
    MTCompiledGeneration *compiledGeneration,
    MTGenerationWriterConfiguration *configuration,
    NSError **error) {
    if (![compiledGeneration isKindOfClass:MTCompiledGeneration.class] ||
        ![compiledGeneration.descriptor
            isKindOfClass:MTGenerationDescriptor.class] ||
        ![compiledGeneration.index isKindOfClass:MTGenerationIndex.class] ||
        ![compiledGeneration.sourceAssetURLsByContentSHA256
            isKindOfClass:NSDictionary.class]) {
        MTGenerationWriterSetError(error,
            MTGenerationWriterErrorInvalidRequest,
            @"Generation writer requires a complete pure compiler result.", nil);
        return nil;
    }
    NSData *indexData = [compiledGeneration.index.encodedData copy];
    NSData *descriptorData =
        [compiledGeneration.descriptor.canonicalData copy];
    NSError *parseError = nil;
    MTGenerationIndex *index = indexData == nil ? nil :
        [[MTGenerationIndex alloc] initWithEncodedData:indexData
                                                 error:&parseError];
    MTGenerationDescriptor *descriptor = descriptorData == nil ? nil :
        [[MTGenerationDescriptor alloc]
            initWithCanonicalData:descriptorData error:&parseError];
    if (index == nil || descriptor == nil ||
        ![index.encodedData isEqualToData:indexData] ||
        ![descriptor.canonicalData isEqualToData:descriptorData] ||
        !MTGenerationIdentifierIsCanonical(
            descriptor.generationIdentifier) ||
        ![[descriptor.generationIdentifier substringFromIndex:3]
            isEqualToString:descriptor.generationDigest] ||
        descriptor.indexByteCount != indexData.length ||
        descriptor.indexFormatVersion != MTGenerationIndexFormatVersion ||
        descriptor.resourceCount != index.recordCount ||
        ![descriptor.indexSHA256
            isEqualToString:MTSHA256HexDigestForData(indexData)]) {
        MTGenerationWriterSetError(error,
            MTGenerationWriterErrorVerification,
            @"The pure compiler index and completion descriptor are inconsistent.",
            parseError);
        return nil;
    }
    if (descriptor.assetCount > configuration.maximumAssetCount) {
        MTGenerationWriterSetError(error,
            MTGenerationWriterErrorLimitExceeded,
            @"The compiled Generation exceeds the writer asset-count limit.",
            nil);
        return nil;
    }

    NSMutableDictionary<NSString *, MTGenerationAssetDescriptor *>
        *assetsByDigest = [NSMutableDictionary
            dictionaryWithCapacity:descriptor.assets.count];
    uint64_t assetBytes = 0;
    for (MTGenerationAssetDescriptor *asset in descriptor.assets) {
        if (![asset isKindOfClass:MTGenerationAssetDescriptor.class] ||
            !MTStringIsLowercaseSHA256Digest(asset.contentSHA256) ||
            asset.byteCount == 0 ||
            assetsByDigest[asset.contentSHA256] != nil ||
            !MTGenerationWriterAddByteCount(asset.byteCount, &assetBytes,
                                            error)) {
            if (error == NULL || *error == nil) {
                MTGenerationWriterSetError(error,
                    MTGenerationWriterErrorVerification,
                    @"The compiled Generation asset set is invalid.", nil);
            }
            return nil;
        }
        assetsByDigest[asset.contentSHA256] = asset;
    }
    if (assetBytes != descriptor.assetByteCount ||
        assetsByDigest.count != descriptor.assetCount) {
        MTGenerationWriterSetError(error,
            MTGenerationWriterErrorVerification,
            @"The compiled Generation asset totals are inconsistent.", nil);
        return nil;
    }
    NSSet<NSString *> *assetDigestSet =
        [NSSet setWithArray:assetsByDigest.allKeys];
    NSDictionary<NSString *, NSURL *> *sourceURLs =
        compiledGeneration.sourceAssetURLsByContentSHA256;
    if (![[NSSet setWithArray:sourceURLs.allKeys]
            isEqualToSet:assetDigestSet]) {
        MTGenerationWriterSetError(error,
            MTGenerationWriterErrorVerification,
            @"The compiled Generation source URLs are not the exact asset set.",
            nil);
        return nil;
    }
    for (NSString *digest in assetDigestSet) {
        NSURL *url = sourceURLs[digest];
        if (![url isKindOfClass:NSURL.class] || !url.isFileURL ||
            ![url.lastPathComponent isEqualToString:digest]) {
            MTGenerationWriterSetError(error,
                MTGenerationWriterErrorVerification,
                @"A compiled Generation source URL is invalid.", nil);
            return nil;
        }
    }
    NSMutableSet<NSString *> *referencedDigests = [NSMutableSet set];
    for (NSUInteger recordIndex = 0;
         recordIndex < index.recordCount; recordIndex++) {
        MTGenerationIndexRecord *record = [index recordAtIndex:recordIndex];
        MTGenerationAssetDescriptor *asset =
            assetsByDigest[record.contentSHA256];
        if (record == nil || asset == nil ||
            record.assetByteCount != asset.byteCount) {
            MTGenerationWriterSetError(error,
                MTGenerationWriterErrorVerification,
                @"The Generation index references an unknown or mismatched asset.",
                nil);
            return nil;
        }
        [referencedDigests addObject:record.contentSHA256];
    }
    if (![referencedDigests isEqualToSet:assetDigestSet]) {
        MTGenerationWriterSetError(error,
            MTGenerationWriterErrorVerification,
            @"The Generation index and descriptor assets are not an exact set.",
            nil);
        return nil;
    }

    uint64_t totalBytes = assetBytes;
    if (!MTGenerationWriterAddByteCount(indexData.length, &totalBytes, error) ||
        !MTGenerationWriterAddByteCount(descriptorData.length, &totalBytes,
                                        error)) {
        return nil;
    }
    if (totalBytes > configuration.maximumGenerationByteCount) {
        MTGenerationWriterSetError(error,
            MTGenerationWriterErrorLimitExceeded,
            @"The compiled Generation exceeds the writer byte limit.", nil);
        return nil;
    }

    MTGenerationValidatedInput *input =
        [[MTGenerationValidatedInput alloc] init];
    input.descriptor = descriptor;
    input.index = index;
    input.indexData = indexData;
    input.descriptorData = descriptorData;
    input.assetsByDigest = assetsByDigest;
    input.sortedAssetDigests =
        [assetsByDigest.allKeys sortedArrayUsingSelector:@selector(compare:)];
    input.sourceURLs = sourceURLs;
    input.totalByteCount = totalBytes;
    return input;
}

BOOL MTGenerationWriterVerifyTree(
    int generationDescriptor,
    MTGenerationValidatedInput *input,
    MTImportCancellationToken *token,
    NSError **error) {
    if (MTGenerationWriterCancelled(token,
            @"Generation verification was cancelled before opening the tree.",
            error)) {
        return NO;
    }
    NSArray<NSString *> *names = nil;
    if (!MTGenerationListDirectoryNames(generationDescriptor, &names, error) ||
        ![[NSSet setWithArray:names] isEqualToSet:[NSSet setWithArray:@[
            MTGenerationAssetsDirectoryName,
            MTGenerationIndexFilename,
            MTGenerationDescriptorFilename,
        ]]]) {
        if (error == NULL || *error == nil) {
            MTGenerationWriterSetError(error,
                MTGenerationWriterErrorVerification,
                @"A Generation tree does not contain its exact required nodes.",
                nil);
        }
        return NO;
    }
    int assetsDescriptor = -1;
    if (!MTGenerationOpenPrivateDirectoryAt(
            generationDescriptor, MTGenerationAssetsDirectoryName,
            &assetsDescriptor, error)) {
        return NO;
    }
    NSArray<NSString *> *assetNames = nil;
    BOOL success = MTGenerationListDirectoryNames(
        assetsDescriptor, &assetNames, error) &&
        [assetNames isEqualToArray:input.sortedAssetDigests];
    if (!success && (error == NULL || *error == nil)) {
        MTGenerationWriterSetError(error,
            MTGenerationWriterErrorVerification,
            @"A Generation tree does not contain its exact asset set.", nil);
    }
    NSData *indexData = success ? MTGenerationReadPrivateFileAt(
        generationDescriptor, MTGenerationIndexFilename,
        input.indexData.length, error) : nil;
    success = success && [indexData isEqualToData:input.indexData];
    if (!success && indexData != nil && (error == NULL || *error == nil)) {
        MTGenerationWriterSetError(error,
            MTGenerationWriterErrorVerification,
            @"A Generation tree index does not match the compiler output.", nil);
    }
    NSData *descriptorData = success ? MTGenerationReadPrivateFileAt(
        generationDescriptor, MTGenerationDescriptorFilename,
        input.descriptorData.length, error) : nil;
    success = success &&
        [descriptorData isEqualToData:input.descriptorData];
    if (!success && descriptorData != nil && (error == NULL || *error == nil)) {
        MTGenerationWriterSetError(error,
            MTGenerationWriterErrorVerification,
            @"A Generation completion marker does not match the compiler output.",
            nil);
    }
    if (success) {
        for (NSString *digest in input.sortedAssetDigests) {
            MTGenerationAssetDescriptor *asset =
                input.assetsByDigest[digest];
            if (!MTGenerationVerifyPrivateFileAt(
                    assetsDescriptor, digest, asset.byteCount, digest,
                    token, error)) {
                success = NO;
                break;
            }
        }
    }
    close(assetsDescriptor);
    return success;
}
BOOL MTGenerationWriterVerifyFinal(
    int generationsDescriptor,
    MTGenerationValidatedInput *input,
    MTImportCancellationToken *token,
    NSError **error) {
    NSString *identifier = input.descriptor.generationIdentifier;
    struct stat pathBefore = {0};
    if (fstatat(generationsDescriptor,
                identifier.fileSystemRepresentation, &pathBefore,
                AT_SYMLINK_NOFOLLOW) != 0) {
        return MTGenerationWriterSetError(error,
            MTGenerationWriterErrorStorage,
            @"Unable to inspect an existing Generation destination.",
            MTGenerationPOSIXError(errno));
    }
    int finalDescriptor = -1;
    if (!MTGenerationOpenPrivateDirectoryAt(
            generationsDescriptor, identifier, &finalDescriptor, error)) {
        return NO;
    }
    struct stat opened = {0};
    BOOL success = fstat(finalDescriptor, &opened) == 0 &&
        opened.st_dev == pathBefore.st_dev && opened.st_ino == pathBefore.st_ino &&
        MTGenerationWriterVerifyTree(finalDescriptor, input, token, error);
    struct stat after = {0};
    struct stat pathAfter = {0};
    if (success) {
        success = fstat(finalDescriptor, &after) == 0 &&
            fstatat(generationsDescriptor,
                    identifier.fileSystemRepresentation, &pathAfter,
                    AT_SYMLINK_NOFOLLOW) == 0 &&
            after.st_dev == opened.st_dev && after.st_ino == opened.st_ino &&
            pathAfter.st_dev == opened.st_dev &&
            pathAfter.st_ino == opened.st_ino;
        if (!success) {
            MTGenerationWriterSetError(error,
                MTGenerationWriterErrorVerification,
                @"An existing Generation changed while it was verified.", nil);
        }
    }
    close(finalDescriptor);
    if (!success && (error == NULL || *error == nil)) {
        MTGenerationWriterSetError(error,
            MTGenerationWriterErrorVerification,
            @"An existing Generation failed complete writer validation.", nil);
    }
    return success;
}
