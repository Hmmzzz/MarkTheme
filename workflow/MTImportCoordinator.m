#import "MTImportCoordinator.h"

#import <unistd.h>

#import "MTImportDiagnostics.h"

#import "MTImportSession.h"
#import "MTThemeImport.h"
#import "MTThemeLibraryStore.h"

NSString *const MTImportCoordinatorErrorDomain =
    @"com.hmmzzz.marktheme.import-coordinator";

NSString *MTImportWorkflowPhaseName(MTImportWorkflowPhase phase) {
    switch (phase) {
        case MTImportWorkflowPhaseIdle: return @"idle";
        case MTImportWorkflowPhaseAcquiring: return @"acquiring";
        case MTImportWorkflowPhaseAuditing: return @"auditing";
        case MTImportWorkflowPhaseParsing: return @"parsing";
        case MTImportWorkflowPhaseStaging: return @"staging";
        case MTImportWorkflowPhaseValidating: return @"validating";
        case MTImportWorkflowPhaseReadyForReview: return @"ready-for-review";
        case MTImportWorkflowPhaseCommitting: return @"committing";
        case MTImportWorkflowPhaseCompleted: return @"completed";
        case MTImportWorkflowPhaseCancelling: return @"cancelling";
        case MTImportWorkflowPhaseCancelled: return @"cancelled";
        case MTImportWorkflowPhaseFailed: return @"failed";
    }
    return @"unknown";
}

static BOOL MTImportCoordinatorSetError(NSError **error,
                                        NSString *description) {
    if (error != NULL) {
        *error = [NSError errorWithDomain:MTImportCoordinatorErrorDomain
                                     code:1
                                 userInfo:@{
            NSLocalizedDescriptionKey : description,
        }];
    }
    return NO;
}

@interface MTImportWorkflowSnapshot ()
- (instancetype)initWithPhase:(MTImportWorkflowPhase)phase
            completedUnitCount:(NSUInteger)completedUnitCount
                totalUnitCount:(NSUInteger)totalUnitCount
                preparedImport:
                    (nullable MTPreparedThemeImport *)preparedImport
               libraryRevision:
                   (nullable MTThemeLibraryRevision *)libraryRevision
                         error:(nullable NSError *)error;
@end

@implementation MTImportWorkflowSnapshot

- (instancetype)initWithPhase:(MTImportWorkflowPhase)phase
            completedUnitCount:(NSUInteger)completedUnitCount
                totalUnitCount:(NSUInteger)totalUnitCount
                preparedImport:(MTPreparedThemeImport *)preparedImport
               libraryRevision:(MTThemeLibraryRevision *)libraryRevision
                         error:(NSError *)error {
    self = [super init];
    if (self == nil) return nil;
    _phase = phase;
    _completedUnitCount = completedUnitCount;
    _totalUnitCount = totalUnitCount;
    _preparedImport = preparedImport;
    _libraryRevision = libraryRevision;
    _error = error;
    return self;
}

- (BOOL)canChooseArchive {
    return self.canChooseSource;
}

- (BOOL)canChooseSource {
    return self.phase == MTImportWorkflowPhaseIdle ||
        self.phase == MTImportWorkflowPhaseCancelled ||
        self.phase == MTImportWorkflowPhaseCompleted ||
        (self.phase == MTImportWorkflowPhaseFailed &&
         self.preparedImport == nil);
}

- (BOOL)canCancel {
    switch (self.phase) {
        case MTImportWorkflowPhaseAcquiring:
        case MTImportWorkflowPhaseAuditing:
        case MTImportWorkflowPhaseParsing:
        case MTImportWorkflowPhaseStaging:
        case MTImportWorkflowPhaseValidating:
        case MTImportWorkflowPhaseReadyForReview:
        case MTImportWorkflowPhaseCommitting:
            return YES;
        case MTImportWorkflowPhaseFailed:
            return self.preparedImport != nil;
        default:
            return NO;
    }
}

- (BOOL)canConfirm {
    return self.phase == MTImportWorkflowPhaseReadyForReview;
}

- (BOOL)canRetryCommit {
    return self.phase == MTImportWorkflowPhaseFailed &&
        self.preparedImport.isActive;
}

@end

@interface MTImportCoordinator ()
@property(atomic, strong, readwrite) MTImportWorkflowSnapshot *snapshot;
@property(nonatomic, strong) MTImportCancellationToken *cancellationToken;
@property(nonatomic, strong) MTPreparedThemeImport *preparedImport;
@property(nonatomic, assign) NSUInteger workflowGeneration;
@property(nonatomic, copy, nullable)
    MTImportWorkflowStateHandler internalStateDidChangeHandler;
@property(nonatomic, strong, nullable) NSOperation *callbackTailOperation;
@property(nonatomic, strong, nullable)
    MTImportWorkflowSnapshot *lastEnqueuedSnapshot;
@property(nonatomic, strong, nullable)
    MTImportWorkflowSnapshot *pendingProgressSnapshot;
@property(nonatomic, assign) BOOL progressCallbackEnqueued;
- (BOOL)startImportAtURL:(NSURL *)sourceURL
              sourceName:(NSString *)sourceName
             isDirectory:(BOOL)isDirectory
                   error:(NSError **)error;
@end

@implementation MTImportCoordinator

- (void)enqueueHandler:(MTImportWorkflowStateHandler)handler
               snapshot:(MTImportWorkflowSnapshot *)snapshot {
    if (handler == nil) return;
    NSBlockOperation *operation = [NSBlockOperation
        blockOperationWithBlock:^{ handler(snapshot); }];
    @synchronized (self) {
        if (self.callbackTailOperation != nil) {
            [operation addDependency:self.callbackTailOperation];
        }
        self.callbackTailOperation = operation;
    }
    [self.callbackQueue addOperation:operation];
}

- (void)enqueueProgressHandler:(MTImportWorkflowStateHandler)handler
                       snapshot:(MTImportWorkflowSnapshot *)snapshot {
    if (handler == nil) return;
    NSBlockOperation *operation = nil;
    @synchronized (self) {
        self.pendingProgressSnapshot = snapshot;
        if (self.progressCallbackEnqueued) return;
        self.progressCallbackEnqueued = YES;
        __weak typeof(self) weakSelf = self;
        operation = [NSBlockOperation blockOperationWithBlock:^{
            typeof(self) self = weakSelf;
            if (self == nil) return;
            MTImportWorkflowSnapshot *latest = nil;
            @synchronized (self) {
                latest = self.pendingProgressSnapshot;
                self.pendingProgressSnapshot = nil;
                self.progressCallbackEnqueued = NO;
            }
            if (latest != nil) handler(latest);
        }];
        if (self.callbackTailOperation != nil) {
            [operation addDependency:self.callbackTailOperation];
        }
        self.callbackTailOperation = operation;
    }
    [self.callbackQueue addOperation:operation];
}

static BOOL MTImportCoordinatorProgressCanCoalesce(
    MTImportWorkflowSnapshot *previous,
    MTImportWorkflowSnapshot *next) {
    return previous != nil && previous.phase == next.phase &&
        previous.preparedImport == nil && next.preparedImport == nil &&
        previous.libraryRevision == nil && next.libraryRevision == nil &&
        previous.error == nil && next.error == nil &&
        next.phase >= MTImportWorkflowPhaseAcquiring &&
        next.phase <= MTImportWorkflowPhaseValidating;
}

static NSUInteger MTImportCoordinatorProgressBucket(
    MTImportWorkflowSnapshot *snapshot) {
    if (snapshot.totalUnitCount == 0) return 0;
    if (snapshot.completedUnitCount >= snapshot.totalUnitCount) return 100;
    long double fraction = (long double)snapshot.completedUnitCount /
        (long double)snapshot.totalUnitCount;
    return (NSUInteger)(fraction * 100.0L);
}

static BOOL MTImportCoordinatorShouldEnqueueProgress(
    MTImportWorkflowSnapshot *lastEnqueued,
    MTImportWorkflowSnapshot *next) {
    if (lastEnqueued == nil || lastEnqueued.phase != next.phase ||
        lastEnqueued.totalUnitCount != next.totalUnitCount ||
        next.completedUnitCount == 0 ||
        next.completedUnitCount >= next.totalUnitCount) {
        return YES;
    }
    return MTImportCoordinatorProgressBucket(lastEnqueued) !=
        MTImportCoordinatorProgressBucket(next);
}

- (instancetype)initWithPipeline:(MTThemeImportPipeline *)pipeline {
    return [self initWithPipeline:pipeline
                    callbackQueue:NSOperationQueue.mainQueue];
}

- (instancetype)initWithPipeline:(MTThemeImportPipeline *)pipeline
                    callbackQueue:(NSOperationQueue *)callbackQueue {
    NSParameterAssert(pipeline != nil);
    NSParameterAssert(callbackQueue != nil);
    self = [super init];
    if (self == nil) return nil;
    _pipeline = pipeline;
    _callbackQueue = callbackQueue;
    _workerQueue = [[NSOperationQueue alloc] init];
    _workerQueue.name = @"com.hmmzzz.marktheme.import-workflow";
    _workerQueue.maxConcurrentOperationCount = 1;
    _workerQueue.qualityOfService = NSQualityOfServiceUserInitiated;
    _snapshot = [[MTImportWorkflowSnapshot alloc]
        initWithPhase:MTImportWorkflowPhaseIdle
        completedUnitCount:0
        totalUnitCount:0
        preparedImport:nil
        libraryRevision:nil
        error:nil];
    return self;
}

- (void)setStateDidChangeHandler:
        (MTImportWorkflowStateHandler)stateDidChangeHandler {
    @synchronized (self) {
        _internalStateDidChangeHandler = [stateDidChangeHandler copy];
    }
    if (stateDidChangeHandler != nil) {
        MTImportWorkflowSnapshot *current = self.snapshot;
        @synchronized (self) {
            self.lastEnqueuedSnapshot = current;
        }
        [self enqueueHandler:stateDidChangeHandler snapshot:current];
    }
}

- (MTImportWorkflowStateHandler)stateDidChangeHandler {
    @synchronized (self) {
        return [_internalStateDidChangeHandler copy];
    }
}

- (void)publishPhase:(MTImportWorkflowPhase)phase
            completed:(NSUInteger)completed
                total:(NSUInteger)total
             prepared:(MTPreparedThemeImport *)prepared
             revision:(MTThemeLibraryRevision *)revision
                error:(NSError *)error
           generation:(NSUInteger)generation {
    MTImportWorkflowStateHandler handler = nil;
    MTImportWorkflowSnapshot *next = nil;
    BOOL coalescesProgress = NO;
    BOOL shouldEnqueue = NO;
    @synchronized (self) {
        if (generation != self.workflowGeneration) return;
        MTImportWorkflowSnapshot *previous = self.snapshot;
        next = [[MTImportWorkflowSnapshot alloc]
            initWithPhase:phase
            completedUnitCount:completed
            totalUnitCount:total
            preparedImport:prepared
            libraryRevision:revision
            error:error];
        self.snapshot = next;
        handler = [_internalStateDidChangeHandler copy];
        coalescesProgress = MTImportCoordinatorProgressCanCoalesce(
            previous, next);
        shouldEnqueue = handler != nil &&
            (!coalescesProgress ||
             MTImportCoordinatorShouldEnqueueProgress(
                 self.lastEnqueuedSnapshot, next));
        if (shouldEnqueue) self.lastEnqueuedSnapshot = next;
    }
    if (shouldEnqueue && coalescesProgress) {
        [self enqueueProgressHandler:handler snapshot:next];
    } else if (shouldEnqueue) {
        [self enqueueHandler:handler snapshot:next];
    }
}

static MTImportWorkflowPhase MTImportCoordinatorPhaseForStage(
    MTThemeImportStage stage) {
    switch (stage) {
        case MTThemeImportStageAcquiring:
            return MTImportWorkflowPhaseAcquiring;
        case MTThemeImportStageAuditing:
            return MTImportWorkflowPhaseAuditing;
        case MTThemeImportStageParsing:
            return MTImportWorkflowPhaseParsing;
        case MTThemeImportStageStaging:
            return MTImportWorkflowPhaseStaging;
        case MTThemeImportStageValidating:
            return MTImportWorkflowPhaseValidating;
        case MTThemeImportStageCommitting:
            return MTImportWorkflowPhaseCommitting;
    }
    return MTImportWorkflowPhaseFailed;
}

- (void)publishProgressForStage:(MTThemeImportStage)stage
                       completed:(NSUInteger)completed
                           total:(NSUInteger)total
                      generation:(NSUInteger)generation {
    @synchronized (self) {
        if (generation != self.workflowGeneration ||
            self.snapshot.phase == MTImportWorkflowPhaseCancelling) {
            return;
        }
    }
    [self publishPhase:MTImportCoordinatorPhaseForStage(stage)
              completed:completed
                  total:total
               prepared:nil
               revision:nil
                  error:nil
             generation:generation];
}

- (BOOL)startZIPImportAtURL:(NSURL *)archiveURL
                  sourceName:(NSString *)sourceName
                       error:(NSError **)error {
    return [self startImportAtURL:archiveURL sourceName:sourceName
                      isDirectory:NO error:error];
}

- (BOOL)startArchiveImportAtURL:(NSURL *)archiveURL
                      sourceName:(NSString *)sourceName
                           error:(NSError **)error {
    return [self startImportAtURL:archiveURL sourceName:sourceName
                      isDirectory:NO error:error];
}

- (BOOL)startDirectoryImportAtURL:(NSURL *)directoryURL
                        sourceName:(NSString *)sourceName
                             error:(NSError **)error {
    return [self startImportAtURL:directoryURL sourceName:sourceName
                      isDirectory:YES error:error];
}

- (BOOL)startImportAtURL:(NSURL *)sourceURL
              sourceName:(NSString *)sourceName
             isDirectory:(BOOL)isDirectory
                   error:(NSError **)error {
    BOOL validURLObject = [sourceURL isKindOfClass:NSURL.class];
    BOOL validNameObject = [sourceName isKindOfClass:NSString.class];
    MTImportDiagnosticsRecord(@"coordinator.start-request", @{
        @"isDirectory" : @(isDirectory),
        @"isFileURL" : @(validURLObject && sourceURL.isFileURL),
        @"lastPathComponent" : validURLObject
            ? sourceURL.lastPathComponent ?: @"" : @"<invalid>",
        @"pathExtension" : validURLObject
            ? sourceURL.pathExtension ?: @"" : @"<invalid>",
        @"path" : validURLObject ? sourceURL.path ?: @"" : @"<invalid>",
        @"sourceName" : validNameObject ? sourceName : @"<invalid>",
        @"effectiveUID" : @(geteuid()),
        @"importSessionsRoot" :
            self.pipeline.configuration.importSessionsRootURL.path ?: @"",
        @"assetSessionsRoot" :
            self.pipeline.configuration.assetSessionsRootURL.path ?: @"",
    });
    if (!validURLObject || !sourceURL.isFileURL ||
        !validNameObject || sourceName.length == 0) {
        return MTImportCoordinatorSetError(error,
            isDirectory
                ? @"A local directory and display name are required."
                : @"A supported local archive and display name are required.");
    }
    __block NSUInteger generation = 0;
    @synchronized (self) {
        if (!self.snapshot.canChooseSource) {
            return MTImportCoordinatorSetError(error,
                @"The current import must finish or be reset first.");
        }
        self.workflowGeneration++;
        generation = self.workflowGeneration;
        self.cancellationToken = [[MTImportCancellationToken alloc] init];
        self.preparedImport = nil;
    }
    [self publishPhase:MTImportWorkflowPhaseAcquiring
              completed:0 total:1 prepared:nil revision:nil error:nil
             generation:generation];

    // Take the security scope synchronously, while the document-picker or
    // open-URL callback that supplied it is still active. The worker may not
    // run until after that callback returns; iOS 18 can otherwise leave a
    // valid File Provider URL unreadable before acquisition starts.
    BOOL sourceSecurityScopeAccessed =
        [sourceURL startAccessingSecurityScopedResource];
    MTImportDiagnosticsRecord(@"coordinator.security-scope", @{
        @"accessed" : @(sourceSecurityScopeAccessed),
        @"generation" : @(generation),
    });
    MTImportCancellationToken *token = self.cancellationToken;
    __weak typeof(self) weakSelf = self;
    [self.workerQueue addOperationWithBlock:^{
        @try {
            typeof(self) self = weakSelf;
            if (self == nil) return;
            MTImportDiagnosticsRecord(@"coordinator.worker.begin", @{
                @"generation" : @(generation),
                @"isDirectory" : @(isDirectory),
            });
            NSError *prepareError = nil;
            MTThemeImportProgressHandler progressHandler =
                ^(MTThemeImportStage stage, NSUInteger completed,
                  NSUInteger total) {
                [self publishProgressForStage:stage completed:completed
                    total:total generation:generation];
            };
            MTPreparedThemeImport *prepared = isDirectory
                ? [self.pipeline prepareDirectoryThemeAtURL:sourceURL
                    sourceName:sourceName cancellationToken:token
                    progressHandler:progressHandler error:&prepareError]
                : [self.pipeline prepareArchiveThemeAtURL:sourceURL
                    sourceName:sourceName cancellationToken:token
                    progressHandler:progressHandler error:&prepareError];
            if (prepared == nil) {
                MTImportDiagnosticsRecordError(@"coordinator.prepare.failed",
                    prepareError, @{
                        @"generation" : @(generation),
                        @"cancelled" : @(token.isCancelled),
                    });
                MTImportWorkflowPhase terminal = token.isCancelled
                    ? MTImportWorkflowPhaseCancelled
                    : MTImportWorkflowPhaseFailed;
                [self publishPhase:terminal completed:0 total:0 prepared:nil
                          revision:nil error:prepareError
                         generation:generation];
                return;
            }
            if (token.isCancelled) {
                [prepared discard:NULL];
                [self publishPhase:MTImportWorkflowPhaseCancelled
                          completed:0 total:0 prepared:nil revision:nil
                              error:nil generation:generation];
                return;
            }
            @synchronized (self) {
                if (generation != self.workflowGeneration) {
                    [prepared discard:NULL];
                    return;
                }
                self.preparedImport = prepared;
            }
            [self publishPhase:MTImportWorkflowPhaseReadyForReview
                      completed:prepared.uniqueAssetCount
                          total:prepared.uniqueAssetCount
                       prepared:prepared revision:nil error:nil
                     generation:generation];
            MTImportDiagnosticsRecord(@"coordinator.prepare.ready", @{
                @"generation" : @(generation),
                @"uniqueAssetCount" : @(prepared.uniqueAssetCount),
            });
        } @finally {
            if (sourceSecurityScopeAccessed) {
                [sourceURL stopAccessingSecurityScopedResource];
            }
            MTImportDiagnosticsRecord(@"coordinator.worker.end", @{
                @"generation" : @(generation),
                @"scopeReleased" : @(sourceSecurityScopeAccessed),
            });
        }
    }];
    return YES;
}

- (BOOL)confirmPreparedImport:(NSError **)error {
    __block NSUInteger generation = 0;
    __block MTPreparedThemeImport *prepared = nil;
    __block MTImportCancellationToken *token = nil;
    @synchronized (self) {
        if (!(self.snapshot.canConfirm || self.snapshot.canRetryCommit) ||
            !self.preparedImport.isActive) {
            return MTImportCoordinatorSetError(error,
                @"No active reviewed import is ready to commit.");
        }
        generation = self.workflowGeneration;
        prepared = self.preparedImport;
        self.cancellationToken = [[MTImportCancellationToken alloc] init];
        token = self.cancellationToken;
    }
    [self publishPhase:MTImportWorkflowPhaseCommitting completed:0 total:1
                 prepared:prepared revision:nil error:nil
               generation:generation];
    __weak typeof(self) weakSelf = self;
    [self.workerQueue addOperationWithBlock:^{
        typeof(self) self = weakSelf;
        if (self == nil) return;
        NSError *commitError = nil;
        MTThemeLibraryRevision *revision = [self.pipeline
            commitPreparedImport:prepared
               cancellationToken:token
                 progressHandler:^(MTThemeImportStage stage,
                                   NSUInteger completed,
                                   NSUInteger total) {
            [self publishProgressForStage:stage completed:completed total:total
                                generation:generation];
        }
                           error:&commitError];
        if (revision != nil) {
            @synchronized (self) {
                if (generation == self.workflowGeneration) {
                    self.preparedImport = nil;
                }
            }
            [self publishPhase:MTImportWorkflowPhaseCompleted
                      completed:1 total:1 prepared:nil revision:revision
                          error:nil generation:generation];
            return;
        }
        if (token.isCancelled) {
            [prepared discard:NULL];
            @synchronized (self) {
                if (generation == self.workflowGeneration) {
                    self.preparedImport = nil;
                }
            }
            [self publishPhase:MTImportWorkflowPhaseCancelled
                      completed:0 total:0 prepared:nil revision:nil
                          error:commitError generation:generation];
            return;
        }
        [self publishPhase:MTImportWorkflowPhaseFailed completed:0 total:1
                 prepared:prepared revision:nil error:commitError
               generation:generation];
    }];
    return YES;
}

- (void)cancel {
    NSUInteger generation = 0;
    MTPreparedThemeImport *prepared = nil;
    BOOL needsQueuedDiscard = NO;
    @synchronized (self) {
        if (!self.snapshot.canCancel) return;
        generation = self.workflowGeneration;
        [self.cancellationToken cancel];
        prepared = self.preparedImport;
        needsQueuedDiscard =
            self.snapshot.phase == MTImportWorkflowPhaseReadyForReview ||
            self.snapshot.phase == MTImportWorkflowPhaseFailed;
    }
    [self publishPhase:MTImportWorkflowPhaseCancelling completed:0 total:0
                 prepared:prepared revision:nil error:nil
               generation:generation];
    if (!needsQueuedDiscard) return;

    __weak typeof(self) weakSelf = self;
    [self.workerQueue addOperationWithBlock:^{
        typeof(self) self = weakSelf;
        if (self == nil) return;
        NSError *discardError = nil;
        BOOL discarded = [prepared discard:&discardError];
        @synchronized (self) {
            if (generation == self.workflowGeneration && discarded) {
                self.preparedImport = nil;
            }
        }
        [self publishPhase:discarded ? MTImportWorkflowPhaseCancelled
                                     : MTImportWorkflowPhaseFailed
                  completed:0 total:0
                   prepared:discarded ? nil : prepared
                   revision:nil error:discardError
                 generation:generation];
    }];
}

- (BOOL)reset:(NSError **)error {
    NSUInteger generation = 0;
    @synchronized (self) {
        if (self.preparedImport != nil ||
            !(self.snapshot.phase == MTImportWorkflowPhaseCancelled ||
              self.snapshot.phase == MTImportWorkflowPhaseCompleted ||
              self.snapshot.phase == MTImportWorkflowPhaseFailed)) {
            return MTImportCoordinatorSetError(error,
                @"Only a terminal import without provisional assets can reset.");
        }
        self.workflowGeneration++;
        generation = self.workflowGeneration;
        self.cancellationToken = nil;
    }
    [self publishPhase:MTImportWorkflowPhaseIdle completed:0 total:0
                 prepared:nil revision:nil error:nil generation:generation];
    return YES;
}

- (void)dealloc {
    [self.cancellationToken cancel];
    [self.preparedImport discard:NULL];
}

@end
