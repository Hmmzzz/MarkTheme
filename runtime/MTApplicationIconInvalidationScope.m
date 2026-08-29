#import "MTApplicationIconInvalidationScope.h"

#import "MTGenerationDescriptor.h"
#import "MTGenerationIndexCodec.h"
#import "MTGenerationReader.h"
#import "MTRuntimeSnapshot.h"
#import "MTRuntimeFeatureState.h"
#import "MTStaticIconConfiguration.h"

static NSString *const MTApplicationIconStaticCapabilityID = @"icons.static";
static NSString *const MTApplicationIconMaskCapabilityID = @"icons.mask";
static NSString *const MTApplicationIconOverlayCapabilityID = @"icons.overlay";
static NSString *const MTApplicationIconCalendarCapabilityID = @"icons.calendar";
static NSString *const MTApplicationIconClockCapabilityID = @"icons.clock";
static NSString *const MTApplicationIconUIResourceCapabilityID = @"ui.resources";

static NSArray<NSString *> *MTApplicationIconSourceCapabilityIDs(void) {
    return @[
        MTApplicationIconStaticCapabilityID,
        MTApplicationIconMaskCapabilityID,
        MTApplicationIconOverlayCapabilityID,
    ];
}

static NSArray<NSString *> *MTApplicationIconOwnerCapabilityIDs(void) {
    NSMutableArray<NSString *> *moduleIDs =
        [MTApplicationIconSourceCapabilityIDs() mutableCopy];
    [moduleIDs addObjectsFromArray:@[
        MTApplicationIconCalendarCapabilityID,
        MTApplicationIconClockCapabilityID,
    ]];
    return moduleIDs;
}

static NSString *MTApplicationIconCanonicalSubjectPrefix(NSString *subject) {
    if (!MTStaticIconBundleIdentifierIsValid(subject)) return nil;
    NSString *surface = @"springboard.home";
    return [NSString stringWithFormat:@"mtk1|%lu:%@|%lu:%@|%lu:%@|",
        (unsigned long)[MTApplicationIconStaticCapabilityID
            lengthOfBytesUsingEncoding:NSUTF8StringEncoding],
        MTApplicationIconStaticCapabilityID,
        (unsigned long)[surface
            lengthOfBytesUsingEncoding:NSUTF8StringEncoding],
        surface,
        (unsigned long)[subject
            lengthOfBytesUsingEncoding:NSUTF8StringEncoding],
        subject];
}

NSSet<NSString *> *
MTApplicationIconInvalidationAffectedBundleIdentifiers(
    MTRuntimeSnapshot *snapshot,
    NSArray<NSString *> *installedBundleIdentifiers) {
    if (![snapshot isKindOfClass:MTRuntimeSnapshot.class] ||
        installedBundleIdentifiers.count == 0) {
        return [NSSet set];
    }
    MTGeneration *generation = snapshot.generation;
    MTGenerationDescriptor *descriptor = generation.descriptor;
    if (generation == nil ||
        ![descriptor.moduleIDs
            containsObject:MTApplicationIconStaticCapabilityID]) {
        return [NSSet set];
    }
    NSMutableArray<NSString *> *validIdentifiers = [NSMutableArray array];
    for (NSString *identifier in installedBundleIdentifiers) {
        if (MTStaticIconBundleIdentifierIsValid(identifier)) {
            [validIdentifiers addObject:identifier];
        }
    }
    if (validIdentifiers.count == 0) return [NSSet set];

    NSDictionary *configurationDictionary =
        descriptor.moduleConfigurations[MTApplicationIconStaticCapabilityID];
    MTStaticIconConfiguration *configuration = nil;
    if (configurationDictionary != nil) {
        configuration = [[MTStaticIconConfiguration alloc]
            initWithDictionary:configurationDictionary error:NULL];
        if (configuration == nil) {
            return [NSSet setWithArray:validIdentifiers];
        }
    }

    NSMutableSet<NSString *> *affected = [NSMutableSet set];
    for (NSString *bundleIdentifier in validIdentifiers) {
        NSMutableArray<NSString *> *subjects =
            [NSMutableArray arrayWithObject:bundleIdentifier];
        for (NSString *fallback in [configuration
                themedBundleIdentifierCandidatesForRequestedIdentifier:
                    bundleIdentifier]) {
            if (fallback.length > 0 && ![subjects containsObject:fallback]) {
                [subjects addObject:fallback];
            }
        }
        for (NSString *subject in subjects) {
            NSString *prefix =
                MTApplicationIconCanonicalSubjectPrefix(subject);
            if (prefix == nil) {
                return [NSSet setWithArray:validIdentifiers];
            }
            NSError *lookupError = nil;
            BOOL present = [generation.index
                containsRecordWithCanonicalResourceKeyPrefix:prefix
                error:&lookupError];
            if (lookupError != nil) {
                return [NSSet setWithArray:validIdentifiers];
            }
            if (present) {
                [affected addObject:bundleIdentifier];
                break;
            }
        }
    }
    return [affected copy];
}

MTRuntimeFeatureState *MTApplicationIconSourceFeatureState(
    MTRuntimeSnapshot *snapshot) {
    return MTRuntimeFeatureStateForSnapshot(
        snapshot, MTApplicationIconSourceCapabilityIDs());
}

MTRuntimeFeatureState *MTApplicationIconOwnerFeatureState(
    MTRuntimeSnapshot *snapshot,
    BOOL includesUIResources) {
    NSMutableArray<NSString *> *moduleIDs =
        [MTApplicationIconOwnerCapabilityIDs() mutableCopy];
    if (includesUIResources) {
        [moduleIDs addObject:MTApplicationIconUIResourceCapabilityID];
    }
    return MTRuntimeFeatureStateForSnapshot(snapshot, moduleIDs);
}

BOOL MTApplicationIconFeatureStateUsesGlobalAppearance(
    MTRuntimeFeatureState *state) {
    if (![state isKindOfClass:MTRuntimeFeatureState.class]) return YES;
    return [state.moduleIDsWithResources
               containsObject:MTApplicationIconMaskCapabilityID] ||
        [state.moduleIDsWithResources
               containsObject:MTApplicationIconOverlayCapabilityID];
}
