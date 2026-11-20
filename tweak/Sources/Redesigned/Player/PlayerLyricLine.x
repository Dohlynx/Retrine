// Player redesign: the line of the lyrics being sung, one line in the gap under the cover and over the title,
// while the lyrics are not open in the player and the track has synced lines. It is the one line a place with
// room for one shows (SGKaraokeLeadLine, as the lock screen's), at the player's position less the Lyrics page's
// Delay, the way the lyrics view reads it (SGRKaraokeView's positionMs). A tap on it opens the lyrics, as the
// footer's lyrics glyph does (SGRPlayerToggleLyrics).
//
// It is a view of the mod's in SPTNowPlayingView (NowPlayingViewController's view), placed on every layout pass
// of the player, cover and chips. The words occupy Spotify's preview cell above the bottom stack,
// including when a clip replaces the art. The unshrunk cover limits the ink, not the cell's transparent
// padding. A visible chip lifts the rows only far enough to leave a grid gap, including over a clip. With less room than the
// line and a gap either side, a player wider than it is tall, or Spotify's own lyric preview under the cover,
// it is not shown. While translations are shown (below) and the track has synced lines of the line's own, the line
// takes the preview's place instead (SGRPlayerLineTakesPreview): the preview is hidden by an empty mask of the
// line's (again on every pass, as Spotify may set its own), its alpha and touches left to Spotify, the room is
// measured as if it were not there, and the line shows where it would without it. Translations switched off, or a
// track with no synced lines, give every preview hidden back as it was, and the line stands down for it again.
//
// A lyric longer than two rows shows in full-size portions (only an overwide word shrinks): the
// line being sung's portion while it is timed by the word, else its share of the line's time (PlayerLyricFit.h).
//
// While the lyrics' menu shows translations (SGRKeyLyricsTranslation, the lyrics page's own switch), the line's
// translation (SGRPlayerLineTranslation: none, or one that only repeats the line, shows nothing) sits under it in a
// smaller type in the artist color with the lyrics page's translation weight and brightness, on one row that shrinks to
// SGRLyricMinScale and then truncates. It goes under the line only when the room holds both with a gap either side
// (SGRPlayerLineFitIn); else the line shows alone in today's place. The translations are the lyrics page's: on the
// same kept lines, which it translates in place, and the saved ones read onto them from disk (SGLyricsLoadTranslation,
// as the Live Activity restores them); the line never asks a translator. One saved, removed or switched on or off is
// picked up at once: the translation fades in or out and the pair settles into place (at once under Reduce Motion).
//
// It reads the line on a one-shot timer armed again after every update, aimed at the next portion or the next line,
// not a display link (a CADisplayLink capped at 60 Hz drags the player's 120 Hz transitions down), and changes only
// when the line does: the new line crosses over the old one. Seeks, rate changes, lyrics changes and coming back to
// the foreground re-aim it.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Shared/Lyrics/Lyrics.h"
#import "Shared/LyricsTranslation/LyricsTranslation.h"
#import "Shared/Player/PlayerState.h"
#import "Shared/Player/PlayerSettings.h"
#import "Redesigned/Lyrics/AutoTranslation.h"
#import "Redesigned/Lyrics/LyricsLook.h"
#import "Redesigned/Lyrics/LyricsText.h"
#import <math.h>
#import "Player.h"
#import "PlayerLyricLine.h"
#import "PlayerLyricFit.h"

static const CGFloat kTapHeight = 44;
// Spotify 9.2.0's LyricsElementWrapperView, including its space above and below the centered text.
static const CGFloat kPreviewHeight = 100, kPreviewInset = 24, kPreviewPoints = 19.098;

static char kLineKey, kStackKey, kTitleKey;
static __weak UIView *sg_host;              // SPTNowPlayingView
static __weak UIViewController *sg_floating; // the chips over the title (FloatingElementsUnit)
static BOOL lineHasPlace(void);
static void placeLine(void);
static CGFloat visibleChipTop(UIView *host);

BOOL SGRPlayerLyricLineOn(void) {
    static BOOL on;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ on = SGHidden(SGRKeyPlayerLyricLine); });
    return on;
}

@interface SGRLyricLineView : UIView
@property (nonatomic) BOOL fits;   // set by the layout: there is room for it
@property (nonatomic) BOOL overClip;
@property (nonatomic) CGRect slot;
@property (nonatomic) CGFloat chipTop;
- (void)setRightToLeft:(BOOL)rtl;
@property (nonatomic) CGRect room; // set by the layout: the gap under the cover, CGRectNull without one
- (void)tick;
- (BOOL)place;
- (BOOL)placeWithChipTop:(CGFloat)top;
@end

@interface SGRLyricLineView () <SGPlayerStateObserver>
@end

@implementation SGRLyricLineView {
    UILabel *_label;
    NSTimer *_timer;   // one-shot, armed again after every update
    BOOL _running;     // in a window and Spotify in front: the timer runs
    NSArray<SGKaraokeLine *> *_source, *_ordered;
    BOOL _timed;
    NSInteger _index;
    NSString *_text;   // the line being sung, nil for none: what the label and VoiceOver name
    NSArray<SGRLyricPortion *> *_portions;   // that line's portions for the label's width and font
    CGFloat _portionWidth;                   // the width they were measured for
    BOOL _shown;
    UILabel *_translationLabel;
    NSString *_translation;      // the line being sung's translation, nil for none
    BOOL _translationShown;      // it is under the line: there is one and the room holds both
    CGFloat _slotLift;
    // The kept lines the saved translations were last read onto, and in which language.
    NSArray<SGKaraokeLine *> *_restored;
    NSString *_restoredLanguage;
    // Where the timer was armed, to tell a seek, a pause or resume and a speed change from the report that follows.
    BOOL _armed;
    double _armedMs, _armedRate;
    CFAbsoluteTime _armedAt;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _index = NSNotFound;
    _room = CGRectNull;
    _chipTop = CGFLOAT_MAX;
    self.alpha = 0;
    self.userInteractionEnabled = NO;
    self.accessibilityElementsHidden = YES;
    self.isAccessibilityElement = YES;
    self.accessibilityTraits = UIAccessibilityTraitButton | UIAccessibilityTraitUpdatesFrequently;
    self.accessibilityHint = SGL(@"settings.player.lyric_line.hint", @"Opens the lyrics.");
    _label = [[UILabel alloc] initWithFrame:self.bounds];
    _label.numberOfLines = 2;
    _label.lineBreakMode = NSLineBreakByWordWrapping;
    _label.textColor = UIColor.whiteColor;
    _label.font = [self font];
    [self addSubview:_label];
    _translationLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _translationLabel.numberOfLines = 1;
    _translationLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _translationLabel.adjustsFontSizeToFitWidth = YES;
    _translationLabel.minimumScaleFactor = SGRLyricMinScale;
    _translationLabel.alpha = 0;
    [self styleTranslation];
    [self addSubview:_translationLabel];
    [self addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapped)]];
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserver:self selector:@selector(clock) name:UIApplicationDidBecomeActiveNotification object:nil];
    [center addObserver:self selector:@selector(clock) name:UIApplicationDidEnterBackgroundNotification object:nil];
    // Lyrics kept for the track, or the Lyrics page's Delay changed: the line and its portions are read again.
    [center addObserver:self selector:@selector(linesChanged) name:SGKaraokeLinesKeptNotification object:nil];
    [center addObserver:self selector:@selector(linesChanged) name:SGLyricsOffsetsDidChangeNotification object:nil];
    // A translation saved, removed or deleted, or a job of the lyrics page's starting or ending (all posted on main):
    // the saved ones are read onto the lines again and the line looks again.
    for (NSNotificationName name in @[SGLyricsTranslationSavedNotification, SGLyricsTranslationsDidChangeNotification,
                                      SGRTranslationNotification]) {
        [center addObserver:self selector:@selector(translationsChanged) name:name object:nil];
    }
    // The menu's translation switch, or the Text sizes page's translation look.
    [center addObserver:self selector:@selector(lyricsTextChanged) name:SGRLyricsTextDidChangeNotification object:nil];
    // The size chosen for the line under the cover (LyricsLook.h).
    [center addObserver:self selector:@selector(sizeChanged) name:SGRLyricsLookDidChangeNotification object:nil];
    SGAddPlayerStateObserver(self);
    return self;
}

- (UIFont *)font {
    CGFloat share = SGRLyricsSizeShare(SGRLyricsPlaceUnderCover);
    return [UIFont systemFontOfSize:share == 1 ? kPreviewPoints : round(kPreviewPoints * share) weight:UIFontWeightBold];
}

- (void)styleTranslation {
    SGRLyricsTextLook look = SGRLyricsTextLookOf(SGRLyricsTextTranslation);
    _translationLabel.font = [UIFont systemFontOfSize:round([self font].pointSize * 0.8) weight:SGRLyricsTextFontWeight(look.weight)];
    // PlayerTitle.x gives the artist this same color, including under Increase Contrast.
    UIColor *dim = SGRSecondary();
    _translationLabel.textColor = [dim colorWithAlphaComponent:MIN(1, CGColorGetAlpha(dim.CGColor) * look.brightness / 100.0)];
}

- (CGFloat)translationHeight {
    return ceil(_translationLabel.font.lineHeight);
}

// The translation switch also hands the place under the cover between the line and Spotify's preview: the room is
// measured again from the player at once.
- (void)lyricsTextChanged {
    [self styleTranslation];
    placeLine();
    [self setNeedsLayout];
    [self translationsChanged];
}

- (void)translationsChanged {
    _restored = nil;
    if (_running) [self tick];
}

// The saved translations of the playing track's kept lines read onto them, once for the lines and language: what
// the lyrics page shows for them even when it has not been opened this launch. A read from disk only.
- (void)restoreTranslations {
    NSString *track = SGKaraokePlayingTrack(), *language = SGLyricsGeminiLanguage();
    NSArray<SGKaraokeLine *> *lines = _source;
    if (!track.length || !lines.count || !language.length) return;
    if (lines == _restored && [language isEqualToString:_restoredLanguage]) return;
    _restored = lines;
    _restoredLanguage = language;
    __weak SGRLyricLineView *weakSelf = self;
    SGLyricsLoadTranslation(track, language, lines, ^BOOL {
        return [track isEqualToString:SGKaraokePlayingTrack()] && lines == SGKaraokeLinesForTrack(track)
            && [language isEqualToString:SGLyricsGeminiLanguage()] && SGFlag(SGRKeyLyricsTranslation, NO);
    }, ^{
        SGRLyricLineView *view = weakSelf;
        if (view && view->_running) [view tick];
    });
}

- (void)setRightToLeft:(BOOL)rtl {
    _label.textAlignment = _translationLabel.textAlignment = rtl ? NSTextAlignmentRight : NSTextAlignmentLeft;
}

- (BOOL)placeWithChipTop:(CGFloat)top {
    BOOL moving = _chipTop != top && self.userInteractionEnabled;
    _chipTop = top;
    if (!moving) return [self place];
    __block BOOL fits;
    SGRAnimate(SGRMotionLayout, ^{
        fits = [self place];
        [self layoutIfNeeded];
    }, nil);
    return fits;
}

- (BOOL)place {
    if (CGRectIsNull(_room)) return NO;
    CGFloat half = [self lineHeight] / 2, native = CGRectGetMidY(_slot);
    CGFloat translation = _translation ? [self translationHeight] : 0;
    CGFloat middle;
    for (;;) {
        middle = MIN(native, _chipTop - SGRGrid - half - translation);
        SGRPlayerLineFit fit = SGRPlayerLineFitIn(middle - CGRectGetMinY(_room), CGRectGetMaxY(_room) - middle,
                                                  2 * half, translation, SGRGrid / 2);
        if (fit.line && (!translation || fit.translation)) break;
        if (!translation) return NO;
        translation = 0; // Retry the line at its own least displacement.
    }
    BOOL pair = translation > 0;
    if (_slotLift != native - middle) {
        _slotLift = native - middle;
        [self setNeedsLayout];
    }
    CGFloat top = MAX(CGRectGetMinY(_room), middle - MAX(kTapHeight / 2, half));
    CGFloat end = MIN(MIN(_chipTop, CGRectGetMaxY(_room)), middle + MAX(kTapHeight / 2, half + translation));
    CGRect frame = CGRectMake(_slot.origin.x, top, _slot.size.width, end - top);
    if (!CGRectEqualToRect(self.frame, frame)) {
        self.frame = frame;
        if (_overClip && _shown) SGRPlayerMotionLineMoved();
    }
    if (pair != _translationShown) {
        _translationShown = pair;
        [self setNeedsLayout];
        UILabel *label = _translationLabel;
        SGRAnimate(SGRMotionFade, ^{ label.alpha = pair ? 1 : 0; }, nil);
    }
    self.accessibilityValue = _translationShown ? _translation : nil;
    return YES;
}

// Give UILabel exactly Spotify's text rectangle. The translation never pushes it upwards.
- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds = self.bounds;
    _label.frame = CGRectOffset(_slot, -self.frame.origin.x, -self.frame.origin.y - _slotLift);
    CGFloat width = MIN(bounds.size.width, ceil([_translationLabel sizeThatFits:CGSizeMake(bounds.size.width, CGFLOAT_MAX)].width));
    _translationLabel.frame = CGRectMake(_label.textAlignment == NSTextAlignmentRight ? bounds.size.width - width : 0,
        CGRectGetMidY(_label.frame) + [self lineHeight] / 2, width, [self translationHeight]);
}

- (CGFloat)lineHeight {
    if (!_label.text.length || self.slot.size.width <= 0) return ceil([self font].lineHeight);
    return ceil([_label textRectForBounds:(CGRect){CGPointZero, self.slot.size}
                    limitedToNumberOfLines:_label.numberOfLines].size.height);
}

- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    [self restyle];
}

// The text size changed: the line is measured again for the room, and its portions for the new font.
- (void)restyle {
    _label.font = [self font];
    [self styleTranslation];
    _portions = nil;
    // Over a clip the labels are sized to their text here, and the view's frame may not change with the font.
    [self setNeedsLayout];
    [self.superview setNeedsLayout];
}

// A size change shows at once, rather than at the line's next portion.
- (void)sizeChanged {
    [self restyle];
    if (_running) [self tick];
}

// Touches only over the words, a tap's height tall, so a swipe across the rest of the gap still reaches the covers.
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    CGFloat text = [_label sizeThatFits:self.bounds.size].width;
    if (_translationShown) text = MAX(text, [_translationLabel sizeThatFits:self.bounds.size].width);
    CGFloat width = MIN(self.bounds.size.width, text + 2 * SGRSideMargin);
    CGRect words = CGRectMake(_label.textAlignment == NSTextAlignmentRight ? self.bounds.size.width - width : 0,
                              0, width, self.bounds.size.height);
    return CGRectContainsPoint(words, point);
}

- (void)tapped {
    if (!_shown || SGRPlayerLyricsOpen()) return;
    SGLog(@"redesign player: the line under the cover opens the lyrics");
    SGRPlayerToggleLyrics();
}

- (BOOL)accessibilityActivate {
    if (!_shown || SGRPlayerLyricsOpen()) return NO;
    [self tapped];
    return YES;
}

- (CGRect)accessibilityFrame {
    CGRect rows = [_label textRectForBounds:_label.bounds limitedToNumberOfLines:_label.numberOfLines];
    rows = [self convertRect:rows fromView:_label];
    if (_translationShown) rows = CGRectUnion(rows, _translationLabel.frame);
    return UIAccessibilityConvertFrameToScreenCoordinates(rows, self);
}

#pragma mark - the clock

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self clock];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [_timer invalidate];
}

// Runs while the line is in a window and Spotify is in front; stopped otherwise. Coming back starts it over, which
// catches up with where the song went while it was away.
- (void)clock {
    BOOL run = self.window && UIApplication.sharedApplication.applicationState != UIApplicationStateBackground;
    if (run == _running) return;
    _running = run;
    if (!run) {
        [_timer invalidate];
        _timer = nil;
        _armed = NO;
        return;
    }
    [self tick];
}

// The next update, one shot, at the next portion or line the line being sung turns over at. Nothing nearer than
// SGRLyricMaxWait is a look every SGRLyricMaxWait, with its tolerance; a wait aimed at a boundary is not late.
- (void)armTimer:(SGRLyricWait)next {
    [_timer invalidate];
    _armedMs = SGKaraokePositionMs();
    _armedRate = [self rate];
    _armedAt = CFAbsoluteTimeGetCurrent();
    _armed = _armedMs >= 0;
    __weak SGRLyricLineView *weakSelf = self;
    _timer = [NSTimer timerWithTimeInterval:next.wait repeats:NO block:^(NSTimer *timer) { [weakSelf tick]; }];
    _timer.tolerance = next.tolerance;
    [NSRunLoop.mainRunLoop addTimer:_timer forMode:NSRunLoopCommonModes];
}

// The rate the song's time runs at: 0 while the player is paused or has not said, so nothing is aimed at.
- (double)rate {
    SPTPlayerState *state = SGPlayerState();
    if (!state || state.isPaused) return 0;
    double rate = state.playbackSpeed;
    return rate > 0 ? rate : 1;
}

// A report from the player: a seek re-aims the timer, and so does a speed change. A paused report carries the exact
// place the song was put, so any move of it while paused is a seek, however small: it can cross a portion's boundary.
- (void)playerStateDidChange:(SPTPlayerState *)state {
    [self rearmForState:state];
}

- (void)playerStateDidReport:(SPTPlayerState *)state {
    [self rearmForState:state];
}

- (void)rearmForState:(SPTPlayerState *)state {
    if (!_running) return;
    if (!_armed || !_timer) {
        [self tick];
        return;
    }
    // Whole milliseconds, as SGKaraokePositionMs counts the position the timer was armed at.
    double position = (state.isPaused ? state.positionAsOfTimestamp : state.position) * 1000;
    if (SGRLyricRearmNeeded((NSInteger)_armedMs, _armedRate, (NSInteger)position, [self rate],
                            CFAbsoluteTimeGetCurrent() - _armedAt)) {
        [self tick];
    }
}

// The lines were kept or the Delay moved: read again from here, and aimed again from what is read. While the line is
// stopped the next clock does it.
- (void)linesChanged {
    if (_running) [self tick];
}

// The playing track's synced lines in time order, and the one being sung; NSNotFound when there is none to show.
- (NSInteger)currentIndex {
    NSArray<SGKaraokeLine *> *lines = SGKaraokeLinesForTrack(SGKaraokePlayingTrack());
    if (lines != _source) {
        _source = lines;
        _ordered = lines ? SGKaraokeInTimeOrder(lines) : nil;
        _timed = lines && SGKaraokeLinesTiming(lines) != SGKaraokeTimingNone;
    }
    if (!_timed) return NSNotFound;
    NSInteger ms = SGKaraokePositionMs();
    if (ms < 0) return NSNotFound;
    NSInteger index = SGKaraokeLeadLine(_ordered, ms - SGKaraokeDelayMs());
    return index < 0 ? NSNotFound : index;
}

- (CGFloat)textWidth {
    return CGRectGetWidth(self.slot);
}

- (void)tick {
    NSArray<SGKaraokeLine *> *before = _source;
    NSInteger index = [self currentIndex];
    if (index != _index || _source != before) {
        _index = index;
        NSString *text = index == NSNotFound ? nil
            : [SGKaraokeLineText(_ordered[(NSUInteger)index]) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        _text = text.length ? text : nil;
        _portions = nil;
        self.accessibilityLabel = _text;
    }
    // The portion of the line the label has room for, measured once for the line, the width and the font.
    SGKaraokeLine *line = _index == NSNotFound ? nil : _ordered[(NSUInteger)_index];
    if (line && (!_portions || _portionWidth != [self textWidth])) {
        _portionWidth = [self textWidth];
        _portions = SGRLyricPortions(line, _portionWidth, [self font]);
    }
    if (_portions.count) {
        // The portion holding the position, which is the first for a line just begun and after a seek back into it.
        SGRLyricPortion *shown = _portions[(NSUInteger)SGRLyricPortionAt(_portions, SGKaraokePositionMs() - SGKaraokeDelayMs())];
        [self showText:shown.text scale:shown.scale];
    } else if (line && _text) [self showText:_text scale:1];
    // Its translation, read again every update, so one that arrives mid-line shows at once. With no line the last one
    // stays, as the line's own text does, for the fade out.
    BOOL translations = SGFlag(SGRKeyLyricsTranslation, NO);
    if (translations && _source) [self restoreTranslations];
    if (line) {
        NSString *translation = SGRPlayerLineTranslation(line, translations);
        if (translation != _translation && ![translation isEqualToString:_translation]) [self showTranslation:translation];
    }
    // Spotify's own preview can come up with no pass of a view this file hooks (its cover cell unhidden as the song
    // changes), so every update looks again: while the line takes its place it is hidden again, else the line stands
    // down by its next portion at the latest. The layout gives the room back once the preview goes.
    // Spotify can fade or move the chip without laying out the player. Reuse the existing lyric clock.
    if (!CGRectIsNull(_room)) {
        CGFloat top = visibleChipTop(self.superview);
        if (top != _chipTop) _fits = [self placeWithChipTop:top];
    }
    if (!lineHasPlace()) _fits = NO;
    UIView *covers = SGRPlayerCoverList();
    BOOL shown = _fits && _text && !SGRPlayerLyricsOpen() && (!covers || covers.alpha > 0.01);
    if (shown != _shown) {
        _shown = shown;
        self.userInteractionEnabled = shown;
        self.accessibilityElementsHidden = !shown;
        if (_overClip) SGRPlayerMotionLineMoved();
        SGRAnimate(shown ? SGRMotionFade : SGRMotionRespond, ^{ self.alpha = shown ? 1 : 0; }, nil);
    }
    // Armed again from every update, whether or not the line changed: the clock is the only thing that moves it.
    if (_running) {
        [self armTimer:SGRLyricLineWait(_ordered, SGKaraokePositionMs(), SGKaraokeDelayMs(),
                                        [self textWidth], [self font], [self rate])];
    }
}

// A new line, or a new portion of it, crosses over the one before; one coming while the line is out of sight is set
// at once. With no line the last one stays in the label for the fade out.
- (void)showText:(NSString *)text scale:(CGFloat)scale {
    UIFont *font = SGRLyricFontAtScale([self font], scale);
    if (!text) return;
    NSDictionary *attributes = @{NSFontAttributeName:font};
    if (text.length && [text isEqual:_label.text] && _label.attributedText.length &&
        [[_label.attributedText attribute:NSFontAttributeName atIndex:0 effectiveRange:nil] isEqual:font] &&
        [_label.font isEqual:font]) return;
    _label.font = font;
    UILabel *label = _label;
    [self setNeedsLayout];
    NSAttributedString *styled = [[NSAttributedString alloc] initWithString:text attributes:attributes];
    if (!_shown || [label.text isEqual:text]) label.attributedText = styled;
    else [UIView transitionWithView:label duration:SGRCrossfade
                       options:UIViewAnimationOptionTransitionCrossDissolve | UIViewAnimationOptionAllowUserInteraction
                    animations:^{ label.attributedText = styled; } completion:nil];
    _fits = [self place];
}

// A new translation crosses over the one under the line, or comes in with its place; none fades the last one out.
// The pair settles into its place with a layout spring, at once under Reduce Motion, where only the fade is kept.
- (void)showTranslation:(NSString *)translation {
    BOOL crossing = _shown && _translationShown && translation;
    _translation = translation;
    [self setNeedsLayout];
    UILabel *label = _translationLabel;
    if (crossing) {
        [UIView transitionWithView:label duration:SGRCrossfade
                           options:UIViewAnimationOptionTransitionCrossDissolve | UIViewAnimationOptionAllowUserInteraction
                        animations:^{ label.text = translation; } completion:nil];
    } else if (translation) {
        label.text = translation;
    }
    if (!_shown) {
        [self place];
        return;
    }
    SGRAnimate(SGRMotionLayout, ^{
        [self place];
        [self layoutIfNeeded];
    }, nil);
}

@end

#pragma mark - the room under the cover

// Whether `view` shows: neither it nor any view above it up to `root` hidden or clear.
static BOOL showsIn(UIView *view, UIView *root) {
    for (UIView *v = view; v && v != root.superview; v = v.superview) {
        if (v.hidden || v.alpha < 0.01) return NO;
    }
    return YES;
}

// The video switch owns its whole pill, not just the inset text or image. For other chips
// use the visible controls, labels and images. Carry clipping and visibility down the tree.
static CGFloat chipTopInBranch(UIView *view, UIView *host, CGRect clip) {
    if (view.hidden || view.alpha < 0.01) return CGFLOAT_MAX;
    CGRect visible = CGRectIntersection(clip, [host convertRect:view.bounds fromView:view]);
    CGFloat top = CGRectIsEmpty(visible) ? CGFLOAT_MAX : CGRectGetMinY(visible);
    if ([view.accessibilityIdentifier isEqualToString:SGVideoSwitchIdentifier]) return top;
    if (![view isKindOfClass:UIControl.class] && ![view isKindOfClass:UILabel.class] && ![view isKindOfClass:UIImageView.class])
        top = CGFLOAT_MAX;
    for (UIView *child in view.subviews) {
        CGFloat other = chipTopInBranch(child, host, view.clipsToBounds ? visible : clip);
        top = MIN(top, other);
    }
    return top;
}

static CGFloat visibleChipTop(UIView *host) {
    UIView *floating = sg_floating.viewIfLoaded;
    if (!floating.window || floating.window != host.window || !showsIn(floating, host.window)) return CGFLOAT_MAX;
    CGRect clip = host.bounds;
    for (UIView *v = floating.superview; v && v != host; v = v.superview)
        if (v.clipsToBounds) clip = CGRectIntersection(clip, [host convertRect:v.bounds fromView:v]);
    return chipTopInBranch(floating, host, clip);
}

// Spotify's own lyric preview under the cover, beside the tilt view, shown when Spotify's lyrics setting has it:
// Lyrics_NPVContainerKit.LyricsContainerView, and in 9.1.90 Lyrics_NPVElementsKitImpl.LyricsElementWrapperView.
static BOOL isPreview(UIView *view) {
    static Class preview, wrapper;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        preview = NSClassFromString(@"_TtC22Lyrics_NPVContainerKit19LyricsContainerView");
        wrapper = NSClassFromString(@"_TtC25Lyrics_NPVElementsKitImpl24LyricsElementWrapperView");
    });
    return (preview && [view isKindOfClass:preview]) || (wrapper && [view isKindOfClass:wrapper]);
}

static BOOL previewShowing(UIView *tilt, UIView *host) {
    for (UIView *sub in tilt.superview.subviews) {
        if (isPreview(sub) && sub.bounds.size.height > 1 && showsIn(sub, host)) return YES;
    }
    return NO;
}

static char kPreviewMaskKey;      // on a preview the line hid: the empty mask that hides it
static char kPreviewOwnMaskKey;   // and the mask of Spotify's that one replaced, if it had one
static BOOL sg_takesPreview;      // the line takes the previews' place
static NSHashTable<UIView *> *sg_hiddenPreviews;   // every preview the line hid, wherever it is now

// Hidden by a mask of the line's own, an empty layer, so Spotify's alpha and touches are never touched, and kept
// from VoiceOver. Set again on every call: a mask Spotify puts on in the meantime is the one given back.
static void hidePreview(UIView *preview) {
    CALayer *mask = objc_getAssociatedObject(preview, &kPreviewMaskKey);
    if (!mask) {
        mask = [CALayer layer];
        objc_setAssociatedObject(preview, &kPreviewMaskKey, mask, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    CALayer *layer = preview.layer;
    if (layer.mask != mask) {
        objc_setAssociatedObject(preview, &kPreviewOwnMaskKey, layer.mask, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        layer.mask = mask;
    }
    preview.accessibilityElementsHidden = YES;
    if (!sg_hiddenPreviews) sg_hiddenPreviews = [NSHashTable weakObjectsHashTable];
    [sg_hiddenPreviews addObject:preview];
}

// Only the line's mask comes off, Spotify's own back in its place; one Spotify put on since is left as it is.
static void showPreview(UIView *preview) {
    CALayer *mask = objc_getAssociatedObject(preview, &kPreviewMaskKey), *layer = preview.layer;
    if (mask && layer.mask == mask) layer.mask = objc_getAssociatedObject(preview, &kPreviewOwnMaskKey);
    objc_setAssociatedObject(preview, &kPreviewMaskKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(preview, &kPreviewOwnMaskKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    preview.accessibilityElementsHidden = NO;
}

// The playing track has synced lines the line can show.
static BOOL playingTrackSynced(void) {
    NSArray<SGKaraokeLine *> *lines = SGKaraokeLinesForTrack(SGKaraokePlayingTrack());
    return lines.count && SGKaraokeLinesTiming(lines) != SGKaraokeTimingNone;
}

// Whether the line has the place under the cover to itself: it takes Spotify's preview's place, which hides every
// preview in the covers (the next cover's too, so a skip or a swipe never shows one), or the preview does not show.
// Every preview it hid, under the covers or not, is given back once it no longer takes their place. Asked again on
// every update, so lines kept for the track, or a new track, are looked at.
static BOOL settlePreview(UIView *host, UIView *tilt) {
    BOOL takes = SGRPlayerLineTakesPreview(SGRPlayerLyricLineOn(), SGFlag(SGRKeyLyricsTranslation, NO),
                                           host.bounds.size.height > host.bounds.size.width, playingTrackSynced());
    for (UIView *preview in SGRPlayerPreviewsToGiveBack(sg_hiddenPreviews, takes)) showPreview(preview);
    if (takes) {
        UIView *covers = SGRPlayerCoverList();
        SGForEachView(covers && [tilt isDescendantOfView:covers] ? covers : tilt.superview, ^(UIView *view) {
            if (isPreview(view)) hidePreview(view);
        });
    }
    // A hand-over found by an update rather than a pass (the switch set where no notification says so, lines kept)
    // measures the room again on the player's next pass.
    if (takes != sg_takesPreview) {
        SGLog(@"redesign player: the line under the cover %@ Spotify's lyric preview",
              takes ? @"takes the place of" : @"gives the place back to");
        sg_takesPreview = takes;
        [host setNeedsLayout];
    }
    return takes || !previewShowing(tilt, host);
}

// The line has the place under the cover on screen now (settlePreview); YES while no cover is up to have one.
static BOOL lineHasPlace(void) {
    UIView *host = sg_host, *tilt = SGRPlayerShowingCover().superview;
    return !host || !tilt || ![tilt isDescendantOfView:host] || settlePreview(host, tilt);
}

static void placeLine(void) {
    UIView *host = sg_host;
    if (!host || !SGRPlayerLyricLineOn()) return;
    SGRLyricLineView *line = objc_getAssociatedObject(host, &kLineKey);
    if (!line) {
        line = [[SGRLyricLineView alloc] initWithFrame:CGRectZero];
        objc_setAssociatedObject(host, &kLineKey, line, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        SGLog(@"redesign player: the line under the cover goes into %@", NSStringFromClass(host.class));
    }
    if (line.superview != host) [host addSubview:line];

    UIView *art = SGRPlayerShowingCover();
    UIView *tilt = art.superview;
    UIView *stack = SGRFindByIdentifier(host, @"npv.bottomStackView", &kStackKey);
    CGRect room = CGRectNull;
    // Settled first, in any orientation, so a preview the line hid is given back where the line has no room.
    BOOL clear = tilt && [tilt isDescendantOfView:host] && settlePreview(host, tilt);
    BOOL clip = SGRPlayerMotionShowing();
    UIView *title = SGRFindByIdentifier(stack, @"now-playing-title-label", &kTitleKey);
    BOOL rtl = title.effectiveUserInterfaceLayoutDirection == UIUserInterfaceLayoutDirectionRightToLeft;
    CGFloat priorWidth = line.slot.size.width;
    CGFloat chipTop = CGFLOAT_MAX;
    if (clear && title && host.bounds.size.height > host.bounds.size.width) {
        CGRect anchor = [host convertRect:title.bounds fromView:title];
        CGRect stackFrame = [host convertRect:stack.bounds fromView:stack];
        CGRect slot = CGRectMake(kPreviewInset, stackFrame.origin.y - kPreviewHeight,
                                 host.bounds.size.width - 2 * kPreviewInset, kPreviewHeight);
        [line setRightToLeft:rtl];
        CGRect unshrunk = CGRectMake(art.center.x - art.bounds.size.width / 2, art.center.y - art.bounds.size.height / 2,
                                     art.bounds.size.width, art.bounds.size.height);
        CGFloat top = clip ? host.safeAreaInsets.top : CGRectGetMaxY([host convertRect:unshrunk fromView:tilt]);
        CGFloat bottom = CGRectGetMinY(anchor);
        chipTop = visibleChipTop(host);
        if (bottom > top)
            room = CGRectMake(slot.origin.x, top, slot.size.width, bottom - top);
        if (!CGRectEqualToRect(line.slot, slot)) { line.slot = slot; [line setNeedsLayout]; }
    }
    BOOL changed = line.overClip != clip;
    line.overClip = clip;
    line.room = room;
    BOOL fits = [line placeWithChipTop:chipTop];
    if (fits != line.fits || changed || priorWidth != line.slot.size.width) {
        line.fits = fits;
        [line tick];
    }
}

void SGRPlayerLyricClipChanged(void) { placeLine(); }

CGRect SGRPlayerVisibleClipLineIn(UIView *view) {
    SGRLyricLineView *line = objc_getAssociatedObject(sg_host, &kLineKey);
    return line.overClip && line.userInteractionEnabled && view.window == line.window ? SGRPlayerLyricLineIn(view) : CGRectNull;
}

CGRect SGRPlayerLyricLineIn(UIView *view) {
    UIView *host = sg_host;
    SGRLyricLineView *line = host ? objc_getAssociatedObject(host, &kLineKey) : nil;
    if (!view || !line.fits || !line.window) return CGRectNull;
    return [view convertRect:line.bounds fromView:line];
}

// The cover's own layout (PlayerArtwork.x sizes it there): the line follows where the cover now is. Only the
// player's covers, not the now playing bar's.
%hook _TtC35CreativeWorkCommons_CoverArtTiltKit16CoverArtTiltView
- (void)layoutSubviews {
    %orig;
    UIView *host = sg_host;
    if (host && [(UIView *)self isDescendantOfView:host]) placeLine();
}
%end

// Spotify's own lyric preview (9.1.90) gets its height when its lyrics arrive, after the cover's last pass: the line
// stands down there and then rather than on the player's next layout. While the line takes its place, its passes
// (and the older LyricsContainerView's) are where Spotify sets its alpha back, and where it is hidden again.
%hook _TtC25Lyrics_NPVElementsKitImpl24LyricsElementWrapperView
- (void)layoutSubviews {
    %orig;
    UIView *host = sg_host;
    if (host && [(UIView *)self isDescendantOfView:host]) placeLine();
}
%end

%hook _TtC22Lyrics_NPVContainerKit19LyricsContainerView
- (void)layoutSubviews {
    %orig;
    UIView *host = sg_host;
    if (host && [(UIView *)self isDescendantOfView:host]) placeLine();
}
%end

%hook _TtC19NowPlaying_ViewImpl24NowPlayingViewController
- (void)viewDidLayoutSubviews {
    %orig;
    UIView *host = ((UIViewController *)self).viewIfLoaded;
    if (!host.window) return;
    sg_host = host;
    placeLine();
}
%end

%hook _TtC20NowPlaying_ModesImpl20FloatingElementsUnit
- (void)viewDidLayoutSubviews {
    %orig;
    sg_floating = (UIViewController *)self;
    placeLine();
}
%end

%ctor {
    if (!SGRedesignedUI()) return;
    if (!SGRPlayerLyricLineOn()) return;
    %init;
    SGRequireClasses(@[
        @"_TtC35CreativeWorkCommons_CoverArtTiltKit16CoverArtTiltView",
        @"_TtC19NowPlaying_ViewImpl24NowPlayingViewController",
        @"_TtC20NowPlaying_ModesImpl20FloatingElementsUnit",
    ]);
}
