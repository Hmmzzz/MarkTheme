#import "MTThemeApplyService.h"

#import "MTBootstrapPaths.h"
#import "MTGenerationWriter.h"
#import "MTImportSession.h"
#import "MTRuntimeHelperClient.h"
#import "MTRuntimeState.h"
#import "MTStaticIconCompiler.h"
#import "MTThemeComponentCatalog.h"
#import "MTThemeLibraryStore.h"
#import "MTThemeManifest.h"

NSString *const MTThemeApplyServiceErrorDomain =
    @"com.hmmzzz.marktheme.theme-apply-service";
NSString *const MTThemeApplyServiceStageKey = @"MTThemeApplyServiceStage";

static void MTThemeApplySetError(NSError **error,
                                 MTThemeApplyServiceErrorCode code,
                                 MTThemeApplyStage stage,
                                 NSString *description,
                                 NSError *underlying) {
    if (error == NULL) return;
    NSMutableDictionary *userInfo = [NSMutableDictionary
        dictionaryWithObjectsAndKeys:
            description, NSLocalizedDescriptionKey,
            @(stage), MTThemeApplyServiceStageKey,
            nil];
    if (underlying != nil) userInfo[NSUnderlyingErrorKey] = underlying;
    *error = [NSError errorWithDomain:MTThemeApplyServiceErrorDomain
                                 code:code
                             userInfo:userInfo];
}

static BOOL MTThemeApplyCheckCancellation(
    MTImportCancellationToken *cancellationToken,
    MTThemeApplyStage stage,
    NSError **error) {
    if (!cancellationToken.isCancelled) return YES;
    MTThemeApplySetError(error, MTThemeApplyServiceErrorCancelled, stage,
        @"The theme Apply operation was cancelled.", nil);
    return NO;
}

@interface MTThemeApplyResult ()

@property(nonatomic, copy, readwrite) NSString *themeID;
@property(nonatomic, copy, readwrite) NSString *libraryRevisionIdentifier;
@property(nonatomic, copy, readwrite) NSString *generationIdentifier;
@property(nonatomic, assign, readwrite) BOOL reusedInboxGeneration;
@property(nonatomic, assign, readwrite) BOOL reusedRuntimeGeneration;
@property(nonatomic, strong, readwrite) MTRuntimeState *runtimeState;
@property(nonatomic, assign, readwrite) BOOL runtimeAcknowledged;

- (instancetype)initWithThemeID:(NSString *)themeID
       libraryRevisionIdentifier:(NSString *)libraryRevisionIdentifier
            generationIdentifier:(NSString *)generationIdentifier
         reusedInboxGeneration:(BOOL)reusedInboxGeneration
       reusedRuntimeGeneration:(BOOL)reusedRuntimeGeneration
                    runtimeState:(MTRuntimeState *)runtimeState
             runtimeAcknowledged:(BOOL)runtimeAcknowledged;

@end

@implementation MTThemeApplyResult

- (instancetype)initWithThemeID:(NSString *)themeID
       libraryRevisionIdentifier:(NSString *)libraryRevisionIdentifier
            generationIdentifier:(NSString *)generationIdentifier
         reusedInboxGeneration:(BOOL)reusedInboxGeneration
       reusedRuntimeGeneration:(BOOL)reusedRuntimeGeneration
                    runtimeState:(MTRuntimeState *)runtimeState
             runtimeAcknowledged:(BOOL)runtimeAcknowledged {
    self = [super init];
    if (self == nil) return nil;
    _themeID = [themeID copy];
    _libraryRevisionIdentifier = [libraryRevisionIdentifier copy];
    _generationIdentifier = [generationIdentifier copy];
    _reusedInboxGeneration = reusedInboxGeneration;
    _reusedRuntimeGeneration = reusedRuntimeGeneration;
    _runtimeState = runtimeState;
    _runtimeAcknowledged = runtimeAcknowledged;
    return self;
}

@end

@interface MTThemeApplyService ()

@property(nonatomic, strong, readwrite) MTThemeLibraryStore *libraryStore;
@property(nonatomic, strong, readwrite) MTStaticIconCompiler *compiler;
@property(nonatomic, strong, readwrite) MTGenerationWriter *inboxWriter;
@property(nonatomic, strong, readwrite) MTRuntimeHelperClient *runtimeClient;

@end

@implementation MTThemeApplyService

+ (instancetype)defaultServiceWithError:(NSError **)error {
    MTThemeLibraryStore *libraryStore = [[MTThemeLibraryStore alloc]
        initWithConfiguration:MTThemeLibraryConfiguration.defaultConfiguration];
    return [self defaultServiceWithLibraryStore:libraryStore error:error];
}

+ (instancetype)defaultServiceWithLibraryStore:
        (MTThemeLibraryStore *)libraryStore
                                              error:(NSError **)error {
    NSParameterAssert(libraryStore != nil);
    NSURL *inboxURL = MTDefaultGenerationInboxURL(error);
    if (inboxURL == nil) return nil;
    MTRuntimeHelperClient *runtimeClient =
        [MTRuntimeHelperClient defaultClientWithError:error];
    if (runtimeClient == nil) return nil;

    MTGenerationWriterConfiguration *defaults =
        MTGenerationWriterConfiguration.defaultConfiguration;
    MTGenerationWriterConfiguration *inboxConfiguration =
        [[MTGenerationWriterConfiguration alloc]
            initWithRootURL:inboxURL
            maximumAssetCount:defaults.maximumAssetCount
            maximumGenerationByteCount:defaults.maximumGenerationByteCount
            minimumFreeSpaceReserveBytes:
                defaults.minimumFreeSpaceReserveBytes
            maximumRecoveryNodeCount:defaults.maximumRecoveryNodeCount];
    return [[self alloc]
        initWithLibraryStore:libraryStore
        compiler:MTStaticIconCompiler.defaultCompiler
        inboxWriter:[[MTGenerationWriter alloc]
            initWithConfiguration:inboxConfiguration]
        runtimeClient:runtimeClient];
}

- (instancetype)initWithLibraryStore:(MTThemeLibraryStore *)libraryStore
                              compiler:(MTStaticIconCompiler *)compiler
                           inboxWriter:(MTGenerationWriter *)inboxWriter
                         runtimeClient:(MTRuntimeHelperClient *)runtimeClient {
    NSParameterAssert(libraryStore != nil);
    NSParameterAssert(compiler != nil);
    NSParameterAssert(inboxWriter != nil);
    NSParameterAssert(runtimeClient != nil);
    self = [super init];
    if (self == nil) return nil;
    _libraryStore = libraryStore;
    _compiler = compiler;
    _inboxWriter = inboxWriter;
    _runtimeClient = runtimeClient;
    return self;
}

- (MTThemeApplyResult *)
    applyCurrentThemeWithIdentifier:(NSString *)themeID
                  cancellationToken:
                      (MTImportCancellationToken *)cancellationToken
                              error:(NSError **)error {
    return [self applyCurrentThemeWithIdentifier:themeID
                              componentSelection:nil
                              cancellationToken:cancellationToken
                                          error:error];
}

- (MTThemeApplyResult *)
    applyCurrentThemeWithIdentifier:(NSString *)themeID
                  componentSelection:
                      (MTThemeComponentSelection *)componentSelection
                  cancellationToken:
                      (MTImportCancellationToken *)cancellationToken
                              error:(NSError **)error {
    if (themeID.length == 0) {
        MTThemeApplySetError(error, MTThemeApplyServiceErrorInvalidRequest,
            MTThemeApplyStageLoadLibrary,
            @"Apply requires a theme identifier.", nil);
        return nil;
    }
    if (!MTThemeApplyCheckCancellation(cancellationToken,
            MTThemeApplyStageLoadLibrary, error)) {
        return nil;
    }

    NSError *stageError = nil;
    MTThemeLibraryRevision *revision = [self.libraryStore
        loadCurrentRevisionForThemeID:themeID
        cancellationToken:cancellationToken
        error:&stageError];
    if (revision == nil) {
        MTThemeApplySetError(error,
            cancellationToken.isCancelled
                ? MTThemeApplyServiceErrorCancelled
                : MTThemeApplyServiceErrorLibrary,
            MTThemeApplyStageLoadLibrary,
            @"Unable to load the current Library revision for Apply.",
            stageError);
        return nil;
    }

    stageError = nil;
    MTCompiledGeneration *compiled = componentSelection == nil
        ? [self.compiler compileLibraryRevision:revision
             cancellationToken:cancellationToken error:&stageError]
        : [self.compiler compileLibraryRevision:revision
             componentSelection:componentSelection
             cancellationToken:cancellationToken error:&stageError];
    if (compiled == nil) {
        MTThemeApplySetError(error,
            cancellationToken.isCancelled
                ? MTThemeApplyServiceErrorCancelled
                : MTThemeApplyServiceErrorCompile,
            MTThemeApplyStageCompile,
            @"Unable to compile the current Library revision.", stageError);
        return nil;
    }
    if (!MTThemeApplyCheckCancellation(cancellationToken,
            MTThemeApplyStageWriteInbox, error)) {
        return nil;
    }

    stageError = nil;
    MTGenerationWriteResult *writeResult = [self.inboxWriter
        writeCompiledGeneration:compiled
        cancellationToken:cancellationToken
        error:&stageError];
    if (writeResult == nil) {
        MTThemeApplySetError(error,
            cancellationToken.isCancelled
                ? MTThemeApplyServiceErrorCancelled
                : MTThemeApplyServiceErrorInbox,
            MTThemeApplyStageWriteInbox,
            @"Unable to publish the compiled Generation to the private Inbox.",
            stageError);
        return nil;
    }
    if (!MTThemeApplyCheckCancellation(cancellationToken,
            MTThemeApplyStageActivateRuntime, error)) {
        return nil;
    }

    stageError = nil;
    MTRuntimeApplyResult *runtimeResult = [self.runtimeClient
        applyGenerationWithIdentifier:writeResult.generationIdentifier
        error:&stageError];
    if (runtimeResult == nil || !runtimeResult.state.isRuntimeEnabled ||
        ![runtimeResult.state.activeGenerationIdentifier
            isEqualToString:writeResult.generationIdentifier]) {
        MTThemeApplySetError(error, MTThemeApplyServiceErrorRuntime,
            MTThemeApplyStageActivateRuntime,
            @"The Runtime Helper did not activate the compiled Generation.",
            stageError);
        return nil;
    }

    return [[MTThemeApplyResult alloc]
        initWithThemeID:revision.manifest.themeID
        libraryRevisionIdentifier:revision.revisionIdentifier
        generationIdentifier:writeResult.generationIdentifier
        reusedInboxGeneration:writeResult.reusedExistingGeneration
        reusedRuntimeGeneration:runtimeResult.reusedExistingGeneration
        runtimeState:runtimeResult.state
        runtimeAcknowledged:
            runtimeResult.delivery == MTRuntimeApplyDeliveryAcknowledged];
}

@end
