include ../Config.mk
include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = MarkTheme

MarkTheme_FILES = main.m MTAppDelegate.m MTDesignSystem.m \
    MTApplyResultViewController.m \
    MTThemePreviewProvider.m MTThemePreviewRepository.m \
    MTFoundationViewController.m \
    MTThemeLibraryViewController.m MTThemeDetailViewController.m \
    MTSettingsViewController.m \
    MTDiagnosticsReport.m \
    MTDiagnosticsViewController.m \
    MTImportViewController.m \
    ../core/MTIdentifier.m \
    ../core/MTImportLimits.m \
    ../core/MTVersionContracts.m \
    ../core/MTCanonicalJSON.m \
    ../core/MTDigest.m \
    ../core/MTResourceKey.m \
    ../core/MTSourceInventory.m \
    ../core/MTThemeManifest.m \
    ../core/MTDiagnostic.m \
    ../core/MTLayerResolver.m \
    ../core/MTModuleConfiguration.m \
    ../modules/MTModuleDescriptor.m \
    ../modules/MTModuleRegistry.m \
    ../modules/MTStaticIconsModule.m \
    ../modules/MTStaticIconConfiguration.m \
    ../modules/MTBadgeContract.m \
    ../modules/MTBadgeConfiguration.m \
    ../modules/MTBadgesModule.m \
    ../modules/MTCalendarIconConfiguration.m \
    ../modules/MTCalendarIconsModule.m \
    ../modules/MTClockIconContract.m \
    ../modules/MTClockIconsModule.m \
    ../modules/MTDialerContract.m \
    ../modules/MTDialerModule.m \
    ../modules/MTFolderIconContract.m \
    ../modules/MTFolderIconsModule.m \
    ../modules/MTIconMaskConfiguration.m \
    ../modules/MTIconMaskContract.m \
    ../modules/MTIconMaskModule.m \
    ../modules/MTIconOverlayContract.m \
    ../modules/MTIconOverlayModule.m \
    ../modules/MTIconShadowConfiguration.m \
    ../modules/MTIconShadowContract.m \
    ../modules/MTIconShadowsModule.m \
    ../modules/MTThemeComponentCatalog.m \
    ../modules/MTThemeMixSelection.m \
    ../modules/MTStatusBarContract.m \
    ../modules/MTStatusBarModule.m \
    ../modules/MTUIResourcesModule.m \
    ../compiler/MTGenerationDescriptor.m \
    ../compiler/MTGenerationAssetWriter.m \
    ../compiler/MTGenerationFilesystem.m \
    ../compiler/MTGenerationIndexCodec.m \
    ../compiler/MTGenerationReader.m \
    ../compiler/MTGenerationReaderFilesystem.m \
    ../compiler/MTGenerationReaderValidation.m \
    ../compiler/MTGenerationRecovery.m \
    ../compiler/MTStaticIconCompiler.m \
    ../compiler/MTGenerationWriter.m \
    ../compiler/MTGenerationWriterValidation.m \
    ../ingestion/MTDirectorySnapshotFilesystem.m \
    ../ingestion/MTDirectorySnapshotSession.m \
    ../ingestion/MTExpandedArchiveSession.m \
    ../ingestion/MTImportSession.m \
    ../ingestion/MTAuditedSource.m \
    ../ingestion/MTAuditedZIPEntryStreamer.m \
    ../ingestion/MTSafeImageDecoder.m \
    ../ingestion/MTSafeImageInspector.m \
    ../ingestion/MTSafePropertyListReader.m \
    ../ingestion/MTSafeZIPArchiveReader.m \
    ../importers/MTSafeDirectoryScanner.m \
    ../importers/MTIconBundlesImporter.m \
    ../importers/MTLegacyThemeResourcesImporter.m \
    ../importers/MTThemeComponentPath.m \
    ../importers/MTUIResourcesImporter.m \
    ../importers/MTThemeInfoMetadataImporter.m \
    ../importers/MTThemeInfoMetadataMapper.m \
    ../library/MTAssetStagingFilesystem.m \
    ../library/MTAssetStagingSession.m \
    ../library/MTThemeLibraryFilesystem.m \
    ../library/MTThemeLibraryStore.m \
    ../library/MTThemeLibraryTransaction.m \
    ../library/MTThemeLibraryCatalog.m \
    ../workflow/MTThemeImport.m \
    ../workflow/MTImportDiagnostics.m \
    ../workflow/MTThemeSourceRoot.m \
    ../workflow/MTInstalledThemeLocator.m \
    ../workflow/MTImportCoordinator.m \
    ../workflow/MTThemeApplyService.m \
    ../workflow/MTThemeComponentSelectionStore.m \
    ../workflow/MTManagerController.m \
    ../workflow/MTThemeCapabilityReport.m \
    ../platform/MTBootstrapPaths.m \
    ../store/MTRuntimeState.m \
    ../store/MTRuntimeHelperClient.m \
    ../runtime/MTRuntimeSnapshot.m \
    ../runtime/MTRuntimeSnapshotLoader.m
MarkTheme_FRAMEWORKS = UIKit CoreGraphics ImageIO UniformTypeIdentifiers
MarkTheme_LIBRARIES = z $(MARKTHEME_PATH_LIBRARIES)
MarkTheme_CFLAGS = -fobjc-arc -fblocks -Wall -Wextra -Werror \
    $(MARKTHEME_PATH_CFLAGS) \
    -DMARKTHEME_RUNTIME_BUILD_NUMBER=$(MARKTHEME_RUNTIME_BUILD_NUMBER) \
    -I../core -I../compiler -I../ingestion -I../importers -I../library \
    -I../modules -I../platform -I../runtime -I../store -I../workflow
MarkTheme_CODESIGN_FLAGS = -Sentitlements.plist -Icom.hmmzzz.marktheme
MarkTheme_RESOURCE_DIRS = Resources

include $(THEOS_MAKE_PATH)/application.mk
