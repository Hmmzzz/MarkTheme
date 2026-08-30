#import "MTDiagnosticsReport.h"

#import "MTBootstrapPaths.h"
#import "MTImportDiagnostics.h"

static NSURL *MTDiagnosticsDirectoryURL(void) {
    return [MTDefaultManagerDataRootURL()
        URLByAppendingPathComponent:@"Diagnostics" isDirectory:YES];
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
// failing contract is the reason the surface stayed stock. Owners without a
// recorded adapter state (if any) print once at the end.
static void MTAppendRemainingContracts(
    NSMutableString *text,
    NSArray<NSString *> *groupIDs,
    NSArray<NSDictionary<NSString *, id> *> *contracts) {
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

static NSString *MTDiagnosticValueText(id value) {
    if (value == nil || value == NSNull.null) return @"<none>";
    if ([value isKindOfClass:NSString.class]) return value;
    if ([value isKindOfClass:NSNumber.class]) {
        return [value stringValue];
    }
    if ([value isKindOfClass:NSArray.class]) {
        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        for (id item in (NSArray *)value) {
            [parts addObject:MTDiagnosticValueText(item)];
        }
        return [parts componentsJoinedByString:@", "];
    }
    return [value description] ?: @"<unknown>";
}

static NSString *MTObservationGroupName(NSString *compactID) {
    if ([compactID isEqualToString:@"nativeIcon"]) {
        return @"application-icon.native-invalidation";
    }
    if ([compactID isEqualToString:@"calendar"]) {
        return @"springboard.calendar-appearance";
    }
    if ([compactID isEqualToString:@"calendarSource"]) {
        return @"calendar-ui-kit.dynamic-icon-source";
    }
    if ([compactID isEqualToString:@"calendarRender"]) {
        return @"calendar-icons.renderer";
    }
    if ([compactID isEqualToString:@"clockSource"]) {
        return @"springboard-home.clock-icon-sources";
    }
    if ([compactID isEqualToString:@"clock"]) {
        return @"clock-icons.snapshot";
    }
    if ([compactID isEqualToString:@"dialerSource"]) {
        return @"mobilephone.dialer-buttons";
    }
    if ([compactID isEqualToString:@"dialer"]) {
        return @"dialer.snapshot";
    }
    if ([compactID isEqualToString:@"folderSource"]) {
        return @"springboard-home.folder-icon-source";
    }
    if ([compactID isEqualToString:@"badgeSource"]) {
        return @"springboard-home.badge-source";
    }
    if ([compactID isEqualToString:@"preferencesSource"]) {
        return @"preferences.ui-resource-image";
    }
    if ([compactID isEqualToString:@"searchCalendar"]) {
        return @"spotlight.calendar-appearance";
    }
    if ([compactID isEqualToString:@"shareGlyph"]) {
        return @"share-sheet.activity-glyph";
    }
    if ([compactID isEqualToString:@"statusBarSource"]) {
        return @"springboard.statusbar-signal-image";
    }
    if ([compactID isEqualToString:@"statusBar"]) {
        return @"statusbar.snapshot";
    }
    if ([compactID isEqualToString:@"static"]) {
        return @"static-icons.snapshot";
    }
    if ([compactID isEqualToString:@"mask"]) {
        return @"icon-mask.snapshot";
    }
    if ([compactID isEqualToString:@"overlay"]) {
        return @"icon-overlay.snapshot";
    }
    if ([compactID isEqualToString:@"overlayDebug"]) {
        return @"icon-overlay.debug";
    }
    if ([compactID isEqualToString:@"view"]) {
        return @"springboard.icon-shadow";
    }
    if ([compactID isEqualToString:@"shadowCarrier"]) {
        return @"springboard-home.icon-shadow-carrier";
    }
    if ([compactID isEqualToString:@"shadow"]) {
        return @"icon-shadow.snapshot";
    }
    if ([compactID isEqualToString:@"morph"]) {
        return @"springboard.icon-morph-carrier";
    }
    if ([compactID isEqualToString:@"folder"]) {
        return @"folder-icons.snapshot";
    }
    if ([compactID isEqualToString:@"badge"]) {
        return @"badges.snapshot";
    }
    if ([compactID isEqualToString:@"uiResources"]) {
        return @"ui-resources.snapshot";
    }
    return compactID;
}

static NSArray<NSString *> *MTObservationLabels(NSString *compactID,
                                                NSUInteger schema) {
    if ([compactID isEqualToString:@"nativeIcon"]) {
        if (schema <= 3) {
            return @[
                @"requests", @"verifiedRequests", @"launchServicesSignals",
                @"notificationCacheClears", @"preferencesReloads",
                @"shareSheetCacheClears", @"shareSheetReloads", @"failures",
                @"clientCacheInvalidations", @"clientRegisteredIcons",
                @"clientRegistryEntriesRemoved", @"clientImageCachesCleared",
                @"clientDescriptorBagsCleared", @"springBoardCachePurges",
                @"springBoardObserverSignals", @"shareSheetProvidersTracked",
            ];
        }
        return @[
            @"requests", @"verifiedRequests", @"launchServicesSignals",
            @"notificationCacheClears", @"preferencesReloads",
            @"shareSheetCacheClears", @"shareSheetReloads", @"failures",
            @"clientCacheInvalidations", @"clientRegisteredIcons",
            @"clientRegistryEntriesRemoved", @"clientImageCachesCleared",
            @"clientDescriptorBagsCleared", @"shareSheetProvidersTracked",
        ];
    }
    if ([compactID isEqualToString:@"calendar"]) {
        return @[
            @"installed", @"generatedCalls", @"appearanceReplacements",
        ];
    }
    if ([compactID isEqualToString:@"calendarSource"]) {
        return @[
            @"state", @"calls", @"outOfScopeCalls",
            @"originalFailures", @"resolverMisses", @"rasterRejects",
            @"replacements",
        ];
    }
    if ([compactID isEqualToString:@"calendarRender"]) {
        return @[
            @"renderAttempts", @"renderSuccesses", @"renderFailures",
        ];
    }
    if ([compactID isEqualToString:@"clockSource"]) {
        return @[
            @"state", @"faceSourceCalls", @"maskedFaceCalls",
            @"unmaskedFaceCalls", @"themedFaces", @"handSourceCalls",
            @"themedHandSets", @"originalFailures", @"resolverMisses",
            @"contractRejects",
        ];
    }
    if ([compactID isEqualToString:@"clock"]) {
        return @[
            @"state", @"reloads", @"resourceRequests", @"resourceHits",
            @"decodeSuccesses", @"decodeFailures", @"imageSetPublishes",
            @"componentMatchRequests", @"componentMatchResults",
            @"staleResultsDiscarded",
        ];
    }
    if ([compactID isEqualToString:@"dialerSource"]) {
        return @[
            @"state", @"installAttempts", @"numberSourceCalls",
            @"numberNormalCalls", @"numberHighlightedCalls",
            @"circleAlphaCalls", @"circleSuppressions",
            @"callButtonCreations", @"callNormalReplacements",
            @"callOverlayRequests", @"callPressedReplacements",
            @"resolverMisses", @"contractRejects",
        ];
    }
    if ([compactID isEqualToString:@"dialer"]) {
        return @[
            @"state", @"reloads", @"imageRequests",
            @"contractRejects", @"resourceHits", @"cacheHits",
            @"decodeSuccesses", @"decodeFailures",
            @"replacementResults", @"completeSetChecks",
            @"completeSetPasses",
        ];
    }
    if ([compactID isEqualToString:@"folderSource"]) {
        return @[
            @"state", @"sourceCalls", @"nativeBackgroundCalls",
            @"nilBackgroundCalls", @"themedBackgrounds",
            @"overlayActivations", @"nativeFallbacks",
            @"contractRejects",
        ];
    }
    if ([compactID isEqualToString:@"badgeSource"]) {
        return @[
            @"state", @"installAttempts", @"sourceCalls",
            @"mainThreadCalls", @"nativeBackgroundCalls",
            @"themedBackgrounds", @"nativeFallbacks",
            @"contractRejects",
        ];
    }
    if ([compactID isEqualToString:@"preferencesSource"]) {
        return @[
            @"state", @"installAttempts", @"totalCalls", @"stringKeys",
            @"nilOriginalResults", @"replacementResults",
        ];
    }
    if ([compactID isEqualToString:@"searchCalendar"]) {
        return @[
            @"state", @"calls", @"replacements", @"trackedImages",
            @"refreshRequests", @"refreshInvalidations",
        ];
    }
    if ([compactID isEqualToString:@"shareGlyph"]) {
        if (schema <= 4) {
            return @[
                @"state", @"calls", @"applicationActivitiesPreserved",
                @"customActivityIdentities", @"replacements",
                @"nativeApplicationBridgeRequests",
                @"nativeApplicationBridgeResults",
                @"providerRequestsTracked",
            ];
        }
        return @[
            @"state", @"installAttempts", @"requestCalls",
            @"deliveryCalls", @"applicationContexts",
            @"customContexts", @"nativeApplicationBridgeResults",
            @"replacements", @"providersTracked", @"contextMisses",
            @"contractRejects",
        ];
    }
    if ([compactID isEqualToString:@"statusBarSource"]) {
        return @[
            @"state", @"installAttempts", @"wifiCommitCalls",
            @"cellularCommitCalls", @"mainThreadCalls",
            @"resolverCalls", @"appliedResults", @"stockFallbacks",
            @"contractRejects",
        ];
    }
    if ([compactID isEqualToString:@"statusBar"]) {
        return @[
            @"state", @"reloads", @"nativeCommitRequests",
            @"contextRequests", @"contextMisses", @"resourceHits",
            @"cacheHits", @"decodeSuccesses", @"decodeFailures",
            @"replacementResults", @"stockRestores",
        ];
    }
    if ([compactID isEqualToString:@"static"]) {
        return @[
            @"state", @"lookupCalls", @"unsupportedOriginalMisses",
            @"snapshotMisses", @"resourceHits", @"cacheHits",
            @"decodeScheduled", @"decodeSuccesses", @"decodeFailures",
        ];
    }
    if ([compactID isEqualToString:@"mask"]) {
        if (schema == 1) {
            return @[
                @"state", @"reloads", @"decodeSuccesses", @"decodeFailures",
                @"resolutionCalls", @"unsupportedCandidateMisses",
                @"compositions",
            ];
        }
        return @[
            @"state", @"reloads", @"decodeSuccesses", @"decodeFailures",
            @"resolutionCalls", @"unsupportedCandidateMisses",
            @"cacheHits", @"compositions", @"memoryPressurePurges",
            @"cacheEvictions",
        ];
    }
    if ([compactID isEqualToString:@"overlay"]) {
        if (schema == 1) {
            return @[
                @"state", @"reloads", @"overlayResourceHits",
                @"decodeSuccesses", @"decodeFailures", @"resolutionCalls",
                @"unsupportedCandidateMisses", @"alreadyProcessedHits",
                @"compositions",
            ];
        }
        return @[
            @"state", @"reloads", @"overlayResourceHits",
            @"decodeSuccesses", @"decodeFailures", @"resolutionCalls",
            @"unsupportedCandidateMisses", @"alreadyProcessedHits",
            @"cacheHits", @"compositions", @"memoryPressurePurges",
            @"cacheEvictions",
        ];
    }
    if ([compactID isEqualToString:@"overlayDebug"]) {
        return @[
            @"invalidRequestMisses", @"imageSetUnavailableMisses",
            @"candidateValidationMisses", @"overlayUnavailableMisses",
            @"compositionMisses",
        ];
    }
    if ([compactID isEqualToString:@"view"]) {
        return @[
            @"state", @"configureCalls", @"imageInfoCalls",
            @"resolverCalls", @"appliedResults", @"refreshRequests",
            @"refreshExecutions",
            @"applicationIconRefreshRequests",
            @"applicationIconCachePurges",
            @"applicationIconObserverSignals",
            @"applicationIconRefreshFailures",
        ];
    }
    if ([compactID isEqualToString:@"shadowCarrier"]) {
        return @[
            @"state", @"installAttempts", @"layoutCalls", @"reuseCalls",
            @"mainThreadCalls", @"folderExclusions", @"resolverCalls",
            @"appliedResults", @"cleanupCalls", @"contractRejects",
        ];
    }
    if ([compactID isEqualToString:@"shadow"]) {
        return @[
            @"state", @"preparationAttempts", @"resourceHits",
            @"decodeSuccesses", @"decodeFailures", @"carrierResolutions",
            @"attachmentsCreated", @"attachmentUpdates",
            @"attachmentsRemoved", @"contextMisses",
        ];
    }
    if ([compactID isEqualToString:@"morph"]) {
        return @[
            @"state", @"scopeUpdates", @"squareContentsCalls",
            @"eligibleCarriers", @"prepareCalls", @"proxyActivations",
            @"fadeSynchronizations", @"cleanups",
        ];
    }
    if ([compactID isEqualToString:@"folder"]) {
        return @[
            @"state", @"reloads", @"baseResourceHits",
            @"lightResourceHits", @"decodeSuccesses", @"decodeFailures",
            @"backgroundResolutions", @"backgroundReplacements",
            @"overlayActivations",
        ];
    }
    if ([compactID isEqualToString:@"badge"]) {
        return @[
            @"state", @"reloads", @"lightResourceHits",
            @"darkResourceHits", @"decodeSuccesses", @"decodeFailures",
            @"nativeSourceResolutions", @"appearanceSelections",
            @"themedBackgrounds", @"nativeFallbacks",
        ];
    }
    if ([compactID isEqualToString:@"uiResources"]) {
        return @[
            @"state", @"lookupCalls", @"snapshotMisses",
            @"resourceHits", @"cacheHits", @"decodeSuccesses",
            @"decodeFailures", @"replacementResults",
            @"memoryPressurePurges",
        ];
    }
    return @[];
}

static NSString *MTTextForReport(NSDictionary<NSString *, id> *report) {
    NSMutableString *text = [NSMutableString string];
    [text appendFormat:@"profile: %@\n", report[@"profile"] ?: @"?"];
    [text appendFormat:@"process: %@\n", report[@"process"] ?: @"?"];
    [text appendFormat:@"runtimeBuild: %@\n",
        report[@"runtimeBuild"] ?: @"<legacy-report>"];
    [text appendFormat:@"generatedAt: %@\n",
        report[@"generatedAt"] ?: @"<legacy-report>"];
    [text appendFormat:@"processIdentifier: %@\n",
        report[@"processIdentifier"] ?: @"<legacy-report>"];
    NSDictionary<NSString *, id> *runtime = report[@"runtime"];
    if ([runtime isKindOfClass:NSDictionary.class] && runtime.count > 0) {
        [text appendFormat:
            @"runtime: sequence=%@ enabled=%@ ready=%@ generation=%@\n",
            runtime[@"sequence"] ?: @"?",
            runtime[@"runtimeEnabled"] ?: @"?",
            runtime[@"ready"] ?: @"?",
            MTDiagnosticValueText(
                runtime[@"activeGenerationIdentifier"])];
    }

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

    NSDictionary<NSString *, id> *observations = report[@"observations"];
    if ([observations isKindOfClass:NSDictionary.class] &&
        observations.count > 0) {
        for (NSString *groupID in [observations.allKeys
                sortedArrayUsingSelector:@selector(compare:)]) {
            id values = observations[groupID];
            [text appendFormat:@"observation: %@\n",
                MTObservationGroupName(groupID)];
            NSUInteger observationSchema =
                [report[@"observationSchema"] unsignedIntegerValue];
            NSArray<NSString *> *labels = MTObservationLabels(
                groupID, observationSchema);
            if (observationSchema >= 1 && observationSchema <= 7 &&
                [values isKindOfClass:NSArray.class] &&
                labels.count == [(NSArray *)values count]) {
                NSArray *compactValues = values;
                for (NSUInteger index = 0; index < labels.count; index++) {
                    [text appendFormat:@"  %@: %@\n", labels[index],
                        MTDiagnosticValueText(compactValues[index])];
                }
                continue;
            }
            if (![values isKindOfClass:NSDictionary.class]) continue;
            NSDictionary<NSString *, id> *legacyValues = values;
            for (NSString *key in [legacyValues.allKeys
                    sortedArrayUsingSelector:@selector(compare:)]) {
                [text appendFormat:@"  %@: %@\n", key,
                    MTDiagnosticValueText(legacyValues[key])];
            }
        }
    }

    NSDictionary<NSString *, id> *samples = report[@"samples"];
    if ([samples isKindOfClass:NSDictionary.class] && samples.count > 0) {
        for (NSString *groupID in [samples.allKeys
                sortedArrayUsingSelector:@selector(compare:)]) {
            id rawGroupSamples = samples[groupID];
            NSArray<NSDictionary<NSString *, id> *> *groupSamples =
                [rawGroupSamples isKindOfClass:NSDictionary.class]
                    ? @[rawGroupSamples] : rawGroupSamples;
            if (![groupSamples isKindOfClass:NSArray.class]) continue;
            [text appendFormat:@"samples: %@ (%lu)\n", groupID,
                (unsigned long)groupSamples.count];
            NSUInteger index = 0;
            for (NSDictionary<NSString *, id> *sample in groupSamples) {
                if (![sample isKindOfClass:NSDictionary.class]) continue;
                index += 1;
                [text appendFormat:@"  #%lu\n", (unsigned long)index];
                for (NSString *key in [sample.allKeys
                        sortedArrayUsingSelector:@selector(compare:)]) {
                    [text appendFormat:@"    %@: %@\n", key,
                        MTDiagnosticValueText(sample[key])];
                }
            }
        }
    }

    // Contracts recorded by owners without a recorded state still print, so
    // no probe evidence is silently dropped.
    MTAppendRemainingContracts(text, adapterIDs, contracts);
    return text;
}

NSString *MTDiagnosticsReportText(void) {
    NSURL *directory = MTDiagnosticsDirectoryURL();
    NSMutableString *text = [NSMutableString string];
    [text appendString:@"MarkTheme diagnostics\n"];
    [text appendFormat:@"appVersion: %@ (%@)\nos: %@\n\n%@",
        NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"?",
        NSBundle.mainBundle.infoDictionary[@"CFBundleVersion"] ?: @"?",
        NSProcessInfo.processInfo.operatingSystemVersionString ?: @"?",
        MTImportDiagnosticsText()];

    NSArray<NSURL *> *files = directory == nil ? nil :
        [NSFileManager.defaultManager
            contentsOfDirectoryAtURL:directory
          includingPropertiesForKeys:nil
                             options:NSDirectoryEnumerationSkipsHiddenFiles
                               error:NULL];
    if (files.count == 0) {
        [text appendString:@"\nNo runtime report yet.\n"
             "Apply a theme, respring, then reopen this page."];
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
