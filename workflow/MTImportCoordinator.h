#import <Foundation/Foundation.h>

@class MTPreparedThemeImport;
@class MTThemeImportPipeline;
@class MTThemeLibraryRevision;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTImportCoordinatorErrorDomain;

typedef NS_ENUM(NSUInteger, MTImportWorkflowPhase) {
    MTImportWorkflowPhaseIdle = 0,
    MTImportWorkflowPhaseAcquiring = 1,
    MTImportWorkflowPhaseAuditing = 2,
    MTImportWorkflowPhaseParsing = 3,
    MTImportWorkflowPhaseStaging = 4,
    MTImportWorkflowPhaseValidating = 5,
    MTImportWorkflowPhaseReadyForReview = 6,
    MTImportWorkflowPhaseCommitting = 7,
    MTImportWorkflowPhaseCompleted = 8,
    MTImportWorkflowPhaseCancelling = 9,
    MTImportWorkflowPhaseCancelled = 10,
    MTImportWorkflowPhaseFailed = 11,
};

FOUNDATION_EXPORT NSString *MTImportWorkflowPhaseName(
    MTImportWorkflowPhase phase);

@interface MTImportWorkflowSnapshot : NSObject

@property(nonatomic, assign, readonly) MTImportWorkflowPhase phase;
@property(nonatomic, assign, readonly) NSUInteger completedUnitCount;
@property(nonatomic, assign, readonly) NSUInteger totalUnitCount;
@property(nonatomic, strong, readonly, nullable)
    MTPreparedThemeImport *preparedImport;
@property(nonatomic, strong, readonly, nullable)
    MTThemeLibraryRevision *libraryRevision;
@property(nonatomic, strong, readonly, nullable) NSError *error;

@property(nonatomic, assign, readonly) BOOL canChooseArchive;
@property(nonatomic, assign, readonly) BOOL canChooseSource;
@property(nonatomic, assign, readonly) BOOL canCancel;
@property(nonatomic, assign, readonly) BOOL canConfirm;
@property(nonatomic, assign, readonly) BOOL canRetryCommit;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

typedef void (^MTImportWorkflowStateHandler)(
    MTImportWorkflowSnapshot *snapshot);

// Async UI-facing state owner. Heavy work is serialized on one bounded worker
// queue. State callbacks are delivered in order on the configured callback
// queue (main queue in production).
@interface MTImportCoordinator : NSObject

@property(nonatomic, strong, readonly) MTThemeImportPipeline *pipeline;
@property(nonatomic, strong, readonly) NSOperationQueue *workerQueue;
@property(nonatomic, strong, readonly) NSOperationQueue *callbackQueue;
@property(atomic, strong, readonly) MTImportWorkflowSnapshot *snapshot;
@property(nonatomic, copy, nullable)
    MTImportWorkflowStateHandler stateDidChangeHandler;

- (instancetype)initWithPipeline:(MTThemeImportPipeline *)pipeline;
- (instancetype)initWithPipeline:(MTThemeImportPipeline *)pipeline
                    callbackQueue:(NSOperationQueue *)callbackQueue
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (BOOL)startZIPImportAtURL:(NSURL *)archiveURL
                  sourceName:(NSString *)sourceName
                       error:(NSError **)error;
- (BOOL)startArchiveImportAtURL:(NSURL *)archiveURL
                      sourceName:(NSString *)sourceName
                           error:(NSError **)error;
- (BOOL)startDirectoryImportAtURL:(NSURL *)directoryURL
                        sourceName:(NSString *)sourceName
                             error:(NSError **)error;
- (BOOL)confirmPreparedImport:(NSError **)error;
- (void)cancel;
- (BOOL)reset:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
