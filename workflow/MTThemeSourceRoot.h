#import <Foundation/Foundation.h>

#import "MTAuditedSource.h"

NS_ASSUME_NONNULL_BEGIN

// Presents one already-audited theme as a logical theme root. Direct
// IconBundles/Bundles layouts remain unchanged; archives or directory
// snapshots with exactly one wrapper directory are rebased without extracting
// or copying their contents again.
@interface MTThemeSourceRoot : NSObject <MTAuditedSource>

@property(nonatomic, strong, readonly) MTSourceInventory *inventory;

+ (nullable id<MTAuditedSource>)
    sourceByResolvingThemeRootInSource:(id<MTAuditedSource>)source
                                 error:(NSError **)error;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
