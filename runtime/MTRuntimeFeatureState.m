#import "MTRuntimeFeatureState.h"

#import "MTCanonicalJSON.h"
#import "MTDigest.h"
#import "MTGenerationDescriptor.h"
#import "MTGenerationIndexCodec.h"
#import "MTGenerationReader.h"
#import "MTIdentifier.h"
#import "MTRuntimeSnapshot.h"

static const NSUInteger MTRuntimeFeatureStateSchemaVersion = 1;

static NSString *MTRuntimeFeatureModulePrefix(NSString *moduleID) {
    NSUInteger byteCount =
        [moduleID lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    return [NSString stringWithFormat:@"mtk1|%lu:%@|",
        (unsigned long)byteCount, moduleID];
}

@interface MTRuntimeFeatureState ()
@property(nonatomic, copy, readwrite) NSString *fingerprint;
@property(nonatomic, copy, readwrite) NSArray<NSString *> *enabledModuleIDs;
@property(nonatomic, copy, readwrite)
    NSSet<NSString *> *moduleIDsWithResources;
@property(nonatomic, assign, readwrite) NSUInteger resourceCount;
- (instancetype)initWithFingerprint:(NSString *)fingerprint
                    enabledModuleIDs:(NSArray<NSString *> *)enabledModuleIDs
              moduleIDsWithResources:
                  (NSSet<NSString *> *)moduleIDsWithResources
                       resourceCount:(NSUInteger)resourceCount;
@end

@implementation MTRuntimeFeatureState

- (instancetype)initWithFingerprint:(NSString *)fingerprint
                    enabledModuleIDs:(NSArray<NSString *> *)enabledModuleIDs
              moduleIDsWithResources:
                  (NSSet<NSString *> *)moduleIDsWithResources
                       resourceCount:(NSUInteger)resourceCount {
    self = [super init];
    if (self == nil) return nil;
    _fingerprint = [fingerprint copy];
    _enabledModuleIDs = [enabledModuleIDs copy];
    _moduleIDsWithResources = [moduleIDsWithResources copy];
    _resourceCount = resourceCount;
    return self;
}

@end

MTRuntimeFeatureState *MTRuntimeFeatureStateForSnapshot(
    MTRuntimeSnapshot *snapshot,
    NSArray<NSString *> *moduleIDs) {
    if (![snapshot isKindOfClass:MTRuntimeSnapshot.class] ||
        ![moduleIDs isKindOfClass:NSArray.class] ||
        moduleIDs.count == 0) {
        return nil;
    }
    NSMutableSet<NSString *> *requestedSet = [NSMutableSet set];
    for (id candidate in moduleIDs) {
        if (![candidate isKindOfClass:NSString.class] ||
            !MTIdentifierIsValid(candidate)) {
            return nil;
        }
        [requestedSet addObject:candidate];
    }
    if (requestedSet.count != moduleIDs.count) return nil;
    NSArray<NSString *> *requested = [requestedSet.allObjects
        sortedArrayUsingSelector:@selector(compare:)];

    MTGeneration *generation = snapshot.isReady ? snapshot.generation : nil;
    MTGenerationDescriptor *descriptor = generation.descriptor;
    if (snapshot.isReady && (generation == nil || descriptor == nil)) {
        return nil;
    }
    NSMutableArray<NSString *> *enabled = [NSMutableArray array];
    for (NSString *moduleID in requested) {
        if ([descriptor.moduleIDs containsObject:moduleID]) {
            [enabled addObject:moduleID];
        }
    }
    NSMutableDictionary<NSString *, NSString *> *prefixes =
        [NSMutableDictionary dictionaryWithCapacity:enabled.count];
    for (NSString *moduleID in enabled) {
        prefixes[moduleID] = MTRuntimeFeatureModulePrefix(moduleID);
    }

    NSMutableArray<NSDictionary<NSString *, id> *> *resources =
        [NSMutableArray array];
    NSMutableSet<NSString *> *modulesWithResources = [NSMutableSet set];
    for (NSUInteger index = 0; index < generation.index.recordCount; index++) {
        MTGenerationIndexRecord *record =
            [generation.index recordAtIndex:index];
        if (record == nil) return nil;
        NSString *matchedModule = nil;
        for (NSString *moduleID in enabled) {
            if ([record.canonicalResourceKey
                    hasPrefix:prefixes[moduleID]]) {
                matchedModule = moduleID;
                break;
            }
        }
        if (matchedModule == nil) continue;
        [modulesWithResources addObject:matchedModule];
        [resources addObject:@{
            @"byteCount" : @(record.assetByteCount),
            @"key" : record.canonicalResourceKey,
            @"sha256" : record.contentSHA256,
        }];
    }

    NSMutableDictionary<NSString *, NSDictionary<NSString *, id> *> *
        configurations = [NSMutableDictionary dictionary];
    for (NSString *moduleID in enabled) {
        NSDictionary<NSString *, id> *configuration =
            descriptor.moduleConfigurations[moduleID];
        if (configuration != nil) configurations[moduleID] = configuration;
    }
    NSDictionary<NSString *, id> *canonicalState = @{
        @"configurations" : configurations,
        @"enabledModuleIDs" : enabled,
        @"requestedModuleIDs" : requested,
        @"resources" : resources,
        @"schemaVersion" : @(MTRuntimeFeatureStateSchemaVersion),
    };
    NSData *canonicalData = MTCanonicalJSONData(canonicalState, NULL);
    NSString *digest = canonicalData == nil ? nil :
        MTSHA256HexDigestForData(canonicalData);
    if (digest.length != 64) return nil;
    NSString *fingerprint = [@"mtfs1-" stringByAppendingString:digest];
    return [[MTRuntimeFeatureState alloc]
        initWithFingerprint:fingerprint
        enabledModuleIDs:enabled
        moduleIDsWithResources:modulesWithResources
        resourceCount:resources.count];
}
