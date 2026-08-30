#import <Foundation/Foundation.h>

@class MTThemeApplyService;
@class MTThemeComponentSelection;
@class MTThemeComponentSelectionStore;
@class MTThemeCapabilityReport;
@class MTThemeLibraryRevisionSummary;
@class MTThemeLibraryStore;
@class MTThemeLibraryThemeSummary;
@class MTThemeMixSelection;
@class MTRuntimeHelperClient;
@class MTRuntimeSnapshotLoader;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSNotificationName const
    MTManagerControllerDidChangeNotification;
FOUNDATION_EXPORT NSString *const MTManagerControllerErrorDomain;

typedef NS_ENUM(NSUInteger, MTManagerOperation) {
    MTManagerOperationIdle = 0,
    MTManagerOperationReloading = 1,
    MTManagerOperationApplying = 2,
    MTManagerOperationDisabling = 3,
    MTManagerOperationRollingBack = 4,
    MTManagerOperationSwitchingRevision = 5,
    MTManagerOperationRemovingRevision = 6,
    MTManagerOperationRespringing = 7,
    MTManagerOperationRemovingTheme = 8,
};

typedef void (^MTManagerOperationCompletion)(BOOL success,
                                              NSError * _Nullable error);
typedef void (^MTManagerApplyCompletion)(BOOL success,
                                         NSError * _Nullable error);
typedef void (^MTManagerRevisionHistoryCompletion)(
    NSArray<MTThemeLibraryRevisionSummary *> * _Nullable revisions,
    NSError * _Nullable error);

// Immutable product-facing projection of Library and Runtime. UIKit screens
// consume this object and never infer canonical state independently.
@interface MTManagerSnapshot : NSObject

@property(nonatomic, copy, readonly)
    NSArray<MTThemeLibraryThemeSummary *> *themes;
@property(nonatomic, copy, readonly)
    NSDictionary<NSString *, MTThemeComponentSelection *> *
        componentSelectionsByThemeIdentifier;
@property(nonatomic, copy, readonly)
    NSDictionary<NSString *, MTThemeMixSelection *> *
        mixSelectionsByThemeIdentifier;
// Library-derived capability indexes are built off the main thread and reused
// by every detail screen. Component edits replace only the changed theme's
// availability set; Runtime-only snapshots preserve both maps by identity.
@property(nonatomic, copy, readonly)
    NSDictionary<NSString *, MTThemeCapabilityReport *> *
        capabilityReportsByThemeIdentifier;
@property(nonatomic, copy, readonly)
    NSDictionary<NSString *, NSSet<NSString *> *> *
        availableFeatureIdentifiersByThemeIdentifier;
@property(nonatomic, copy, readonly, nullable)
    NSString *selectedThemeIdentifier;
@property(nonatomic, assign, readonly) MTManagerOperation operation;
@property(nonatomic, assign, readonly, getter=isLoading) BOOL loading;
@property(nonatomic, assign, readonly, getter=isMutating) BOOL mutating;
@property(nonatomic, assign, readonly, getter=isLibraryRefreshing)
    BOOL libraryRefreshing;
@property(nonatomic, assign, readonly, getter=isRuntimeRefreshing)
    BOOL runtimeRefreshing;

@property(nonatomic, assign, readonly) BOOL runtimeAvailable;
@property(nonatomic, assign, readonly) BOOL runtimeControlAvailable;
@property(nonatomic, assign, readonly) BOOL runtimeEnabled;
@property(nonatomic, assign, readonly) uint64_t runtimeSequence;
@property(nonatomic, copy, readonly, nullable)
    NSString *activeThemeIdentifier;
@property(nonatomic, copy, readonly, nullable)
    NSString *activeRevisionIdentifier;
@property(nonatomic, copy, readonly, nullable)
    NSString *activeGenerationIdentifier;
@property(nonatomic, copy, readonly, nullable)
    NSString *previousGenerationIdentifier;
@property(nonatomic, assign, readonly) NSUInteger runtimeResourceCount;
@property(nonatomic, copy, readonly) NSArray<NSString *> *runtimeModuleIDs;
@property(nonatomic, strong, readonly, nullable)
    MTThemeComponentSelection *activeComponentSelection;
@property(nonatomic, strong, readonly, nullable)
    MTThemeMixSelection *activeMixSelection;
@property(nonatomic, assign, readonly) BOOL canRollbackRuntime;

@property(nonatomic, strong, readonly, nullable) NSError *libraryError;
@property(nonatomic, strong, readonly, nullable) NSError *runtimeError;
@property(nonatomic, strong, readonly, nullable) NSError *operationError;

- (nullable MTThemeLibraryThemeSummary *)themeWithIdentifier:
    (nullable NSString *)themeIdentifier;
- (nullable MTThemeComponentSelection *)componentSelectionForThemeIdentifier:
    (nullable NSString *)themeIdentifier;
- (nullable MTThemeMixSelection *)mixSelectionForThemeIdentifier:
    (nullable NSString *)themeIdentifier;
- (BOOL)runtimeMatchesCurrentSelectionForThemeIdentifier:
    (nullable NSString *)themeIdentifier;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

// The sole Manager control plane. It is a Foundation component in the App
// process: one Library store, one serial mutation queue, one canonical state
// projection, and no additional service or injected process.
@interface MTManagerController : NSObject

@property(atomic, strong, readonly) MTManagerSnapshot *snapshot;
@property(nonatomic, strong, readonly) MTThemeLibraryStore *libraryStore;
@property(nonatomic, strong, readonly)
    MTThemeComponentSelectionStore *componentSelectionStore;

+ (nullable instancetype)defaultControllerWithError:(NSError **)error;
- (instancetype)initWithLibraryStore:(MTThemeLibraryStore *)libraryStore
                         applyService:
                             (nullable MTThemeApplyService *)applyService
                        runtimeClient:
                             (nullable MTRuntimeHelperClient *)runtimeClient
                       snapshotLoader:
                             (MTRuntimeSnapshotLoader *)snapshotLoader;
- (instancetype)initWithLibraryStore:(MTThemeLibraryStore *)libraryStore
                         applyService:
                             (nullable MTThemeApplyService *)applyService
                        runtimeClient:
                             (nullable MTRuntimeHelperClient *)runtimeClient
                       snapshotLoader:
                             (MTRuntimeSnapshotLoader *)snapshotLoader
              componentSelectionStore:
                  (MTThemeComponentSelectionStore *)componentSelectionStore
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

// All callbacks and change notifications are delivered on the main thread.
// Full reload is the cold-start/explicit-audit path. The first complete
// projection selects the exact active Library theme when Runtime is enabled;
// later explicit stock-theme selections remain nil. Navigation must consume
// the current immutable snapshot instead of invoking it again.
- (void)reload;
// Foreground and Settings status refreshes only reread Runtime state. The
// cached Library catalog keeps the same identity and is not rescanned.
- (void)refreshRuntime;
// Reloads the canonical catalog and selects this theme only after it appears
// in the newly loaded Library snapshot. This is the import-completion path;
// selectThemeIdentifier: intentionally accepts only the current snapshot.
- (void)reloadSelectingThemeIdentifier:
    (nullable NSString *)themeIdentifier;
- (void)selectThemeIdentifier:(nullable NSString *)themeIdentifier;
- (void)setComponentIdentifier:(NSString *)componentIdentifier
                        enabled:(BOOL)enabled
             forThemeIdentifier:(NSString *)themeIdentifier
                     completion:
                         (nullable MTManagerOperationCompletion)completion;
- (void)selectVariantIdentifier:(NSString *)variantIdentifier
             forGroupIdentifier:(NSString *)groupIdentifier
                themeIdentifier:(NSString *)themeIdentifier
                     completion:
                         (nullable MTManagerOperationCompletion)completion;
- (void)setFeatureIdentifier:(NSString *)featureIdentifier
                       enabled:(BOOL)enabled
        forBaseThemeIdentifier:(NSString *)baseThemeIdentifier
                    completion:
                        (nullable MTManagerOperationCompletion)completion;
- (void)setSourceThemeIdentifier:(NSString *)sourceThemeIdentifier
              forFeatureIdentifier:(NSString *)featureIdentifier
            baseThemeIdentifier:(NSString *)baseThemeIdentifier
                      completion:
                          (nullable MTManagerOperationCompletion)completion;
- (void)applySelectionWithCompletion:
    (nullable MTManagerApplyCompletion)completion;
- (void)requestRespringWithCompletion:
    (nullable MTManagerOperationCompletion)completion;
- (void)rollbackRuntimeWithCompletion:
    (nullable MTManagerOperationCompletion)completion;

- (void)loadRevisionHistoryForThemeIdentifier:(NSString *)themeIdentifier
    completion:(MTManagerRevisionHistoryCompletion)completion;
- (void)switchThemeIdentifier:(NSString *)themeIdentifier
           toRevisionIdentifier:(NSString *)revisionIdentifier
                     completion:
                         (nullable MTManagerOperationCompletion)completion;
- (void)removeRevisionIdentifier:(NSString *)revisionIdentifier
              fromThemeIdentifier:(NSString *)themeIdentifier
                        completion:
                            (nullable MTManagerOperationCompletion)completion;
// Removes a theme and every revision it stores. The caller is responsible for
// confirming the deletion; a theme that is currently applied must be disabled
// or replaced first, which the Library refuses to do implicitly.
- (void)removeThemeIdentifier:(NSString *)themeIdentifier
                     completion:
                         (nullable MTManagerOperationCompletion)completion;

@end

NS_ASSUME_NONNULL_END
