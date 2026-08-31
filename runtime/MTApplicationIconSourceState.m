#import "MTApplicationIconSourceState.h"

#import "MTGenerationDescriptor.h"
#import "MTGenerationIndexCodec.h"
#import "MTGenerationReader.h"
#import "MTRuntimeSnapshot.h"
#import "MTStaticIconConfiguration.h"

static NSString *const MTApplicationIconStaticCapabilityID = @"icons.static";
static NSString *const MTApplicationIconMaskCapabilityID = @"icons.mask";
static NSString *const MTApplicationIconOverlayCapabilityID = @"icons.overlay";

static BOOL MTApplicationIconSnapshotHasResourcesForCapability(
    MTRuntimeSnapshot *snapshot,
    NSString *capabilityID) {
    MTGeneration *generation = snapshot.generation;
    if (!snapshot.isReady || generation == nil ||
        ![generation.descriptor.moduleIDs containsObject:capabilityID]) {
        return NO;
    }
    NSUInteger byteCount =
        [capabilityID lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    NSString *prefix = [NSString stringWithFormat:@"mtk1|%lu:%@|",
        (unsigned long)byteCount, capabilityID];
    NSError *error = nil;
    BOOL present = [generation.index
        containsRecordWithCanonicalResourceKeyPrefix:prefix error:&error];
    // This only scopes an optional animation. On an impossible admitted-index
    // inconsistency, retaining the animation is the harmless fallback.
    return error == nil ? present : YES;
}

static NSString *_Nullable MTApplicationIconCanonicalSubjectPrefix(
    NSString *subject) {
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

BOOL MTApplicationIconSnapshotAffectsBundleIdentifier(
    MTRuntimeSnapshot *snapshot,
    NSString *bundleIdentifier) {
    if (![snapshot isKindOfClass:MTRuntimeSnapshot.class] ||
        !MTStaticIconBundleIdentifierIsValid(bundleIdentifier)) {
        return NO;
    }
    if (MTApplicationIconSnapshotHasResourcesForCapability(
            snapshot, MTApplicationIconMaskCapabilityID) ||
        MTApplicationIconSnapshotHasResourcesForCapability(
            snapshot, MTApplicationIconOverlayCapabilityID)) {
        return YES;
    }

    MTGeneration *generation = snapshot.generation;
    MTGenerationDescriptor *descriptor = generation.descriptor;
    if (generation == nil || ![descriptor.moduleIDs
            containsObject:MTApplicationIconStaticCapabilityID]) {
        return NO;
    }
    NSDictionary *dictionary = descriptor.moduleConfigurations[
        MTApplicationIconStaticCapabilityID];
    MTStaticIconConfiguration *configuration = dictionary == nil ? nil :
        [[MTStaticIconConfiguration alloc]
            initWithDictionary:dictionary error:NULL];
    if (dictionary != nil && configuration == nil) return YES;

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
        NSString *prefix = MTApplicationIconCanonicalSubjectPrefix(subject);
        if (prefix == nil) return YES;
        NSError *lookupError = nil;
        BOOL present = [generation.index
            containsRecordWithCanonicalResourceKeyPrefix:prefix
            error:&lookupError];
        if (lookupError != nil) return YES;
        if (present) return YES;
    }
    return NO;
}
