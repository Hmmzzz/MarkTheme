#import "MTManagerController.h"

#import <os/signpost.h>

#import "MTGenerationDescriptor.h"
#import "MTGenerationReader.h"
#import "MTRuntimeHelperClient.h"
#import "MTRuntimeSnapshot.h"
#import "MTRuntimeSnapshotLoader.h"
#import "MTRuntimeState.h"
#import "MTThemeApplyService.h"
#import "MTThemeComponentCatalog.h"
#import "MTThemeComponentSelectionStore.h"
#import "MTThemeMixSelection.h"
#import "MTThemeCapabilityReport.h"
#import "MTThemeImport.h"
#import "MTThemeLibraryCatalog.h"
#import "MTThemeLibraryStore.h"

NSNotificationName const MTManagerControllerDidChangeNotification =
    @"MTManagerControllerDidChangeNotification";
NSString *const MTManagerControllerErrorDomain =
    @"com.hmmzzz.marktheme.manager-controller";

static os_log_t MTManagerPerformanceLog(void) {
    static os_log_t log;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        log = os_log_create("com.hmmzzz.marktheme", "ManagerPerformance");
    });
    return log;
}

typedef NS_ENUM(NSInteger, MTManagerControllerErrorCode) {
    MTManagerControllerErrorUnavailable = 1,
    MTManagerControllerErrorBusy = 2,
    MTManagerControllerErrorInvalidSelection = 3,
};

static NSError *MTManagerError(MTManagerControllerErrorCode code,
                               NSString *description) {
    return [NSError errorWithDomain:MTManagerControllerErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey : description}];
}

@interface MTManagerSnapshot ()
@property(nonatomic, copy, readwrite)
    NSArray<MTThemeLibraryThemeSummary *> *themes;
@property(nonatomic, copy, readwrite)
    NSDictionary<NSString *, MTThemeComponentSelection *> *
        componentSelectionsByThemeIdentifier;
@property(nonatomic, copy, readwrite)
    NSDictionary<NSString *, MTThemeMixSelection *> *
        mixSelectionsByThemeIdentifier;
@property(nonatomic, copy, readwrite)
    NSDictionary<NSString *, MTThemeCapabilityReport *> *
        capabilityReportsByThemeIdentifier;
@property(nonatomic, copy, readwrite)
    NSDictionary<NSString *, NSSet<NSString *> *> *
        availableFeatureIdentifiersByThemeIdentifier;
@property(nonatomic, copy)
    NSDictionary<NSString *, MTThemeLibraryThemeSummary *> *themeIndex;
@property(nonatomic, copy, readwrite, nullable)
    NSString *selectedThemeIdentifier;
@property(nonatomic, assign, readwrite) MTManagerOperation operation;
@property(nonatomic, assign, readwrite, getter=isLibraryRefreshing)
    BOOL libraryRefreshing;
@property(nonatomic, assign, readwrite, getter=isRuntimeRefreshing)
    BOOL runtimeRefreshing;
@property(nonatomic, assign, readwrite) BOOL runtimeAvailable;
@property(nonatomic, assign, readwrite) BOOL runtimeControlAvailable;
@property(nonatomic, assign, readwrite) BOOL runtimeEnabled;
@property(nonatomic, assign, readwrite) uint64_t runtimeSequence;
@property(nonatomic, copy, readwrite, nullable)
    NSString *activeThemeIdentifier;
@property(nonatomic, copy, readwrite, nullable)
    NSString *activeRevisionIdentifier;
@property(nonatomic, copy, readwrite, nullable)
    NSString *activeGenerationIdentifier;
@property(nonatomic, copy, readwrite, nullable)
    NSString *previousGenerationIdentifier;
@property(nonatomic, assign, readwrite) NSUInteger runtimeResourceCount;
@property(nonatomic, copy, readwrite) NSArray<NSString *> *runtimeModuleIDs;
@property(nonatomic, strong, readwrite, nullable)
    MTThemeComponentSelection *activeComponentSelection;
@property(nonatomic, strong, readwrite, nullable)
    MTThemeMixSelection *activeMixSelection;
@property(nonatomic, strong, readwrite, nullable) NSError *libraryError;
@property(nonatomic, strong, readwrite, nullable) NSError *runtimeError;
@property(nonatomic, strong, readwrite, nullable) NSError *operationError;

- (instancetype)initWithThemes:
        (NSArray<MTThemeLibraryThemeSummary *> *)themes
    themeIndex:(nullable NSDictionary<NSString *,
                   MTThemeLibraryThemeSummary *> *)themeIndex
    componentSelectionsByThemeIdentifier:
        (NSDictionary<NSString *, MTThemeComponentSelection *> *)
            componentSelectionsByThemeIdentifier
    mixSelectionsByThemeIdentifier:
        (NSDictionary<NSString *, MTThemeMixSelection *> *)
            mixSelectionsByThemeIdentifier
    capabilityReportsByThemeIdentifier:
        (NSDictionary<NSString *, MTThemeCapabilityReport *> *)
            capabilityReportsByThemeIdentifier
    availableFeatureIdentifiersByThemeIdentifier:
        (NSDictionary<NSString *, NSSet<NSString *> *> *)
            availableFeatureIdentifiersByThemeIdentifier
    selectedThemeIdentifier:(nullable NSString *)selectedThemeIdentifier
    operation:(MTManagerOperation)operation
    libraryRefreshing:(BOOL)libraryRefreshing
    runtimeRefreshing:(BOOL)runtimeRefreshing
    runtimeAvailable:(BOOL)runtimeAvailable
    runtimeControlAvailable:(BOOL)runtimeControlAvailable
    runtimeEnabled:(BOOL)runtimeEnabled
    runtimeSequence:(uint64_t)runtimeSequence
    activeThemeIdentifier:(nullable NSString *)activeThemeIdentifier
    activeRevisionIdentifier:(nullable NSString *)activeRevisionIdentifier
    activeGenerationIdentifier:(nullable NSString *)activeGenerationIdentifier
    previousGenerationIdentifier:(nullable NSString *)previousGenerationIdentifier
    runtimeResourceCount:(NSUInteger)runtimeResourceCount
    runtimeModuleIDs:(NSArray<NSString *> *)runtimeModuleIDs
    activeComponentSelection:
        (nullable MTThemeComponentSelection *)activeComponentSelection
    activeMixSelection:(nullable MTThemeMixSelection *)activeMixSelection
    libraryError:(nullable NSError *)libraryError
    runtimeError:(nullable NSError *)runtimeError
    operationError:(nullable NSError *)operationError;
- (MTManagerSnapshot *)snapshotWithSelectedThemeIdentifier:
    (nullable NSString *)selectedThemeIdentifier;
- (MTManagerSnapshot *)snapshotWithOperation:(MTManagerOperation)operation
                              operationError:(nullable NSError *)operationError;
- (MTManagerSnapshot *)snapshotRefreshingLibrary:(BOOL)libraryRefreshing
                                         runtime:(BOOL)runtimeRefreshing;
- (MTManagerSnapshot *)snapshotWithComponentSelections:
    (NSDictionary<NSString *, MTThemeComponentSelection *> *)componentSelections
    availableFeatureIdentifiersByThemeIdentifier:
        (NSDictionary<NSString *, NSSet<NSString *> *> *)availableFeatures
    mixSelections:(NSDictionary<NSString *, MTThemeMixSelection *> *)mixSelections
                                       operationError:
                                           (nullable NSError *)operationError;
@end

@implementation MTManagerSnapshot

static NSDictionary<NSString *, MTThemeLibraryThemeSummary *> *
MTManagerBuildThemeIndex(
    NSArray<MTThemeLibraryThemeSummary *> *themes) {
    NSMutableDictionary<NSString *, MTThemeLibraryThemeSummary *> *index =
        [NSMutableDictionary dictionaryWithCapacity:themes.count];
    for (MTThemeLibraryThemeSummary *theme in themes) {
        index[theme.themeID] = theme;
    }
    return [index copy];
}

static NSDictionary<NSString *, NSString *> *
MTManagerCurrentRevisionIdentifiers(
    NSArray<MTThemeLibraryThemeSummary *> *themes) {
    NSMutableDictionary<NSString *, NSString *> *revisions =
        [NSMutableDictionary dictionaryWithCapacity:themes.count];
    for (MTThemeLibraryThemeSummary *theme in themes) {
        if (theme.themeID.length > 0 &&
            theme.currentRevision.revisionIdentifier.length > 0) {
            revisions[theme.themeID] =
                theme.currentRevision.revisionIdentifier;
        }
    }
    return [revisions copy];
}

static NSDictionary<NSString *, MTThemeMixSelection *> *
MTManagerBuildMixSelections(
    NSArray<MTThemeLibraryThemeSummary *> *themes,
    NSDictionary<NSString *, MTThemeComponentSelection *> *componentSelections,
    NSDictionary<NSString *, NSSet<NSString *> *> *availableFeatures,
    MTThemeComponentSelectionStore *selectionStore) {
    NSDictionary<NSString *, NSString *> *revisions =
        MTManagerCurrentRevisionIdentifiers(themes);
    NSMutableDictionary<NSString *, MTThemeMixSelection *> *mixes =
        [NSMutableDictionary dictionaryWithCapacity:themes.count];
    for (MTThemeLibraryThemeSummary *theme in themes) {
        MTThemeMixSelection *selection = [selectionStore
            mixSelectionForBaseThemeIdentifier:theme.themeID
            revisionIdentifiersByThemeIdentifier:revisions
            componentSelectionsByThemeIdentifier:componentSelections
            availableFeatureIdentifiersByThemeIdentifier:availableFeatures];
        if (selection != nil) mixes[theme.themeID] = selection;
    }
    return [mixes copy];
}

static NSDictionary<NSString *, NSSet<NSString *> *> *
MTManagerBuildAvailableFeatures(
    NSArray<MTThemeLibraryThemeSummary *> *themes,
    NSDictionary<NSString *, MTThemeComponentSelection *> *componentSelections,
    NSDictionary<NSString *, MTThemeCapabilityReport *> *capabilityReports) {
    NSMutableDictionary<NSString *, NSSet<NSString *> *> *availableFeatures =
        [NSMutableDictionary dictionaryWithCapacity:themes.count];
    for (MTThemeLibraryThemeSummary *theme in themes) {
        availableFeatures[theme.themeID] =
            MTThemeRuntimeApplicableFeatureIdentifiersForSelectionUsingReport(
                theme.currentRevision.manifest,
                componentSelections[theme.themeID],
                capabilityReports[theme.themeID]);
    }
    return [availableFeatures copy];
}

static NSDictionary<NSString *, MTThemeCapabilityReport *> *
MTManagerBuildCapabilityReports(
    NSArray<MTThemeLibraryThemeSummary *> *themes) {
    NSMutableDictionary<NSString *, MTThemeCapabilityReport *> *reports =
        [NSMutableDictionary dictionaryWithCapacity:themes.count];
    for (MTThemeLibraryThemeSummary *theme in themes) {
        reports[theme.themeID] = [MTThemeCapabilityReport
            reportForManifest:theme.currentRevision.manifest];
    }
    return [reports copy];
}

- (instancetype)initWithThemes:
        (NSArray<MTThemeLibraryThemeSummary *> *)themes
    themeIndex:(NSDictionary<NSString *, MTThemeLibraryThemeSummary *> *)themeIndex
    componentSelectionsByThemeIdentifier:
        (NSDictionary<NSString *, MTThemeComponentSelection *> *)
            componentSelectionsByThemeIdentifier
    mixSelectionsByThemeIdentifier:
        (NSDictionary<NSString *, MTThemeMixSelection *> *)
            mixSelectionsByThemeIdentifier
    capabilityReportsByThemeIdentifier:
        (NSDictionary<NSString *, MTThemeCapabilityReport *> *)
            capabilityReportsByThemeIdentifier
    availableFeatureIdentifiersByThemeIdentifier:
        (NSDictionary<NSString *, NSSet<NSString *> *> *)
            availableFeatureIdentifiersByThemeIdentifier
    selectedThemeIdentifier:(NSString *)selectedThemeIdentifier
    operation:(MTManagerOperation)operation
    libraryRefreshing:(BOOL)libraryRefreshing
    runtimeRefreshing:(BOOL)runtimeRefreshing
    runtimeAvailable:(BOOL)runtimeAvailable
    runtimeControlAvailable:(BOOL)runtimeControlAvailable
    runtimeEnabled:(BOOL)runtimeEnabled
    runtimeSequence:(uint64_t)runtimeSequence
    activeThemeIdentifier:(NSString *)activeThemeIdentifier
    activeRevisionIdentifier:(NSString *)activeRevisionIdentifier
    activeGenerationIdentifier:(NSString *)activeGenerationIdentifier
    previousGenerationIdentifier:(NSString *)previousGenerationIdentifier
    runtimeResourceCount:(NSUInteger)runtimeResourceCount
    runtimeModuleIDs:(NSArray<NSString *> *)runtimeModuleIDs
    activeComponentSelection:
        (MTThemeComponentSelection *)activeComponentSelection
    activeMixSelection:(MTThemeMixSelection *)activeMixSelection
    libraryError:(NSError *)libraryError
    runtimeError:(NSError *)runtimeError
    operationError:(NSError *)operationError {
    self = [super init];
    if (self == nil) return nil;
    _themes = [themes copy];
    _themeIndex = [themeIndex copy] ?: MTManagerBuildThemeIndex(_themes);
    _componentSelectionsByThemeIdentifier =
        [componentSelectionsByThemeIdentifier copy] ?: @{};
    _mixSelectionsByThemeIdentifier =
        [mixSelectionsByThemeIdentifier copy] ?: @{};
    _capabilityReportsByThemeIdentifier =
        [capabilityReportsByThemeIdentifier copy] ?: @{};
    _availableFeatureIdentifiersByThemeIdentifier =
        [availableFeatureIdentifiersByThemeIdentifier copy] ?: @{};
    _selectedThemeIdentifier = [selectedThemeIdentifier copy];
    _operation = operation;
    _libraryRefreshing = libraryRefreshing;
    _runtimeRefreshing = runtimeRefreshing;
    _runtimeAvailable = runtimeAvailable;
    _runtimeControlAvailable = runtimeControlAvailable;
    _runtimeEnabled = runtimeEnabled;
    _runtimeSequence = runtimeSequence;
    _activeThemeIdentifier = [activeThemeIdentifier copy];
    _activeRevisionIdentifier = [activeRevisionIdentifier copy];
    _activeGenerationIdentifier = [activeGenerationIdentifier copy];
    _previousGenerationIdentifier = [previousGenerationIdentifier copy];
    _runtimeResourceCount = runtimeResourceCount;
    _runtimeModuleIDs = [runtimeModuleIDs copy];
    _activeComponentSelection = activeComponentSelection;
    _activeMixSelection = activeMixSelection;
    _libraryError = libraryError;
    _runtimeError = runtimeError;
    _operationError = operationError;
    return self;
}

- (BOOL)isLoading {
    return self.operation == MTManagerOperationReloading;
}

- (BOOL)isMutating {
    return self.operation >= MTManagerOperationApplying;
}

- (BOOL)canRollbackRuntime {
    return self.runtimeControlAvailable &&
        self.previousGenerationIdentifier.length > 0 && !self.isMutating;
}

- (MTThemeLibraryThemeSummary *)themeWithIdentifier:
        (NSString *)themeIdentifier {
    if (themeIdentifier.length == 0) return nil;
    return self.themeIndex[themeIdentifier];
}

- (MTThemeComponentSelection *)componentSelectionForThemeIdentifier:
        (NSString *)themeIdentifier {
    if (themeIdentifier.length == 0) return nil;
    return self.componentSelectionsByThemeIdentifier[themeIdentifier];
}

- (MTThemeMixSelection *)mixSelectionForThemeIdentifier:
        (NSString *)themeIdentifier {
    if (themeIdentifier.length == 0) return nil;
    return self.mixSelectionsByThemeIdentifier[themeIdentifier];
}

- (BOOL)runtimeMatchesCurrentSelectionForThemeIdentifier:
        (NSString *)themeIdentifier {
    MTThemeLibraryThemeSummary *theme = [self
        themeWithIdentifier:themeIdentifier];
    MTThemeComponentSelection *desired = [self
        componentSelectionForThemeIdentifier:themeIdentifier];
    MTThemeMixSelection *desiredMix = [self
        mixSelectionForThemeIdentifier:themeIdentifier];
    if (!self.runtimeEnabled || theme == nil || desired == nil ||
        desiredMix == nil ||
        ![self.activeThemeIdentifier isEqualToString:themeIdentifier]) {
        return NO;
    }
    if (self.activeMixSelection != nil) {
        return [self.activeMixSelection
            isRuntimeEquivalentToSelection:desiredMix];
    }
    // Generations published before cross-theme configuration records existed
    // remain exact only for the legacy, unmodified single-theme default.
    return desiredMix.sourceThemeIdentifiersByFeature.count == 0 &&
        desiredMix.disabledFeatureIdentifiers.count == 0 &&
        [self.activeRevisionIdentifier isEqualToString:
            theme.currentRevision.revisionIdentifier] &&
        [self.activeComponentSelection isEqual:desired];
}

- (BOOL)runtimeUsesThemeIdentifier:(NSString *)themeIdentifier {
    if (!self.runtimeEnabled || themeIdentifier.length == 0) return NO;
    if (self.activeMixSelection != nil) {
        return [self.activeMixSelection.effectiveThemeIdentifiers
            containsObject:themeIdentifier];
    }
    return [self.activeThemeIdentifier isEqualToString:themeIdentifier];
}

- (MTManagerSnapshot *)snapshotWithSelectedThemeIdentifier:
        (NSString *)selectedThemeIdentifier {
    return [[MTManagerSnapshot alloc]
        initWithThemes:self.themes
        themeIndex:self.themeIndex
        componentSelectionsByThemeIdentifier:
            self.componentSelectionsByThemeIdentifier
        mixSelectionsByThemeIdentifier:self.mixSelectionsByThemeIdentifier
        capabilityReportsByThemeIdentifier:
            self.capabilityReportsByThemeIdentifier
        availableFeatureIdentifiersByThemeIdentifier:
            self.availableFeatureIdentifiersByThemeIdentifier
        selectedThemeIdentifier:selectedThemeIdentifier
        operation:self.operation
        libraryRefreshing:self.libraryRefreshing
        runtimeRefreshing:self.runtimeRefreshing
        runtimeAvailable:self.runtimeAvailable
        runtimeControlAvailable:self.runtimeControlAvailable
        runtimeEnabled:self.runtimeEnabled
        runtimeSequence:self.runtimeSequence
        activeThemeIdentifier:self.activeThemeIdentifier
        activeRevisionIdentifier:self.activeRevisionIdentifier
        activeGenerationIdentifier:self.activeGenerationIdentifier
        previousGenerationIdentifier:self.previousGenerationIdentifier
        runtimeResourceCount:self.runtimeResourceCount
        runtimeModuleIDs:self.runtimeModuleIDs
        activeComponentSelection:self.activeComponentSelection
        activeMixSelection:self.activeMixSelection
        libraryError:self.libraryError
        runtimeError:self.runtimeError
        operationError:self.operationError];
}

- (MTManagerSnapshot *)snapshotWithOperation:(MTManagerOperation)operation
                              operationError:(NSError *)operationError {
    return [[MTManagerSnapshot alloc]
        initWithThemes:self.themes
        themeIndex:self.themeIndex
        componentSelectionsByThemeIdentifier:
            self.componentSelectionsByThemeIdentifier
        mixSelectionsByThemeIdentifier:self.mixSelectionsByThemeIdentifier
        capabilityReportsByThemeIdentifier:
            self.capabilityReportsByThemeIdentifier
        availableFeatureIdentifiersByThemeIdentifier:
            self.availableFeatureIdentifiersByThemeIdentifier
        selectedThemeIdentifier:self.selectedThemeIdentifier
        operation:operation
        libraryRefreshing:NO
        runtimeRefreshing:NO
        runtimeAvailable:self.runtimeAvailable
        runtimeControlAvailable:self.runtimeControlAvailable
        runtimeEnabled:self.runtimeEnabled
        runtimeSequence:self.runtimeSequence
        activeThemeIdentifier:self.activeThemeIdentifier
        activeRevisionIdentifier:self.activeRevisionIdentifier
        activeGenerationIdentifier:self.activeGenerationIdentifier
        previousGenerationIdentifier:self.previousGenerationIdentifier
        runtimeResourceCount:self.runtimeResourceCount
        runtimeModuleIDs:self.runtimeModuleIDs
        activeComponentSelection:self.activeComponentSelection
        activeMixSelection:self.activeMixSelection
        libraryError:self.libraryError
        runtimeError:self.runtimeError
        operationError:operationError];
}

- (MTManagerSnapshot *)snapshotRefreshingLibrary:(BOOL)libraryRefreshing
                                         runtime:(BOOL)runtimeRefreshing {
    return [[MTManagerSnapshot alloc]
        initWithThemes:self.themes
        themeIndex:self.themeIndex
        componentSelectionsByThemeIdentifier:
            self.componentSelectionsByThemeIdentifier
        mixSelectionsByThemeIdentifier:self.mixSelectionsByThemeIdentifier
        capabilityReportsByThemeIdentifier:
            self.capabilityReportsByThemeIdentifier
        availableFeatureIdentifiersByThemeIdentifier:
            self.availableFeatureIdentifiersByThemeIdentifier
        selectedThemeIdentifier:self.selectedThemeIdentifier
        operation:MTManagerOperationReloading
        libraryRefreshing:libraryRefreshing
        runtimeRefreshing:runtimeRefreshing
        runtimeAvailable:self.runtimeAvailable
        runtimeControlAvailable:self.runtimeControlAvailable
        runtimeEnabled:self.runtimeEnabled
        runtimeSequence:self.runtimeSequence
        activeThemeIdentifier:self.activeThemeIdentifier
        activeRevisionIdentifier:self.activeRevisionIdentifier
        activeGenerationIdentifier:self.activeGenerationIdentifier
        previousGenerationIdentifier:self.previousGenerationIdentifier
        runtimeResourceCount:self.runtimeResourceCount
        runtimeModuleIDs:self.runtimeModuleIDs
        activeComponentSelection:self.activeComponentSelection
        activeMixSelection:self.activeMixSelection
        libraryError:self.libraryError
        runtimeError:self.runtimeError
        operationError:nil];
}

- (MTManagerSnapshot *)snapshotWithComponentSelections:
        (NSDictionary<NSString *,MTThemeComponentSelection *> *)componentSelections
    availableFeatureIdentifiersByThemeIdentifier:
        (NSDictionary<NSString *,NSSet<NSString *> *> *)availableFeatures
    mixSelections:(NSDictionary<NSString *,MTThemeMixSelection *> *)mixSelections
                                           operationError:
                                               (NSError *)operationError {
    return [[MTManagerSnapshot alloc]
        initWithThemes:self.themes
        themeIndex:self.themeIndex
        componentSelectionsByThemeIdentifier:componentSelections
        mixSelectionsByThemeIdentifier:mixSelections
        capabilityReportsByThemeIdentifier:
            self.capabilityReportsByThemeIdentifier
        availableFeatureIdentifiersByThemeIdentifier:availableFeatures
        selectedThemeIdentifier:self.selectedThemeIdentifier
        operation:self.operation
        libraryRefreshing:self.libraryRefreshing
        runtimeRefreshing:self.runtimeRefreshing
        runtimeAvailable:self.runtimeAvailable
        runtimeControlAvailable:self.runtimeControlAvailable
        runtimeEnabled:self.runtimeEnabled
        runtimeSequence:self.runtimeSequence
        activeThemeIdentifier:self.activeThemeIdentifier
        activeRevisionIdentifier:self.activeRevisionIdentifier
        activeGenerationIdentifier:self.activeGenerationIdentifier
        previousGenerationIdentifier:self.previousGenerationIdentifier
        runtimeResourceCount:self.runtimeResourceCount
        runtimeModuleIDs:self.runtimeModuleIDs
        activeComponentSelection:self.activeComponentSelection
        activeMixSelection:self.activeMixSelection
        libraryError:self.libraryError
        runtimeError:self.runtimeError
        operationError:operationError];
}

@end

typedef BOOL (^MTManagerMutation)(NSError **error);
typedef MTThemeComponentSelection *_Nullable (^MTManagerSelectionMutation)(
    MTThemeComponentSelection *selection,
    MTThemeComponentCatalog *catalog,
    NSError **error);
typedef MTThemeMixSelection *_Nullable (^MTManagerMixMutation)(
    MTThemeMixSelection *selection,
    NSDictionary<NSString *, NSString *> *revisionIdentifiers,
    NSDictionary<NSString *, MTThemeComponentSelection *> *componentSelections,
    NSError **error);

typedef NS_OPTIONS(NSUInteger, MTManagerRefreshScope) {
    MTManagerRefreshScopeNone = 0,
    MTManagerRefreshScopeLibrary = 1 << 0,
    MTManagerRefreshScopeRuntime = 1 << 1,
};

@interface MTManagerController ()
@property(atomic, strong, readwrite) MTManagerSnapshot *snapshot;
@property(nonatomic, strong, readwrite) MTThemeLibraryStore *libraryStore;
@property(nonatomic, strong, readwrite)
    MTThemeComponentSelectionStore *componentSelectionStore;
@property(nonatomic, strong, nullable) MTThemeApplyService *applyService;
@property(nonatomic, strong, nullable) MTRuntimeHelperClient *runtimeClient;
@property(nonatomic, strong) MTRuntimeSnapshotLoader *snapshotLoader;
@property(nonatomic, strong) NSOperationQueue *workerQueue;
@property(nonatomic, assign) BOOL recoveryCompleted;
@property(nonatomic, assign) BOOL refreshInFlight;
@property(nonatomic, assign) MTManagerRefreshScope activeRefreshScope;
@property(nonatomic, copy, nullable) NSString *activeRefreshSelection;
@property(nonatomic, assign) MTManagerRefreshScope pendingRefreshScope;
@property(nonatomic, assign) BOOL pendingSelectionSpecified;
@property(nonatomic, copy, nullable) NSString *pendingRefreshSelection;
- (void)updateComponentSelectionForThemeIdentifier:
        (NSString *)themeIdentifier
    mutation:(MTManagerSelectionMutation)mutation
    completion:(nullable MTManagerOperationCompletion)completion;
- (void)updateMixSelectionForBaseThemeIdentifier:
        (NSString *)baseThemeIdentifier
    mutation:(MTManagerMixMutation)mutation
    completion:(nullable MTManagerOperationCompletion)completion;
@end

@implementation MTManagerController

static BOOL MTManagerThemeSupportsFeature(
    MTManagerSnapshot *snapshot,
    NSString *themeIdentifier,
    NSString *featureIdentifier) {
    if (themeIdentifier.length == 0 || featureIdentifier.length == 0) return NO;
    return [snapshot.availableFeatureIdentifiersByThemeIdentifier[
        themeIdentifier] containsObject:featureIdentifier];
}

+ (instancetype)defaultControllerWithError:(NSError **)error {
    MTThemeLibraryStore *store = [[MTThemeLibraryStore alloc]
        initWithConfiguration:MTThemeLibraryConfiguration.defaultConfiguration];
    MTRuntimeSnapshotLoader *loader =
        [MTRuntimeSnapshotLoader defaultLoaderWithError:error];
    if (loader == nil) return nil;

    NSError *controlError = nil;
    MTThemeApplyService *applyService =
        [MTThemeApplyService defaultServiceWithLibraryStore:store
                                                      error:&controlError];
    MTRuntimeHelperClient *client = applyService.runtimeClient;
    return [[self alloc] initWithLibraryStore:store
                                applyService:applyService
                               runtimeClient:client
                              snapshotLoader:loader
                     componentSelectionStore:
                         MTThemeComponentSelectionStore.defaultStore];
}

- (instancetype)initWithLibraryStore:(MTThemeLibraryStore *)libraryStore
                         applyService:(MTThemeApplyService *)applyService
                        runtimeClient:(MTRuntimeHelperClient *)runtimeClient
                       snapshotLoader:(MTRuntimeSnapshotLoader *)snapshotLoader {
    return [self initWithLibraryStore:libraryStore
                         applyService:applyService
                        runtimeClient:runtimeClient
                       snapshotLoader:snapshotLoader
              componentSelectionStore:
                  MTThemeComponentSelectionStore.defaultStore];
}

- (instancetype)initWithLibraryStore:(MTThemeLibraryStore *)libraryStore
                         applyService:(MTThemeApplyService *)applyService
                        runtimeClient:(MTRuntimeHelperClient *)runtimeClient
                       snapshotLoader:(MTRuntimeSnapshotLoader *)snapshotLoader
              componentSelectionStore:
                  (MTThemeComponentSelectionStore *)componentSelectionStore {
    NSParameterAssert(libraryStore != nil);
    NSParameterAssert(snapshotLoader != nil);
    NSParameterAssert(componentSelectionStore != nil);
    self = [super init];
    if (self == nil) return nil;
    _libraryStore = libraryStore;
    _applyService = applyService;
    _runtimeClient = runtimeClient;
    _snapshotLoader = snapshotLoader;
    _componentSelectionStore = componentSelectionStore;
    _workerQueue = [[NSOperationQueue alloc] init];
    _workerQueue.name = @"com.hmmzzz.marktheme.manager-control";
    _workerQueue.maxConcurrentOperationCount = 1;
    _workerQueue.qualityOfService = NSQualityOfServiceUserInitiated;
    _snapshot = [[MTManagerSnapshot alloc]
        initWithThemes:@[]
        themeIndex:nil
        componentSelectionsByThemeIdentifier:@{}
        mixSelectionsByThemeIdentifier:@{}
        capabilityReportsByThemeIdentifier:@{}
        availableFeatureIdentifiersByThemeIdentifier:@{}
        selectedThemeIdentifier:nil
        operation:MTManagerOperationReloading
        libraryRefreshing:YES
        runtimeRefreshing:YES
        runtimeAvailable:NO
        runtimeControlAvailable:applyService != nil && runtimeClient != nil
        runtimeEnabled:NO
        runtimeSequence:0
        activeThemeIdentifier:nil
        activeRevisionIdentifier:nil
        activeGenerationIdentifier:nil
        previousGenerationIdentifier:nil
        runtimeResourceCount:0
        runtimeModuleIDs:@[]
        activeComponentSelection:nil
        activeMixSelection:nil
        libraryError:nil
        runtimeError:nil
        operationError:nil];
    return self;
}

- (void)dealloc {
    [self.workerQueue cancelAllOperations];
}

- (void)publishSnapshot:(MTManagerSnapshot *)snapshot {
    NSAssert(NSThread.isMainThread, @"Manager snapshots publish on main.");
    self.snapshot = snapshot;
    [NSNotificationCenter.defaultCenter
        postNotificationName:MTManagerControllerDidChangeNotification
                      object:self];
}

- (MTManagerSnapshot *)loadSnapshotFromSnapshot:(MTManagerSnapshot *)base
    selectingThemeIdentifier:(NSString *)selectedThemeIdentifier
    refreshScope:(MTManagerRefreshScope)refreshScope {
    NSArray<MTThemeLibraryThemeSummary *> *themes = base.themes;
    NSDictionary<NSString *, MTThemeComponentSelection *> *componentSelections =
        base.componentSelectionsByThemeIdentifier;
    NSDictionary<NSString *, MTThemeMixSelection *> *mixSelections =
        base.mixSelectionsByThemeIdentifier;
    NSDictionary<NSString *, MTThemeCapabilityReport *> *capabilityReports =
        base.capabilityReportsByThemeIdentifier;
    NSDictionary<NSString *, NSSet<NSString *> *> *availableFeatures =
        base.availableFeatureIdentifiersByThemeIdentifier;
    NSError *libraryError = base.libraryError;
    if ((refreshScope & MTManagerRefreshScopeLibrary) != 0) {
        NSError *recoveryError = nil;
        if (!self.recoveryCompleted) {
            self.recoveryCompleted =
                [MTThemeImportPipeline recoverAbandonedStateWithConfiguration:
                    MTThemeImportConfiguration.defaultConfiguration
                                                                  error:&recoveryError];
            if (!self.recoveryCompleted) {
                NSLog(@"MarkTheme startup recovery failed (%@/%ld): %@",
                      recoveryError.domain, (long)recoveryError.code,
                      recoveryError.localizedDescription);
            }
        }
        libraryError = nil;
        NSArray<MTThemeLibraryThemeSummary *> *loadedThemes = [self.libraryStore
            loadThemeCatalogWithCancellationToken:nil error:&libraryError];
        // Keep the last immutable read model visible across a transient read
        // failure. Cold start naturally retains the initial empty snapshot.
        if (loadedThemes != nil) {
            themes = loadedThemes;
            NSMutableDictionary<NSString *, MTThemeComponentSelection *> *loaded =
                [NSMutableDictionary dictionaryWithCapacity:themes.count];
            for (MTThemeLibraryThemeSummary *theme in themes) {
                MTThemeComponentCatalog *catalog = [MTThemeComponentCatalog
                    catalogForManifest:theme.currentRevision.manifest
                    error:NULL];
                if (catalog != nil) {
                    loaded[theme.themeID] = [self.componentSelectionStore
                        selectionForCatalog:catalog];
                }
            }
            componentSelections = [loaded copy];
            capabilityReports = MTManagerBuildCapabilityReports(themes);
            availableFeatures = MTManagerBuildAvailableFeatures(themes,
                componentSelections, capabilityReports);
            mixSelections = MTManagerBuildMixSelections(themes,
                componentSelections, availableFeatures,
                self.componentSelectionStore);
        }
        if (libraryError != nil) {
            NSLog(@"MarkTheme Library catalog failed at %@ (%@/%ld): %@",
                  self.libraryStore.rootURL.path, libraryError.domain,
                  (long)libraryError.code, libraryError.localizedDescription);
        }
    }

    BOOL runtimeAvailable = base.runtimeAvailable;
    BOOL runtimeEnabled = base.runtimeEnabled;
    uint64_t runtimeSequence = base.runtimeSequence;
    NSString *activeThemeIdentifier = base.activeThemeIdentifier;
    NSString *activeRevisionIdentifier = base.activeRevisionIdentifier;
    NSString *activeGenerationIdentifier = base.activeGenerationIdentifier;
    NSString *previousGenerationIdentifier =
        base.previousGenerationIdentifier;
    NSUInteger runtimeResourceCount = base.runtimeResourceCount;
    NSArray<NSString *> *runtimeModuleIDs = base.runtimeModuleIDs;
    MTThemeComponentSelection *activeComponentSelection =
        base.activeComponentSelection;
    MTThemeMixSelection *activeMixSelection = base.activeMixSelection;
    NSError *runtimeError = base.runtimeError;
    if ((refreshScope & MTManagerRefreshScopeRuntime) != 0) {
        runtimeError = nil;
        MTRuntimeSnapshot *runtimeSnapshot =
            [self.snapshotLoader loadSnapshotWithError:&runtimeError];
        MTRuntimeState *state = runtimeSnapshot.state;
        MTGenerationDescriptor *descriptor =
            runtimeSnapshot.generation.descriptor;
        runtimeAvailable = runtimeSnapshot != nil;
        runtimeEnabled = runtimeSnapshot != nil && state.isRuntimeEnabled &&
            descriptor != nil;
        runtimeSequence = state.sequence;
        activeThemeIdentifier = runtimeEnabled ? descriptor.themeID : nil;
        activeRevisionIdentifier = runtimeEnabled
            ? descriptor.libraryRevisionIdentifier : nil;
        activeGenerationIdentifier = runtimeEnabled
            ? descriptor.generationIdentifier : nil;
        previousGenerationIdentifier = state.previousGenerationIdentifier;
        runtimeResourceCount = runtimeEnabled ? descriptor.resourceCount : 0;
        runtimeModuleIDs = runtimeEnabled ? descriptor.moduleIDs : @[];
        activeComponentSelection = nil;
        activeMixSelection = nil;
    }

    NSDictionary<NSString *, MTThemeLibraryThemeSummary *> *themeIndex =
        themes == base.themes ? base.themeIndex
                              : MTManagerBuildThemeIndex(themes);
    if (runtimeEnabled && activeGenerationIdentifier.length > 0) {
        MTThemeLibraryThemeSummary *activeTheme =
            themeIndex[activeThemeIdentifier];
        MTThemeLibraryRevisionSummary *activeRevision = nil;
        for (MTThemeLibraryRevisionSummary *candidate in
                activeTheme.revisionHistory) {
            if ([candidate.revisionIdentifier
                    isEqualToString:activeRevisionIdentifier]) {
                activeRevision = candidate;
                break;
            }
        }
        MTThemeComponentCatalog *activeCatalog = activeRevision == nil
            ? nil : [MTThemeComponentCatalog
                catalogForManifest:activeRevision.manifest error:NULL];
        activeComponentSelection = activeCatalog == nil ? nil :
            [self.componentSelectionStore
                appliedSelectionForGenerationIdentifier:
                    activeGenerationIdentifier
                themeIdentifier:activeThemeIdentifier
                revisionIdentifier:activeRevisionIdentifier
                catalog:activeCatalog];
        activeMixSelection = [self.componentSelectionStore
            appliedMixSelectionForGenerationIdentifier:
                activeGenerationIdentifier
            baseThemeIdentifier:activeThemeIdentifier
            baseRevisionIdentifier:activeRevisionIdentifier];
    } else {
        activeComponentSelection = nil;
        activeMixSelection = nil;
    }
    // Match MarkFont's cold-start selection contract: the first complete
    // Library + Runtime projection starts from the theme that is actually in
    // effect. The initial nil selection is controller bootstrap state, not a
    // user choice of the stock theme. Once the initial snapshot becomes idle,
    // later nil selections remain explicit stock-theme choices and survive
    // foreground/runtime refreshes.
    BOOL resolvingInitialSelection =
        base.operation == MTManagerOperationReloading &&
        base.themes.count == 0 && base.selectedThemeIdentifier == nil;
    NSString *selection = selectedThemeIdentifier;
    if (resolvingInitialSelection && runtimeEnabled &&
        themeIndex[activeThemeIdentifier] != nil) {
        selection = activeThemeIdentifier;
    }
    BOOL selectionExists = selection.length == 0 ||
        themeIndex[selection] != nil;
    if (!selectionExists) {
        selection = nil;
        if (runtimeEnabled && themeIndex[activeThemeIdentifier] != nil) {
            selection = activeThemeIdentifier;
        }
    }

    return [[MTManagerSnapshot alloc]
        initWithThemes:themes
        themeIndex:themeIndex
        componentSelectionsByThemeIdentifier:componentSelections
        mixSelectionsByThemeIdentifier:mixSelections
        capabilityReportsByThemeIdentifier:capabilityReports
        availableFeatureIdentifiersByThemeIdentifier:availableFeatures
        selectedThemeIdentifier:selection
        operation:MTManagerOperationIdle
        libraryRefreshing:NO
        runtimeRefreshing:NO
        runtimeAvailable:runtimeAvailable
        runtimeControlAvailable:self.applyService != nil &&
            self.runtimeClient != nil
        runtimeEnabled:runtimeEnabled
        runtimeSequence:runtimeSequence
        activeThemeIdentifier:activeThemeIdentifier
        activeRevisionIdentifier:activeRevisionIdentifier
        activeGenerationIdentifier:activeGenerationIdentifier
        previousGenerationIdentifier:previousGenerationIdentifier
        runtimeResourceCount:runtimeResourceCount
        runtimeModuleIDs:runtimeModuleIDs
        activeComponentSelection:activeComponentSelection
        activeMixSelection:activeMixSelection
        libraryError:libraryError
        runtimeError:runtimeError
        operationError:nil];
}

- (void)startPendingRefreshIfPossible {
    NSAssert(NSThread.isMainThread, @"Manager refresh state is main-thread owned.");
    if (self.refreshInFlight || self.snapshot.isMutating ||
        self.pendingRefreshScope == MTManagerRefreshScopeNone) {
        return;
    }
    MTManagerRefreshScope scope = self.pendingRefreshScope;
    BOOL selectionSpecified = self.pendingSelectionSpecified;
    NSString *selection = selectionSpecified
        ? self.pendingRefreshSelection
        : self.snapshot.selectedThemeIdentifier;
    self.pendingRefreshScope = MTManagerRefreshScopeNone;
    self.pendingSelectionSpecified = NO;
    self.pendingRefreshSelection = nil;
    self.refreshInFlight = YES;
    self.activeRefreshScope = scope;
    self.activeRefreshSelection = selection;
    os_log_t performanceLog = MTManagerPerformanceLog();
    os_signpost_id_t refreshSignpost =
        os_signpost_id_generate(performanceLog);
    os_signpost_interval_begin(performanceLog, refreshSignpost,
        "Manager Refresh", "scope=%lu current_themes=%lu",
        (unsigned long)scope, (unsigned long)self.snapshot.themes.count);

    MTManagerSnapshot *base = self.snapshot;
    NSString *loadingSelection = selection;
    if (selectionSpecified && selection.length > 0 &&
        [base themeWithIdentifier:selection] == nil) {
        loadingSelection = base.selectedThemeIdentifier;
    }
    MTManagerSnapshot *loadingBase = [base
        snapshotWithSelectedThemeIdentifier:loadingSelection];
    [self publishSnapshot:[loadingBase
        snapshotRefreshingLibrary:
            (scope & MTManagerRefreshScopeLibrary) != 0
        runtime:(scope & MTManagerRefreshScopeRuntime) != 0]];
    __weak typeof(self) weakSelf = self;
    [self.workerQueue addOperationWithBlock:^{
        typeof(self) self = weakSelf;
        if (self == nil) return;
        __block MTManagerSnapshot *loaded = [self loadSnapshotFromSnapshot:base
            selectingThemeIdentifier:selection refreshScope:scope];
        [[NSOperationQueue mainQueue] addOperationWithBlock:^{
            typeof(self) self = weakSelf;
            if (self == nil) return;
            NSString *liveSelection = self.snapshot.selectedThemeIdentifier;
            BOOL selectionChangedWhileLoading =
                !(liveSelection == loadingSelection ||
                  [liveSelection isEqualToString:loadingSelection]);
            if (selectionChangedWhileLoading &&
                (liveSelection.length == 0 ||
                 [loaded themeWithIdentifier:liveSelection] != nil)) {
                loaded = [loaded
                    snapshotWithSelectedThemeIdentifier:liveSelection];
            }
            self.refreshInFlight = NO;
            self.activeRefreshScope = MTManagerRefreshScopeNone;
            self.activeRefreshSelection = nil;
            [self publishSnapshot:loaded];
            os_signpost_interval_end(performanceLog, refreshSignpost,
                "Manager Refresh", "themes=%lu library_error=%d runtime_error=%d",
                (unsigned long)loaded.themes.count,
                loaded.libraryError != nil, loaded.runtimeError != nil);
            [self startPendingRefreshIfPossible];
        }];
    }];
}

- (void)requestRefreshScope:(MTManagerRefreshScope)scope
    selectingThemeIdentifier:(NSString *)themeIdentifier
    selectionSpecified:(BOOL)selectionSpecified
    invalidatesInFlightLibrary:(BOOL)invalidatesInFlightLibrary {
    void (^requestBlock)(void) = ^{
        MTManagerRefreshScope requestedScope = scope;
        if (self.refreshInFlight) {
            requestedScope &= ~self.activeRefreshScope;
            BOOL sameSelection = self.activeRefreshSelection == themeIdentifier ||
                [self.activeRefreshSelection isEqualToString:themeIdentifier];
            if (selectionSpecified &&
                (invalidatesInFlightLibrary || !sameSelection)) {
                requestedScope |= MTManagerRefreshScopeLibrary;
            }
        }
        self.pendingRefreshScope |= requestedScope;
        if (selectionSpecified &&
            (!self.refreshInFlight || invalidatesInFlightLibrary ||
             !(self.activeRefreshSelection == themeIdentifier ||
               [self.activeRefreshSelection isEqualToString:themeIdentifier]))) {
            self.pendingSelectionSpecified = YES;
            self.pendingRefreshSelection = [themeIdentifier copy];
        }
        [self startPendingRefreshIfPossible];
    };
    if (NSThread.isMainThread) {
        requestBlock();
    } else {
        dispatch_async(dispatch_get_main_queue(), requestBlock);
    }
}

- (void)reload {
    [self requestRefreshScope:
        MTManagerRefreshScopeLibrary | MTManagerRefreshScopeRuntime
        selectingThemeIdentifier:nil
        selectionSpecified:NO
        invalidatesInFlightLibrary:NO];
}

- (void)refreshRuntime {
    [self requestRefreshScope:MTManagerRefreshScopeRuntime
        selectingThemeIdentifier:nil
        selectionSpecified:NO
        invalidatesInFlightLibrary:NO];
}

- (void)reloadSelectingThemeIdentifier:(NSString *)themeIdentifier {
    [self requestRefreshScope:MTManagerRefreshScopeLibrary
        selectingThemeIdentifier:themeIdentifier
        selectionSpecified:YES
        invalidatesInFlightLibrary:YES];
}

- (void)selectThemeIdentifier:(NSString *)themeIdentifier {
    void (^selectionBlock)(void) = ^{
        if (themeIdentifier.length > 0 &&
            [self.snapshot themeWithIdentifier:themeIdentifier] == nil) {
            return;
        }
        [self publishSnapshot:[self.snapshot
            snapshotWithSelectedThemeIdentifier:themeIdentifier]];
    };
    if (NSThread.isMainThread) {
        selectionBlock();
    } else {
        dispatch_async(dispatch_get_main_queue(), selectionBlock);
    }
}

- (void)updateComponentSelectionForThemeIdentifier:
        (NSString *)themeIdentifier
    mutation:(MTManagerSelectionMutation)mutation
    completion:(MTManagerOperationCompletion)completion {
    void (^updateBlock)(void) = ^{
        MTManagerSnapshot *snapshot = self.snapshot;
        if (snapshot.isMutating || self.refreshInFlight) {
            NSError *error = MTManagerError(MTManagerControllerErrorBusy,
                @"Another Manager operation is still running.");
            if (completion != nil) completion(NO, error);
            return;
        }
        MTThemeLibraryThemeSummary *theme = [snapshot
            themeWithIdentifier:themeIdentifier];
        if (theme == nil) {
            NSError *error = MTManagerError(
                MTManagerControllerErrorInvalidSelection,
                @"The requested theme is absent from the Manager Library snapshot.");
            if (completion != nil) completion(NO, error);
            return;
        }

        NSError *selectionError = nil;
        MTThemeComponentCatalog *catalog = [MTThemeComponentCatalog
            catalogForManifest:theme.currentRevision.manifest
            error:&selectionError];
        MTThemeComponentSelection *current = catalog == nil ? nil :
            [snapshot componentSelectionForThemeIdentifier:themeIdentifier];
        if (current == nil && catalog != nil) {
            current = [self.componentSelectionStore selectionForCatalog:catalog];
        }
        MTThemeComponentSelection *updated =
            current == nil || catalog == nil ? nil :
            mutation(current, catalog, &selectionError);
        if (updated == nil) {
            NSError *error = selectionError ?: MTManagerError(
                MTManagerControllerErrorInvalidSelection,
                @"The requested theme component choice is unavailable.");
            if (completion != nil) completion(NO, error);
            return;
        }
        if ([updated isEqual:current]) {
            if (completion != nil) completion(YES, nil);
            return;
        }
        if (![self.componentSelectionStore saveSelection:updated
                                               forCatalog:catalog
                                                    error:&selectionError]) {
            if (completion != nil) completion(NO, selectionError);
            return;
        }
        NSMutableDictionary<NSString *, MTThemeComponentSelection *> *selections =
            [snapshot.componentSelectionsByThemeIdentifier mutableCopy];
        selections[themeIdentifier] = updated;
        NSSet<NSString *> *updatedAvailableFeatures =
            MTThemeRuntimeApplicableFeatureIdentifiersForSelectionUsingReport(
                theme.currentRevision.manifest, updated,
                snapshot.capabilityReportsByThemeIdentifier[themeIdentifier]);
        NSMutableDictionary<NSString *, NSSet<NSString *> *> *availableFeatures =
            [snapshot.availableFeatureIdentifiersByThemeIdentifier mutableCopy];
        availableFeatures[themeIdentifier] = updatedAvailableFeatures;
        NSDictionary<NSString *, MTThemeMixSelection *> *mixes =
            MTManagerBuildMixSelections(snapshot.themes, [selections copy], @{
                themeIdentifier : updatedAvailableFeatures,
            }, self.componentSelectionStore);
        [self publishSnapshot:[snapshot
            snapshotWithComponentSelections:[selections copy]
            availableFeatureIdentifiersByThemeIdentifier:
                [availableFeatures copy]
            mixSelections:mixes
            operationError:nil]];
        if (completion != nil) completion(YES, nil);
    };
    if (NSThread.isMainThread) {
        updateBlock();
    } else {
        dispatch_async(dispatch_get_main_queue(), updateBlock);
    }
}

- (void)setComponentIdentifier:(NSString *)componentIdentifier
                        enabled:(BOOL)enabled
             forThemeIdentifier:(NSString *)themeIdentifier
                     completion:
                         (MTManagerOperationCompletion)completion {
    [self updateComponentSelectionForThemeIdentifier:themeIdentifier
        mutation:^MTThemeComponentSelection *(
            MTThemeComponentSelection *selection,
            MTThemeComponentCatalog *catalog,
            NSError **error) {
        return [selection
            selectionBySettingComponentIdentifier:componentIdentifier
            enabled:enabled
            catalog:catalog
            error:error];
    } completion:completion];
}

- (void)selectVariantIdentifier:(NSString *)variantIdentifier
             forGroupIdentifier:(NSString *)groupIdentifier
                themeIdentifier:(NSString *)themeIdentifier
                     completion:
                         (MTManagerOperationCompletion)completion {
    [self updateComponentSelectionForThemeIdentifier:themeIdentifier
        mutation:^MTThemeComponentSelection *(
            MTThemeComponentSelection *selection,
            MTThemeComponentCatalog *catalog,
            NSError **error) {
        return [selection
            selectionBySelectingVariantIdentifier:variantIdentifier
            forGroupIdentifier:groupIdentifier
            catalog:catalog
            error:error];
    } completion:completion];
}

- (void)updateMixSelectionForBaseThemeIdentifier:
        (NSString *)baseThemeIdentifier
    mutation:(MTManagerMixMutation)mutation
    completion:(MTManagerOperationCompletion)completion {
    void (^updateBlock)(void) = ^{
        MTManagerSnapshot *snapshot = self.snapshot;
        if (snapshot.isMutating || self.refreshInFlight) {
            NSError *error = MTManagerError(MTManagerControllerErrorBusy,
                @"Another Manager operation is still running.");
            if (completion != nil) completion(NO, error);
            return;
        }
        MTThemeMixSelection *current = [snapshot
            mixSelectionForThemeIdentifier:baseThemeIdentifier];
        if (current == nil ||
            [snapshot themeWithIdentifier:baseThemeIdentifier] == nil) {
            NSError *error = MTManagerError(
                MTManagerControllerErrorInvalidSelection,
                @"The requested base theme has no current mix configuration.");
            if (completion != nil) completion(NO, error);
            return;
        }
        NSDictionary<NSString *, NSString *> *revisions =
            MTManagerCurrentRevisionIdentifiers(snapshot.themes);
        NSError *selectionError = nil;
        MTThemeMixSelection *updated = mutation(current, revisions,
            snapshot.componentSelectionsByThemeIdentifier, &selectionError);
        if (updated == nil) {
            NSError *error = selectionError ?: MTManagerError(
                MTManagerControllerErrorInvalidSelection,
                @"The requested theme feature configuration is unavailable.");
            if (completion != nil) completion(NO, error);
            return;
        }
        if ([updated isEqual:current]) {
            if (completion != nil) completion(YES, nil);
            return;
        }
        if (![self.componentSelectionStore saveMixSelection:updated
                                                      error:&selectionError]) {
            if (completion != nil) completion(NO, selectionError);
            return;
        }
        NSMutableDictionary<NSString *, MTThemeMixSelection *> *mixes =
            [snapshot.mixSelectionsByThemeIdentifier mutableCopy];
        mixes[baseThemeIdentifier] = updated;
        [self publishSnapshot:[snapshot
            snapshotWithComponentSelections:
                snapshot.componentSelectionsByThemeIdentifier
            availableFeatureIdentifiersByThemeIdentifier:
                snapshot.availableFeatureIdentifiersByThemeIdentifier
            mixSelections:[mixes copy]
            operationError:nil]];
        if (completion != nil) completion(YES, nil);
    };
    if (NSThread.isMainThread) {
        updateBlock();
    } else {
        dispatch_async(dispatch_get_main_queue(), updateBlock);
    }
}

- (void)setFeatureIdentifier:(NSString *)featureIdentifier
                       enabled:(BOOL)enabled
        forBaseThemeIdentifier:(NSString *)baseThemeIdentifier
                    completion:
                        (MTManagerOperationCompletion)completion {
    [self updateMixSelectionForBaseThemeIdentifier:baseThemeIdentifier
        mutation:^MTThemeMixSelection *(
            MTThemeMixSelection *selection,
            NSDictionary<NSString *,NSString *> *revisions,
            NSDictionary<NSString *,MTThemeComponentSelection *> *components,
            NSError **error) {
        (void)revisions;
        (void)components;
        BOOL knownFeature = MTThemeFeatureSupportsMixing(featureIdentifier);
        NSString *sourceIdentifier = [selection
            sourceThemeIdentifierForFeatureIdentifier:featureIdentifier];
        if (!knownFeature || (enabled &&
            !MTManagerThemeSupportsFeature(
                self.snapshot, sourceIdentifier, featureIdentifier))) {
            if (error != NULL) *error = MTManagerError(
                MTManagerControllerErrorInvalidSelection,
                @"Choose a theme that supports this feature before enabling it.");
            return nil;
        }
        return [selection selectionBySettingFeatureIdentifier:featureIdentifier
                                                       enabled:enabled
                                                         error:error];
    } completion:completion];
}

- (void)setSourceThemeIdentifier:(NSString *)sourceThemeIdentifier
              forFeatureIdentifier:(NSString *)featureIdentifier
            baseThemeIdentifier:(NSString *)baseThemeIdentifier
                      completion:
                          (MTManagerOperationCompletion)completion {
    [self updateMixSelectionForBaseThemeIdentifier:baseThemeIdentifier
        mutation:^MTThemeMixSelection *(
            MTThemeMixSelection *selection,
            NSDictionary<NSString *,NSString *> *revisions,
            NSDictionary<NSString *,MTThemeComponentSelection *> *components,
            NSError **error) {
        if (!MTManagerThemeSupportsFeature(
                self.snapshot, sourceThemeIdentifier,
                featureIdentifier)) {
            if (error != NULL) *error = MTManagerError(
                MTManagerControllerErrorInvalidSelection,
                @"The selected source theme does not support this feature.");
            return nil;
        }
        MTThemeMixSelection *updated = [selection
            selectionBySettingSourceThemeIdentifier:sourceThemeIdentifier
            forFeatureIdentifier:featureIdentifier
            revisionIdentifiersByThemeIdentifier:revisions
            componentSelectionsByThemeIdentifier:components
            error:error];
        return [updated selectionBySettingFeatureIdentifier:featureIdentifier
                                                     enabled:YES
                                                       error:error];
    } completion:completion];
}

- (void)performOperation:(MTManagerOperation)operation
                 mutation:(MTManagerMutation)mutation
    refreshLibraryAfterMutation:(BOOL)refreshLibrary
               completion:(MTManagerOperationCompletion)completion {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.snapshot.isMutating || self.refreshInFlight) {
            NSError *error = MTManagerError(MTManagerControllerErrorBusy,
                @"Another Manager operation is still running.");
            if (completion != nil) completion(NO, error);
            return;
        }
        NSString *selection = self.snapshot.selectedThemeIdentifier;
        MTManagerSnapshot *base = self.snapshot;
        [self publishSnapshot:[self.snapshot snapshotWithOperation:operation
                                                    operationError:nil]];
        __weak typeof(self) weakSelf = self;
        [self.workerQueue addOperationWithBlock:^{
            typeof(self) self = weakSelf;
            if (self == nil) return;
            NSError *operationError = nil;
            BOOL success = mutation(&operationError);
            MTManagerRefreshScope scope = MTManagerRefreshScopeRuntime |
                (refreshLibrary ? MTManagerRefreshScopeLibrary
                                : MTManagerRefreshScopeNone);
            MTManagerSnapshot *snapshot = [self loadSnapshotFromSnapshot:base
                selectingThemeIdentifier:selection refreshScope:scope];
            if (!success) {
                snapshot = [snapshot snapshotWithOperation:MTManagerOperationIdle
                                            operationError:operationError];
            }
            [[NSOperationQueue mainQueue] addOperationWithBlock:^{
                typeof(self) self = weakSelf;
                if (self == nil) return;
                [self publishSnapshot:snapshot];
                if (completion != nil) completion(success, operationError);
                [self startPendingRefreshIfPossible];
            }];
        }];
    });
}

- (void)applySelectionWithCompletion:
        (MTManagerApplyCompletion)completion {
    if (!NSThread.isMainThread) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf applySelectionWithCompletion:completion];
        });
        return;
    }
    NSString *selection = self.snapshot.selectedThemeIdentifier;
    MTThemeComponentSelection *componentSelection = selection.length == 0
        ? nil : [self.snapshot
            componentSelectionForThemeIdentifier:selection];
    MTThemeMixSelection *mixSelection = selection.length == 0
        ? nil : [self.snapshot mixSelectionForThemeIdentifier:selection];
    if (selection.length > 0 &&
        (componentSelection == nil || mixSelection == nil)) {
        if (completion != nil) {
            completion(NO, NO, MTManagerError(
                MTManagerControllerErrorInvalidSelection,
                @"The selected theme has no valid component configuration."));
        }
        return;
    }
    MTManagerOperation operation = selection.length > 0
        ? MTManagerOperationApplying : MTManagerOperationDisabling;
    __block BOOL reloadRequired = NO;
    __weak typeof(self) weakSelf = self;
    [self performOperation:operation mutation:^BOOL(NSError **error) {
        typeof(self) self = weakSelf;
        if (self == nil) return NO;
        if (selection.length == 0) {
            if (self.runtimeClient == nil) {
                if (error != NULL) *error = MTManagerError(
                    MTManagerControllerErrorUnavailable,
                    @"Runtime control is unavailable on this platform.");
                return NO;
            }
            MTRuntimeState *state = [self.runtimeClient disableWithError:error];
            return state != nil && !state.isRuntimeEnabled;
        }
        if (self.applyService == nil) {
            if (error != NULL) *error = MTManagerError(
                MTManagerControllerErrorUnavailable,
                @"Theme Apply is unavailable on this platform.");
            return NO;
        }
        MTThemeApplyResult *result = [self.applyService
            applyThemeMixSelection:mixSelection
            cancellationToken:nil
            error:error];
        if (result != nil) {
            NSError *recordError = nil;
            if (![self.componentSelectionStore
                    recordAppliedSelection:componentSelection
                    themeIdentifier:result.themeID
                    revisionIdentifier:result.libraryRevisionIdentifier
                    generationIdentifier:result.generationIdentifier
                    error:&recordError]) {
                NSLog(@"MarkTheme could not record applied component selection "
                      @"(%@/%ld): %@", recordError.domain,
                      (long)recordError.code,
                      recordError.localizedDescription);
            }
            recordError = nil;
            if (![self.componentSelectionStore
                    recordAppliedMixSelection:mixSelection
                    generationIdentifier:result.generationIdentifier
                    error:&recordError]) {
                NSLog(@"MarkTheme could not record applied mix selection "
                      @"(%@/%ld): %@", recordError.domain,
                      (long)recordError.code,
                      recordError.localizedDescription);
            }
        }
        reloadRequired = result != nil && !result.runtimeAcknowledged;
        return result != nil;
    } refreshLibraryAfterMutation:NO
      completion:^(BOOL success, NSError *error) {
        if (completion != nil) {
            completion(success, success && reloadRequired, error);
        }
    }];
}

- (void)reloadDesktopWithCompletion:
        (MTManagerOperationCompletion)completion {
    __weak typeof(self) weakSelf = self;
    [self performOperation:MTManagerOperationReloadingDesktop
                  mutation:^BOOL(NSError **error) {
        typeof(self) self = weakSelf;
        if (self.runtimeClient == nil) {
            if (error != NULL) *error = MTManagerError(
                MTManagerControllerErrorUnavailable,
                @"Desktop reload is unavailable on this platform.");
            return NO;
        }
        return [self.runtimeClient reloadDesktopWithError:error];
    } refreshLibraryAfterMutation:NO completion:completion];
}

- (void)rollbackRuntimeWithCompletion:
        (MTManagerOperationCompletion)completion {
    __weak typeof(self) weakSelf = self;
    [self performOperation:MTManagerOperationRollingBack
                  mutation:^BOOL(NSError **error) {
        typeof(self) self = weakSelf;
        if (self.runtimeClient == nil) {
            if (error != NULL) *error = MTManagerError(
                MTManagerControllerErrorUnavailable,
                @"Runtime rollback is unavailable on this platform.");
            return NO;
        }
        return [self.runtimeClient rollbackWithError:error] != nil;
    } refreshLibraryAfterMutation:NO completion:completion];
}

- (void)loadRevisionHistoryForThemeIdentifier:(NSString *)themeIdentifier
    completion:(MTManagerRevisionHistoryCompletion)completion {
    NSParameterAssert(completion != nil);
    void (^historyBlock)(void) = ^{
        MTThemeLibraryThemeSummary *theme = [self.snapshot
            themeWithIdentifier:themeIdentifier];
        if (theme == nil) {
            completion(nil, MTManagerError(
                MTManagerControllerErrorInvalidSelection,
                @"The requested theme is absent from the Manager Library snapshot."));
            return;
        }
        completion(theme.revisionHistory, nil);
    };
    if (NSThread.isMainThread) {
        historyBlock();
    } else {
        dispatch_async(dispatch_get_main_queue(), historyBlock);
    }
}

- (void)switchThemeIdentifier:(NSString *)themeIdentifier
           toRevisionIdentifier:(NSString *)revisionIdentifier
                     completion:(MTManagerOperationCompletion)completion {
    MTThemeLibraryStore *store = self.libraryStore;
    [self performOperation:MTManagerOperationSwitchingRevision
                  mutation:^BOOL(NSError **error) {
        return [store switchCurrentRevisionForThemeID:themeIdentifier
            revisionIdentifier:revisionIdentifier
            cancellationToken:nil
            error:error] != nil;
    } refreshLibraryAfterMutation:YES completion:completion];
}

- (void)removeRevisionIdentifier:(NSString *)revisionIdentifier
              fromThemeIdentifier:(NSString *)themeIdentifier
                        completion:(MTManagerOperationCompletion)completion {
    MTThemeLibraryStore *store = self.libraryStore;
    [self performOperation:MTManagerOperationRemovingRevision
                  mutation:^BOOL(NSError **error) {
        return [store removeRevisionForThemeID:themeIdentifier
            revisionIdentifier:revisionIdentifier
            cancellationToken:nil
            error:error];
    } refreshLibraryAfterMutation:YES completion:completion];
}

- (void)removeThemeIdentifier:(NSString *)themeIdentifier
                     completion:(MTManagerOperationCompletion)completion {
    if (!NSThread.isMainThread) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf removeThemeIdentifier:themeIdentifier
                                 completion:completion];
        });
        return;
    }
    if (![themeIdentifier isKindOfClass:NSString.class] ||
        themeIdentifier.length == 0) {
        if (completion != nil) {
            completion(NO, MTManagerError(
                MTManagerControllerErrorInvalidSelection,
                @"A theme identifier is required to remove a theme."));
        }
        return;
    }
    if ([self.snapshot runtimeUsesThemeIdentifier:themeIdentifier]) {
        if (completion != nil) {
            completion(NO, MTManagerError(
                MTManagerControllerErrorInvalidSelection,
                @"A theme used by the active mix must be replaced or disabled before deletion."));
        }
        return;
    }
    // A deleted theme can no longer be the selection. Fall back to the stock
    // theme before the mutation so the refreshed snapshot cannot carry an
    // identifier that no longer exists in the Library.
    if ([self.snapshot.selectedThemeIdentifier
            isEqualToString:themeIdentifier]) {
        [self selectThemeIdentifier:nil];
    }
    MTThemeLibraryStore *store = self.libraryStore;
    [self performOperation:MTManagerOperationRemovingTheme
                  mutation:^BOOL(NSError **error) {
        return [store removeThemeWithID:themeIdentifier
                      cancellationToken:nil
                                  error:error];
    } refreshLibraryAfterMutation:YES completion:completion];
}

@end
