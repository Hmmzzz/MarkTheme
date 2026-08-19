#import "MTThemeApplyServiceTests.h"

#import <string.h>
#import <sys/stat.h>
#import <unistd.h>

#import "MTGenerationDescriptor.h"
#import "MTGenerationWriter.h"
#import "MTImportSession.h"
#import "MTRuntimeHelperClient.h"
#import "MTRuntimeState.h"
#import "MTStaticIconCompiler.h"
#import "MTThemeApplyService.h"
#import "MTThemeComponentCatalog.h"
#import "MTThemeLibraryStore.h"
#import "MTThemeManifest.h"

static NSUInteger MTThemeApplyAssertionCount = 0;
static NSString *const MTThemeApplyFixtureErrorDomain =
    @"com.hmmzzz.marktheme.theme-apply-fixture";

static void MTThemeApplyAssert(BOOL condition, NSString *message) {
    MTThemeApplyAssertionCount++;
    if (condition) return;
    fprintf(stderr, "FAIL: %s\n", message.UTF8String);
    exit(1);
}

static NSError *MTThemeApplyFixtureError(NSString *description) {
    return [NSError errorWithDomain:MTThemeApplyFixtureErrorDomain
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey : description}];
}

static NSString *MTThemeApplyTemporaryDirectory(void) {
    NSString *template = [NSTemporaryDirectory()
        stringByAppendingPathComponent:@"marktheme-apply.XXXXXX"];
    NSMutableData *buffer = [[template dataUsingEncoding:NSUTF8StringEncoding]
        mutableCopy];
    [buffer increaseLengthBy:1];
    char *path = buffer.mutableBytes;
    MTThemeApplyAssert(mkdtemp(path) != NULL,
        @"Apply fixture root must be created");
    return [NSFileManager.defaultManager
        stringWithFileSystemRepresentation:path length:strlen(path)];
}

static BOOL MTThemeApplyPathHasMode(NSString *path, mode_t mode) {
    struct stat status = {0};
    return lstat(path.fileSystemRepresentation, &status) == 0 &&
        (status.st_mode & 0777) == mode;
}

static BOOL MTThemeApplyErrorMatches(NSError *error,
                                     MTThemeApplyServiceErrorCode code,
                                     MTThemeApplyStage stage) {
    return [error.domain isEqualToString:MTThemeApplyServiceErrorDomain] &&
        error.code == code &&
        [error.userInfo[MTThemeApplyServiceStageKey] isEqual:@(stage)];
}

@interface MTRuntimeApplyResult (MTThemeApplyServiceTests)
- (instancetype)initWithGenerationIdentifier:(NSString *)generationIdentifier
                     reusedExistingGeneration:(BOOL)reused
                                        state:(MTRuntimeState *)state
                                     delivery:(MTRuntimeApplyDelivery)delivery;
@end

@interface MTThemeApplyLibraryStore : MTThemeLibraryStore
@property(nonatomic, strong) MTThemeLibraryRevision *fixtureRevision;
@property(nonatomic, strong) NSMutableArray<NSString *> *events;
@property(nonatomic, assign) BOOL failNext;
@end

@implementation MTThemeApplyLibraryStore
- (MTThemeLibraryRevision *)
    loadCurrentRevisionForThemeID:(NSString *)themeID
                cancellationToken:
                    (MTImportCancellationToken *)cancellationToken
                            error:(NSError **)error {
    (void)themeID;
    (void)cancellationToken;
    [self.events addObject:@"library"];
    if (self.failNext) {
        self.failNext = NO;
        if (error != NULL) {
            *error = MTThemeApplyFixtureError(@"library failure");
        }
        return nil;
    }
    return self.fixtureRevision;
}
@end

@interface MTThemeApplyCompiler : MTStaticIconCompiler
@property(nonatomic, strong) MTCompiledGeneration *fixtureGeneration;
@property(nonatomic, strong) NSMutableArray<NSString *> *events;
@property(nonatomic, assign) BOOL failNext;
@property(nonatomic, assign) BOOL cancelAfterCompile;
@property(nonatomic, strong, nullable)
    MTThemeComponentSelection *capturedComponentSelection;
@end

@implementation MTThemeApplyCompiler
- (MTCompiledGeneration *)compileLibraryRevision:
    (MTThemeLibraryRevision *)revision
                                      cancellationToken:
    (MTImportCancellationToken *)cancellationToken
                                                   error:(NSError **)error {
    (void)revision;
    [self.events addObject:@"compile"];
    if (self.failNext) {
        self.failNext = NO;
        if (error != NULL) {
            *error = MTThemeApplyFixtureError(@"compile failure");
        }
        return nil;
    }
    if (self.cancelAfterCompile) {
        self.cancelAfterCompile = NO;
        [cancellationToken cancel];
    }
    return self.fixtureGeneration;
}

- (MTCompiledGeneration *)compileLibraryRevision:
        (MTThemeLibraryRevision *)revision
                                  componentSelection:
                                      (MTThemeComponentSelection *)componentSelection
                                  cancellationToken:
                                      (MTImportCancellationToken *)cancellationToken
                                               error:(NSError **)error {
    self.capturedComponentSelection = componentSelection;
    return [self compileLibraryRevision:revision
                       cancellationToken:cancellationToken
                                    error:error];
}
@end

@interface MTThemeApplyWriter : MTGenerationWriter
@property(nonatomic, strong) NSMutableArray<NSString *> *events;
@property(nonatomic, assign) BOOL failNext;
@end

@implementation MTThemeApplyWriter
- (MTGenerationWriteResult *)writeCompiledGeneration:
    (MTCompiledGeneration *)compiledGeneration
                                               cancellationToken:
    (MTImportCancellationToken *)cancellationToken
                                                        error:(NSError **)error {
    [self.events addObject:@"write"];
    if (self.failNext) {
        self.failNext = NO;
        if (error != NULL) {
            *error = MTThemeApplyFixtureError(@"inbox failure");
        }
        return nil;
    }
    return [super writeCompiledGeneration:compiledGeneration
                        cancellationToken:cancellationToken
                                     error:error];
}
@end

@interface MTThemeApplyRuntimeClient : MTRuntimeHelperClient
@property(nonatomic, strong) NSMutableArray<NSString *> *events;
@property(nonatomic, assign) BOOL failNext;
@property(nonatomic, assign) BOOL reused;
@property(nonatomic, assign) BOOL mismatchedState;
@property(nonatomic, assign) uint64_t sequence;
@property(nonatomic, assign) MTRuntimeApplyDelivery delivery;
@end

@implementation MTThemeApplyRuntimeClient
- (MTRuntimeApplyResult *)applyGenerationWithIdentifier:
    (NSString *)generationIdentifier
                                                   error:(NSError **)error {
    [self.events addObject:@"runtime"];
    if (self.failNext) {
        self.failNext = NO;
        if (error != NULL) {
            *error = MTThemeApplyFixtureError(@"runtime failure");
        }
        return nil;
    }
    self.sequence++;
    NSString *activeIdentifier = self.mismatchedState
        ? [@"g1-" stringByAppendingString:
            [@"0" stringByPaddingToLength:64
                                withString:@"0"
                           startingAtIndex:0]]
        : generationIdentifier;
    MTRuntimeState *state = [[MTRuntimeState alloc]
        initWithSequence:self.sequence
        runtimeEnabled:YES
        activeGenerationIdentifier:activeIdentifier
        previousGenerationIdentifier:nil
        error:NULL];
    return [[MTRuntimeApplyResult alloc]
        initWithGenerationIdentifier:generationIdentifier
        reusedExistingGeneration:self.reused
        state:state
        delivery:self.delivery];
}
@end

NSUInteger MTRunThemeApplyServiceTests(
    MTThemeLibraryStore *realLibraryStore,
    MTThemeLibraryRevision *revision,
    MTCompiledGeneration *compiledGeneration) {
    MTThemeApplyAssertionCount = 0;
    MTThemeApplyAssert(realLibraryStore != nil && revision != nil &&
        compiledGeneration != nil,
        @"Apply service tests require real Library and compiler fixtures");

    MTImportCancellationToken *libraryCancellation =
        [[MTImportCancellationToken alloc] init];
    [libraryCancellation cancel];
    NSError *error = nil;
    MTThemeApplyAssert([realLibraryStore
        loadCurrentRevisionForThemeID:revision.manifest.themeID
        cancellationToken:libraryCancellation error:&error] == nil &&
        [error.domain isEqualToString:MTThemeLibraryStoreErrorDomain] &&
        error.code == MTThemeLibraryStoreErrorCancelled,
        @"The full current-revision read must honor pre-cancellation");
    error = nil;
    MTThemeLibraryRevision *reloaded = [realLibraryStore
        loadCurrentRevisionForThemeID:revision.manifest.themeID
        cancellationToken:nil error:&error];
    MTThemeApplyAssert(reloaded != nil && error == nil &&
        [reloaded.revisionIdentifier
            isEqualToString:revision.revisionIdentifier],
        @"The cancellable Library API must return the exact current revision");

    NSString *root = MTThemeApplyTemporaryDirectory();
    NSString *inboxPath = [root stringByAppendingPathComponent:@"PublishInbox"];
    NSURL *inboxURL = [NSURL fileURLWithPath:inboxPath isDirectory:YES];
    MTGenerationWriterConfiguration *configuration =
        [[MTGenerationWriterConfiguration alloc]
            initWithRootURL:inboxURL
            maximumAssetCount:20000
            maximumGenerationByteCount:1024ULL * 1024ULL * 1024ULL
            minimumFreeSpaceReserveBytes:0
            maximumRecoveryNodeCount:25000];
    NSMutableArray<NSString *> *events = [NSMutableArray array];

    MTThemeApplyLibraryStore *libraryStore =
        [[MTThemeApplyLibraryStore alloc]
            initWithRootURL:[NSURL fileURLWithPath:
                [root stringByAppendingPathComponent:@"Library"]
                                       isDirectory:YES]];
    libraryStore.fixtureRevision = revision;
    libraryStore.events = events;
    MTThemeApplyCompiler *compiler = [[MTThemeApplyCompiler alloc] init];
    compiler.fixtureGeneration = compiledGeneration;
    compiler.events = events;
    MTThemeApplyWriter *writer = [[MTThemeApplyWriter alloc]
        initWithConfiguration:configuration];
    writer.events = events;
    MTThemeApplyRuntimeClient *runtimeClient =
        [[MTThemeApplyRuntimeClient alloc]
            initWithHelperURL:[NSURL fileURLWithPath:
                @"/usr/libexec/marktheme-helper"]];
    runtimeClient.events = events;
    runtimeClient.delivery = MTRuntimeApplyDeliveryAcknowledged;
    MTThemeApplyService *service = [[MTThemeApplyService alloc]
        initWithLibraryStore:libraryStore
        compiler:compiler
        inboxWriter:writer
        runtimeClient:runtimeClient];
    MTThemeApplyAssert(service.libraryStore == libraryStore &&
        service.compiler == compiler && service.inboxWriter == writer &&
        service.runtimeClient == runtimeClient,
        @"Apply service must retain exactly its four injected modules");

    [events removeAllObjects];
    error = nil;
    MTThemeApplyAssert([service
        applyCurrentThemeWithIdentifier:@""
        cancellationToken:nil error:&error] == nil &&
        events.count == 0 && MTThemeApplyErrorMatches(error,
            MTThemeApplyServiceErrorInvalidRequest,
            MTThemeApplyStageLoadLibrary),
        @"Apply must reject an empty theme identifier before any module runs");

    error = nil;
    MTThemeApplyResult *result = [service
        applyCurrentThemeWithIdentifier:revision.manifest.themeID
        cancellationToken:nil
        error:&error];
    NSString *generationIdentifier =
        compiledGeneration.descriptor.generationIdentifier;
    MTThemeApplyAssert(result != nil && error == nil &&
        [result.themeID isEqualToString:revision.manifest.themeID] &&
        [result.libraryRevisionIdentifier
            isEqualToString:revision.revisionIdentifier] &&
        [result.generationIdentifier isEqualToString:generationIdentifier] &&
        !result.reusedInboxGeneration &&
        !result.reusedRuntimeGeneration &&
        result.runtimeState.isRuntimeEnabled && result.runtimeAcknowledged,
        @"Apply must expose the exact revision, Generation and Runtime state");
    MTThemeApplyAssert([events isEqualToArray:
        @[@"library", @"compile", @"write", @"runtime"]],
        @"Apply must execute Library, compile, Inbox and Runtime in order");

    MTThemeComponentCatalog *componentCatalog = [MTThemeComponentCatalog
        catalogForManifest:revision.manifest error:NULL];
    MTThemeComponentSelection *componentSelection =
        componentCatalog.defaultSelection;
    [events removeAllObjects];
    compiler.capturedComponentSelection = nil;
    error = nil;
    result = [service
        applyCurrentThemeWithIdentifier:revision.manifest.themeID
        componentSelection:componentSelection
        cancellationToken:nil
        error:&error];
    MTThemeApplyAssert(result != nil && error == nil &&
        compiler.capturedComponentSelection == componentSelection &&
        [events isEqualToArray:
            @[@"library", @"compile", @"write", @"runtime"]],
        @"Manager Apply must pass one immutable component selection into the compiler without adding another stage");

    NSString *generationPath = [[inboxPath
        stringByAppendingPathComponent:@"generations"]
        stringByAppendingPathComponent:generationIdentifier];
    MTThemeApplyAssert(
        MTThemeApplyPathHasMode(inboxPath, 0700) &&
        MTThemeApplyPathHasMode([inboxPath
            stringByAppendingPathComponent:@"generations"], 0700) &&
        MTThemeApplyPathHasMode(generationPath, 0700) &&
        MTThemeApplyPathHasMode([generationPath
            stringByAppendingPathComponent:@"generation.json"], 0600) &&
        MTThemeApplyPathHasMode([generationPath
            stringByAppendingPathComponent:@"index.mtg"], 0600) &&
        access([[root stringByAppendingPathComponent:@"Compiler"]
            fileSystemRepresentation], F_OK) != 0,
        @"Apply must write one private Inbox tree without a Compiler copy");

    [events removeAllObjects];
    runtimeClient.reused = YES;
    runtimeClient.delivery = MTRuntimeApplyDeliveryReloadRequired;
    error = nil;
    result = [service
        applyCurrentThemeWithIdentifier:revision.manifest.themeID
        cancellationToken:nil
        error:&error];
    MTThemeApplyAssert(result != nil && error == nil &&
        result.reusedInboxGeneration && result.reusedRuntimeGeneration &&
        !result.runtimeAcknowledged &&
        [events isEqualToArray:
            @[@"library", @"compile", @"write", @"runtime"]],
        @"Repeated Apply must preserve publication reuse and reload delivery");

    [events removeAllObjects];
    MTImportCancellationToken *preCancelled =
        [[MTImportCancellationToken alloc] init];
    [preCancelled cancel];
    error = nil;
    MTThemeApplyAssert([service
        applyCurrentThemeWithIdentifier:revision.manifest.themeID
        cancellationToken:preCancelled error:&error] == nil &&
        events.count == 0 && MTThemeApplyErrorMatches(error,
            MTThemeApplyServiceErrorCancelled,
            MTThemeApplyStageLoadLibrary),
        @"Pre-cancelled Apply must not start the Library read");

    [events removeAllObjects];
    MTImportCancellationToken *midCancelled =
        [[MTImportCancellationToken alloc] init];
    compiler.cancelAfterCompile = YES;
    error = nil;
    MTThemeApplyAssert([service
        applyCurrentThemeWithIdentifier:revision.manifest.themeID
        cancellationToken:midCancelled error:&error] == nil &&
        [events isEqualToArray:@[@"library", @"compile"]] &&
        MTThemeApplyErrorMatches(error, MTThemeApplyServiceErrorCancelled,
            MTThemeApplyStageWriteInbox),
        @"Cancellation after compile must not write or invoke the Helper");

    [events removeAllObjects];
    libraryStore.failNext = YES;
    error = nil;
    MTThemeApplyAssert([service
        applyCurrentThemeWithIdentifier:revision.manifest.themeID
        cancellationToken:nil error:&error] == nil &&
        [events isEqualToArray:@[@"library"]] &&
        MTThemeApplyErrorMatches(error, MTThemeApplyServiceErrorLibrary,
            MTThemeApplyStageLoadLibrary) &&
        [((NSError *)error.userInfo[NSUnderlyingErrorKey]).domain
            isEqualToString:MTThemeApplyFixtureErrorDomain],
        @"Library failure must retain its stage and underlying evidence");

    [events removeAllObjects];
    compiler.failNext = YES;
    error = nil;
    MTThemeApplyAssert([service
        applyCurrentThemeWithIdentifier:revision.manifest.themeID
        cancellationToken:nil error:&error] == nil &&
        [events isEqualToArray:@[@"library", @"compile"]] &&
        MTThemeApplyErrorMatches(error, MTThemeApplyServiceErrorCompile,
            MTThemeApplyStageCompile),
        @"Compiler failure must stop before Inbox publication");

    [events removeAllObjects];
    writer.failNext = YES;
    error = nil;
    MTThemeApplyAssert([service
        applyCurrentThemeWithIdentifier:revision.manifest.themeID
        cancellationToken:nil error:&error] == nil &&
        [events isEqualToArray:@[@"library", @"compile", @"write"]] &&
        MTThemeApplyErrorMatches(error, MTThemeApplyServiceErrorInbox,
            MTThemeApplyStageWriteInbox),
        @"Inbox failure must stop before Runtime mutation");

    [events removeAllObjects];
    runtimeClient.failNext = YES;
    error = nil;
    MTThemeApplyAssert([service
        applyCurrentThemeWithIdentifier:revision.manifest.themeID
        cancellationToken:nil error:&error] == nil &&
        [events isEqualToArray:
            @[@"library", @"compile", @"write", @"runtime"]] &&
        MTThemeApplyErrorMatches(error, MTThemeApplyServiceErrorRuntime,
            MTThemeApplyStageActivateRuntime),
        @"Runtime failure must be reported after a retryable Inbox publish");

    [events removeAllObjects];
    runtimeClient.mismatchedState = YES;
    error = nil;
    MTThemeApplyAssert([service
        applyCurrentThemeWithIdentifier:revision.manifest.themeID
        cancellationToken:nil error:&error] == nil &&
        MTThemeApplyErrorMatches(error, MTThemeApplyServiceErrorRuntime,
            MTThemeApplyStageActivateRuntime),
        @"Apply must reject a Helper state that activates another Generation");

    [NSFileManager.defaultManager removeItemAtPath:root error:NULL];
    return MTThemeApplyAssertionCount;
}
