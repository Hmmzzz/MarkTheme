#import "MTRuntimeStoreTests.h"

#import <fcntl.h>
#import <signal.h>
#import <stdlib.h>
#import <string.h>
#import <sys/file.h>
#import <sys/stat.h>
#import <sys/wait.h>
#import <unistd.h>

#import "MTCanonicalJSON.h"
#import "MTGenerationDescriptor.h"
#import "MTGenerationIndexCodec.h"
#import "MTGenerationReader.h"
#import "MTGenerationWriter.h"
#import "MTImportSession.h"
#import "MTRuntimeSnapshotLoader.h"
#import "MTRuntimeState.h"
#import "MTRuntimeStoreController.h"
#import "MTRuntimeStoreTesting.h"
#import "MTStaticIconCompiler.h"

static NSUInteger MTRuntimeStoreAssertionCount = 0;
static volatile sig_atomic_t MTRuntimeStoreArmedCheckpoint = 0;

void MTRuntimeStoreTestingReachCheckpoint(
    MTRuntimeStoreTestingCheckpoint checkpoint) {
    if (MTRuntimeStoreArmedCheckpoint == (sig_atomic_t)checkpoint) {
        _exit(90 + (int)checkpoint);
    }
}

static void MTRuntimeStoreAssert(BOOL condition, NSString *message) {
    MTRuntimeStoreAssertionCount++;
    if (condition) return;
    fprintf(stderr, "FAIL: %s\n", message.UTF8String);
    exit(1);
}

@interface MTCompiledGeneration (MTRuntimeStoreTests)
- (instancetype)initWithDescriptor:(MTGenerationDescriptor *)descriptor
                              index:(MTGenerationIndex *)index
            sourceAssetURLsByDigest:
    (NSDictionary<NSString *, NSURL *> *)sourceAssetURLsByDigest;
@end

static NSString *MTRuntimeStoreTemporaryDirectory(void) {
    NSString *template = [NSTemporaryDirectory()
        stringByAppendingPathComponent:@"marktheme-runtime-store.XXXXXX"];
    NSMutableData *buffer = [[template dataUsingEncoding:NSUTF8StringEncoding]
        mutableCopy];
    [buffer increaseLengthBy:1];
    char *path = buffer.mutableBytes;
    MTRuntimeStoreAssert(mkdtemp(path) != NULL,
        @"Runtime store test root must be created");
    return [NSFileManager.defaultManager
        stringWithFileSystemRepresentation:path length:strlen(path)];
}

static MTGenerationWriter *MTRuntimeStoreCompilerWriter(NSString *path) {
    MTGenerationWriterConfiguration *configuration =
        [[MTGenerationWriterConfiguration alloc]
            initWithRootURL:[NSURL fileURLWithPath:path isDirectory:YES]
            maximumAssetCount:20000
            maximumGenerationByteCount:1024ULL * 1024ULL * 1024ULL
            minimumFreeSpaceReserveBytes:0
            maximumRecoveryNodeCount:25000];
    return [[MTGenerationWriter alloc] initWithConfiguration:configuration];
}

static MTGenerationReader *MTRuntimeStoreCompilerReader(NSString *path) {
    MTGenerationReaderConfiguration *configuration =
        [[MTGenerationReaderConfiguration alloc]
            initWithRootURL:[NSURL fileURLWithPath:path isDirectory:YES]
            maximumAssetCount:20000
            maximumGenerationByteCount:1024ULL * 1024ULL * 1024ULL
            ownershipProfile:MTGenerationReaderOwnershipProfilePrivate];
    return [[MTGenerationReader alloc] initWithConfiguration:configuration];
}

static BOOL MTRuntimeStorePathHasMode(NSString *path, mode_t mode) {
    struct stat status = {0};
    return lstat(path.fileSystemRepresentation, &status) == 0 &&
        (status.st_mode & 0777) == mode;
}

static int MTRuntimeStoreRunRollbackCrashCut(
    NSURL *runtimeURL,
    MTRuntimeStoreTestingCheckpoint checkpoint) {
    pid_t child = fork();
    MTRuntimeStoreAssert(child >= 0,
        @"Runtime state crash-cut child must start");
    if (child == 0) {
        MTRuntimeStoreArmedCheckpoint = (sig_atomic_t)checkpoint;
        @autoreleasepool {
            MTRuntimeStoreController *controller =
                [[MTRuntimeStoreController alloc]
                    initWithRuntimeRootURL:runtimeURL];
            [controller rollbackWithError:NULL];
        }
        _exit(89);
    }
    int status = 0;
    pid_t waited = -1;
    do {
        waited = waitpid(child, &status, 0);
    } while (waited < 0 && errno == EINTR);
    MTRuntimeStoreAssert(waited == child,
        @"Runtime state crash-cut child must be collected");
    return status;
}

static void MTRuntimeStoreExportFixtureIfRequested(
    NSString *compilerPath,
    MTGeneration *firstGeneration,
    MTGeneration *secondGeneration) {
    const char *output = getenv("MARKTHEME_RUNTIME_FIXTURE_OUTPUT");
    if (output == NULL || output[0] == '\0') return;

    NSString *outputPath = [NSFileManager.defaultManager
        stringWithFileSystemRepresentation:output length:strlen(output)];
    NSError *error = nil;
    BOOL copied = outputPath.isAbsolutePath &&
        ![NSFileManager.defaultManager fileExistsAtPath:outputPath] &&
        [NSFileManager.defaultManager
            createDirectoryAtPath:outputPath.stringByDeletingLastPathComponent
            withIntermediateDirectories:YES attributes:nil error:&error] &&
        [NSFileManager.defaultManager copyItemAtPath:compilerPath
                                             toPath:outputPath
                                              error:&error];
    if (!copied) {
        fprintf(stderr, "FAIL: Runtime fixture export failed: %s\n",
            error.localizedDescription.UTF8String ?: "invalid output path");
        exit(1);
    }

    printf("RUNTIME-FIXTURE: %s\n", outputPath.fileSystemRepresentation);
    MTGenerationIndexRecord *resourceRecord =
        [firstGeneration.index recordAtIndex:0];
    if (resourceRecord == nil) {
        fprintf(stderr, "FAIL: Runtime fixture lookup metadata is unavailable.\n");
        exit(1);
    }
    printf("RUNTIME-GENERATION: %s\n",
        firstGeneration.generationIdentifier.UTF8String);
    printf("RUNTIME-GENERATION: %s\n",
        secondGeneration.generationIdentifier.UTF8String);
    printf("RUNTIME-THEME-ID: %s\n",
        firstGeneration.descriptor.themeID.UTF8String);
    printf("RUNTIME-RESOURCE-KEY: %s\n",
        resourceRecord.canonicalResourceKey.UTF8String);
    printf("RUNTIME-RESOURCE-SHA256: %s\n",
        resourceRecord.contentSHA256.UTF8String);
    printf("RUNTIME-RESOURCE-BYTES: %llu\n",
        (unsigned long long)resourceRecord.assetByteCount);
}

NSUInteger MTRunRuntimeStoreTests(MTCompiledGeneration *compiledGeneration) {
    MTRuntimeStoreAssertionCount = 0;
    MTRuntimeStoreAssert(
        [compiledGeneration isKindOfClass:MTCompiledGeneration.class] &&
        compiledGeneration.descriptor.assets.count > 0,
        @"Runtime store tests require a non-empty compiler result");

    NSString *root = MTRuntimeStoreTemporaryDirectory();
    NSString *compilerPath = [root stringByAppendingPathComponent:@"compiler"];
    NSString *runtimePath = [root stringByAppendingPathComponent:@"runtime"];
    NSURL *runtimeURL = [NSURL fileURLWithPath:runtimePath isDirectory:YES];
    MTGenerationWriter *compilerWriter =
        MTRuntimeStoreCompilerWriter(compilerPath);
    MTGenerationReader *compilerReader =
        MTRuntimeStoreCompilerReader(compilerPath);
    NSError *error = nil;
    MTGenerationWriteResult *firstWrite = [compilerWriter
        writeCompiledGeneration:compiledGeneration
        cancellationToken:nil error:&error];
    MTGeneration *firstGeneration = firstWrite == nil ? nil : [compilerReader
        readGenerationWithIdentifier:firstWrite.generationIdentifier
        cancellationToken:nil error:&error];
    MTRuntimeStoreAssert(firstGeneration != nil && error == nil,
        @"Runtime fixture must open a real independently validated Generation");

    error = nil;
    MTGenerationDescriptor *secondDescriptor =
        [[MTGenerationDescriptor alloc]
            initWithThemeID:@"theme.runtime-alternate"
            libraryRevisionIdentifier:
                compiledGeneration.descriptor.libraryRevisionIdentifier
            manifestDigest:compiledGeneration.descriptor.manifestDigest
            indexSHA256:compiledGeneration.descriptor.indexSHA256
            indexByteCount:compiledGeneration.descriptor.indexByteCount
            indexFormatVersion:compiledGeneration.descriptor.indexFormatVersion
            resourceCount:compiledGeneration.descriptor.resourceCount
            assets:compiledGeneration.descriptor.assets
            moduleIDs:compiledGeneration.descriptor.moduleIDs
            error:&error];
    MTCompiledGeneration *secondCompiled = secondDescriptor == nil ? nil :
        [[MTCompiledGeneration alloc]
            initWithDescriptor:secondDescriptor
            index:compiledGeneration.index
            sourceAssetURLsByDigest:
                compiledGeneration.sourceAssetURLsByContentSHA256];
    MTGenerationWriteResult *secondWrite = secondCompiled == nil ? nil :
        [compilerWriter writeCompiledGeneration:secondCompiled
                              cancellationToken:nil error:&error];
    MTGeneration *secondGeneration = secondWrite == nil ? nil : [compilerReader
        readGenerationWithIdentifier:secondWrite.generationIdentifier
        cancellationToken:nil error:&error];
    MTRuntimeStoreAssert(secondGeneration != nil && error == nil &&
        ![firstGeneration.generationIdentifier
            isEqualToString:secondGeneration.generationIdentifier],
        @"Runtime fixture must expose two distinct valid Generations");
    MTRuntimeStoreExportFixtureIfRequested(
        compilerPath, firstGeneration, secondGeneration);

    MTRuntimeState *initial = MTRuntimeState.initialState;
    error = nil;
    MTRuntimeState *roundTrip = [[MTRuntimeState alloc]
        initWithCanonicalData:initial.canonicalData error:&error];
    MTRuntimeStoreAssert(roundTrip != nil && error == nil &&
        roundTrip.sequence == 0 && !roundTrip.isRuntimeEnabled &&
        roundTrip.activeGenerationIdentifier == nil,
        @"Initial Runtime state must round-trip canonically");
    NSMutableDictionary *unknownState = [@{
        @"activeGenerationIdentifier" : NSNull.null,
        @"previousGenerationIdentifier" : NSNull.null,
        @"runtimeEnabled" : @NO,
        @"schemaVersion" : @1,
        @"sequence" : @0,
        @"unknown" : @1,
    } mutableCopy];
    NSData *unknownData = MTCanonicalJSONData(unknownState, &error);
    error = nil;
    MTRuntimeStoreAssert([[MTRuntimeState alloc]
        initWithCanonicalData:unknownData error:&error] == nil && error != nil,
        @"Runtime state must reject fields outside its small canonical schema");

    MTRuntimeStoreController *controller = [[MTRuntimeStoreController alloc]
        initWithRuntimeRootURL:runtimeURL];
    MTImportCancellationToken *cancelled =
        [[MTImportCancellationToken alloc] init];
    [cancelled cancel];
    error = nil;
    MTRuntimeStoreAssert([controller
        publishGeneration:firstGeneration cancellationToken:cancelled
        error:&error] == nil &&
        [error.domain isEqualToString:MTRuntimeStoreErrorDomain] &&
        error.code == MTRuntimeStoreErrorCancelled &&
        access(runtimePath.fileSystemRepresentation, F_OK) != 0,
        @"Pre-cancelled publication must not create a Runtime store");

    MTRuntimeSnapshotLoader *loader = [[MTRuntimeSnapshotLoader alloc]
        initWithRuntimeRootURL:runtimeURL];
    MTRuntimeState *loadedState = nil;
    error = nil;
    MTGeneration *loaded = [loader
        loadActiveGenerationWithState:&loadedState error:&error];
    MTRuntimeStoreAssert(loaded == nil && error == nil &&
        loadedState.sequence == 0 && !loadedState.isRuntimeEnabled &&
        loadedState.activeGenerationIdentifier == nil,
        @"A missing Runtime store must resolve to the initial stock state");

    NSString *generationsPath = [runtimePath
        stringByAppendingPathComponent:@"generations"];
    NSString *stateDirectoryPath = [runtimePath
        stringByAppendingPathComponent:@"state"];
    MTRuntimeStoreAssert([NSFileManager.defaultManager
        createDirectoryAtPath:generationsPath
        withIntermediateDirectories:YES
        attributes:@{NSFilePosixPermissions : @0700}
        error:&error] &&
        [NSFileManager.defaultManager
            createDirectoryAtPath:stateDirectoryPath
            withIntermediateDirectories:YES
            attributes:@{NSFilePosixPermissions : @0700}
            error:&error] &&
        chmod(runtimePath.fileSystemRepresentation, 0700) == 0 &&
        chmod(generationsPath.fileSystemRepresentation, 0700) == 0 &&
        chmod(stateDirectoryPath.fileSystemRepresentation, 0700) == 0,
        @"Runtime upgrade fixture must create stale private directory modes");

    error = nil;
    MTRuntimePublishResult *firstPublish = [controller
        publishGeneration:firstGeneration cancellationToken:nil error:&error];
    MTRuntimeState *state = [controller currentStateWithError:&error];
    MTRuntimeStoreAssert(firstPublish != nil && error == nil &&
        !firstPublish.reusedExistingGeneration && state.sequence == 0 &&
        !state.isRuntimeEnabled &&
        state.activeGenerationIdentifier == nil,
        @"Publishing immutable bytes must not implicitly activate them");
    NSString *firstRuntimePath = [[runtimePath
        stringByAppendingPathComponent:@"generations"]
        stringByAppendingPathComponent:firstGeneration.generationIdentifier];
    MTRuntimeStoreAssert(
        MTRuntimeStorePathHasMode(runtimePath, 0755) &&
        MTRuntimeStorePathHasMode(generationsPath, 0755) &&
        MTRuntimeStorePathHasMode(stateDirectoryPath, 0755) &&
        MTRuntimeStorePathHasMode(firstRuntimePath, 0755) &&
        MTRuntimeStorePathHasMode([firstRuntimePath
            stringByAppendingPathComponent:@"index.mtg"], 0644) &&
        [[NSData dataWithContentsOfFile:[firstRuntimePath
            stringByAppendingPathComponent:@"index.mtg"]]
            isEqualToData:firstGeneration.index.encodedData],
        @"Runtime publication must repair stale directory metadata and expose exact bytes through shared read-only modes");

    error = nil;
    MTRuntimePublishResult *reused = [controller
        publishGeneration:firstGeneration cancellationToken:nil error:&error];
    MTRuntimeStoreAssert(reused != nil && error == nil &&
        reused.reusedExistingGeneration,
        @"Publishing an existing valid Runtime Generation must be idempotent");

    NSString *missingIdentifier = [@"g1-" stringByAppendingString:
        [@"0" stringByPaddingToLength:64 withString:@"0" startingAtIndex:0]];
    error = nil;
    MTRuntimeStoreAssert([controller
        activateGenerationWithIdentifier:missingIdentifier error:&error] == nil &&
        error.code == MTRuntimeStoreErrorNotFound &&
        [controller currentStateWithError:NULL].sequence == 0,
        @"Activation must reject a missing Generation without changing state");

    error = nil;
    state = [controller activateGenerationWithIdentifier:
        firstGeneration.generationIdentifier error:&error];
    NSString *runtimeStatePath = [[runtimePath
        stringByAppendingPathComponent:@"state"]
        stringByAppendingPathComponent:@"active.json"];
    MTRuntimeStoreAssert(state != nil && error == nil &&
        state.sequence == 1 && state.isRuntimeEnabled &&
        MTRuntimeStorePathHasMode(runtimeStatePath, 0644) &&
        [state.activeGenerationIdentifier
            isEqualToString:firstGeneration.generationIdentifier] &&
        state.previousGenerationIdentifier == nil,
        @"First activation must publish sequence one and no rollback target");

    chmod(runtimeStatePath.fileSystemRepresentation, 0600);
    error = nil;
    MTRuntimeStoreAssert([controller currentStateWithError:&error] == nil &&
        error.code == MTRuntimeStoreErrorVerification &&
        chmod(runtimeStatePath.fileSystemRepresentation, 0644) == 0,
        @"The root controller must reject a private-mode authoritative state");

    loadedState = nil;
    error = nil;
    loaded = [loader
        loadActiveGenerationWithState:&loadedState error:&error];
    MTRuntimeStoreAssert(loaded != nil && error == nil &&
        loadedState.sequence == 1 &&
        [loaded.generationIdentifier
            isEqualToString:firstGeneration.generationIdentifier],
        @"Read-only Runtime must load the exact active Generation snapshot");

    BOOL changedRuntimeStateMode =
        chmod(runtimeStatePath.fileSystemRepresentation, 0600) == 0;
    MTRuntimeState *unsafeLoadedState = nil;
    error = nil;
    MTGeneration *unsafeLoaded = [loader
        loadActiveGenerationWithState:&unsafeLoadedState error:&error];
    BOOL restoredRuntimeStateMode =
        chmod(runtimeStatePath.fileSystemRepresentation, 0644) == 0;
    MTRuntimeStoreAssert(changedRuntimeStateMode && unsafeLoaded == nil &&
        unsafeLoadedState == nil &&
        [error.domain isEqualToString:MTRuntimeStateErrorDomain] &&
        error.code == MTRuntimeStateErrorStorage &&
        restoredRuntimeStateMode,
        @"Read-only Runtime must require the published state ownership profile");

    MTGenerationIndexRecord *expectedRecord =
        [firstGeneration.index recordAtIndex:0];
    error = nil;
    MTGenerationResource *resource = [loaded
        resourceForCanonicalResourceKey:expectedRecord.canonicalResourceKey
        error:&error];
    MTRuntimeStoreAssert(resource != nil && error == nil &&
        [resource.contentSHA256 isEqualToString:expectedRecord.contentSHA256] &&
        resource.assetByteCount == expectedRecord.assetByteCount &&
        [resource.assetURL.lastPathComponent
            isEqualToString:expectedRecord.contentSHA256],
        @"Read-only Runtime lookup must return the exact indexed asset record");

    error = nil;
    resource = [loaded resourceForCanonicalResourceKey:
        @"mtk1|12:icons.static|16:springboard.home|19:com.example.missing|7:primary|3|3:any"
        error:&error];
    MTRuntimeStoreAssert(resource == nil && error == nil,
        @"A canonical Runtime lookup miss must preserve stock fallback semantics");

    MTGenerationAssetDescriptor *firstRuntimeAsset =
        firstGeneration.descriptor.assets.firstObject;
    NSString *firstRuntimeAssetPath = [[firstRuntimePath
        stringByAppendingPathComponent:@"assets"]
        stringByAppendingPathComponent:firstRuntimeAsset.contentSHA256];
    BOOL changedFirstRuntimeAssetMode =
        chmod(firstRuntimeAssetPath.fileSystemRepresentation, 0600) == 0;
    loadedState = nil;
    error = nil;
    loaded = [loader loadActiveGenerationWithState:&loadedState error:&error];
    BOOL restoredFirstRuntimeAssetMode =
        chmod(firstRuntimeAssetPath.fileSystemRepresentation, 0644) == 0;
    MTRuntimeStoreAssert(changedFirstRuntimeAssetMode && loaded == nil &&
        loadedState.sequence == 1 &&
        [error.domain isEqualToString:MTGenerationReaderErrorDomain] &&
        error.code == MTGenerationReaderErrorVerification &&
        restoredFirstRuntimeAssetMode,
        @"Read-only Runtime must reject unsafe active asset metadata without changing state");

    error = nil;
    state = [controller activateGenerationWithIdentifier:
        firstGeneration.generationIdentifier error:&error];
    MTRuntimeStoreAssert(state != nil && error == nil && state.sequence == 1,
        @"Reactivating the active Generation must not rewrite state");

    NSString *secondRuntimePath = [[runtimePath
        stringByAppendingPathComponent:@"generations"]
        stringByAppendingPathComponent:secondGeneration.generationIdentifier];
    NSData *stateBeforeNoSpace = [NSData dataWithContentsOfFile:runtimeStatePath];
    MTRuntimeStoreController *noSpaceController =
        [[MTRuntimeStoreController alloc]
            initWithRuntimeRootURL:runtimeURL
            minimumFreeSpaceReserveBytes:UINT64_MAX];
    error = nil;
    MTRuntimeStoreAssert([noSpaceController
        publishGeneration:secondGeneration cancellationToken:nil
        error:&error] == nil &&
        [error.domain isEqualToString:MTRuntimeStoreErrorDomain] &&
        error.code == MTRuntimeStoreErrorInsufficientSpace &&
        ![NSFileManager.defaultManager fileExistsAtPath:secondRuntimePath] &&
        ![NSFileManager.defaultManager fileExistsAtPath:[runtimePath
            stringByAppendingPathComponent:@".publish"]] &&
        [[NSData dataWithContentsOfFile:runtimeStatePath]
            isEqualToData:stateBeforeNoSpace],
        @"Runtime no-space admission must fail before staging or state changes");

    error = nil;
    MTRuntimePublishResult *secondPublish = [controller
        publishGeneration:secondGeneration cancellationToken:nil error:&error];
    MTGenerationAssetDescriptor *secondAsset =
        secondGeneration.descriptor.assets.firstObject;
    NSString *secondAssetPath = [[secondRuntimePath
        stringByAppendingPathComponent:@"assets"]
        stringByAppendingPathComponent:secondAsset.contentSHA256];
    chmod(secondAssetPath.fileSystemRepresentation, 0600);
    error = nil;
    MTRuntimeStoreAssert(secondPublish != nil &&
        [controller activateGenerationWithIdentifier:
            secondGeneration.generationIdentifier error:&error] == nil &&
        error.code == MTRuntimeStoreErrorVerification &&
        chmod(secondAssetPath.fileSystemRepresentation, 0644) == 0,
        @"Activation must reject a Generation outside published root modes");
    error = nil;
    state = secondPublish == nil ? nil : [controller
        activateGenerationWithIdentifier:secondGeneration.generationIdentifier
        error:&error];
    MTRuntimeStoreAssert(secondPublish != nil && state != nil && error == nil &&
        state.sequence == 2 &&
        [state.activeGenerationIdentifier
            isEqualToString:secondGeneration.generationIdentifier] &&
        [state.previousGenerationIdentifier
            isEqualToString:firstGeneration.generationIdentifier],
        @"A second activation must retain exactly one rollback target");

    MTRuntimeStoreController *restarted = [[MTRuntimeStoreController alloc]
        initWithRuntimeRootURL:runtimeURL];
    error = nil;
    state = [restarted currentStateWithError:&error];
    MTRuntimeStoreAssert(state != nil && error == nil && state.sequence == 2 &&
        [state.activeGenerationIdentifier
            isEqualToString:secondGeneration.generationIdentifier],
        @"A new Manager instance must observe the persisted active state");

    NSData *stateBeforeCrashCuts = [NSData
        dataWithContentsOfFile:runtimeStatePath];
    int crashStatus = MTRuntimeStoreRunRollbackCrashCut(
        runtimeURL, MTRuntimeStoreTestingCheckpointBeforeStateRename);
    NSString *pendingStatePath = [[runtimePath
        stringByAppendingPathComponent:@"state"]
        stringByAppendingPathComponent:@".active.pending"];
    error = nil;
    state = [restarted currentStateWithError:&error];
    MTRuntimeStoreAssert(WIFEXITED(crashStatus) &&
        WEXITSTATUS(crashStatus) ==
            90 + MTRuntimeStoreTestingCheckpointBeforeStateRename &&
        [NSFileManager.defaultManager fileExistsAtPath:pendingStatePath] &&
        [[NSData dataWithContentsOfFile:runtimeStatePath]
            isEqualToData:stateBeforeCrashCuts] &&
        state != nil && error == nil && state.sequence == 2 &&
        [state.activeGenerationIdentifier
            isEqualToString:secondGeneration.generationIdentifier],
        @"A crash before state rename must preserve the prior canonical state");

    error = nil;
    state = [restarted activateGenerationWithIdentifier:
        secondGeneration.generationIdentifier error:&error];
    MTRuntimeStoreAssert(state != nil && error == nil && state.sequence == 2 &&
        ![NSFileManager.defaultManager fileExistsAtPath:pendingStatePath] &&
        [[NSData dataWithContentsOfFile:runtimeStatePath]
            isEqualToData:stateBeforeCrashCuts],
        @"The next idempotent mutation must recover pre-rename state residue");

    crashStatus = MTRuntimeStoreRunRollbackCrashCut(
        runtimeURL, MTRuntimeStoreTestingCheckpointAfterStateRename);
    error = nil;
    state = [restarted currentStateWithError:&error];
    MTRuntimeStoreAssert(WIFEXITED(crashStatus) &&
        WEXITSTATUS(crashStatus) ==
            90 + MTRuntimeStoreTestingCheckpointAfterStateRename &&
        ![NSFileManager.defaultManager fileExistsAtPath:pendingStatePath] &&
        state != nil && error == nil && state.sequence == 3 &&
        [state.activeGenerationIdentifier
            isEqualToString:firstGeneration.generationIdentifier] &&
        [state.previousGenerationIdentifier
            isEqualToString:secondGeneration.generationIdentifier],
        @"A crash after state rename must expose exactly the new canonical state");

    error = nil;
    state = [restarted activateGenerationWithIdentifier:
        firstGeneration.generationIdentifier error:&error];
    MTRuntimeStoreAssert(state != nil && error == nil && state.sequence == 3 &&
        ![NSFileManager.defaultManager fileExistsAtPath:pendingStatePath],
        @"The post-rename state must remain idempotently usable after restart");

    error = nil;
    state = [restarted disableWithError:&error];
    loadedState = nil;
    loaded = [loader loadActiveGenerationWithState:&loadedState error:&error];
    MTRuntimeStoreAssert(state != nil && error == nil && state.sequence == 4 &&
        !state.isRuntimeEnabled && loaded == nil &&
        loadedState.sequence == 4 &&
        [state.activeGenerationIdentifier
            isEqualToString:firstGeneration.generationIdentifier],
        @"Disable must retain rollback metadata while Runtime returns no snapshot");

    NSString *publishStaging = [runtimePath
        stringByAppendingPathComponent:@".publish/orphan"];
    NSString *pendingState = [[runtimePath
        stringByAppendingPathComponent:@"state"]
        stringByAppendingPathComponent:@".active.pending"];
    [NSFileManager.defaultManager createDirectoryAtPath:publishStaging
        withIntermediateDirectories:YES
        attributes:@{NSFilePosixPermissions : @0700} error:NULL];
    [initial.canonicalData writeToFile:pendingState atomically:NO];
    chmod(pendingState.fileSystemRepresentation, 0600);
    error = nil;
    state = [restarted disableWithError:&error];
    MTRuntimeStoreAssert(state != nil && error == nil && state.sequence == 4 &&
        access([[runtimePath stringByAppendingPathComponent:@".publish"]
            fileSystemRepresentation], F_OK) != 0 &&
        access(pendingState.fileSystemRepresentation, F_OK) != 0,
        @"The next mutation must discard only the two fixed staging nodes");

    NSString *lockPath = [runtimePath
        stringByAppendingPathComponent:@"control.lock"];
    int heldLock = open(lockPath.fileSystemRepresentation,
        O_RDWR | O_CLOEXEC | O_NOFOLLOW);
    MTRuntimeStoreAssert(heldLock >= 0 &&
        flock(heldLock, LOCK_EX | LOCK_NB) == 0,
        @"Runtime contention fixture must hold the control lock");
    error = nil;
    MTRuntimeStoreAssert([restarted activateGenerationWithIdentifier:
        firstGeneration.generationIdentifier error:&error] == nil &&
        error.code == MTRuntimeStoreErrorBusy &&
        [restarted currentStateWithError:NULL].sequence == 4,
        @"A contended Runtime operation must fail without changing state");
    flock(heldLock, LOCK_UN);
    close(heldLock);

    error = nil;
    state = [restarted activateGenerationWithIdentifier:
        firstGeneration.generationIdentifier error:&error];
    MTRuntimeStoreAssert(state != nil && error == nil && state.sequence == 5,
        @"A disabled Runtime must reactivate its retained Generation");
    MTGenerationAssetDescriptor *firstAsset =
        firstGeneration.descriptor.assets.firstObject;
    NSString *activeAssetPath = [[firstRuntimePath
        stringByAppendingPathComponent:@"assets"]
        stringByAppendingPathComponent:firstAsset.contentSHA256];
    int assetDescriptor = open(activeAssetPath.fileSystemRepresentation,
        O_RDWR | O_CLOEXEC | O_NOFOLLOW);
    unsigned char byte = 0;
    BOOL mutated = assetDescriptor >= 0 && pread(assetDescriptor, &byte, 1, 0) == 1;
    byte ^= 0xff;
    mutated = mutated && pwrite(assetDescriptor, &byte, 1, 0) == 1;
    if (assetDescriptor >= 0) close(assetDescriptor);
    loadedState = nil;
    error = nil;
    loaded = [loader loadActiveGenerationWithState:&loadedState error:&error];
    MTRuntimeStoreAssert(mutated && loaded == nil && error != nil &&
        loadedState.sequence == 5,
        @"Read-only Runtime must reject corruption without rewriting state");

    error = nil;
    state = [restarted rollbackWithError:&error];
    loaded = state == nil ? nil : [loader
        loadActiveGenerationWithState:NULL error:&error];
    MTRuntimeStoreAssert(state != nil && loaded != nil && error == nil &&
        state.sequence == 6 &&
        [loaded.generationIdentifier
            isEqualToString:secondGeneration.generationIdentifier],
        @"Rollback must recover from a corrupt active tree using the valid previous tree");

    NSString *unsafeRuntimePath = [root
        stringByAppendingPathComponent:@"unsafe-runtime-node"];
    MTRuntimeStoreAssert([@"not a directory"
        writeToFile:unsafeRuntimePath atomically:NO
        encoding:NSUTF8StringEncoding error:&error],
        @"Unsafe Runtime root fixture must create a regular file");
    MTRuntimeStoreController *unsafeController =
        [[MTRuntimeStoreController alloc]
            initWithRuntimeRootURL:
                [NSURL fileURLWithPath:unsafeRuntimePath isDirectory:YES]];
    error = nil;
    MTRuntimeStoreAssert([unsafeController
        publishGeneration:secondGeneration cancellationToken:nil
        error:&error] == nil &&
        [error.domain isEqualToString:MTRuntimeStoreErrorDomain] &&
        error.code == MTRuntimeStoreErrorStorage &&
        [error.localizedDescription isEqualToString:
            @"A Runtime store directory path is occupied by an unsafe node."] &&
        [error.userInfo[NSUnderlyingErrorKey]
            isKindOfClass:NSError.class] &&
        [error.userInfo[NSUnderlyingErrorKey] code] == ENOTDIR,
        @"Runtime directory repair must reject non-directory nodes with a precise underlying error");

    [NSFileManager.defaultManager removeItemAtPath:root error:NULL];
    return MTRuntimeStoreAssertionCount;
}
