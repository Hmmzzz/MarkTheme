#import "MTCalendarIconSnapshotResolver.h"

#import <os/lock.h>

#import "MTCalendarIconConfiguration.h"
#import "MTGenerationDescriptor.h"
#import "MTGenerationReader.h"

NSString *const MTCalendarIconCompositeModuleID = @"calendar-icons.composite";
NSString *const MTCalendarIconTargetBundleIdentifier = @"com.apple.mobilecal";
NSString *const MTCalendarIconSnapshotResolverErrorDomain =
    @"com.hmmzzz.marktheme.calendar-icon-snapshot-resolver";

static NSString *const MTCalendarIconCapabilityID = @"icons.calendar";
static NSString *const MTStaticIconCapabilityID = @"icons.static";

@interface MTCalendarIconSnapshotResolver () {
    os_unfair_lock _lock;
    NSString *_cachedGenerationIdentifier;
    MTCalendarIconConfiguration *_cachedConfiguration;
    NSError *_cachedError;
    BOOL _cachedCapabilityEnabled;
}
@end

@implementation MTCalendarIconSnapshotResolver

- (instancetype)init {
    self = [super init];
    if (self == nil) return nil;
    _lock = OS_UNFAIR_LOCK_INIT;
    return self;
}

- (MTCalendarIconConfiguration *)
    configurationForBundleIdentifier:(NSString *)bundleIdentifier
                           generation:(MTGeneration *)generation
                                error:(NSError **)error {
    if (error != NULL) *error = nil;
    if (![bundleIdentifier
            isEqualToString:MTCalendarIconTargetBundleIdentifier]) {
        return nil;
    }

    NSString *generationIdentifier = generation.generationIdentifier;
    os_unfair_lock_lock(&_lock);
    BOOL cached = generationIdentifier.length > 0 &&
        [_cachedGenerationIdentifier isEqualToString:generationIdentifier];
    BOOL cachedCapabilityEnabled = _cachedCapabilityEnabled;
    MTCalendarIconConfiguration *cachedConfiguration =
        _cachedConfiguration;
    NSError *cachedError = _cachedError;
    os_unfair_lock_unlock(&_lock);
    if (cached) {
        if (error != NULL) *error = cachedError;
        return cachedCapabilityEnabled ? cachedConfiguration : nil;
    }

    MTGenerationDescriptor *descriptor = generation.descriptor;
    BOOL capabilityEnabled = [descriptor.moduleIDs
        containsObject:MTCalendarIconCapabilityID];
    MTCalendarIconConfiguration *configuration = nil;
    NSError *resolutionError = nil;
    if (generationIdentifier.length == 0 || descriptor == nil) {
        resolutionError = [NSError
            errorWithDomain:MTCalendarIconSnapshotResolverErrorDomain
                       code:1
                   userInfo:@{
            NSLocalizedDescriptionKey :
                @"Calendar configuration requires one validated Generation."
        }];
        capabilityEnabled = YES;
    } else if (capabilityEnabled) {
        NSDictionary *dictionary =
            descriptor.moduleConfigurations[MTCalendarIconCapabilityID];
        NSError *configurationError = nil;
        configuration = [[MTCalendarIconConfiguration alloc]
            initWithDictionary:dictionary error:&configurationError];
        if (![descriptor.moduleIDs containsObject:MTStaticIconCapabilityID] ||
            configuration == nil) {
            NSMutableDictionary *userInfo = [NSMutableDictionary
                dictionaryWithObject:
                    @"Calendar capability has no valid static background configuration."
                             forKey:NSLocalizedDescriptionKey];
            if (configurationError != nil) {
                userInfo[NSUnderlyingErrorKey] = configurationError;
            }
            resolutionError = [NSError
                errorWithDomain:MTCalendarIconSnapshotResolverErrorDomain
                           code:2
                       userInfo:userInfo];
        }
    }

    os_unfair_lock_lock(&_lock);
    _cachedGenerationIdentifier = [generationIdentifier copy];
    _cachedCapabilityEnabled = capabilityEnabled;
    _cachedConfiguration = configuration;
    _cachedError = resolutionError;
    os_unfair_lock_unlock(&_lock);
    if (error != NULL) *error = resolutionError;
    return resolutionError == nil && capabilityEnabled ? configuration : nil;
}

@end
