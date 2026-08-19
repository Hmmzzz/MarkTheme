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
    NSArray<NSDictionary<NSString *, id> *> *contracts,
    BOOL satisfiedWanted) {
    for (NSDictionary<NSString *, id> *contract in contracts) {
        if (![contract isKindOfClass:NSDictionary.class]) continue;
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

static NSString *MTTextForReport(NSDictionary<NSString *, id> *report) {
    NSMutableString *text = [NSMutableString string];
    [text appendFormat:@"profile: %@\n", report[@"profile"] ?: @"?"];
    [text appendFormat:@"process: %@\n", report[@"process"] ?: @"?"];

    NSDictionary<NSString *, id> *adapters = report[@"adapters"];
    if ([adapters isKindOfClass:NSDictionary.class] && adapters.count > 0) {
        for (NSString *adapterID in [adapters.allKeys
                sortedArrayUsingSelector:@selector(compare:)]) {
            NSDictionary<NSString *, id> *state = adapters[adapterID];
            if (![state isKindOfClass:NSDictionary.class]) continue;
            [text appendFormat:@"adapter: %@ -> %@ (%@)\n", adapterID,
                state[@"stateName"] ?: @"?", state[@"state"] ?: @"?"];
        }
    }

    NSArray<NSDictionary<NSString *, id> *> *contracts = report[@"contracts"];
    if ([contracts isKindOfClass:NSArray.class] && contracts.count > 0) {
        // Failures first: they are the reason the surface stayed stock.
        MTAppendContracts(text, contracts, NO);
        MTAppendContracts(text, contracts, YES);
    }
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
