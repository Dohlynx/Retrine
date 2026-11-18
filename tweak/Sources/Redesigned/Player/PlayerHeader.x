// Player redesign: the header the way the Music app's full screen player has it, only a grabber at the top. The
// ordinary player's down arrow and ⋯ are put away, and its ⋯ is the mod's own beside the title (PlayerMenu.m); the
// AI DJ's header keeps both buttons, each on a glass circle, as its ⋯ opens the DJ's own menu.
//
// The ordinary player's two buttons stay Spotify's and in Spotify's row: each goes by alpha, out of VoiceOver's reach
// (Encore's stacks crash on a hidden subview, so never hidden), and its action is still run from code. The ⋯'s brings
// up Spotify's sheet for the menu's rows (PlayerMenu.m, ContextMenu.x); the arrow's closes the player, from the
// grabber. The player still closes with a swipe down, Spotify's own.
//
// The arrow goes only once the grabber has a way to close by: the arrow a control with a tap's action (a primary
// action or a touch up inside, SGRControlActionEvents). Until then, or where it never has one, the arrow stays as
// Spotify's, on glass while Header glass is on, and the grabber is only drawn, as the header was before.
//
// The grabber is a button of the mod's: a tap on it, VoiceOver's activation of it (it reads as the arrow's own words,
// a button) and VoiceOver's escape on it close the player through the arrow's action. It is a subview of the header
// unit's view, so it fades with the row while the lyrics have the player to themselves (PlayerLyrics.x fades that
// view by its alpha) and comes back with it. Its whole touch area lies inside the row, which takes touches only
// within its bounds, and the pill is placed in it on its own, where the Music app has it.
//
// The AI DJ's circles: glass is the control layer floating over the field, so it goes behind the round buttons only.
// Each circle is a subview of the button it sits behind (SGRGlassInside), below what the button draws and taking no
// touches, so the buttons stay Spotify's, with their actions, state and accessibility, and the circle follows the
// button wherever Spotify's row puts it. Circles placed from the unit's layout pass instead (a backing across the
// unit's view) were read before the row had laid the buttons out and sat 24pt up and to the side until a tap laid
// the unit out again (trees/continuous/1.txt, 2026-09-17). They can be switched off on the Player page
// (SGRKeyPlayerHeaderGlass), which the open player follows at once: only the circles go, and each button draws as
// Spotify's own again. The circle presses in itself (scale, the Kit's press spring) from the button's own touches:
// Spotify draws a button's pressed look under its subviews, where the circle covers it (phone, 2026-10-06).
//
// Tree (trees/clean/player/01.txt): HeaderElementsUnit's view is a 402x48 row holding
// id=now-playing-minimize-button 48x48 (:103) and id=Context menu 48x48 (:122), the playlist name between them.
// 9.1.78 also carries mobile-nowplaying-close-button (strings in the binary), so the down arrow is looked for under
// either name; which view each button was found as is logged once, so a phone where one is missing says why.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Redesigned/ContextMenu/ContextMenu.h"
#import "Player.h"

static char kGlassKey, kCloseKey, kMoreKey, kPressKey, kGrabberKey;
static char kContextKey, kContextStateKey;
static const CGFloat kPressScale = 0.92;
static NSString *const kMoreID = @"Context menu";

static NSArray<NSString *> *closeIDs(void) {
    return @[@"now-playing-minimize-button", @"mobile-nowplaying-close-button"];
}

static void contextVisibility(UIView *header) {
    // The recorded title container carries the accessibility label as well as the nested marquee.
    // Alpha preserves its stack slot; hidden would change Spotify's stack layout.
    UIView *context = SGRFindByIdentifier(header, @"now-playing-navigation-unit-title-label", &kContextKey);
    if (!context) return;
    NSArray<NSNumber *> *saved = objc_getAssociatedObject(context, &kContextStateKey);
    if (SGEnabled(SGRKeyPlayerHideContext)) {
        if (!saved) {
            saved = @[@(context.alpha), @(context.isAccessibilityElement), @(context.accessibilityElementsHidden)];
            objc_setAssociatedObject(context, &kContextStateKey, saved, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        context.alpha = 0;
        context.isAccessibilityElement = NO;
        context.accessibilityElementsHidden = YES;
    } else if (saved) {
        context.alpha = saved[0].doubleValue;
        context.isAccessibilityElement = saved[1].boolValue;
        context.accessibilityElementsHidden = saved[2].boolValue;
        objc_setAssociatedObject(context, &kContextStateKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

// The first of `identifiers` found in `host`, logged once by its first name when none is there.
static UIView *buttonIn(UIView *host, NSArray<NSString *> *identifiers, const void *findKey) {
    UIView *button = nil;
    for (NSString *identifier in identifiers) {
        if ((button = SGRFindByIdentifier(host, identifier, findKey))) break;
    }
    static NSMutableSet<NSString *> *said;
    if (!said) said = [NSMutableSet set];
    NSString *name = identifiers.firstObject;
    if (!button && ![said containsObject:name]) {
        [said addObject:name];
        SGLog(@"redesign player: %@ not found in %@, left as Spotify's", [identifiers componentsJoinedByString:@" or "], NSStringFromClass(host.class));
    }
    return button;
}

#pragma mark - the AI DJ's glass

// It listens for a touch up inside, so it says it is a watcher (SGRControlWatcher): the grabber's route to close by is
// the arrow's own action, never this.
@interface SGRHeaderPress : NSObject <SGRControlWatcher>
@end
@implementation SGRHeaderPress
- (void)down:(UIControl *)control {
    UIView *circle = objc_getAssociatedObject(control, &kGlassKey);
    SGRAnimate(SGRMotionPress, ^{ circle.transform = CGAffineTransformMakeScale(kPressScale, kPressScale); }, nil);
}
- (void)up:(UIControl *)control {
    UIView *circle = objc_getAssociatedObject(control, &kGlassKey);
    SGRAnimate(SGRMotionPress, ^{ circle.transform = CGAffineTransformIdentity; }, nil);
}
@end

static void pressFrom(UIControl *control) {
    if (![control isKindOfClass:UIControl.class] || objc_getAssociatedObject(control, &kPressKey)) return;
    objc_setAssociatedObject(control, &kPressKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    static SGRHeaderPress *press;
    if (!press) press = [SGRHeaderPress new];
    [control addTarget:press action:@selector(down:) forControlEvents:UIControlEventTouchDown | UIControlEventTouchDragEnter];
    [control addTarget:press action:@selector(up:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside
                                                                    | UIControlEventTouchDragExit | UIControlEventTouchCancel];
}

// The button's circle, taken out while the header glass is switched off (SGRKeyPlayerHeaderGlass); the next pass with
// it on makes a new one. Only the circle goes: the button and its press watcher stay.
static void dropCircle(UIView *button) {
    UIView *circle = objc_getAssociatedObject(button, &kGlassKey);
    if (!circle) return;
    [circle removeFromSuperview];
    objc_setAssociatedObject(button, &kGlassKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// A circle behind `button` while the header glass is on, none while it is off.
static void glassBehind(UIView *button) {
    BOOL glass = SGEnabled(SGRKeyPlayerHeaderGlass);
    UIView *circle = glass ? SGRGlassInside(button, &kGlassKey, SGRGlassCircleSize) : nil;
    if (!glass) dropCircle(button);
    static NSMutableSet<NSString *> *said;
    if (!said) said = [NSMutableSet set];
    NSString *name = button.accessibilityIdentifier ?: NSStringFromClass(button.class);
    if (![said containsObject:name] && button.bounds.size.width > 0) {
        [said addObject:name];
        SGLog(@"redesign player: %@ in %@ (id %@, %.0fx%.0f)", circle ? [NSString stringWithFormat:@"a %.0fpt glass circle", circle.bounds.size.width] : @"no glass circle, switched off",
              NSStringFromClass(button.class), button.accessibilityIdentifier, button.bounds.size.width, button.bounds.size.height);
    }
    pressFrom((UIControl *)button);
}

static void glassInside(UIViewController *unit) {
    UIView *host = unit.viewIfLoaded;
    if (!host) return;
    NSUInteger found = 0;
    static const void *keys[] = {&kCloseKey, &kMoreKey};
    NSArray<NSArray<NSString *> *> *identifiers = @[closeIDs(), @[kMoreID]];
    for (NSUInteger i = 0; i < identifiers.count; i++) {
        UIView *button = buttonIn(host, identifiers[i], keys[i]);
        if (!button) continue;
        glassBehind(button);
        found++;
    }
    static BOOL logged;
    if (!logged) {
        logged = YES;
        SGLog(@"redesign player: glass inside %lu of %lu buttons in %@", (unsigned long)found, (unsigned long)identifiers.count, NSStringFromClass(unit.class));
    }
}

#pragma mark - the ordinary player's buttons put away

// Spotify's ElementView holding a header button (trees of 9.2.0: each button alone in one). Spotify gives the ⋯ its
// alpha back as playback starts, with no layout of the header (9.2.0 simulator, 2026-11-18), and leaves the holder's.
static NSString *const kElementHolderPrefix = @"_TtGC13Element_UIKit11ElementView";

static void putAway(UIView *button) {
    if (!button) return;
    UIView *holder = button.superview;
    BOOL held = [NSStringFromClass(holder.class) hasPrefix:kElementHolderPrefix];
    for (UIView *view in held ? @[button, holder] : @[button]) {
        if (view.alpha != 0) view.alpha = 0;
        if (!view.accessibilityElementsHidden) view.accessibilityElementsHidden = YES;
    }
    if (button.isAccessibilityElement) button.isAccessibilityElement = NO;
}

// The events a tap on the down arrow fires, which the grabber closes the player by.
static const UIControlEvents kCloseEvents = UIControlEventPrimaryActionTriggered | UIControlEventTouchUpInside;

// The arrow, when it is a control with a tap's action to close the player by; else nil.
static UIControl *closeRoute(UIView *close) {
    if (![close isKindOfClass:UIControl.class]) return nil;
    return SGRControlActionEvents((UIControl *)close) & kCloseEvents ? (UIControl *)close : nil;
}

// The ⋯ always (the mod's own beside the title stands in); the arrow only with a route to close by, else it stays
// Spotify's, on glass as the setting has it.
static void putButtonsAway(UIView *header, UIView *close, UIControl *route) {
    UIView *more = buttonIn(header, @[kMoreID], &kMoreKey);
    if (route) putAway(close);
    else if (close) glassBehind(close);
    putAway(more);
    if (more) SGRPlayerMenuWatch(more);
    static BOOL logged;
    if (!logged && (close || more)) {
        logged = YES;
        SGLog(@"redesign player: the header's %@ and %@ put away for the grabber", !close ? @"(no down arrow)" : route ? @"down arrow" : @"(down arrow kept, no action to close by)",
              more ? @"⋯" : @"(no ⋯)");
    }
}

#pragma mark - the grabber

// The Music app's grabber over its full screen player (measured on its screenshot: a 60 x 4 pill, 7pt under the safe
// area's top), in a touch area of at least 44pt.
static const CGSize kGrabberSize = {60, 4};
static const CGFloat kGrabberTop = 7, kGrabberTouch = 44;

@interface SGRPlayerGrabber : UIControl
@property (nonatomic, weak) UIControl *close;
@property (nonatomic, readonly) UIView *pill;
@end

@implementation SGRPlayerGrabber

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _pill = [UIView new];
    _pill.userInteractionEnabled = NO;
    _pill.layer.cornerRadius = kGrabberSize.height / 2;
    _pill.layer.cornerCurve = kCACornerCurveContinuous;
    [self addSubview:_pill];
    self.isAccessibilityElement = YES;
    self.accessibilityTraits = UIAccessibilityTraitButton;
    [self addTarget:self action:@selector(sgr_close) forControlEvents:UIControlEventTouchUpInside];
    return self;
}

// YES once the arrow's action has been sent: the arrow still has one to send.
- (BOOL)sgr_close {
    UIControl *close = self.close;
    BOOL routed = close && (SGRControlActionEvents(close) & kCloseEvents);
    NSString *how = routed ? SGRFireControl(close) : @"nothing: the down arrow has no action to close by";
    static int logged;
    if (logged++ < 3) SGLog(@"redesign player: the grabber closes the player by %@", how);
    return routed;
}

- (BOOL)accessibilityActivate {
    return [self sgr_close];
}

- (BOOL)accessibilityPerformEscape {
    return [self sgr_close];
}

@end

// `route`: the arrow to close by, or nil, when the grabber is only drawn; `close`: the arrow, whose words it reads.
static void placeGrabber(UIView *header, UIView *close, UIControl *route) {
    UIWindow *window = header.window;
    if (!window) return;
    SGRPlayerGrabber *grabber = objc_getAssociatedObject(header, &kGrabberKey);
    if (!grabber) {
        grabber = [SGRPlayerGrabber new];
        objc_setAssociatedObject(header, &kGrabberKey, grabber, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    grabber.close = route;
    grabber.userInteractionEnabled = route != nil;
    grabber.isAccessibilityElement = route != nil;
    grabber.accessibilityElementsHidden = !route;
    // Spotify's words for its arrow, which the grabber stands in for.
    NSString *label = close.accessibilityLabel.length ? close.accessibilityLabel : SGL(@"player.grabber.close", @"Close Player");
    if (![grabber.accessibilityLabel isEqualToString:label]) grabber.accessibilityLabel = label;
    grabber.pill.backgroundColor = [UIColor colorWithWhite:1 alpha:SGRIncreaseContrast() ? 0.5 : 0.3];
    if (grabber.superview != header) [header addSubview:grabber];
    else if (header.subviews.lastObject != grabber) [header bringSubviewToFront:grabber];

    // Measured in the player's own full screen view (SPTNowPlayingView), whose top is the screen's once the player
    // is up, under the window's safe area: the player's own safe area and the window's coordinates both take in the
    // player's open as it slides up, and the header is not laid out again once it is up (9.2.0, 2026-11-18: the
    // grabber 500pt over the screen).
    UIView *player = nil;
    for (UIView *v = header.superview; v && v != window; v = v.superview) {
        if ([v.nextResponder isKindOfClass:%c(_TtC19NowPlaying_ViewImpl24NowPlayingViewController)]) {
            player = v;
            break;
        }
    }
    if (!player) return;
    CGFloat top = window.safeAreaInsets.top + kGrabberTop;   // in the player
    CGFloat pillY = [header convertPoint:CGPointMake(0, top) fromView:player].y;
    // The touch area centered on the pill as far as the row lets it, and never past the row's edges, where the row's
    // own hit test would cut it off.
    CGFloat rowHeight = header.bounds.size.height;
    CGSize touch = CGSizeMake(kGrabberSize.width + kGrabberTouch, MIN(kGrabberTouch, rowHeight));
    CGFloat touchY = MIN(MAX(0, pillY + kGrabberSize.height / 2 - touch.height / 2), rowHeight - touch.height);
    CGRect frame = CGRectMake(round(CGRectGetMidX(header.bounds) - touch.width / 2), round(touchY), touch.width, touch.height);
    if (!CGRectEqualToRect(grabber.frame, frame)) grabber.frame = frame;
    CGRect pill = CGRectMake((touch.width - kGrabberSize.width) / 2, round(pillY) - frame.origin.y, kGrabberSize.width, kGrabberSize.height);
    if (!CGRectEqualToRect(grabber.pill.frame, pill)) grabber.pill.frame = pill;

    static dispatch_once_t once;
    dispatch_once(&once, ^{
        SGLog(@"redesign player: grabber at %.0f in %@ (safe top %.0f, header row at %.0f, touch area %@ in it), %@", top, NSStringFromClass(player.class),
              window.safeAreaInsets.top, [header convertPoint:CGPointZero toView:player].y, NSStringFromCGRect(frame),
              route ? @"closing by the down arrow" : close ? @"drawn only, the down arrow has no action to close by" : @"drawn only, no down arrow");
    });
}

// `ordinary`: the ordinary player's header, its buttons put away; else the AI DJ's, its buttons on glass.
static void layOutHeader(UIViewController *unit, BOOL ordinary) {
    UIView *header = unit.viewIfLoaded;
    if (!header) return;
    UIView *close = buttonIn(header, closeIDs(), &kCloseKey);
    UIControl *route = closeRoute(close);
    if (ordinary) putButtonsAway(header, close, route);
    else glassInside(unit);
    contextVisibility(header);
    placeGrabber(header, close, route);
    SGRPlayerWatchLook(header);
}

%hook _TtC20NowPlaying_ModesImpl18HeaderElementsUnit
- (void)viewDidLayoutSubviews {
    %orig;
    layOutHeader((UIViewController *)self, YES);
}
%end

// The AI DJ's player has a header unit of its own with the same two buttons. Its ⋯ opens the DJ's own menu
// (feedback, language, voice), not the player's, so both stay, on glass.
%group SGRDJHeaderHooks
%hook SGRDJHeaderUnit
- (void)viewDidLayoutSubviews {
    %orig;
    layOutHeader((UIViewController *)self, NO);
}
%end
%end

%ctor {
    if (!SGRedesignedUI()) return;
    %init;
    Class djHeader = SGRDJClass(@"DJMHeaderElementsUnitViewController");
    if (djHeader) { %init(SGRDJHeaderHooks, SGRDJHeaderUnit = djHeader); }
    SGRequireClasses(@[@"_TtC20NowPlaying_ModesImpl18HeaderElementsUnit"]);
}
