#import "MTImportDiagnostics.h"

static NSString *const MTImportDiagnosticsDefaultsKey =
    @"MTImportDiagnosticsEventsV1";
static const NSUInteger MTImportDiagnosticsMaximumEvents = 80;

static id MTImportDiagnosticScalar(id value) {
    if ([value isKindOfClass:NSString.class] ||
        [value isKindOfClass:NSNumber.class]) {
        return value;
    }
    if ([value isKindOfClass:NSURL.class]) return [value path] ?: @"";
    if ([value isKindOfClass:NSArray.class]) {
        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        for (id item in (NSArray *)value) {
            id scalar = MTImportDiagnosticScalar(item);
            if (scalar != nil) [parts addObject:[scalar description]];
        }
        return [parts componentsJoinedByString:@", "];
    }
    return value == nil || value == NSNull.null
        ? @"<nil>" : [value description];
}

static NSDictionary<NSString *, id> *MTImportDiagnosticSanitizeFields(
    NSDictionary<NSString *, id> *fields) {
    NSMutableDictionary<NSString *, id> *safe = [NSMutableDictionary dictionary];
    [fields enumerateKeysAndObjectsUsingBlock:
        ^(NSString *key, id value, __unused BOOL *stop) {
        if (![key isKindOfClass:NSString.class] || key.length == 0) return;
        id scalar = MTImportDiagnosticScalar(value);
        if (scalar != nil) safe[key] = scalar;
    }];
    return safe;
}

static NSString *MTImportDiagnosticScheme(void) {
#if defined(THEOS_PACKAGE_SCHEME_ROOTHIDE)
    return @"roothide";
#elif defined(THEOS_PACKAGE_SCHEME_ROOTLESS)
    return @"rootless";
#elif defined(MT_HOST_TESTING)
    return @"host-test";
#else
    return @"unknown";
#endif
}

void MTImportDiagnosticsRecord(NSString *event,
                               NSDictionary<NSString *, id> *fields) {
#if defined(MT_HOST_TESTING)
    (void)event;
    (void)fields;
    return;
#endif
    if (![event isKindOfClass:NSString.class] || event.length == 0) return;
    @synchronized (NSUserDefaults.standardUserDefaults) {
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        NSArray *stored = [defaults arrayForKey:MTImportDiagnosticsDefaultsKey];
        NSMutableArray<NSDictionary<NSString *, id> *> *events =
            [NSMutableArray array];
        for (id item in stored) {
            if ([item isKindOfClass:NSDictionary.class]) [events addObject:item];
        }
        NSNumber *previousSequence = events.lastObject[@"sequence"];
        NSUInteger sequence = [previousSequence isKindOfClass:NSNumber.class]
            ? previousSequence.unsignedIntegerValue + 1 : 1;
        NSDictionary *entry = @{
            @"timestamp" : @([NSDate.date timeIntervalSince1970]),
            @"sequence" : @(sequence),
            @"event" : event,
            @"scheme" : MTImportDiagnosticScheme(),
            @"thread" : NSThread.isMainThread ? @"main" : @"background",
            @"fields" : MTImportDiagnosticSanitizeFields(fields ?: @{}),
        };
        [events addObject:entry];
        if (events.count > MTImportDiagnosticsMaximumEvents) {
            [events removeObjectsInRange:NSMakeRange(
                0, events.count - MTImportDiagnosticsMaximumEvents)];
        }
        [defaults setObject:events forKey:MTImportDiagnosticsDefaultsKey];
        [defaults synchronize];
    }
}

void MTImportDiagnosticsRecordError(NSString *event,
                                    NSError *error,
                                    NSDictionary<NSString *, id> *fields) {
    NSMutableDictionary<NSString *, id> *details =
        [NSMutableDictionary dictionaryWithDictionary:fields ?: @{}];
    NSError *current = error;
    for (NSUInteger depth = 0; current != nil && depth < 6; depth++) {
        NSString *prefix = depth == 0 ? @"error" :
            [NSString stringWithFormat:@"underlying%lu",
                (unsigned long)depth];
        details[[prefix stringByAppendingString:@"Domain"]] =
            current.domain ?: @"";
        details[[prefix stringByAppendingString:@"Code"]] = @(current.code);
        details[[prefix stringByAppendingString:@"Description"]] =
            current.localizedDescription ?: @"";
        id next = current.userInfo[NSUnderlyingErrorKey];
        current = [next isKindOfClass:NSError.class] ? next : nil;
    }
    MTImportDiagnosticsRecord(event, details);
}

static NSString *MTImportDiagnosticTimestamp(NSNumber *timestamp) {
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:
        timestamp.doubleValue];
    static NSDateFormatter *formatter = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [[NSDateFormatter alloc] init];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS Z";
    });
    @synchronized (formatter) {
        return [formatter stringFromDate:date] ?: @"?";
    }
}

NSString *MTImportDiagnosticsText(void) {
    NSArray *stored = [NSUserDefaults.standardUserDefaults
        arrayForKey:MTImportDiagnosticsDefaultsKey];
    NSMutableString *text = [NSMutableString stringWithString:
        @"Import breadcrumbs (oldest first)\n"];
    if (stored.count == 0) {
        [text appendString:@"  <no import events recorded>\n"];
        return text;
    }
    for (id item in stored) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *entry = item;
        [text appendFormat:@"#%@ %@ [%@/%@] %@\n",
            entry[@"sequence"] ?: @"?",
            MTImportDiagnosticTimestamp(entry[@"timestamp"]),
            entry[@"scheme"] ?: @"?", entry[@"thread"] ?: @"?",
            entry[@"event"] ?: @"?"];
        NSDictionary *fields = entry[@"fields"];
        if (![fields isKindOfClass:NSDictionary.class]) continue;
        for (NSString *key in [fields.allKeys
                sortedArrayUsingSelector:@selector(compare:)]) {
            [text appendFormat:@"    %@: %@\n", key, fields[key]];
        }
    }
    return text;
}
