#import "MTThemeApplyService.h"

#import "MTBootstrapPaths.h"
#import "MTGenerationDescriptor.h"
#import "MTGenerationWriter.h"
#import "MTImportDiagnostics.h"
#import "MTImportSession.h"
#import "MTRuntimeHelperClient.h"
#import "MTRuntimeState.h"
#import "MTStaticIconCompiler.h"
#import "MTThemeComponentCatalog.h"
#import "MTThemeLibraryStore.h"
#import "MTThemeManifest.h"
#import "MTThemeMixSelection.h"

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

- (instancetype)initWithThemeID:(NSString *)themeID
       libraryRevisionIdentifier:(NSString *)libraryRevisionIdentifier
            generationIdentifier:(NSString *)generationIdentifier
         reusedInboxGeneration:(BOOL)reusedInboxGeneration
       reusedRuntimeGeneration:(BOOL)reusedRuntimeGeneration
                    runtimeState:(MTRuntimeState *)runtimeState;

@end

@implementation MTThemeApplyResult

- (instancetype)initWithThemeID:(NSString *)themeID
       libraryRevisionIdentifier:(NSString *)libraryRevisionIdentifier
            generationIdentifier:(NSString *)generationIdentifier
         reusedInboxGeneration:(BOOL)reusedInboxGeneration
       reusedRuntimeGeneration:(BOOL)reusedRuntimeGeneration
                    runtimeState:(MTRuntimeState *)runtimeState {
    self = [super init];
    if (self == nil) return nil;
    _themeID = [themeID copy];
    _libraryRevisionIdentifier = [libraryRevisionIdentifier copy];
    _generationIdentifier = [generationIdentifier copy];
    _reusedInboxGeneration = reusedInboxGeneration;
    _reusedRuntimeGeneration = reusedRuntimeGeneration;
    _runtimeState = runtimeState;
    return self;
}

@end

@interface MTThemeApplyService ()

@property(nonatomic, strong, readwrite) MTThemeLibraryStore *libraryStore;
@property(nonatomic, strong, readwrite) MTStaticIconCompiler *compiler;
@property(nonatomic, strong, readwrite) MTGenerationWriter *inboxWriter;
@property(nonatomic, strong, readwrite) MTRuntimeHelperClient *runtimeClient;
- (nullable MTThemeApplyResult *)publishCompiledGeneration:
    (MTCompiledGeneration *)compiled
                                             baseRevision:
                                                 (MTThemeLibraryRevision *)baseRevision
                                        cancellationToken:
                                            (nullable MTImportCancellationToken *)cancellationToken
                                                    error:(NSError **)error;

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

- (MTThemeApplyResult *)publishCompiledGeneration:
        (MTCompiledGeneration *)compiled
                                         baseRevision:
                                             (MTThemeLibraryRevision *)baseRevision
                                    cancellationToken:
                                        (MTImportCancellationToken *)cancellationToken
                                                error:(NSError **)error {
    if (!MTThemeApplyCheckCancellation(cancellationToken,
            MTThemeApplyStageWriteInbox, error)) {
        return nil;
    }
    NSError *stageError = nil;
    MTGenerationWriteResult *writeResult = [self.inboxWriter
        writeCompiledGeneration:compiled
        cancellationToken:cancellationToken
        error:&stageError];
    if (writeResult == nil) {
        MTImportDiagnosticsRecordError(@"apply.inbox.failed",
            stageError, @{
                @"generationIdentifier" :
                    compiled.descriptor.generationIdentifier ?: @"",
                @"inboxRoot" :
                    self.inboxWriter.configuration.rootURL.path ?: @"",
            });
        MTThemeApplySetError(error,
            cancellationToken.isCancelled
                ? MTThemeApplyServiceErrorCancelled
                : MTThemeApplyServiceErrorInbox,
            MTThemeApplyStageWriteInbox,
            @"Unable to publish the compiled Generation to the private Inbox.",
            stageError);
        return nil;
    }
    MTImportDiagnosticsRecord(@"apply.inbox.ready", @{
        @"generationIdentifier" : writeResult.generationIdentifier ?: @"",
        @"generationPath" : writeResult.generationURL.path ?: @"",
        @"reused" : @(writeResult.reusedExistingGeneration),
        @"clonedAssetCount" : @(writeResult.clonedAssetCount),
        @"streamedAssetCount" : @(writeResult.streamedAssetCount),
    });
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
        MTImportDiagnosticsRecordError(@"apply.runtime.failed",
            stageError, @{
                @"generationIdentifier" :
                    writeResult.generationIdentifier ?: @"",
                @"hasRuntimeResult" : @(runtimeResult != nil),
                @"runtimeEnabled" : @(runtimeResult.state.isRuntimeEnabled),
                @"activeGenerationIdentifier" :
                    runtimeResult.state.activeGenerationIdentifier ?: @"",
            });
        MTThemeApplySetError(error, MTThemeApplyServiceErrorRuntime,
            MTThemeApplyStageActivateRuntime,
            @"The Runtime Helper did not activate the compiled Generation.",
            stageError);
        return nil;
    }
    if (!runtimeResult.iconServiceAcknowledged) {
        MTImportDiagnosticsRecord(@"apply.icon-service.failed", @{
            @"generationIdentifier" :
                writeResult.generationIdentifier ?: @"",
            @"sequence" : @(runtimeResult.state.sequence),
        });
        MTThemeApplySetError(error, MTThemeApplyServiceErrorRuntime,
            MTThemeApplyStageActivateRuntime,
            @"IconServices did not confirm the application-icon source and "
             "its verified cache transaction. Respring is not a substitute "
             "for this source failure; retry Apply after the service is "
             "available.",
            nil);
        return nil;
    }
    MTImportDiagnosticsRecord(@"apply.runtime.ready", @{
        @"generationIdentifier" : writeResult.generationIdentifier ?: @"",
        @"activeGenerationIdentifier" :
            runtimeResult.state.activeGenerationIdentifier ?: @"",
        @"sequence" : @(runtimeResult.state.sequence),
        @"delivery" : runtimeResult.delivery ==
                MTRuntimeApplyDeliveryAcknowledged
            ? @"acknowledged" : @"reload-required",
        @"iconServiceDelivery" : @"acknowledged",
        @"reused" : @(runtimeResult.reusedExistingGeneration),
    });
    return [[MTThemeApplyResult alloc]
        initWithThemeID:baseRevision.manifest.themeID
        libraryRevisionIdentifier:baseRevision.revisionIdentifier
        generationIdentifier:writeResult.generationIdentifier
        reusedInboxGeneration:writeResult.reusedExistingGeneration
        reusedRuntimeGeneration:runtimeResult.reusedExistingGeneration
        runtimeState:runtimeResult.state];
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
    MTImportDiagnosticsRecord(@"apply.request", @{
        @"themeID" : themeID ?: @"",
        @"libraryRoot" : self.libraryStore.rootURL.path ?: @"",
        @"inboxRoot" : self.inboxWriter.configuration.rootURL.path ?: @"",
        @"helperPath" : self.runtimeClient.helperURL.path ?: @"",
    });
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
        MTImportDiagnosticsRecordError(@"apply.library.failed",
            stageError, @{ @"themeID" : themeID });
        MTThemeApplySetError(error,
            cancellationToken.isCancelled
                ? MTThemeApplyServiceErrorCancelled
                : MTThemeApplyServiceErrorLibrary,
            MTThemeApplyStageLoadLibrary,
            @"Unable to load the current Library revision for Apply.",
            stageError);
        return nil;
    }
    MTImportDiagnosticsRecord(@"apply.library.ready", @{
        @"themeID" : revision.manifest.themeID ?: @"",
        @"revisionIdentifier" : revision.revisionIdentifier ?: @"",
        @"assetCount" : @(revision.assetCount),
        @"assetByteCount" : @(revision.assetByteCount),
    });

    stageError = nil;
    MTCompiledGeneration *compiled = componentSelection == nil
        ? [self.compiler compileLibraryRevision:revision
             cancellationToken:cancellationToken error:&stageError]
        : [self.compiler compileLibraryRevision:revision
             componentSelection:componentSelection
             cancellationToken:cancellationToken error:&stageError];
    if (compiled == nil) {
        MTImportDiagnosticsRecordError(@"apply.compile.failed",
            stageError, @{
                @"themeID" : revision.manifest.themeID ?: @"",
                @"revisionIdentifier" : revision.revisionIdentifier ?: @"",
            });
        MTThemeApplySetError(error,
            cancellationToken.isCancelled
                ? MTThemeApplyServiceErrorCancelled
                : MTThemeApplyServiceErrorCompile,
            MTThemeApplyStageCompile,
            @"Unable to compile the current Library revision.", stageError);
        return nil;
    }
    MTImportDiagnosticsRecord(@"apply.compile.ready", @{
        @"generationIdentifier" :
            compiled.descriptor.generationIdentifier ?: @"",
        @"resourceCount" : @(compiled.descriptor.resourceCount),
        @"assetCount" : @(compiled.descriptor.assetCount),
        @"moduleIDs" : compiled.descriptor.moduleIDs ?: @[],
    });
    return [self publishCompiledGeneration:compiled
                              baseRevision:revision
                         cancellationToken:cancellationToken
                                     error:error];
}

- (MTThemeApplyResult *)applyThemeMixSelection:
        (MTThemeMixSelection *)mixSelection
                                  cancellationToken:
                                      (MTImportCancellationToken *)cancellationToken
                                              error:(NSError **)error {
    MTThemeMixSelection *validated =
        [mixSelection isKindOfClass:MTThemeMixSelection.class]
        ? [MTThemeMixSelection selectionWithCanonicalDictionary:
            mixSelection.canonicalDictionary error:NULL]
        : nil;
    MTImportDiagnosticsRecord(@"apply.mix.request", @{
        @"baseThemeID" : validated.baseThemeIdentifier ?: @"",
        @"sourceCount" : @(validated.effectiveThemeIdentifiers.count),
        @"rememberedSourceCount" :
            @(validated.referencedThemeIdentifiers.count),
        @"disabledFeatureCount" :
            @(validated.disabledFeatureIdentifiers.count),
        @"libraryRoot" : self.libraryStore.rootURL.path ?: @"",
        @"inboxRoot" : self.inboxWriter.configuration.rootURL.path ?: @"",
        @"helperPath" : self.runtimeClient.helperURL.path ?: @"",
    });
    if (validated == nil) {
        MTThemeApplySetError(error, MTThemeApplyServiceErrorInvalidRequest,
            MTThemeApplyStageLoadLibrary,
            @"Apply requires one valid current theme mix selection.", nil);
        return nil;
    }
    if (!MTThemeApplyCheckCancellation(cancellationToken,
            MTThemeApplyStageLoadLibrary, error)) {
        return nil;
    }

    NSMutableDictionary<NSString *, MTThemeLibraryRevision *> *revisions =
        [NSMutableDictionary
            dictionaryWithCapacity:validated.effectiveThemeIdentifiers.count];
    for (NSString *themeIdentifier in validated.effectiveThemeIdentifiers) {
        NSError *stageError = nil;
        MTThemeLibraryRevision *revision = [self.libraryStore
            loadCurrentRevisionForThemeID:themeIdentifier
            cancellationToken:cancellationToken
            error:&stageError];
        NSString *expectedRevision =
            validated.revisionIdentifiersByThemeIdentifier[themeIdentifier];
        if (revision == nil || ![revision.revisionIdentifier
                isEqualToString:expectedRevision]) {
            MTImportDiagnosticsRecordError(@"apply.mix.library.failed",
                stageError, @{
                    @"themeID" : themeIdentifier,
                    @"expectedRevisionIdentifier" : expectedRevision ?: @"",
                    @"actualRevisionIdentifier" :
                        revision.revisionIdentifier ?: @"",
                });
            MTThemeApplySetError(error,
                cancellationToken.isCancelled
                    ? MTThemeApplyServiceErrorCancelled
                    : MTThemeApplyServiceErrorLibrary,
                MTThemeApplyStageLoadLibrary,
                @"A source theme changed or could not be loaded for Apply.",
                stageError);
            return nil;
        }
        revisions[themeIdentifier] = revision;
        if (!MTThemeApplyCheckCancellation(cancellationToken,
                MTThemeApplyStageLoadLibrary, error)) {
            return nil;
        }
    }

    NSError *stageError = nil;
    MTCompiledGeneration *compiled = [self.compiler
        compileLibraryRevisionsByThemeIdentifier:revisions
        mixSelection:validated
        cancellationToken:cancellationToken
        error:&stageError];
    MTThemeLibraryRevision *baseRevision =
        revisions[validated.baseThemeIdentifier];
    if (compiled == nil || baseRevision == nil) {
        MTImportDiagnosticsRecordError(@"apply.mix.compile.failed",
            stageError, @{
                @"baseThemeID" : validated.baseThemeIdentifier,
                @"sourceCount" : @(revisions.count),
            });
        MTThemeApplySetError(error,
            cancellationToken.isCancelled
                ? MTThemeApplyServiceErrorCancelled
                : MTThemeApplyServiceErrorCompile,
            MTThemeApplyStageCompile,
            @"Unable to compile the selected cross-theme configuration.",
            stageError);
        return nil;
    }
    MTImportDiagnosticsRecord(@"apply.mix.compile.ready", @{
        @"generationIdentifier" :
            compiled.descriptor.generationIdentifier ?: @"",
        @"resourceCount" : @(compiled.descriptor.resourceCount),
        @"assetCount" : @(compiled.descriptor.assetCount),
        @"moduleIDs" : compiled.descriptor.moduleIDs ?: @[],
        @"sourceCount" : @(revisions.count),
    });
    return [self publishCompiledGeneration:compiled
                              baseRevision:baseRevision
                         cancellationToken:cancellationToken
                                     error:error];
}

@end
