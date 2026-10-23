#import "MTPreferencesGraphicIconContractTests.h"

#include <string.h>

#import "adapters/MTPreferencesGraphicIconContract.h"

static NSUInteger MTGraphicIconAssertionCount;
static NSUInteger MTGraphicIconGlobalCallbackCount;

static void MTGraphicIconAssert(BOOL condition, NSString *message) {
    MTGraphicIconAssertionCount++;
    if (condition) return;
    fprintf(stderr, "FAIL: %s\n", message.UTF8String);
    exit(1);
}

static const void *MTGraphicIconBlockStorageIdentity(const void *block) {
    // Current Objective-C runtimes can report the heap class for a stack block.
    // Read only the compiler-created literal's ABI isa to distinguish storage.
    const void *identity = NULL;
    memcpy(&identity, block, sizeof(identity));
    return identity;
}

// Genuine compiler-created blocks exercise descriptor layouts with and without
// copy/dispose helpers. No test forges a block header or an invoke pointer.
static void (^const MTGraphicIconGlobalImage)(id) = ^(__unused id image) {
    MTGraphicIconGlobalCallbackCount++;
};
static void (^const MTGraphicIconGlobalImageAndError)(id, id) =
    ^(__unused id image, __unused id error) {
        MTGraphicIconGlobalCallbackCount++;
    };

@interface MTGraphicIconPretendBlock : NSObject
@property(nonatomic) NSUInteger kindOfClassCalls;
@end

@implementation MTGraphicIconPretendBlock
- (BOOL)isKindOfClass:(Class)candidate {
    (void)candidate;
    self.kindOfClassCalls++;
    return YES;
}
@end

static void MTGraphicIconTestStorageClasses(void) {
    __block NSUInteger callbackCount = 0;
    NSObject *capturedObject = [NSObject new];
    void (^__unsafe_unretained stackImage)(id) = ^(id image) {
        if (image == capturedObject) callbackCount++;
    };
    void (^__unsafe_unretained stackPair)(id, id) = ^(id image, id error) {
        if (image == capturedObject && error == nil) callbackCount++;
    };
    void (^heapImage)(id) = [stackImage copy];
    void (^heapPair)(id, id) = [stackPair copy];
    const void *globalStorage = MTGraphicIconBlockStorageIdentity(
        (__bridge const void *)MTGraphicIconGlobalImage);
    const void *stackStorage = MTGraphicIconBlockStorageIdentity(
        (__bridge const void *)stackImage);
    const void *heapStorage = MTGraphicIconBlockStorageIdentity(
        (__bridge const void *)heapImage);
    MTGraphicIconAssert(globalStorage != stackStorage && stackStorage != heapStorage &&
        globalStorage != heapStorage,
        @"Completion fixtures must contain distinct global, stack and heap blocks");
    MTGraphicIconAssert(MTGraphicIconBlockStorageIdentity((__bridge const void *)stackPair) == stackStorage &&
        MTGraphicIconBlockStorageIdentity((__bridge const void *)heapPair) == heapStorage &&
        MTGraphicIconBlockStorageIdentity((__bridge const void *)MTGraphicIconGlobalImageAndError) == globalStorage,
        @"Both callback arities must exercise real global, stack and heap storage");

    MTGraphicIconAssert(MTPreferencesGraphicIconCompletionShape(
        MTGraphicIconGlobalImage) == MTPreferencesGraphicCompletionImage,
        @"A global void(image) block must be recognized");
    // A direct block-to-id conversion can copy under ARC. Bridge through the
    // raw pointer so these calls actually inspect the live stack literal.
    MTGraphicIconAssert(MTPreferencesGraphicIconCompletionShape(
        (__bridge id)(__bridge const void *)stackImage) ==
        MTPreferencesGraphicCompletionImage,
        @"A stack void(image) block must be recognized before copying");
    MTGraphicIconAssert(MTPreferencesGraphicIconCompletionShape(heapImage) ==
        MTPreferencesGraphicCompletionImage,
        @"A heap void(image) block with copy/dispose helpers must be recognized");
    MTGraphicIconAssert(MTPreferencesGraphicIconCompletionShape(
        MTGraphicIconGlobalImageAndError) ==
            MTPreferencesGraphicCompletionImageAndError,
        @"A global void(image,error) block must be recognized");
    MTGraphicIconAssert(MTPreferencesGraphicIconCompletionShape(
        (__bridge id)(__bridge const void *)stackPair) ==
        MTPreferencesGraphicCompletionImageAndError,
        @"A stack void(image,error) block must be recognized before copying");
    MTGraphicIconAssert(MTPreferencesGraphicIconCompletionShape(heapPair) ==
        MTPreferencesGraphicCompletionImageAndError,
        @"A heap void(image,error) block must be recognized");
    void (^typedPair)(NSString *, NSError *) =
        ^(__unused NSString *image, __unused NSError *error) {};
    MTGraphicIconAssert(MTPreferencesGraphicIconCompletionShape(typedPair) ==
        MTPreferencesGraphicCompletionImageAndError,
        @"Named Objective-C object parameter encodings must remain supported");

    MTPreferencesGraphicImageTransform miss = ^id(__unused id image) {
        return nil;
    };
    void (^wrappedStack)(id) =
        MTPreferencesGraphicIconWrapCompletion(
            (__bridge id)(__bridge const void *)stackImage, miss);
    void (^wrappedHeap)(id, id) =
        MTPreferencesGraphicIconWrapCompletion(heapPair, miss);
    wrappedStack(capturedObject);
    wrappedHeap(capturedObject, nil);
    MTGraphicIconAssert(callbackCount == 2,
        @"Copied callbacks must preserve captured objects and by-reference state");
    MTGraphicIconGlobalCallbackCount = 0;
    void (^wrappedGlobal)(id) = MTPreferencesGraphicIconWrapCompletion(
        MTGraphicIconGlobalImage, miss);
    void (^wrappedGlobalPair)(id, id) = MTPreferencesGraphicIconWrapCompletion(
        MTGraphicIconGlobalImageAndError, miss);
    wrappedGlobal(nil);
    wrappedGlobalPair(nil, nil);
    MTGraphicIconAssert(MTGraphicIconGlobalCallbackCount == 2,
        @"Global callbacks must remain callable after wrapping");
}

static void MTGraphicIconTestUnsupportedCompletions(void) {
    __block NSUInteger transforms = 0;
    MTPreferencesGraphicImageTransform transform = ^id(id image) {
        transforms++;
        return image;
    };
    MTGraphicIconAssert(MTPreferencesGraphicIconCompletionShape(nil) ==
        MTPreferencesGraphicCompletionUnsupported &&
        MTPreferencesGraphicIconWrapCompletion(nil, transform) == nil,
        @"A missing native completion must remain missing");
    MTGraphicIconPretendBlock *pretendBlock = [MTGraphicIconPretendBlock new];
    NSArray *unsupported = @[
        [NSObject new], @"not a block", @42, pretendBlock,
        ^{},
        ^id(id image) { return image; },
        ^(__unused NSInteger image) {},
        ^(__unused Class image) {},
        ^(__unused id image, __unused NSError **error) {},
        ^(__unused id image, __unused id error, __unused id context) {},
        ^(__unused void (^image)(void)) {},
        ^NSRange(__unused id image) { return NSMakeRange(0, 1); },
    ];
    for (id completion in unsupported) {
        MTGraphicIconAssert(MTPreferencesGraphicIconCompletionShape(completion) ==
            MTPreferencesGraphicCompletionUnsupported &&
            MTPreferencesGraphicIconWrapCompletion(completion, transform) == completion,
            @"An unknown callback shape or non-block object must pass through by identity");
    }
    MTGraphicIconAssert(pretendBlock.kindOfClassCalls == 0 && transforms == 0,
        @"Block validation must not trust overridable class claims or run the transform");
}

static void MTGraphicIconTestImageCompletion(void) {
    NSObject *original = [NSObject new];
    NSObject *replacement = [NSObject new];
    NSMutableArray *received = [NSMutableArray array];
    NSMutableArray *order = [NSMutableArray array];
    __block NSUInteger transforms = 0;
    void (^callback)(id) = ^(id image) {
        [order addObject:@"callback"];
        [received addObject:image ?: NSNull.null];
    };
    void (^wrapped)(id) = MTPreferencesGraphicIconWrapCompletion(callback,
        ^id(id image) {
            transforms++;
            [order addObject:@"transform"];
            MTGraphicIconAssert(image == original,
                @"The image transform must receive the native image by identity");
            return transforms == 1 ? replacement : nil;
        });
    MTGraphicIconAssert(received.count == 0 && transforms == 0,
        @"Wrapping must not synthesize an early callback or image request");
    wrapped(original);
    wrapped(nil);
    wrapped(original);
    MTGraphicIconAssert(received.count == 3 && received[0] == replacement &&
        received[1] == NSNull.null && received[2] == original && transforms == 2,
        @"Image callbacks must preserve nil, use the replacement and fall back on a miss");
    MTGraphicIconAssert([order isEqualToArray:@[
        @"transform", @"callback", @"callback", @"transform", @"callback"]],
        @"Each native invocation must forward once, after its optional transform");
}

static void MTGraphicIconTestImageAndErrorCompletion(void) {
    NSObject *original = [NSObject new];
    NSObject *replacement = [NSObject new];
    NSError *failure = [NSError errorWithDomain:@"MTGraphicIconTests" code:7 userInfo:nil];
    NSMutableArray *images = [NSMutableArray array];
    NSMutableArray *errors = [NSMutableArray array];
    __block NSUInteger transforms = 0;
    void (^callback)(id, id) = ^(id image, id error) {
        [images addObject:image ?: NSNull.null];
        [errors addObject:error ?: NSNull.null];
    };
    void (^wrapped)(id, id) = MTPreferencesGraphicIconWrapCompletion(callback,
        ^id(id image) {
            transforms++;
            MTGraphicIconAssert(image == original,
                @"A successful pair callback must transform the native image");
            return transforms == 1 ? replacement : nil;
        });
    wrapped(original, nil);
    wrapped(nil, nil);
    wrapped(original, failure);
    wrapped(nil, failure);
    wrapped(original, nil);
    MTGraphicIconAssert(images.count == 5 && errors.count == 5 && transforms == 2,
        @"Nil images and errors must bypass transformation without dropping callbacks");
    MTGraphicIconAssert(images[0] == replacement && images[1] == NSNull.null &&
        images[2] == original && images[3] == NSNull.null && images[4] == original,
        @"Pair callbacks must preserve native nil, error images and resolver misses");
    MTGraphicIconAssert(errors[0] == NSNull.null && errors[1] == NSNull.null &&
        errors[2] == failure && errors[3] == failure && errors[4] == NSNull.null,
        @"Pair callbacks must preserve each native error by identity");
}

static void MTGraphicIconTestAsyncLifetime(MTPreferencesGraphicCompletionShape shape) {
    static char queueKey;
    dispatch_queue_t queue = dispatch_queue_create("marktheme.graphic-icon-contract", NULL);
    dispatch_queue_set_specific(queue, &queueKey, &queueKey, NULL);
    NSObject *original = [NSObject new];
    NSError *failure = [NSError errorWithDomain:@"MTGraphicIconTests" code:8 userInfo:nil];
    __weak NSObject *weakCallbackContext;
    __weak NSObject *weakTransformContext;
    __block id pendingCompletion;
    __block NSUInteger callbacks = 0;
    __block NSUInteger transforms = 0;
    __block BOOL validQueue = YES;
    __block BOOL validDelivery = YES;
    @autoreleasepool {
        NSObject *callbackContext = [NSObject new];
        NSObject *transformContext = [NSObject new];
        weakCallbackContext = callbackContext;
        weakTransformContext = transformContext;
        void (^__unsafe_unretained imageCallback)(id) = ^(id image) {
            callbacks++;
            validQueue &= dispatch_get_specific(&queueKey) == &queueKey;
            validDelivery &= callbackContext == weakCallbackContext &&
                (callbacks == 1 ? image == weakTransformContext : image == nil);
        };
        void (^__unsafe_unretained pairCallback)(id, id) = ^(id image, id error) {
            callbacks++;
            validQueue &= dispatch_get_specific(&queueKey) == &queueKey;
            validDelivery &= callbackContext == weakCallbackContext &&
                (callbacks == 1 ? image == weakTransformContext && error == nil :
                    image == nil && error == failure);
        };
        MTPreferencesGraphicImageTransform __unsafe_unretained transform = ^id(id image) {
            transforms++;
            validQueue &= dispatch_get_specific(&queueKey) == &queueKey;
            validDelivery &= image == original;
            return transformContext;
        };
        pendingCompletion = shape == MTPreferencesGraphicCompletionImage
            ? MTPreferencesGraphicIconWrapCompletion(
                (__bridge id)(__bridge const void *)imageCallback, transform)
            : MTPreferencesGraphicIconWrapCompletion(
                (__bridge id)(__bridge const void *)pairCallback, transform);
    }
    MTGraphicIconAssert(weakCallbackContext != nil && weakTransformContext != nil &&
        callbacks == 0 && transforms == 0,
        @"An escaped wrapper must retain the stack callback and transform captures under ARC");
    dispatch_async(queue, ^{
        @autoreleasepool {
            if (shape == MTPreferencesGraphicCompletionImage) {
                void (^callback)(id) = pendingCompletion;
                pendingCompletion = nil;
                callback(original);
                callback(nil);
            } else {
                void (^callback)(id, id) = pendingCompletion;
                pendingCompletion = nil;
                callback(original, nil);
                callback(nil, failure);
            }
        }
    });
    dispatch_sync(queue, ^{});
    MTGraphicIconAssert(callbacks == 2 && transforms == 1 && validQueue && validDelivery,
        @"Delayed callbacks must keep the native queue, count, result and error semantics");
    MTGraphicIconAssert(weakCallbackContext == nil && weakTransformContext == nil,
        @"Releasing the last wrapper must release both captured contexts without an ARC cycle");
}

NSUInteger MTRunPreferencesGraphicIconContractTests(void) {
    MTGraphicIconAssertionCount = 0;
    MTGraphicIconAssert(MTPreferencesGraphicIconTypeIsSupported(@"com.apple.graphic-icon.wifi") &&
        MTPreferencesGraphicIconTypeIsSupported(@"com.apple.graphic-icon.mobile-data.5g"),
        @"Supported graphic-icon identifiers must retain their full native identity");
    for (id type in @[@"", @"com.apple.graphic-icon.", @"com.apple.application-icon.wifi",
            @"com.apple.graphic-icon.WiFi", @"com.apple.graphic-icon../wifi",
            @"com.apple.graphic-icon.wifi\n", @42,
            [@"com.apple.graphic-icon." stringByPaddingToLength:193
                withString:@"a" startingAtIndex:0]]) {
        MTGraphicIconAssert(!MTPreferencesGraphicIconTypeIsSupported(type),
            @"Unsafe, unrelated, non-string and oversized identifiers must remain native");
    }
    MTGraphicIconAssert(!MTPreferencesGraphicIconTypeIsSupported(nil),
        @"A missing icon type must remain native");
    MTGraphicIconTestStorageClasses();
    MTGraphicIconTestUnsupportedCompletions();
    MTGraphicIconTestImageCompletion();
    MTGraphicIconTestImageAndErrorCompletion();
    MTGraphicIconTestAsyncLifetime(MTPreferencesGraphicCompletionImage);
    MTGraphicIconTestAsyncLifetime(MTPreferencesGraphicCompletionImageAndError);
    return MTGraphicIconAssertionCount;
}
