#import "MTGenerationReaderValidation.h"

#import <stdlib.h>
#import <sys/stat.h>
#import <unistd.h>

#import "MTDigest.h"
#import "MTGenerationDescriptor.h"
#import "MTGenerationIndexCodec.h"
#import "MTGenerationReader.h"
#import "MTGenerationReaderFilesystem.h"
#import "MTImportSession.h"

static NSString *const MTGenerationReaderAssetsName = @"assets";
static NSString *const MTGenerationReaderIndexName = @"index.mtg";
static NSString *const MTGenerationReaderDescriptorName = @"generation.json";

@interface MTGenerationReaderValidatedTree ()

@property(nonatomic, strong, readwrite) MTGenerationDescriptor *descriptor;
@property(nonatomic, strong, readwrite) MTGenerationIndex *index;

- (instancetype)initWithDescriptor:(MTGenerationDescriptor *)descriptor
                              index:(MTGenerationIndex *)index;

@end

@implementation MTGenerationReaderValidatedTree

- (instancetype)initWithDescriptor:(MTGenerationDescriptor *)descriptor
                              index:(MTGenerationIndex *)index {
    self = [super init];
    if (self == nil) return nil;
    _descriptor = descriptor;
    _index = index;
    return self;
}

@end

static BOOL MTGenerationReaderAddByteCount(uint64_t value,
                                           uint64_t *total,
                                           NSError **error) {
    if (value > UINT64_MAX - *total) {
        return MTGenerationReaderSetError(error,
            MTGenerationReaderErrorLimitExceeded,
            @"The Generation logical byte total overflowed.", nil);
    }
    *total += value;
    return YES;
}

static BOOL MTGenerationReaderSetVerificationError(
    NSError **error,
    NSString *description,
    NSError *underlying) {
    return MTGenerationReaderSetError(error,
        MTGenerationReaderErrorVerification, description, underlying);
}

MTGenerationReaderValidatedTree *MTGenerationReaderValidateTree(
    int generationDescriptor,
    MTGenerationReaderConfiguration *configuration,
    NSString *expectedGenerationIdentifier,
    MTImportCancellationToken *token,
    NSError **error) {
    if (generationDescriptor < 0 ||
        ![configuration isKindOfClass:
            MTGenerationReaderConfiguration.class] ||
        !MTGenerationReaderIdentifierIsCanonical(
            expectedGenerationIdentifier)) {
        MTGenerationReaderSetError(error,
            MTGenerationReaderErrorInvalidRequest,
            @"A Generation tree validation request is invalid.", nil);
        return nil;
    }
    if (MTGenerationReaderCancelled(token,
            @"Generation validation was cancelled before tree enumeration.",
            error)) {
        return nil;
    }
    NSArray<NSString *> *generationNames = nil;
    if (!MTGenerationReaderListDirectoryNames(
            generationDescriptor, 4, token, &generationNames, error) ||
        ![generationNames isEqualToArray:@[
            MTGenerationReaderAssetsName,
            MTGenerationReaderDescriptorName,
            MTGenerationReaderIndexName,
        ]]) {
        if (error == NULL || *error == nil) {
            MTGenerationReaderSetVerificationError(error,
                @"A Generation final tree does not contain its exact required nodes.",
                nil);
        }
        return nil;
    }

    int assetsDescriptor = -1;
    struct stat assetsStatus = {0};
    if (!MTGenerationReaderOpenDirectoryAt(
            generationDescriptor, MTGenerationReaderAssetsName,
            configuration.ownershipProfile,
            &assetsDescriptor, &assetsStatus, error)) {
        return nil;
    }

    MTGenerationReaderValidatedTree *result = nil;
    struct stat descriptorStatus = {0};
    NSData *descriptorData = MTGenerationReaderReadFileAt(
        generationDescriptor, MTGenerationReaderDescriptorName,
        MTGenerationDescriptorMaximumByteCount, token,
        configuration.ownershipProfile, &descriptorStatus, error);
    NSError *descriptorError = nil;
    MTGenerationDescriptor *descriptor = descriptorData == nil ? nil :
        [[MTGenerationDescriptor alloc] initWithCanonicalData:descriptorData
                                                       error:&descriptorError];
    BOOL success = descriptor != nil &&
        [descriptor.canonicalData isEqualToData:descriptorData] &&
        [descriptor.generationIdentifier
            isEqualToString:expectedGenerationIdentifier];
    if (!success && descriptorData != nil) {
        MTGenerationReaderSetVerificationError(error,
            @"The Generation completion marker is invalid or does not match its directory name.",
            descriptorError);
    }
    if (success && descriptor.assetCount > configuration.maximumAssetCount) {
        success = MTGenerationReaderSetError(error,
            MTGenerationReaderErrorLimitExceeded,
            @"The Generation exceeds the reader asset-count limit.", nil);
    }

    struct stat indexStatus = {0};
    NSData *indexData = success ? MTGenerationReaderReadFileAt(
        generationDescriptor, MTGenerationReaderIndexName,
        descriptor.indexByteCount, token, configuration.ownershipProfile,
        &indexStatus, error) : nil;
    NSError *indexError = nil;
    MTGenerationIndex *index = indexData == nil ? nil :
        [[MTGenerationIndex alloc] initWithEncodedData:indexData
                                                 error:&indexError];
    if (success) {
        success = index != nil &&
            indexData.length == descriptor.indexByteCount &&
            [index.encodedData isEqualToData:indexData] &&
            descriptor.indexFormatVersion == MTGenerationIndexFormatVersion &&
            descriptor.resourceCount == index.recordCount &&
            [descriptor.indexSHA256
                isEqualToString:MTSHA256HexDigestForData(indexData)];
        if (!success && indexData != nil) {
            MTGenerationReaderSetVerificationError(error,
                @"The Generation index does not match its completion marker.",
                indexError);
        }
    }

    uint64_t totalBytes = descriptor.assetByteCount;
    if (success &&
        (!MTGenerationReaderAddByteCount(descriptorData.length, &totalBytes,
                                        error) ||
         !MTGenerationReaderAddByteCount(indexData.length, &totalBytes,
                                        error))) {
        success = NO;
    }
    if (success &&
        totalBytes > configuration.maximumGenerationByteCount) {
        success = MTGenerationReaderSetError(error,
            MTGenerationReaderErrorLimitExceeded,
            @"The Generation exceeds the reader logical byte limit.", nil);
    }

    NSMutableDictionary<NSString *, MTGenerationAssetDescriptor *>
        *assetsByDigest = [NSMutableDictionary
            dictionaryWithCapacity:descriptor.assetCount];
    NSMutableArray<NSString *> *expectedAssetNames = [NSMutableArray
        arrayWithCapacity:descriptor.assetCount];
    if (success) {
        for (MTGenerationAssetDescriptor *asset in descriptor.assets) {
            if (![asset isKindOfClass:MTGenerationAssetDescriptor.class] ||
                !MTStringIsLowercaseSHA256Digest(asset.contentSHA256) ||
                asset.byteCount == 0 ||
                assetsByDigest[asset.contentSHA256] != nil) {
                success = MTGenerationReaderSetVerificationError(error,
                    @"The Generation completion marker contains an invalid asset set.",
                    nil);
                break;
            }
            assetsByDigest[asset.contentSHA256] = asset;
            [expectedAssetNames addObject:asset.contentSHA256];
        }
    }
    NSArray<NSString *> *assetNames = nil;
    NSUInteger enumerationLimit = configuration.maximumAssetCount + 1;
    if (success) {
        success = MTGenerationReaderListDirectoryNames(
            assetsDescriptor, enumerationLimit, token, &assetNames, error) &&
            [assetNames isEqualToArray:expectedAssetNames];
        if (!success && assetNames != nil &&
            (error == NULL || *error == nil)) {
            MTGenerationReaderSetVerificationError(error,
                @"The Generation asset directory is not the exact descriptor set.",
                nil);
        }
    }

    NSMutableSet<NSString *> *referencedDigests = [NSMutableSet set];
    if (success) {
        for (NSUInteger recordIndex = 0;
             recordIndex < index.recordCount; recordIndex++) {
            MTGenerationIndexRecord *record = [index
                recordAtIndex:recordIndex];
            MTGenerationAssetDescriptor *asset =
                assetsByDigest[record.contentSHA256];
            if (record == nil || asset == nil ||
                record.assetByteCount != asset.byteCount) {
                success = MTGenerationReaderSetVerificationError(error,
                    @"The Generation index references an unknown or mismatched asset.",
                    nil);
                break;
            }
            [referencedDigests addObject:record.contentSHA256];
        }
    }
    if (success && ![referencedDigests isEqualToSet:
            [NSSet setWithArray:expectedAssetNames]]) {
        success = MTGenerationReaderSetVerificationError(error,
            @"The Generation index and descriptor asset sets differ.", nil);
    }

    NSUInteger validatedAssetCount = descriptor.assets.count;
    struct stat *assetStatuses = NULL;
    if (success && validatedAssetCount > 0) {
        if (validatedAssetCount > SIZE_MAX / sizeof(struct stat)) {
            MTGenerationReaderSetError(error,
                MTGenerationReaderErrorLimitExceeded,
                @"The Generation asset-status table size overflowed.", nil);
            success = NO;
        } else {
            assetStatuses = calloc(validatedAssetCount,
                                   sizeof(struct stat));
            if (assetStatuses == NULL) {
                MTGenerationReaderSetError(error,
                    MTGenerationReaderErrorStorage,
                    @"Unable to allocate bounded Generation validation state.",
                    nil);
                success = NO;
            }
        }
    }
    if (success) {
        for (NSUInteger assetIndex = 0;
             assetIndex < validatedAssetCount; assetIndex++) {
            MTGenerationAssetDescriptor *asset =
                descriptor.assets[assetIndex];
            if (!MTGenerationReaderVerifyAssetAt(
                    assetsDescriptor, asset.contentSHA256, asset.byteCount,
                    token, configuration.ownershipProfile,
                    &assetStatuses[assetIndex], error)) {
                success = NO;
                break;
            }
        }
    }
    // Recheck every already-hashed path after the full pass so a mutation of
    // an early asset while a later asset is read cannot escape the snapshot.
    if (success) {
        for (NSUInteger assetIndex = 0;
             assetIndex < validatedAssetCount; assetIndex++) {
            MTGenerationAssetDescriptor *asset =
                descriptor.assets[assetIndex];
            if (MTGenerationReaderCancelled(token,
                    @"Generation final stability verification was cancelled.",
                    error) ||
                !MTGenerationReaderFileIsStableAt(
                    assetsDescriptor, asset.contentSHA256,
                    &assetStatuses[assetIndex], asset.byteCount,
                    configuration.ownershipProfile, error)) {
                success = NO;
                break;
            }
        }
    }
    if (success) {
        success = MTGenerationReaderFileIsStableAt(
                generationDescriptor, MTGenerationReaderDescriptorName,
                &descriptorStatus, descriptorData.length,
                configuration.ownershipProfile, error) &&
            MTGenerationReaderFileIsStableAt(
                generationDescriptor, MTGenerationReaderIndexName,
                &indexStatus, indexData.length,
                configuration.ownershipProfile, error) &&
            MTGenerationReaderDirectoryIsStableAt(
                generationDescriptor, MTGenerationReaderAssetsName,
                assetsDescriptor, &assetsStatus,
                configuration.ownershipProfile, error);
    }
    free(assetStatuses);
    close(assetsDescriptor);
    if (success) {
        result = [[MTGenerationReaderValidatedTree alloc]
            initWithDescriptor:descriptor index:index];
    }
    return result;
}
