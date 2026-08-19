#import "MTRuntimeSnapshotLoader.h"

#import "MTBootstrapPaths.h"
#import "MTGenerationReader.h"
#import "MTRuntimeSnapshot.h"
#import "MTRuntimeState.h"

NSString *const MTRuntimeSnapshotLoaderErrorDomain =
    @"com.hmmzzz.marktheme.runtime-snapshot-loader";

static void MTRuntimeSnapshotLoaderSetError(
    NSError **error,
    MTRuntimeSnapshotLoaderErrorCode code,
    NSString *description,
    NSError *underlying) {
    if (error == NULL) return;
    NSMutableDictionary *userInfo = [NSMutableDictionary
        dictionaryWithObject:description forKey:NSLocalizedDescriptionKey];
    if (underlying != nil) userInfo[NSUnderlyingErrorKey] = underlying;
    *error = [NSError errorWithDomain:MTRuntimeSnapshotLoaderErrorDomain
                                 code:code
                             userInfo:userInfo];
}

@interface MTRuntimeSnapshotLoader ()
@property(nonatomic, copy, readwrite) NSURL *runtimeRootURL;
- (nullable MTRuntimeState *)readStateWithError:(NSError **)error;
- (nullable MTGeneration *)readGenerationWithIdentifier:
    (NSString *)identifier error:(NSError **)error;
- (nullable MTRuntimeSnapshot *)loadSnapshotWithState:
    (MTRuntimeState * _Nullable * _Nullable)state error:(NSError **)error;
@end

@implementation MTRuntimeSnapshotLoader

+ (instancetype)defaultLoaderWithError:(NSError **)error {
    NSURL *runtimeRootURL = MTDefaultRuntimeStoreURL(error);
    return runtimeRootURL == nil ? nil
        : [[self alloc] initWithRuntimeRootURL:runtimeRootURL];
}

- (instancetype)initWithRuntimeRootURL:(NSURL *)runtimeRootURL {
    NSParameterAssert(runtimeRootURL.isFileURL);
    NSParameterAssert(runtimeRootURL.path.length > 0);
    self = [super init];
    if (self == nil) return nil;
    _runtimeRootURL = [runtimeRootURL copy];
    return self;
}

- (MTGeneration *)loadActiveGenerationWithState:
    (MTRuntimeState **)state
                                             error:(NSError **)error {
    MTRuntimeSnapshot *snapshot = [self loadSnapshotWithState:state
                                                        error:error];
    if (snapshot == nil) return nil;
    return snapshot.generation;
}

- (MTRuntimeSnapshot *)loadSnapshotWithError:(NSError **)error {
    return [self loadSnapshotWithState:NULL error:error];
}

- (MTRuntimeSnapshot *)loadSnapshotWithState:(MTRuntimeState **)state
                                         error:(NSError **)error {
    NSError *readError = nil;
    MTRuntimeState *current = [self readStateWithError:&readError];
    if (current == nil) {
        if (error != NULL) *error = readError;
        return nil;
    }
    if (state != NULL) *state = current;
    if (!current.isRuntimeEnabled ||
        current.activeGenerationIdentifier == nil) {
        return [[MTRuntimeSnapshot alloc] initWithState:current
                                            generation:nil];
    }
    MTGeneration *generation = [self
        readGenerationWithIdentifier:current.activeGenerationIdentifier
        error:&readError];
    if (generation == nil) {
        if (readError != nil) {
            if (error != NULL) *error = readError;
        } else {
            MTRuntimeSnapshotLoaderSetError(error,
                MTRuntimeSnapshotLoaderErrorLoadFailed,
                @"The active Runtime Generation could not be loaded.", nil);
        }
        return nil;
    }
    MTRuntimeState *confirmed = [self readStateWithError:&readError];
    if (confirmed == nil) {
        if (error != NULL) *error = readError;
        return nil;
    }
    if (![current.canonicalData isEqualToData:confirmed.canonicalData]) {
        MTRuntimeSnapshotLoaderSetError(error,
            MTRuntimeSnapshotLoaderErrorStateChanged,
            @"Runtime state changed while its Generation was being validated.",
            nil);
        return nil;
    }
    if (state != NULL) *state = confirmed;
    return [[MTRuntimeSnapshot alloc] initWithState:confirmed
                                        generation:generation];
}

- (MTRuntimeState *)readStateWithError:(NSError **)error {
    return [MTRuntimeState
        stateByReadingRuntimeRootURL:self.runtimeRootURL
        ownershipProfile:MTRuntimeStateOwnershipProfilePublished
        error:error];
}

- (MTGeneration *)readGenerationWithIdentifier:(NSString *)identifier
                                           error:(NSError **)error {
    MTGenerationReaderConfiguration *configuration =
        [[MTGenerationReaderConfiguration alloc]
            initWithRootURL:self.runtimeRootURL
            maximumAssetCount:20000
            maximumGenerationByteCount:1024ULL * 1024ULL * 1024ULL
            ownershipProfile:MTGenerationReaderOwnershipProfilePublished];
    MTGenerationReader *reader = [[MTGenerationReader alloc]
        initWithConfiguration:configuration];
    return [reader
        readGenerationWithIdentifier:identifier
        cancellationToken:nil
        error:error];
}

@end
