#import "Core/SGCore.h"
#import "Shared/Player/PlayerState.h"
#import "SponsorBlock.h"

// Spotify 9.1.90 Objective-C metadata: v48@0:8@16@24@?32@?40. This is Spotify's
// existing timed, accessible action snackbar; no Vitrine overlay or playback timer.
@protocol SGSponsorBlockSnackbar <NSObject>
- (void)presentSnackbarWithText:(NSString *)text buttonTitle:(NSString *)title
                   actionBlock:(dispatch_block_t)action presentationEndedBlock:(id)ended;
@end
static __weak id<SGSponsorBlockSnackbar> sg_presenter;
static SGSponsorBlockSession *sg_session;

@interface SGSponsorBlockObserver : NSObject <SGPlayerStateObserver>
@end
@implementation SGSponsorBlockObserver
- (void)playerStateDidChange:(SPTPlayerState *)state {}
- (void)playerStateDidReport:(SPTPlayerState *)state {
    [sg_session observeURI:SGURIString(state.track.URI) position:state.position duration:state.duration
        playing:state.isPlaying && !state.isPaused && !state.isLoading
        enabled:sg_presenter != nil && [SGPlayer() respondsToSelector:@selector(seekTo:)]];
}
@end
static SGSponsorBlockObserver *sg_observer;

%group SGSponsorBlockNotice
%hook SPTSnackbarInternalPresenterImplementation
- (id)initWithTheme:(id)theme viewPresenter:(id)viewPresenter imageLoader:(id)imageLoader
              isRTL:(BOOL)isRTL properties:(id)properties messageOrchestrator:(id)orchestrator {
    id result = %orig;
    dispatch_async(dispatch_get_main_queue(), ^{ sg_presenter = result; });
    return (__bridge id)CFBridgingRetain(result);
}
%end
%end

static BOOL methodMatches(Class cls, SEL selector, const char *result, NSArray<NSString *> *arguments) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method || method_getNumberOfArguments(method) != arguments.count + 2) return NO;
    char type[64];
    method_getReturnType(method, type, sizeof(type));
    if (strcmp(type, result)) return NO;
    for (NSUInteger i = 0; i < arguments.count; i++) {
        method_getArgumentType(method, (unsigned int)i + 2, type, sizeof(type));
        if (strcmp(type, arguments[i].UTF8String)) return NO;
    }
    return YES;
}

%ctor {
    if (!SGFlag(SGKeySponsorBlock, NO)) return;
    Class cls = NSClassFromString(@"SPTSnackbarInternalPresenterImplementation");
    if (!methodMatches(cls, @selector(initWithTheme:viewPresenter:imageLoader:isRTL:properties:messageOrchestrator:),
                       "@", @[@"@", @"@", @"@", @"B", @"@", @"@"]) ||
        !methodMatches(cls, @selector(presentSnackbarWithText:buttonTitle:actionBlock:presentationEndedBlock:),
                       "v", @[@"@", @"@", @"@?", @"@?"])) {
        SGLog(@"SponsorBlock: Spotify's action snackbar is unavailable; skipping disabled");
        return;
    }
    %init(SGSponsorBlockNotice);
    dispatch_async(dispatch_get_main_queue(), ^{
        NSMutableSet *categories = [NSMutableSet set];
        for (NSString *category in SGSponsorBlockCategories())
            if (SGFlag(SGSponsorBlockCategoryKey(category), SGSponsorBlockCategoryDefault(category))) [categories addObject:category];
        sg_session = [[SGSponsorBlockSession alloc] initWithCategories:categories
            fetch:^(NSString *episode, NSSet *selected, SGSponsorBlockReply reply) {
                SGSponsorBlockFetchSegments(episode, selected, reply);
            } seek:^(double seconds) {
                [(id<SPTPlayer>)SGPlayer() seekTo:seconds];
            } notice:^(SGSponsorBlockSegment *segment, dispatch_block_t undo) {
                [sg_presenter presentSnackbarWithText:SGL(@"settings.sponsorblock.skipped", @"Skipped a podcast segment")
                    buttonTitle:SGL(@"settings.sponsorblock.undo", @"Undo") actionBlock:^{
                        // Refresh the identity before acting, even if the notice outlived its episode.
                        [sg_session observeURI:SGURIString(SGPlayerState().track.URI) position:0 duration:0 playing:NO
                            enabled:SGPlayer() != nil];
                        undo();
                    } presentationEndedBlock:nil];
            }];
        sg_observer = [SGSponsorBlockObserver new];
        SGAddPlayerStateObserver(sg_observer);
        if (SGPlayerState()) [sg_observer playerStateDidReport:SGPlayerState()];
    });
}
