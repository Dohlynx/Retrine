// The Audio effects page as the redesigned player's ⋯ opens it: SGDSPShowSettingsSheet (AudioEffectsPage.m) for
// real, from the ⋯ of a stand-in player at the window's root, in a window held light so the sheet's own dark
// shows. Fingers through ../tabbar/touch.m. Each scenario logs PASS lines and exits 0, or exits 1 on the
// first failure (../harness-fail.h).
//
//     sheet=flow      two requests before the sheet is up present one sheet, dark, titled Audio effects; a
//                     request while it is up presents nothing; a finger on Effects switches the effects on through
//                     AudioEffects.h and the summary reads On; Presets pushes inside the sheet; a finger on Close
//                     takes it away and the player is on top, the change kept; then the ⋯ opens it again.
//     sheet=exhaust   another presentation still running when the wait for the menu runs out: no sheet from the
//                     moving controller, none once it has finished, and a later request presents the sheet.
#import <UIKit/UIKit.h>
#import "Shared/AudioEffects/AudioEffects.h"
#import "Shared/AudioEffects/AudioEffectsPage.h"
#import "../harness-fail.h"

extern void SGHarnessTap(UIWindow *window, CGPoint point);

static void check(BOOL ok, NSString *what) {
    if (!ok) HARNESS_FAIL(@"%@", what);
    NSLog(@"[harness] PASS %@", what);
}

static void after(NSTimeInterval seconds, dispatch_block_t block) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), block);
}

static UIView *find(UIView *root, BOOL (^match)(UIView *)) {
    if (match(root)) return root;
    for (UIView *child in root.subviews) {
        UIView *found = find(child, match);
        if (found) return found;
    }
    return nil;
}

// A finger on `view`'s middle.
static void tapView(UIView *view) {
    CGPoint middle = [view convertPoint:CGPointMake(CGRectGetMidX(view.bounds), CGRectGetMidY(view.bounds)) toView:nil];
    SGHarnessTap(view.window, middle);
}

// Longer than the helper's wait for the menu (20 looks 0.05 s apart), and what the checks wait for after a request.
static const NSTimeInterval kSlowSeconds = 3, kPresentSeconds = 1.5;

// A presentation that runs kSlowSeconds.
@interface SGHarnessSlowPresentation : NSObject <UIViewControllerAnimatedTransitioning, UIViewControllerTransitioningDelegate>
@end

@implementation SGHarnessSlowPresentation
- (NSTimeInterval)transitionDuration:(id<UIViewControllerContextTransitioning>)context {
    return kSlowSeconds;
}

- (void)animateTransition:(id<UIViewControllerContextTransitioning>)context {
    UIViewController *toController = [context viewControllerForKey:UITransitionContextToViewControllerKey];
    UIView *to = [context viewForKey:UITransitionContextToViewKey] ?: toController.view;
    to.frame = [context finalFrameForViewController:toController];
    to.alpha = 0;
    [context.containerView addSubview:to];
    [UIView animateWithDuration:kSlowSeconds animations:^{ to.alpha = 1; } completion:^(BOOL finished) { [context completeTransition:YES]; }];
}

- (id<UIViewControllerAnimatedTransitioning>)animationControllerForPresentedController:(UIViewController *)presented
                                                                  presentingController:(UIViewController *)presenting
                                                                      sourceController:(UIViewController *)source {
    return self;
}
@end

@interface SGHarnessSheetPlayer : UIViewController
@property (nonatomic, copy) NSString *scenario;
@property (nonatomic, strong) UIButton *more;
@property (nonatomic, strong) SGHarnessSlowPresentation *slow;
@end

@implementation SGHarnessSheetPlayer

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.25 green:0.1 blue:0.2 alpha:1];
    self.more = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.more setImage:[UIImage systemImageNamed:@"ellipsis"] forState:UIControlStateNormal];
    self.more.frame = CGRectMake(342, 70, 48, 48);
    [self.view addSubview:self.more];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    static BOOL started;
    if (started) return;
    started = YES;
    after(1, ^{
        if ([self.scenario isEqualToString:@"flow"]) [self flow];
        else if ([self.scenario isEqualToString:@"exhaust"]) [self exhaust];
        else HARNESS_FAIL(@"no sheet scenario %@", self.scenario);
    });
}

- (void)finish {
    NSLog(@"[harness] done");
    exit(0);
}

- (void)flow {
    check(!SGDSPSwitch(SGKeyDSP), @"effects start off");
    SGDSPShowSettingsSheet(self.more);
    SGDSPShowSettingsSheet(self.more);
    after(kPresentSeconds, ^{
        UINavigationController *sheet = (UINavigationController *)self.presentedViewController;
        check([sheet isKindOfClass:UINavigationController.class], @"a navigation sheet is presented over the player");
        check(sheet.presentedViewController == nil, @"two pending requests present one sheet");
        UITableViewController *page = (UITableViewController *)sheet.viewControllers.firstObject;
        check([page.title isEqualToString:@"Audio effects"], @"its page is Audio effects");
        check(sheet.overrideUserInterfaceStyle == UIUserInterfaceStyleDark && sheet.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark,
              @"the sheet is dark in a light window");
        check(sheet.view.window == self.view.window && sheet.presentationController.containerView.alpha == 1, @"the sheet is on screen");
        SGDSPShowSettingsSheet(self.more);
        after(kPresentSeconds, ^{
            check(sheet.presentedViewController == nil && self.presentedViewController == sheet, @"a request while the sheet is up presents nothing");
            UISwitch *toggle = (UISwitch *)[page.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]].accessoryView;
            check([toggle isKindOfClass:UISwitch.class], @"the Effects switch is there");
            tapView(toggle);
            after(0.8, ^{
                check(SGDSPSwitch(SGKeyDSP) && toggle.on, @"a finger on Effects switches the effects on through AudioEffects.h");
                check([SGDSPSummary() isEqualToString:@"On"], @"the menu's summary now reads On");
                tapView([page.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:1 inSection:0]]);
                after(1, ^{
                    check(sheet.viewControllers.count == 2, @"Presets pushes inside the sheet");
                    [sheet popViewControllerAnimated:YES];
                    after(1, ^{ [self closeSheet:sheet]; });
                });
            });
        });
    });
}

// Close is the bar's one control at its leading edge (iOS 26 gives the bar button's view no label of its own).
- (void)closeSheet:(UINavigationController *)sheet {
    UIView *close = find(sheet.navigationBar, ^BOOL(UIView *v) {
        CGRect frame = [v convertRect:v.bounds toView:nil];
        return [v isKindOfClass:UIControl.class] && v.window && !v.hidden && v.alpha > 0 && CGRectGetMaxX(frame) < 120 && frame.size.width > 0;
    });
    check(close != nil, @"the sheet has a Close button");
    tapView(close);
    // Held weakly from here: the helper takes a sheet that is still alive for one still up.
    __weak UINavigationController *closed = sheet;
    after(1.2, ^{
        check(self.presentedViewController == nil && !closed.viewIfLoaded.window, @"Close dismisses the sheet back to the player");
        check(SGDSPSwitch(SGKeyDSP), @"the change stays after closing");
        SGDSPShowSettingsSheet(self.more);
        after(kPresentSeconds, ^{
            check([self.presentedViewController isKindOfClass:UINavigationController.class], @"a request after closing presents the sheet again");
            [self finish];
        });
    });
}

- (void)exhaust {
    self.slow = [SGHarnessSlowPresentation new];
    UIViewController *blocker = [UIViewController new];
    blocker.view.backgroundColor = UIColor.systemTealColor;
    blocker.modalPresentationStyle = UIModalPresentationOverFullScreen;   // the player, and its ⋯, stay in the window
    blocker.transitioningDelegate = self.slow;
    [self presentViewController:blocker animated:YES completion:nil];
    SGDSPShowSettingsSheet(self.more);
    after(kPresentSeconds, ^{
        check(blocker.isBeingPresented, @"the other presentation is still running after the wait");
        check(blocker.presentedViewController == nil, @"no sheet is presented from the moving controller");
        after(kSlowSeconds, ^{
            check(!blocker.isBeingPresented && self.presentedViewController == blocker, @"the other presentation finished");
            check(blocker.presentedViewController == nil, @"the dropped request does not present later");
            SGDSPShowSettingsSheet(self.more);
            after(kPresentSeconds, ^{
                UINavigationController *sheet = (UINavigationController *)blocker.presentedViewController;
                check([sheet isKindOfClass:UINavigationController.class] && [sheet.viewControllers.firstObject.title isEqualToString:@"Audio effects"],
                      @"a request after the dropped one presents the sheet");
                [self finish];
            });
        });
    });
}

@end

void SGHarnessRunSheet(UIWindow *window, NSString *scenario) {
    SGHarnessSheetPlayer *player = [SGHarnessSheetPlayer new];
    player.scenario = scenario;
    window.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
    window.rootViewController = player;
    [window makeKeyAndVisible];
}
