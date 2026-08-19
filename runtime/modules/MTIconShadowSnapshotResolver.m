#import "MTIconShadowSnapshotResolver.h"

#import <math.h>
#import <stdint.h>

#import "MTGenerationReader.h"
#import "MTIconShadowContract.h"
#import "MTResourceKey.h"
#import "MTRuntimeSnapshot.h"

@interface MTIconShadowSnapshotContext ()
- (instancetype)initWithScale:(NSUInteger)scale
                   deviceTrait:(NSString *)deviceTrait
      prefersLargeIPadCanvas:(BOOL)prefersLargeIPadCanvas;
@end

@implementation MTIconShadowSnapshotContext

+ (instancetype)contextWithScale:(NSUInteger)scale
                       deviceTrait:(NSString *)deviceTrait
          prefersLargeIPadCanvas:(BOOL)prefersLargeIPadCanvas {
    if (scale < 1 || scale > 3 ||
        (![deviceTrait isEqualToString:@"iphone"] &&
         ![deviceTrait isEqualToString:@"ipad"])) {
        return nil;
    }
    BOOL normalizedLargeCanvas = [deviceTrait isEqualToString:@"ipad"] &&
        prefersLargeIPadCanvas;
    return [[self alloc] initWithScale:scale
                           deviceTrait:deviceTrait
              prefersLargeIPadCanvas:normalizedLargeCanvas];
}

- (instancetype)initWithScale:(NSUInteger)scale
                   deviceTrait:(NSString *)deviceTrait
      prefersLargeIPadCanvas:(BOOL)prefersLargeIPadCanvas {
    self = [super init];
    if (self == nil) return nil;
    _scale = scale;
    _deviceTrait = [deviceTrait copy];
    _prefersLargeIPadCanvas = prefersLargeIPadCanvas;
    _cacheKey = [[NSString alloc] initWithFormat:@"%@:%lu:%@",
        _deviceTrait, (unsigned long)_scale,
        _prefersLargeIPadCanvas ? @"large" : @"regular"];
    return self;
}

- (id)copyWithZone:(NSZone *)zone {
    (void)zone;
    return self;
}

- (BOOL)isEqual:(id)object {
    if (object == self) return YES;
    if (![object isKindOfClass:MTIconShadowSnapshotContext.class]) return NO;
    MTIconShadowSnapshotContext *other = object;
    return self.scale == other.scale &&
        self.prefersLargeIPadCanvas == other.prefersLargeIPadCanvas &&
        [self.deviceTrait isEqualToString:other.deviceTrait];
}

- (NSUInteger)hash {
    return self.cacheKey.hash;
}

@end

@interface MTIconShadowSnapshotResolution ()
- (instancetype)initWithGenerationIdentifier:(NSString *)generationIdentifier
                         canonicalResourceKey:(NSString *)canonicalResourceKey
                                   generation:(MTGeneration *)generation
                                     resource:(MTGenerationResource *)resource
                                      subject:(NSString *)subject
                                  sourceScale:(NSUInteger)sourceScale
                         targetPixelDimension:(uint32_t)targetPixelDimension
                         canvasPointDimension:(double)canvasPointDimension;
@end

@implementation MTIconShadowSnapshotResolution

- (instancetype)initWithGenerationIdentifier:(NSString *)generationIdentifier
                         canonicalResourceKey:(NSString *)canonicalResourceKey
                                   generation:(MTGeneration *)generation
                                     resource:(MTGenerationResource *)resource
                                      subject:(NSString *)subject
                                  sourceScale:(NSUInteger)sourceScale
                         targetPixelDimension:(uint32_t)targetPixelDimension
                         canvasPointDimension:(double)canvasPointDimension {
    self = [super init];
    if (self == nil) return nil;
    _generationIdentifier = [generationIdentifier copy];
    _canonicalResourceKey = [canonicalResourceKey copy];
    _generation = generation;
    _resource = resource;
    _subject = [subject copy];
    _sourceScale = sourceScale;
    _targetPixelDimension = targetPixelDimension;
    _canvasPointDimension = canvasPointDimension;
    return self;
}

@end

@interface MTIconShadowSnapshotResolver ()
@property(nonatomic, copy) MTIconShadowSnapshotProvider snapshotProvider;
@end

static NSArray<NSString *> *MTIconShadowSubjectCandidates(
    MTIconShadowSnapshotContext *context) {
    if ([context.deviceTrait isEqualToString:@"iphone"]) {
        return @[ MTIconShadowSubjectIPhone ];
    }
    return context.prefersLargeIPadCanvas
        ? @[ MTIconShadowSubjectIPadPro, MTIconShadowSubjectIPad ]
        : @[ MTIconShadowSubjectIPad, MTIconShadowSubjectIPadPro ];
}

static NSArray<NSNumber *> *MTIconShadowScaleCandidates(NSUInteger scale) {
    NSMutableArray<NSNumber *> *values = [NSMutableArray arrayWithObjects:
        @(scale), @0, nil];
    if (scale == 3) [values addObject:@2];
    if (scale == 2) [values addObject:@3];
    return values;
}

@implementation MTIconShadowSnapshotResolver

- (instancetype)initWithSnapshotProvider:
    (MTIconShadowSnapshotProvider)snapshotProvider {
    NSParameterAssert(snapshotProvider != nil);
    self = [super init];
    if (self == nil) return nil;
    _snapshotProvider = [snapshotProvider copy];
    return self;
}

- (MTIconShadowSnapshotResolution *)
    resolutionForVariant:(NSString *)variant
                  context:(MTIconShadowSnapshotContext *)context
                    error:(NSError **)error {
    if (error != NULL) *error = nil;
    if (![context isKindOfClass:MTIconShadowSnapshotContext.class]) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:MTResourceKeyErrorDomain
                                         code:1
                                     userInfo:@{
                NSLocalizedDescriptionKey :
                    @"Icon Shadow resolution requires a supported view context."
            }];
        }
        return nil;
    }
    MTRuntimeSnapshot *snapshot = self.snapshotProvider();
    MTGeneration *generation = snapshot.generation;
    if (generation == nil) return nil;

    NSArray<NSString *> *traits = @[
        context.deviceTrait,
        @"any",
    ];
    for (NSString *subject in MTIconShadowSubjectCandidates(context)) {
        double pointDimension = MTIconShadowCanvasPointDimension(subject);
        double pixelDimension = pointDimension * (double)context.scale;
        double roundedPixelDimension = round(pixelDimension);
        if (pointDimension <= 0.0 || roundedPixelDimension < 1.0 ||
            roundedPixelDimension > UINT32_MAX ||
            fabs(pixelDimension - roundedPixelDimension) > 0.0001) {
            continue;
        }
        for (NSNumber *scaleNumber in
                MTIconShadowScaleCandidates(context.scale)) {
            NSUInteger sourceScale = scaleNumber.unsignedIntegerValue;
            for (NSString *trait in traits) {
                NSError *keyError = nil;
                MTResourceKey *key = [[MTResourceKey alloc]
                    initWithModuleID:MTIconShadowsModuleID
                             surface:MTIconShadowSurface
                             subject:subject
                             variant:variant
                               scale:sourceScale
                               trait:trait
                               error:&keyError];
                if (key == nil) {
                    if (error != NULL) *error = keyError;
                    return nil;
                }
                NSError *lookupError = nil;
                MTGenerationResource *resource = [generation
                    resourceForCanonicalResourceKey:key.canonicalString
                    error:&lookupError];
                if (lookupError != nil) {
                    if (error != NULL) *error = lookupError;
                    return nil;
                }
                if (resource != nil) {
                    return [[MTIconShadowSnapshotResolution alloc]
                        initWithGenerationIdentifier:
                            generation.generationIdentifier
                        canonicalResourceKey:key.canonicalString
                        generation:generation
                        resource:resource
                        subject:subject
                        sourceScale:sourceScale
                        targetPixelDimension:(uint32_t)roundedPixelDimension
                        canvasPointDimension:pointDimension];
                }
            }
        }
    }
    return nil;
}

@end
