#import "MTRuntimeWeakObjectMapSnapshot.h"

NSArray<NSArray *> *MTRuntimeWeakObjectMapSnapshot(
    NSMapTable * _Nullable mapTable) {
    if (mapTable == nil) return @[];
    NSMutableArray<NSArray *> *pairs = [[NSMutableArray alloc] init];
    NSArray *keys = mapTable.keyEnumerator.allObjects;
    for (id key in keys) {
        id object = [mapTable objectForKey:key];
        if (object == nil) continue;
        NSArray *pair = [[NSArray alloc] initWithObjects:key, object, nil];
        [pairs addObject:pair];
    }
    return [pairs copy];
}
