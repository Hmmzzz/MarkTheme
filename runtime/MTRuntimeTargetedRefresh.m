#import "MTRuntimeTargetedRefresh.h"

#import <objc/runtime.h>

@class MTRuntimeTargetedRefreshTracker;

@interface MTRuntimeRefreshRegistration : NSObject
@property(nonatomic, weak, readonly) MTRuntimeTargetedRefreshTracker *tracker;
@property(nonatomic, weak, readonly) id recipient;
@property(nonatomic, copy, readonly) NSString *identifier;
- (instancetype)initWithTracker:(MTRuntimeTargetedRefreshTracker *)tracker
                       recipient:(id)recipient
                      identifier:(NSString *)identifier;
@end

@implementation MTRuntimeRefreshRegistration

- (instancetype)initWithTracker:(MTRuntimeTargetedRefreshTracker *)tracker
                       recipient:(id)recipient
                      identifier:(NSString *)identifier {
    self = [super init];
    if (self == nil) return nil;
    _tracker = tracker;
    _recipient = recipient;
    _identifier = [identifier copy];
    return self;
}

@end

static char MTRuntimeRefreshRegistrationAssociationKey;

@interface MTRuntimeRefreshTarget ()
- (instancetype)initWithRecipient:(id)recipient
                          subjects:(NSArray *)subjects;
@end

@implementation MTRuntimeRefreshTarget

- (instancetype)initWithRecipient:(id)recipient
                          subjects:(NSArray *)subjects {
    self = [super init];
    if (self == nil) return nil;
    _recipient = recipient;
    _subjects = [subjects copy];
    return self;
}

@end

@interface MTRuntimeTargetedRefreshEntry : NSObject
@property(nonatomic, strong) id recipient;
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic, copy) NSArray *subjects;
@end

@implementation MTRuntimeTargetedRefreshEntry
@end

@interface MTRuntimeTargetedRefreshSnapshot ()
@property(nonatomic, copy) NSArray<MTRuntimeTargetedRefreshEntry *> *entries;
- (instancetype)initWithEntries:
    (NSArray<MTRuntimeTargetedRefreshEntry *> *)entries
                    identifiers:(NSArray<NSString *> *)identifiers;
@end

@implementation MTRuntimeTargetedRefreshSnapshot

- (instancetype)initWithEntries:
    (NSArray<MTRuntimeTargetedRefreshEntry *> *)entries
                    identifiers:(NSArray<NSString *> *)identifiers {
    self = [super init];
    if (self == nil) return nil;
    _entries = [entries copy];
    _identifiers = [identifiers copy];
    NSUInteger count = 0;
    for (MTRuntimeTargetedRefreshEntry *entry in _entries) {
        count += entry.subjects.count;
    }
    _subjectCount = count;
    return self;
}

- (NSArray<MTRuntimeRefreshTarget *> *)targetsForIdentifiers:
    (NSSet<NSString *> *)identifiers {
    NSMapTable<id, NSHashTable *> *subjectsByRecipient = [NSMapTable
        mapTableWithKeyOptions:NSPointerFunctionsStrongMemory |
                               NSPointerFunctionsObjectPointerPersonality
                  valueOptions:NSPointerFunctionsStrongMemory];
    for (MTRuntimeTargetedRefreshEntry *entry in self.entries) {
        if (identifiers != nil &&
            ![identifiers containsObject:entry.identifier]) {
            continue;
        }
        NSHashTable *subjects = [subjectsByRecipient
            objectForKey:entry.recipient];
        if (subjects == nil) {
            subjects = [NSHashTable hashTableWithOptions:
                NSPointerFunctionsStrongMemory |
                NSPointerFunctionsObjectPointerPersonality];
            [subjectsByRecipient setObject:subjects
                                    forKey:entry.recipient];
        }
        for (id subject in entry.subjects) [subjects addObject:subject];
    }

    NSMutableArray<MTRuntimeRefreshTarget *> *targets = [NSMutableArray array];
    for (id recipient in subjectsByRecipient) {
        NSArray *subjects = [subjectsByRecipient objectForKey:recipient].allObjects;
        if (subjects.count == 0) continue;
        [targets addObject:[[MTRuntimeRefreshTarget alloc]
            initWithRecipient:recipient subjects:subjects]];
    }
    return targets;
}

@end

@interface MTRuntimeTargetedRefreshTracker ()
@property(nonatomic, strong) NSLock *lock;
@property(nonatomic, strong) NSMapTable<id, NSMutableDictionary *> *entries;
@end

@implementation MTRuntimeTargetedRefreshTracker

- (instancetype)init {
    self = [super init];
    if (self == nil) return nil;
    _lock = [[NSLock alloc] init];
    _entries = [NSMapTable
        mapTableWithKeyOptions:NSPointerFunctionsWeakMemory |
                               NSPointerFunctionsObjectPointerPersonality
                  valueOptions:NSPointerFunctionsStrongMemory];
    return self;
}

- (void)recordRecipient:(id)recipient
                 subject:(id)subject
              identifier:(NSString *)identifier {
    if (recipient == nil || subject == nil || identifier.length == 0) return;
    MTRuntimeRefreshRegistration *registration = objc_getAssociatedObject(
        subject, &MTRuntimeRefreshRegistrationAssociationKey);
    if (registration.tracker == self &&
        registration.recipient == recipient &&
        [registration.identifier isEqualToString:identifier]) {
        return;
    }
    [self.lock lock];
    NSMutableDictionary<NSString *, NSHashTable *> *byIdentifier =
        [self.entries objectForKey:recipient];
    if (byIdentifier == nil) {
        byIdentifier = [NSMutableDictionary dictionary];
        [self.entries setObject:byIdentifier forKey:recipient];
    }
    NSHashTable *subjects = byIdentifier[identifier];
    if (subjects == nil) {
        subjects = [NSHashTable hashTableWithOptions:
            NSPointerFunctionsWeakMemory |
            NSPointerFunctionsObjectPointerPersonality];
        byIdentifier[identifier] = subjects;
    }
    [subjects addObject:subject];
    [self.lock unlock];
    registration = [[MTRuntimeRefreshRegistration alloc]
        initWithTracker:self recipient:recipient identifier:identifier];
    objc_setAssociatedObject(
        subject, &MTRuntimeRefreshRegistrationAssociationKey,
        registration, OBJC_ASSOCIATION_RETAIN);
}

- (MTRuntimeTargetedRefreshSnapshot *)snapshot {
    [self.lock lock];
    NSMutableArray<MTRuntimeTargetedRefreshEntry *> *entries =
        [NSMutableArray array];
    NSMutableSet<NSString *> *identifiers = [NSMutableSet set];
    for (id recipient in self.entries) {
        NSMutableDictionary<NSString *, NSHashTable *> *byIdentifier =
            [self.entries objectForKey:recipient];
        NSMutableArray<NSString *> *emptyIdentifiers =
            [NSMutableArray array];
        for (NSString *identifier in byIdentifier) {
            NSArray *subjects = byIdentifier[identifier].allObjects;
            if (subjects.count == 0) {
                [emptyIdentifiers addObject:identifier];
                continue;
            }
            MTRuntimeTargetedRefreshEntry *entry =
                [[MTRuntimeTargetedRefreshEntry alloc] init];
            entry.recipient = recipient;
            entry.identifier = identifier;
            entry.subjects = subjects;
            [entries addObject:entry];
            [identifiers addObject:identifier];
        }
        [byIdentifier removeObjectsForKeys:emptyIdentifiers];
    }
    [self.lock unlock];
    NSArray<NSString *> *orderedIdentifiers =
        [identifiers.allObjects sortedArrayUsingSelector:@selector(compare:)];
    return [[MTRuntimeTargetedRefreshSnapshot alloc]
        initWithEntries:entries identifiers:orderedIdentifiers];
}

@end
