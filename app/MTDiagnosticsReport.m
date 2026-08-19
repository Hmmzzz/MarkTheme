#import "MTDiagnosticsReport.h"

#import "MTBootstrapPaths.h"

static NSURL *MTDiagnosticsDirectoryURL(void) {
#if defined(MT_HOST_TESTING) || TARGET_OS_SIMULATOR
    NSURL *applicationSupport = [NSFileManager.defaultManager
        URLsForDirectory:NSApplicationSupportDirectory
        inDomains:NSUserDomainMask].firstObject;
    return [applicationSupport
        URLByAppendingPathComponent:@"MarkTheme/Diagnostics" isDirectory:YES];
#else
    NSString *path = [MTBootstrapPathResolver.currentResolver
        resolvedPathForLogicalPath:MTDiagnosticsLogicalPath
                             error:NULL];
    return path == nil ? nil : [NSURL fileURLWithPath:path isDirectory:YES];
#endif
}

static void MTAppendContracts(
    NSMutableString *text,
    NSString *groupID,
    NSArray<NSDictionary<NSString *, id> *> *contracts,
    BOOL satisfiedWanted) {
    for (NSDictionary<NSString *, id> *contract in contracts) {
        if (![contract isKindOfClass:NSDictionary.class]) continue;
        NSString *owner = contract[@"adapter"];
        if (groupID != nil &&
            (![owner isKindOfClass:NSString.class] || ![owner isEqualToString:groupID])) {
            continue;
        }
        BOOL satisfied = [contract[@"satisfied"] boolValue];
        if (satisfied != satisfiedWanted) continue;
        NSString *name = contract[@"contract"];
        if (![name isKindOfClass:NSString.class]) continue;
        [text appendFormat:@"  %@ %@\n", satisfied ? @"OK  " : @"FAIL", name];
        if (satisfied) continue;
        id expected = contract[@"expected"];
        id actual = contract[@"actual"];
        if ([expected isKindOfClass:NSString.class]) {
            [text appendFormat:@"      expected: %@\n", expected];
        }
        // NSNull means the class or selector was absent, which is a different
        // failure from a changed layout.
        [text appendFormat:@"      actual:   %@\n",
            [actual isKindOfClass:NSString.class] ? actual : @"<absent>"];
    }
}

// Contracts print under the adapter that recorded them, failures first: a
// failing contract is the reason the surface stayed stock. Ungrouped
// contracts (if any) print last.
static void MTAppendAllContracts(
    NSMutableString *text,
    NSArray<NSString *> *groupIDs,
    NSArray<NSDictionary<NSString *, id> *> *contracts) {
    for (NSString *groupID in groupIDs) {
        MTAppendContracts(text, groupID, contracts, NO);
        MTAppendContracts(text, groupID, contracts, YES);
    }
    NSMutableArray<NSString *> *ungrouped = [NSMutableArray array];
    for (NSDictionary<NSString *, id> *contract in contracts) {
        if (![contract isKindOfClass:NSDictionary.class]) continue;
        NSString *owner = contract[@"adapter"];
        if (![owner isKindOfClass:NSString.class] ||
            [groupIDs containsObject:owner] ||
            [ungrouped containsObject:owner]) {
            continue;
        }
        [ungrouped addObject:owner];
    }
    for (NSString *groupID in ungrouped) {
        MTAppendContracts(text, groupID, contracts, NO);
        MTAppendContracts(text, groupID, contracts, YES);
    }
}

static NSString *MTTextForReport(NSDictionary<NSString *, id> *report) {
    NSMutableString *text = [NSMutableString string];
    [text appendFormat:@"profile: %@\n", report[@"profile"] ?: @"?"];
    [text appendFormat:@"process: %@\n", report[@"process"] ?: @"?"];

    NSArray<NSDictionary<NSString *, id> *> *contracts = @[];
    if ([report[@"contracts"] isKindOfClass:NSArray.class]) {
        contracts = report[@"contracts"];
    }

    NSDictionary<NSString *, id> *adapters = report[@"adapters"];
    NSMutableArray<NSString *> *adapterIDs = [NSMutableArray array];
    if ([adapters isKindOfClass:NSDictionary.class]) {
        [adapterIDs addObjectsFromArray:[adapters.allKeys
            sortedArrayUsingSelector:@selector(compare:)]];
    }
    for (NSString *adapterID in adapterIDs) {
        NSDictionary<NSString *, id> *state = adapters[adapterID];
        if (![state isKindOfClass:NSDictionary.class]) continue;
        [text appendFormat:@"adapter: %@ -> %@ (%@)\n", adapterID,
            state[@"stateName"] ?: @"?", state[@"state"] ?: @"?"];
        MTAppendContracts(text, adapterID, contracts, NO);
        MTAppendContracts(text, adapterID, contracts, YES);
    }

    NSDictionary<NSString *, id> *modules = report[@"modules"];
    if ([modules isKindOfClass:NSDictionary.class] && modules.count > 0) {
        for (NSString *moduleID in [modules.allKeys
                sortedArrayUsingSelector:@selector(compare:)]) {
            NSDictionary<NSString *, id> *state = modules[moduleID];
            if (![state isKindOfClass:NSDictionary.class]) continue;
            [text appendFormat:@"module: %@ -> %@ (%@)\n", moduleID,
                state[@"stateName"] ?: @"?", state[@"state"] ?: @"?"];
        }
    }

    // Contracts recorded by owners without a recorded state still print, so
    // no probe evidence is silently dropped.
    MTAppendAllContracts(text, adapterIDs, contracts);
    return text;
}

NSString *MTDiagnosticsReportText(void) {
    NSURL *directory = MTDiagnosticsDirectoryURL();
    NSMutableString *text = [NSMutableString string];
    [text appendString:@"MarkTheme diagnostics\n"];

    NSArray<NSURL *> *files = directory == nil ? nil :
        [NSFileManager.defaultManager
            contentsOfDirectoryAtURL:directory
          includingPropertiesForKeys:nil
                             options:NSDirectoryEnumerationSkipsHiddenFiles
                               error:NULL];
    if (files.count == 0) {
        [text appendFormat:@"os: %@\n\nNo runtime report yet.\n"
             "Apply a theme, respring, then reopen this page.",
            NSProcessInfo.processInfo.operatingSystemVersionString ?: @"?"];
        return text;
    }

    NSArray<NSURL *> *sorted = [files sortedArrayUsingComparator:
        ^NSComparisonResult(NSURL *lhs, NSURL *rhs) {
        return [lhs.lastPathComponent compare:rhs.lastPathComponent];
    }];
    for (NSURL *file in sorted) {
        if (![file.pathExtension isEqualToString:@"json"]) continue;
        NSData *data = [NSData dataWithContentsOfURL:file];
        if (data == nil) continue;
        id object = [NSJSONSerialization JSONObjectWithData:data
                                                    options:0
                                                      error:NULL];
        if (![object isKindOfClass:NSDictionary.class]) continue;
        NSDictionary<NSString *, id> *report = object;
        // The OS and hardware are identical across reports; print them once,
        // taken from the report itself so they describe the host process that
        // actually probed the ABI rather than this app.
        if (![text containsString:@"device:"]) {
            [text appendFormat:@"os: %@\ndevice: %@\n",
                report[@"systemVersion"] ?: @"?", report[@"machine"] ?: @"?"];
        }
        [text appendString:@"\n"];
        [text appendString:MTTextForReport(report)];
    }
    return text;
}
