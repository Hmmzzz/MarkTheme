#import <Foundation/Foundation.h>

@class MTCalendarIconConfiguration;
@class MTGeneration;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTCalendarIconCompositeModuleID;
FOUNDATION_EXPORT NSString *const MTCalendarIconTargetBundleIdentifier;
FOUNDATION_EXPORT NSString *const MTCalendarIconSnapshotResolverErrorDomain;

// Foundation-only typed configuration bridge. It never reads files or creates
// images, and caches one immutable configuration per Generation identifier.
@interface MTCalendarIconSnapshotResolver : NSObject

// A non-Calendar subject or a Generation without icons.calendar is a clean
// nil result. An enabled but malformed Calendar capability returns an error so
// the shared icon module can fall back to the exact stock image.
- (nullable MTCalendarIconConfiguration *)
    configurationForBundleIdentifier:(NSString *)bundleIdentifier
                           generation:(MTGeneration *)generation
                                error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
