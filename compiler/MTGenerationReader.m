#import "MTGenerationReader.h"

#import "MTGenerationDescriptor.h"
#import "MTGenerationIndexCodec.h"
#import "MTGenerationReaderFilesystem.h"
#import "MTGenerationReaderValidation.h"
#import "MTImportSession.h"
#import "MTBootstrapPaths.h"

#import <fcntl.h>
#import <sys/stat.h>
#import <unistd.h>

#import "MTDigest.h"

NSString *const MTGenerationReaderErrorDomain =
    @"com.hmmzzz.marktheme.generation-reader";

@implementation MTGenerationReaderConfiguration

+ (instancetype)defaultConfiguration {
    NSURL *managerDataRoot = MTDefaultManagerDataRootURL();
    NSAssert(managerDataRoot != nil,
             @"Manager data storage must be available for Generation input.");
    NSURL *rootURL = [managerDataRoot
        URLByAppendingPathComponent:@"Compiler" isDirectory:YES];
    return [[self alloc]
        initWithRootURL:rootURL
        maximumAssetCount:20000
        maximumGenerationByteCount:1024ULL * 1024ULL * 1024ULL
        ownershipProfile:MTGenerationReaderOwnershipProfilePrivate];
}

- (instancetype)initWithRootURL:(NSURL *)rootURL
              maximumAssetCount:(NSUInteger)maximumAssetCount
      maximumGenerationByteCount:(uint64_t)maximumGenerationByteCount
                ownershipProfile:
                    (MTGenerationReaderOwnershipProfile)ownershipProfile {
    NSParameterAssert(rootURL.isFileURL);
    NSParameterAssert(rootURL.path.length > 0);
    NSParameterAssert(maximumAssetCount > 0);
    NSParameterAssert(maximumAssetCount < NSUIntegerMax);
    NSParameterAssert(maximumGenerationByteCount > 0);
    NSParameterAssert(
        ownershipProfile == MTGenerationReaderOwnershipProfilePrivate ||
        ownershipProfile == MTGenerationReaderOwnershipProfilePublished);
    self = [super init];
    if (self == nil) return nil;
    _rootURL = [rootURL copy];
    _maximumAssetCount = maximumAssetCount;
    _maximumGenerationByteCount = maximumGenerationByteCount;
    _ownershipProfile = ownershipProfile;
    return self;
}

@end

@interface MTGenerationResource ()

- (instancetype)initWithRecord:(MTGenerationIndexRecord *)record
                       assetURL:(NSURL *)assetURL;

@end

@implementation MTGenerationResource

- (instancetype)initWithRecord:(MTGenerationIndexRecord *)record
                       assetURL:(NSURL *)assetURL {
    self = [super init];
    if (self == nil) return nil;
    _canonicalResourceKey = [record.canonicalResourceKey copy];
    _contentSHA256 = [record.contentSHA256 copy];
    _assetByteCount = record.assetByteCount;
    _assetURL = [assetURL copy];
    return self;
}

@end

@interface MTGeneration () {
    int _generationDirectoryDescriptor;
    struct stat _generationDirectoryStatus;
    MTGenerationReaderOwnershipProfile _ownershipProfile;
}

@property(nonatomic, strong, readwrite) MTGenerationDescriptor *descriptor;
@property(nonatomic, strong, readwrite) MTGenerationIndex *index;
@property(nonatomic, copy, readwrite) NSString *generationIdentifier;
@property(nonatomic, copy, readwrite) NSURL *generationURL;

- (instancetype)initWithDescriptor:(MTGenerationDescriptor *)descriptor
                              index:(MTGenerationIndex *)index
                      generationURL:(NSURL *)generationURL
       generationDirectoryDescriptor:(int)generationDirectoryDescriptor
          generationDirectoryStatus:
              (const struct stat *)generationDirectoryStatus
                    ownershipProfile:
                        (MTGenerationReaderOwnershipProfile)ownershipProfile;

@end

@implementation MTGeneration

- (instancetype)initWithDescriptor:(MTGenerationDescriptor *)descriptor
                              index:(MTGenerationIndex *)index
                      generationURL:(NSURL *)generationURL
       generationDirectoryDescriptor:(int)generationDirectoryDescriptor
          generationDirectoryStatus:
              (const struct stat *)generationDirectoryStatus
                    ownershipProfile:
                        (MTGenerationReaderOwnershipProfile)ownershipProfile {
    NSParameterAssert(generationDirectoryDescriptor >= 0);
    NSParameterAssert(generationDirectoryStatus != NULL);
    self = [super init];
    if (self == nil) return nil;
    _descriptor = descriptor;
    _index = index;
    _generationIdentifier = [descriptor.generationIdentifier copy];
    _generationURL = [generationURL copy];
    _generationDirectoryDescriptor = generationDirectoryDescriptor;
    _generationDirectoryStatus = *generationDirectoryStatus;
    _ownershipProfile = ownershipProfile;
    return self;
}

- (MTGenerationResource *)resourceForCanonicalResourceKey:
    (NSString *)canonicalResourceKey
                                                               error:
    (NSError **)error {
    MTGenerationIndexRecord *record = [self.index
        recordForCanonicalResourceKey:canonicalResourceKey error:error];
    if (record == nil) return nil;
    NSURL *assetsURL = [self.generationURL
        URLByAppendingPathComponent:@"assets" isDirectory:YES];
    NSURL *assetURL = [assetsURL
        URLByAppendingPathComponent:record.contentSHA256 isDirectory:NO];
    return [[MTGenerationResource alloc] initWithRecord:record
                                               assetURL:assetURL];
}

- (NSData *)verifiedAssetDataForResource:(MTGenerationResource *)resource
                         maximumByteCount:(uint64_t)maximumByteCount
                                      error:(NSError **)error {
    if (error != NULL) *error = nil;
    if (![resource isKindOfClass:MTGenerationResource.class] ||
        maximumByteCount == 0 ||
        resource.assetByteCount > maximumByteCount) {
        MTGenerationReaderSetError(error,
            resource.assetByteCount > maximumByteCount
                ? MTGenerationReaderErrorLimitExceeded
                : MTGenerationReaderErrorInvalidRequest,
            @"A Generation asset read request is invalid or exceeds its budget.",
            nil);
        return nil;
    }
    NSError *recordError = nil;
    MTGenerationIndexRecord *record = [self.index
        recordForCanonicalResourceKey:resource.canonicalResourceKey
        error:&recordError];
    if (record == nil ||
        ![record.contentSHA256 isEqualToString:resource.contentSHA256] ||
        record.assetByteCount != resource.assetByteCount) {
        MTGenerationReaderSetError(error,
            MTGenerationReaderErrorVerification,
            @"The requested asset is not the exact indexed Generation resource.",
            recordError);
        return nil;
    }
    if (!MTGenerationReaderDirectoryDescriptorIsStable(
            _generationDirectoryDescriptor, &_generationDirectoryStatus,
            _ownershipProfile, error)) {
        return nil;
    }
    int assetsDescriptor = -1;
    struct stat assetsStatus = {0};
    if (!MTGenerationReaderOpenDirectoryAt(
            _generationDirectoryDescriptor, @"assets", _ownershipProfile,
            &assetsDescriptor, &assetsStatus, error)) {
        return nil;
    }
    struct stat assetStatus = {0};
    NSData *data = MTGenerationReaderReadFileAt(
        assetsDescriptor, resource.contentSHA256, resource.assetByteCount,
        nil, _ownershipProfile, &assetStatus, error);
    BOOL stable = data != nil &&
        data.length == resource.assetByteCount &&
        [MTSHA256HexDigestForData(data)
            isEqualToString:resource.contentSHA256] &&
        MTGenerationReaderFileIsStableAt(
            assetsDescriptor, resource.contentSHA256, &assetStatus,
            resource.assetByteCount, _ownershipProfile, error) &&
        MTGenerationReaderDirectoryIsStableAt(
            _generationDirectoryDescriptor, @"assets", assetsDescriptor,
            &assetsStatus, _ownershipProfile, error) &&
        MTGenerationReaderDirectoryDescriptorIsStable(
            _generationDirectoryDescriptor, &_generationDirectoryStatus,
            _ownershipProfile, error);
    close(assetsDescriptor);
    if (!stable) {
        if (data != nil && (error == NULL || *error == nil)) {
            MTGenerationReaderSetError(error,
                MTGenerationReaderErrorVerification,
                @"The Generation asset failed digest or stability verification.",
                nil);
        }
        return nil;
    }
    return data;
}

- (void)dealloc {
    if (_generationDirectoryDescriptor >= 0) {
        close(_generationDirectoryDescriptor);
    }
}

@end

@interface MTGenerationReader ()

@property(nonatomic, strong, readwrite)
    MTGenerationReaderConfiguration *configuration;

@end


@implementation MTGenerationReader

+ (instancetype)defaultReader {
    return [[self alloc] initWithConfiguration:
        MTGenerationReaderConfiguration.defaultConfiguration];
}

- (instancetype)initWithConfiguration:
    (MTGenerationReaderConfiguration *)configuration {
    NSParameterAssert(configuration != nil);
    self = [super init];
    if (self == nil) return nil;
    _configuration = configuration;
    return self;
}

- (MTGeneration *)readGenerationWithIdentifier:
    (NSString *)generationIdentifier
                                     cancellationToken:
    (MTImportCancellationToken *)cancellationToken
                                              error:(NSError **)error {
    if (!MTGenerationReaderIdentifierIsCanonical(generationIdentifier)) {
        MTGenerationReaderSetError(error,
            MTGenerationReaderErrorInvalidRequest,
            @"Generation reader requires a canonical generation identifier.",
            nil);
        return nil;
    }
    if (MTGenerationReaderCancelled(cancellationToken,
            @"Generation reading was cancelled before opening the store.",
            error)) {
        return nil;
    }
    MTGenerationReaderDirectories directories;
    if (!MTGenerationReaderOpenDirectories(
            self.configuration, generationIdentifier, &directories, error)) {
        return nil;
    }
    MTGenerationReaderValidatedTree *validated =
        MTGenerationReaderValidateTree(
            directories.generationDescriptor, self.configuration,
            generationIdentifier, cancellationToken, error);
    BOOL success = validated != nil;
    if (success && MTGenerationReaderCancelled(cancellationToken,
            @"Generation reading was cancelled before final identity validation.",
            error)) {
        success = NO;
    }
    if (success) {
        success = MTGenerationReaderDirectoriesAreStable(
            self.configuration, generationIdentifier, &directories, error);
    }
    MTGeneration *result = nil;
    if (success) {
        NSURL *generationURL = [[self.configuration.rootURL
            URLByAppendingPathComponent:@"generations" isDirectory:YES]
            URLByAppendingPathComponent:generationIdentifier
                             isDirectory:YES];
        int retainedDescriptor = fcntl(
            directories.generationDescriptor, F_DUPFD_CLOEXEC, 0);
        if (retainedDescriptor < 0 ||
            !MTGenerationReaderDirectoryDescriptorIsStable(
                retainedDescriptor, &directories.generationStatus,
                self.configuration.ownershipProfile, error)) {
            if (retainedDescriptor >= 0) close(retainedDescriptor);
            result = nil;
        } else {
            result = [[MTGeneration alloc]
                initWithDescriptor:validated.descriptor
                index:validated.index
                generationURL:generationURL
                generationDirectoryDescriptor:retainedDescriptor
                generationDirectoryStatus:&directories.generationStatus
                ownershipProfile:self.configuration.ownershipProfile];
        }
    }
    MTGenerationReaderDirectoriesClose(&directories);
    return result;
}

@end
