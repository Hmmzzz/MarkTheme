#import "MTThemePreviewRepository.h"

#import <os/signpost.h>

#import "MTThemeLibraryCatalog.h"
#import "MTThemeLibraryStore.h"
#import "MTThemePreviewProvider.h"
#import "MTImportSession.h"

static const NSUInteger MTThemePreviewMemoryCostLimit = 32 * 1024 * 1024;
static const NSUInteger MTThemePreviewPresentationCostLimit = 12 * 1024 * 1024;
static const NSUInteger MTThemePreviewPresentationCountLimit = 8;

static NSUInteger MTThemePreviewImagesCost(NSArray<UIImage *> *images) {
    NSUInteger cost = 1;
    for (UIImage *image in images) {
        CGImageRef cgImage = image.CGImage;
        if (cgImage != NULL) {
            cost += CGImageGetBytesPerRow(cgImage) * CGImageGetHeight(cgImage);
        }
    }
    return cost;
}

static os_log_t MTThemePreviewPerformanceLog(void) {
    static os_log_t log;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        log = os_log_create("com.hmmzzz.marktheme", "PreviewPerformance");
    });
    return log;
}

@interface MTThemePreviewRequest ()
@property(nonatomic, assign, readwrite, getter=isCancelled) BOOL cancelled;
@property(nonatomic, assign) BOOL finished;
@property(nonatomic, copy, nullable) dispatch_block_t cancellationHandler;
- (void)finish;
@end

@implementation MTThemePreviewRequest

- (void)cancel {
    __block dispatch_block_t handler = nil;
    @synchronized (self) {
        if (self.cancelled || self.finished) return;
        self.cancelled = YES;
        handler = self.cancellationHandler;
        self.cancellationHandler = nil;
    }
    if (handler == nil) return;
    if (NSThread.isMainThread) {
        handler();
    } else {
        dispatch_async(dispatch_get_main_queue(), handler);
    }
}

- (void)finish {
    @synchronized (self) {
        self.finished = YES;
        self.cancellationHandler = nil;
    }
}

@end

@interface MTThemePreviewWaiter : NSObject
@property(nonatomic, strong) MTThemePreviewRequest *request;
@property(nonatomic, copy) MTThemePreviewCompletion completion;
@end

@implementation MTThemePreviewWaiter
@end

@interface MTThemePreviewRepository ()
@property(nonatomic, strong) MTThemeLibraryStore *libraryStore;
@property(nonatomic, strong) NSCache<NSString *, NSArray<UIImage *> *> *cache;
@property(nonatomic, strong)
    NSMutableDictionary<NSString *, NSArray<UIImage *> *> *presentationCache;
@property(nonatomic, strong)
    NSMutableDictionary<NSString *, NSNumber *> *presentationCosts;
@property(nonatomic, strong) NSMutableOrderedSet<NSString *> *presentationLRU;
@property(nonatomic, assign) NSUInteger presentationCost;
@property(nonatomic, strong) NSOperationQueue *workerQueue;
@property(nonatomic, strong)
    NSMutableDictionary<NSString *, NSMutableArray<MTThemePreviewWaiter *> *> *
        waitersByKey;
@property(nonatomic, strong)
    NSMutableDictionary<NSString *, NSBlockOperation *> *operationsByKey;
@property(nonatomic, strong)
    NSMutableDictionary<NSString *, MTImportCancellationToken *> *
        cancellationTokensByKey;
@property(nonatomic, strong)
    NSMutableDictionary<NSString *, NSString *> *keyByThemeIdentifier;
@property(nonatomic, assign) NSUInteger cacheGeneration;
- (void)promoteOperation:(NSBlockOperation *)operation
               toPriority:(MTThemePreviewPriority)priority;
- (void)cancelRequest:(MTThemePreviewRequest *)request
                forKey:(NSString *)key;
- (void)discardRequestsForKey:(NSString *)key;
- (void)cachePresentationImages:(NSArray<UIImage *> *)images
                         forKey:(NSString *)key;
- (void)removePresentationImagesForKey:(NSString *)key;
@end

@implementation MTThemePreviewRepository

- (instancetype)initWithLibraryStore:(MTThemeLibraryStore *)libraryStore {
    NSParameterAssert(libraryStore != nil);
    self = [super init];
    if (self == nil) return nil;
    _libraryStore = libraryStore;
    _cache = [[NSCache alloc] init];
    _cache.name = @"com.hmmzzz.marktheme.theme-previews";
    _cache.countLimit = 32;
    _cache.totalCostLimit = MTThemePreviewMemoryCostLimit;
    _presentationCache = [NSMutableDictionary dictionary];
    _presentationCosts = [NSMutableDictionary dictionary];
    _presentationLRU = [NSMutableOrderedSet orderedSet];
    _workerQueue = [[NSOperationQueue alloc] init];
    _workerQueue.name = @"com.hmmzzz.marktheme.theme-preview-reader";
    _workerQueue.maxConcurrentOperationCount = 2;
    _workerQueue.qualityOfService = NSQualityOfServiceUtility;
    _waitersByKey = [NSMutableDictionary dictionary];
    _operationsByKey = [NSMutableDictionary dictionary];
    _cancellationTokensByKey = [NSMutableDictionary dictionary];
    _keyByThemeIdentifier = [NSMutableDictionary dictionary];
    [NSNotificationCenter.defaultCenter
        addObserver:self
           selector:@selector(applicationDidReceiveMemoryWarning:)
               name:UIApplicationDidReceiveMemoryWarningNotification
             object:nil];
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    for (MTImportCancellationToken *token in
            self.cancellationTokensByKey.allValues) {
        [token cancel];
    }
    [self.workerQueue cancelAllOperations];
}

- (NSString *)cacheKeyForThemeSummary:
        (MTThemeLibraryThemeSummary *)themeSummary {
    return [NSString stringWithFormat:@"%@|%@|%.2f",
        themeSummary.themeID,
        themeSummary.currentRevision.revisionIdentifier,
        UIScreen.mainScreen.scale];
}

- (NSString *)adoptCacheKeyForThemeSummary:
        (MTThemeLibraryThemeSummary *)themeSummary {
    NSAssert(NSThread.isMainThread, @"Preview repository state is main-thread owned.");
    NSString *key = [self cacheKeyForThemeSummary:themeSummary];
    NSString *previousKey = self.keyByThemeIdentifier[themeSummary.themeID];
    if (previousKey != nil && ![previousKey isEqualToString:key]) {
        [self.cache removeObjectForKey:previousKey];
        [self removePresentationImagesForKey:previousKey];
        [self discardRequestsForKey:previousKey];
    }
    self.keyByThemeIdentifier[themeSummary.themeID] = key;
    return key;
}

- (NSArray<UIImage *> *)cachedImagesForThemeSummary:
        (MTThemeLibraryThemeSummary *)themeSummary {
    NSParameterAssert(themeSummary != nil);
    NSString *key = [self adoptCacheKeyForThemeSummary:themeSummary];
    return self.presentationCache[key] ?: [self.cache objectForKey:key];
}

- (NSArray<UIImage *> *)presentationImagesForThemeSummary:
        (MTThemeLibraryThemeSummary *)themeSummary {
    NSParameterAssert(themeSummary != nil);
    NSString *key = [self adoptCacheKeyForThemeSummary:themeSummary];
    NSArray<UIImage *> *images =
        self.presentationCache[key] ?: [self.cache objectForKey:key];
    if (images != nil) [self cachePresentationImages:images forKey:key];
    return images;
}

- (MTThemePreviewRequest *)loadImagesForThemeSummary:
        (MTThemeLibraryThemeSummary *)themeSummary
                                         priority:(MTThemePreviewPriority)priority
                                       completion:(MTThemePreviewCompletion)completion {
    NSParameterAssert(themeSummary != nil);
    NSParameterAssert(completion != nil);
    NSAssert(NSThread.isMainThread, @"Preview requests originate on main.");
    NSString *key = [self adoptCacheKeyForThemeSummary:themeSummary];
    MTThemePreviewRequest *request = [[MTThemePreviewRequest alloc] init];
    NSArray<UIImage *> *cached =
        self.presentationCache[key] ?: [self.cache objectForKey:key];
    if (cached != nil) {
        [request finish];
        completion(cached);
        return request;
    }
    MTThemePreviewWaiter *waiter = [[MTThemePreviewWaiter alloc] init];
    waiter.request = request;
    waiter.completion = [completion copy];
    __weak typeof(self) weakSelf = self;
    __weak MTThemePreviewRequest *weakRequest = request;
    request.cancellationHandler = ^{
        [weakSelf cancelRequest:weakRequest forKey:key];
    };

    NSMutableArray<MTThemePreviewWaiter *> *waiting =
        self.waitersByKey[key];
    NSBlockOperation *existingOperation = self.operationsByKey[key];
    if (waiting != nil && existingOperation != nil) {
        [waiting addObject:waiter];
        [self promoteOperation:existingOperation toPriority:priority];
        return request;
    }
    self.waitersByKey[key] = [NSMutableArray arrayWithObject:waiter];

    MTThemeLibraryThemeSummary *capturedSummary = themeSummary;
    NSString *themeIdentifier = capturedSummary.themeID;
    NSUInteger cacheGeneration = self.cacheGeneration;
    MTThemeLibraryStore *store = self.libraryStore;
    MTImportCancellationToken *cancellationToken =
        [[MTImportCancellationToken alloc] init];
    self.cancellationTokensByKey[key] = cancellationToken;
    os_log_t performanceLog = MTThemePreviewPerformanceLog();
    os_signpost_id_t decodeSignpost =
        os_signpost_id_generate(performanceLog);
    __block __weak NSBlockOperation *weakOperation = nil;
    NSBlockOperation *operation = [NSBlockOperation blockOperationWithBlock:^{
        @autoreleasepool {
            NSBlockOperation *operation = weakOperation;
            if (operation == nil || operation.isCancelled) return;
            os_signpost_interval_begin(performanceLog, decodeSignpost,
                "Preview Decode", "priority=%ld",
                (long)priority);
            NSArray<UIImage *> *images =
                MTLoadThemePreviewImagesWithCancellation(
                    store, capturedSummary, cancellationToken, nil);
            NSUInteger cost = MTThemePreviewImagesCost(images);
            os_signpost_interval_end(performanceLog, decodeSignpost,
                "Preview Decode", "images=%lu cost=%lu",
                (unsigned long)images.count, (unsigned long)cost);
            if (operation.isCancelled || cancellationToken.isCancelled) return;
            [[NSOperationQueue mainQueue] addOperationWithBlock:^{
                typeof(self) self = weakSelf;
                if (self == nil) return;
                if (self.operationsByKey[key] != operation) return;
                [self.operationsByKey removeObjectForKey:key];
                [self.cancellationTokensByKey removeObjectForKey:key];
                if (cacheGeneration == self.cacheGeneration &&
                    [self.keyByThemeIdentifier[themeIdentifier]
                        isEqualToString:key]) {
                    [self.cache setObject:images forKey:key cost:cost];
                }
                NSArray<MTThemePreviewWaiter *> *waiters =
                    [self.waitersByKey[key] copy];
                [self.waitersByKey removeObjectForKey:key];
                for (MTThemePreviewWaiter *waiting in waiters) {
                    if (waiting.request.isCancelled) continue;
                    [waiting.request finish];
                    waiting.completion(images);
                }
            }];
        }
    }];
    weakOperation = operation;
    operation.qualityOfService = NSQualityOfServiceUtility;
    operation.queuePriority = NSOperationQueuePriorityVeryLow;
    self.operationsByKey[key] = operation;
    [self promoteOperation:operation toPriority:priority];
    [self.workerQueue addOperation:operation];
    return request;
}

- (void)promoteOperation:(NSBlockOperation *)operation
               toPriority:(MTThemePreviewPriority)priority {
    if (priority == MTThemePreviewPriorityHigh) {
        operation.qualityOfService = NSQualityOfServiceUserInitiated;
        operation.queuePriority = NSOperationQueuePriorityHigh;
    } else if (priority == MTThemePreviewPriorityNormal &&
               operation.queuePriority < NSOperationQueuePriorityNormal) {
        operation.qualityOfService = NSQualityOfServiceUserInitiated;
        operation.queuePriority = NSOperationQueuePriorityNormal;
    } else if (operation.queuePriority < NSOperationQueuePriorityLow) {
        operation.qualityOfService = NSQualityOfServiceUtility;
        operation.queuePriority = NSOperationQueuePriorityLow;
    }
}

- (void)cancelRequest:(MTThemePreviewRequest *)request
                forKey:(NSString *)key {
    NSAssert(NSThread.isMainThread, @"Preview repository state is main-thread owned.");
    if (request == nil) return;
    NSMutableArray<MTThemePreviewWaiter *> *waiting = self.waitersByKey[key];
    NSIndexSet *matches = [waiting indexesOfObjectsPassingTest:
        ^BOOL(MTThemePreviewWaiter *candidate, __unused NSUInteger index,
              __unused BOOL *stop) {
        return candidate.request == request;
    }];
    if (matches.count > 0) [waiting removeObjectsAtIndexes:matches];
    if (waiting.count > 0) return;
    [self.cancellationTokensByKey[key] cancel];
    [self.cancellationTokensByKey removeObjectForKey:key];
    [self.operationsByKey[key] cancel];
    [self.operationsByKey removeObjectForKey:key];
    [self.waitersByKey removeObjectForKey:key];
}

- (void)discardRequestsForKey:(NSString *)key {
    NSAssert(NSThread.isMainThread, @"Preview repository state is main-thread owned.");
    [self.cancellationTokensByKey[key] cancel];
    [self.cancellationTokensByKey removeObjectForKey:key];
    [self.operationsByKey[key] cancel];
    [self.operationsByKey removeObjectForKey:key];
    NSArray<MTThemePreviewWaiter *> *waiting = self.waitersByKey[key];
    [self.waitersByKey removeObjectForKey:key];
    for (MTThemePreviewWaiter *waiter in waiting) {
        [waiter.request finish];
    }
}

- (void)cachePresentationImages:(NSArray<UIImage *> *)images
                         forKey:(NSString *)key {
    NSAssert(NSThread.isMainThread,
             @"Presentation preview cache is main-thread owned.");
    [self removePresentationImagesForKey:key];
    NSUInteger cost = MTThemePreviewImagesCost(images);
    self.presentationCache[key] = images;
    self.presentationCosts[key] = @(cost);
    [self.presentationLRU addObject:key];
    self.presentationCost += cost;
    while (self.presentationLRU.count > MTThemePreviewPresentationCountLimit ||
           self.presentationCost > MTThemePreviewPresentationCostLimit) {
        NSString *oldestKey = self.presentationLRU.firstObject;
        if (oldestKey == nil) break;
        [self removePresentationImagesForKey:oldestKey];
    }
}

- (void)removePresentationImagesForKey:(NSString *)key {
    NSNumber *cost = self.presentationCosts[key];
    if (cost != nil) {
        self.presentationCost = cost.unsignedIntegerValue > self.presentationCost
            ? 0 : self.presentationCost - cost.unsignedIntegerValue;
    }
    [self.presentationCosts removeObjectForKey:key];
    [self.presentationCache removeObjectForKey:key];
    [self.presentationLRU removeObject:key];
}

- (void)removeAllCachedImages {
    void (^clearBlock)(void) = ^{
        self.cacheGeneration += 1;
        [self.cache removeAllObjects];
        [self.presentationCache removeAllObjects];
        [self.presentationCosts removeAllObjects];
        [self.presentationLRU removeAllObjects];
        self.presentationCost = 0;
        [self.keyByThemeIdentifier removeAllObjects];
    };
    if (NSThread.isMainThread) {
        clearBlock();
    } else {
        dispatch_async(dispatch_get_main_queue(), clearBlock);
    }
}

- (void)applicationDidReceiveMemoryWarning:(NSNotification *)notification {
    (void)notification;
    // NSCache remains the purgeable history/prefetch tier. Keep only the small
    // bounded presentation tier so currently selected/visible fixed previews
    // survive foreground recovery without pinning every imported theme.
    [self.cache removeAllObjects];
}

@end
