#import <Foundation/Foundation.h>

@class MTGenerationWriter;
@class MTImportCancellationToken;
@class MTRuntimeHelperClient;
@class MTRuntimeState;
@class MTStaticIconCompiler;
@class MTThemeComponentSelection;
@class MTThemeLibraryStore;
@class MTThemeMixSelection;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTThemeApplyServiceErrorDomain;
FOUNDATION_EXPORT NSString *const MTThemeApplyServiceStageKey;

typedef NS_ENUM(NSInteger, MTThemeApplyServiceErrorCode) {
    MTThemeApplyServiceErrorInvalidRequest = 1,
    MTThemeApplyServiceErrorCancelled = 2,
    MTThemeApplyServiceErrorLibrary = 3,
    MTThemeApplyServiceErrorCompile = 4,
    MTThemeApplyServiceErrorInbox = 5,
    MTThemeApplyServiceErrorRuntime = 6,
};

typedef NS_ENUM(NSInteger, MTThemeApplyStage) {
    MTThemeApplyStageLoadLibrary = 1,
    MTThemeApplyStageCompile = 2,
    MTThemeApplyStageWriteInbox = 3,
    MTThemeApplyStageActivateRuntime = 4,
};

@interface MTThemeApplyResult : NSObject

@property(nonatomic, copy, readonly) NSString *themeID;
@property(nonatomic, copy, readonly) NSString *libraryRevisionIdentifier;
@property(nonatomic, copy, readonly) NSString *generationIdentifier;
@property(nonatomic, assign, readonly) BOOL reusedInboxGeneration;
@property(nonatomic, assign, readonly) BOOL reusedRuntimeGeneration;
@property(nonatomic, strong, readonly) MTRuntimeState *runtimeState;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

// Synchronous Manager use case. Callers own queueing and UI state. The
// default service writes the compiled Generation directly into the fixed
// mobile-owned PublishInbox, then invokes the short-lived Helper; it does not
// create an additional Compiler-store copy.
@interface MTThemeApplyService : NSObject

@property(nonatomic, strong, readonly) MTThemeLibraryStore *libraryStore;
@property(nonatomic, strong, readonly) MTStaticIconCompiler *compiler;
@property(nonatomic, strong, readonly) MTGenerationWriter *inboxWriter;
@property(nonatomic, strong, readonly) MTRuntimeHelperClient *runtimeClient;

+ (nullable instancetype)defaultServiceWithError:(NSError **)error;
+ (nullable instancetype)defaultServiceWithLibraryStore:
    (MTThemeLibraryStore *)libraryStore
                                                  error:(NSError **)error;

- (instancetype)initWithLibraryStore:(MTThemeLibraryStore *)libraryStore
                              compiler:(MTStaticIconCompiler *)compiler
                           inboxWriter:(MTGenerationWriter *)inboxWriter
                         runtimeClient:(MTRuntimeHelperClient *)runtimeClient
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (nullable MTThemeApplyResult *)
    applyCurrentThemeWithIdentifier:(NSString *)themeID
                  cancellationToken:
                      (nullable MTImportCancellationToken *)cancellationToken
                              error:(NSError **)error;

- (nullable MTThemeApplyResult *)
    applyCurrentThemeWithIdentifier:(NSString *)themeID
                  componentSelection:
                      (nullable MTThemeComponentSelection *)componentSelection
                  cancellationToken:
                      (nullable MTImportCancellationToken *)cancellationToken
                              error:(NSError **)error;

// Loads every exact current Library revision referenced by the immutable mix,
// compiles one Generation, and activates it through the same Inbox/Helper path.
- (nullable MTThemeApplyResult *)applyThemeMixSelection:
    (MTThemeMixSelection *)mixSelection
                                  cancellationToken:
                                      (nullable MTImportCancellationToken *)cancellationToken
                                              error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
