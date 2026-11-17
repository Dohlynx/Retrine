// The song's title and artist as the redesign shows them: without the extras Simplify song titles takes off, and
// in the user's language when Translate song titles has a translation in (Shared/Lyrics, Shared/LyricsTranslation),
// in the Music app's type: the title 20 pt semibold over the artist 20 pt regular in the secondary color, and 17 over
// 17 while the lyrics have the player (Spotify's were 24 bold over 16). Spotify's own two labels on the player
// (now-playing-title-label, now-playing-subtitle-label, PlayerLyrics.x's tree; in 9.1.90 each an Encore marquee view
// drawing through a UILabel inside it, which is the one taken) are given a subclass of their own class that draws the
// shown text, font and color whenever Spotify sets its own, plain or attributed, the way key-value observing subclasses
// an object: no other label in the app is touched, and each still reads as its class.
#import <objc/runtime.h>
#import <objc/message.h>
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Settings/SGPageStyle.h"
#import "Shared/Fonts/Fonts.h"
#import "Shared/Lyrics/Lyrics.h"
#import "Shared/LyricsTranslation/LyricsTranslation.h"
#import "Shared/Player/PlayerState.h"
#import "Headers/SPTPlayer.h"
#import "Player.h"

static char kOriginalKey, kRoleKey;
// Spotify's own class's setText:, setFont: and setTextColor: for each subclass made, by the subclass and the
// selector. Found by the class the subclass was made of, never by the label's class at the time of the call:
// key-value observing can put a subclass of its own above this one, and the class above would then be this one, and
// the call would come back here forever.
static NSMutableDictionary<NSString *, NSValue *> *sg_setters;
static BOOL sg_simplify, sg_on;
static __weak UILabel *sg_titleLabel, *sg_artistLabel;

// The Music app's sizes: Title 3 in the player, Headline and Body beside the lyrics' thumbnail (PlayerLyrics.x), the
// two column player keeping the player's. Capped where the player's row still holds two lines of it. In the family the
// app draws in: the system font, which Fonts.x draws in the chosen one, unless Spotify's is drawn (Shared/Fonts,
// SGAppFontDrawn); then the family of `given`, the font Spotify set, at the Music app's size and weight.
static UIFont *shownFont(BOOL title, UIFont *given) {
    BOOL lyrics = SGRPlayerLyricsOpen() && !SGRPlayerTwoColumns();
    UIFontTextStyle style = lyrics ? (title ? UIFontTextStyleHeadline : UIFontTextStyleBody) : UIFontTextStyleTitle3;
    UIFontWeight weight = title ? UIFontWeightSemibold : UIFontWeightRegular;
    UIFont *system = SGCategoryCappedFont(style, weight, UIContentSizeCategoryExtraExtraExtraLarge);
    NSString *family = given.familyName;
    if (SGAppFontDrawn() != SGAppFontSpotify || !family.length) return system;
    UIFontDescriptor *descriptor = [UIFontDescriptor fontDescriptorWithFontAttributes:@{
        UIFontDescriptorFamilyAttribute: family,
        UIFontDescriptorTraitsAttribute: @{UIFontWeightTrait: @(weight)},
    }];
    return [UIFont fontWithDescriptor:descriptor size:system.pointSize];
}

static NSString *setterKey(Class class, SEL selector) {
    return [NSString stringWithFormat:@"%@ %@", NSStringFromClass(class), NSStringFromSelector(selector)];
}

// Spotify's implementation of `_cmd` for this label, from the nearest subclass of ours up its classes.
static IMP spotifys(UILabel *label, SEL selector) {
    for (Class class = object_getClass(label); class; class = class_getSuperclass(class)) {
        NSValue *setter = sg_setters[setterKey(class, selector)];
        if (setter) return (IMP)setter.pointerValue;
    }
    return class_getMethodImplementation(UILabel.class, selector);
}

static BOOL isTitle(UILabel *label) {
    return [objc_getAssociatedObject(label, &kRoleKey) boolValue];
}

NSString *SGRShownTitle(NSString *trackID, NSString *title, NSString *artist, NSString **shownArtist) {
    NSString *translatedArtist = nil;
    NSString *translated = trackID ? SGLyricsTranslatedTitle(trackID, title, artist, &translatedArtist) : nil;
    NSString *shown = translated.length ? translated : title;
    if (sg_simplify && shown.length) shown = SGLyricsSimplifiedTitle(shown);
    if (shownArtist) *shownArtist = translatedArtist.length ? translatedArtist : artist;
    return shown;
}

static NSString *idOf(SPTPlayerTrack *track) {
    id uri = track.URI;
    NSString *text = [uri isKindOfClass:NSURL.class] ? ((NSURL *)uri).absoluteString : [uri description];
    return [text hasPrefix:@"spotify:track:"] ? [text substringFromIndex:@"spotify:track:".length] : nil;
}

// What the label draws for the text Spotify gave it; nil to draw Spotify's. Only the playing track's own title
// and artist are changed: an ad, a podcast or the DJ's words are left as they are.
static NSString *shownFor(BOOL title, NSString *text) {
    SPTPlayerTrack *track = SGPlayerState().track;
    if (!text.length || !track) return nil;
    if (![text isEqualToString:title ? track.trackTitle : track.artistName]) return nil;
    NSString *artist = nil;
    NSString *shown = SGRShownTitle(idOf(track), track.trackTitle, track.artistName, &artist);
    NSString *out = title ? shown : artist;
    return out.length && ![out isEqualToString:text] ? out : nil;
}

static void setShownText(UILabel *self, SEL _cmd, NSString *text) {
    NSString *shown = sg_on ? shownFor(isTitle(self), text) : nil;
    objc_setAssociatedObject(self, &kOriginalKey, text, OBJC_ASSOCIATION_COPY_NONATOMIC);
    ((void (*)(id, SEL, NSString *))spotifys(self, _cmd))(self, _cmd, shown ?: text);
}

// Spotify's attributes carry its font and color, so ours go over them once the text is in.
static void setShownAttributedText(UILabel *self, SEL _cmd, NSAttributedString *text) {
    BOOL title = isTitle(self);
    NSString *shown = sg_on ? shownFor(title, text.string) : nil;
    objc_setAssociatedObject(self, &kOriginalKey, text.string, OBJC_ASSOCIATION_COPY_NONATOMIC);
    NSDictionary *attributes = text.length ? [text attributesAtIndex:0 effectiveRange:NULL] : @{};
    NSAttributedString *drawn = shown ? [[NSAttributedString alloc] initWithString:shown attributes:attributes] : text;
    ((void (*)(id, SEL, NSAttributedString *))spotifys(self, _cmd))(self, _cmd, drawn);
    SEL font = @selector(setFont:), color = @selector(setTextColor:);
    UIFont *given = [attributes[NSFontAttributeName] isKindOfClass:UIFont.class] ? attributes[NSFontAttributeName] : self.font;
    ((void (*)(id, SEL, UIFont *))spotifys(self, font))(self, font, shownFont(title, given));
    if (!title) ((void (*)(id, SEL, UIColor *))spotifys(self, color))(self, color, SGRSecondary());
}

static void setShownFont(UILabel *self, SEL _cmd, UIFont *font) {
    ((void (*)(id, SEL, UIFont *))spotifys(self, _cmd))(self, _cmd, shownFont(isTitle(self), font));
}

// The artist in the secondary color; the title as Spotify paints it.
static void setShownColor(UILabel *self, SEL _cmd, UIColor *color) {
    ((void (*)(id, SEL, UIColor *))spotifys(self, _cmd))(self, _cmd, isTitle(self) ? color : SGRSecondary());
}

// The label's own class with setText:, setAttributedText:, setFont: and setTextColor: drawing what is shown, made once per class Spotify uses.
static Class shownClassFor(Class original) {
    NSString *name = [@"SGRShownTitle_" stringByAppendingString:NSStringFromClass(original)];
    Class made = NSClassFromString(name);
    if (made) return made;
    made = objc_allocateClassPair(original, name.UTF8String, 0);
    if (!made) return nil;
    if (!sg_setters) sg_setters = [NSMutableDictionary dictionary];
    struct { SEL selector; IMP shown; } setters[] = {
        {@selector(setText:), (IMP)setShownText}, {@selector(setAttributedText:), (IMP)setShownAttributedText},
        {@selector(setFont:), (IMP)setShownFont}, {@selector(setTextColor:), (IMP)setShownColor},
    };
    for (size_t i = 0; i < sizeof(setters) / sizeof(*setters); i++) {
        sg_setters[setterKey(made, setters[i].selector)] = [NSValue valueWithPointer:(void *)class_getMethodImplementation(original, setters[i].selector)];
        class_addMethod(made, setters[i].selector, setters[i].shown, "v@:@");
    }
    // The label still answers with Spotify's class, as one key-value observing has subclassed does.
    Class (^asked)(id) = ^Class(id me) { return original; };
    class_addMethod(made, @selector(class), imp_implementationWithBlock(asked), "#@:");
    objc_registerClassPair(made);
    return made;
}

static void adopt(UILabel *label, BOOL title) {
    if (![label isKindOfClass:UILabel.class]) return;
    Class current = object_getClass(label);
    BOOL ours = NO;
    for (Class class = current; class && !ours; class = class_getSuperclass(class)) ours = [NSStringFromClass(class) hasPrefix:@"SGRShownTitle_"];
    if (!ours) {
        Class shown = shownClassFor(current);
        if (!shown) return;
        objc_setAssociatedObject(label, &kOriginalKey, label.text, OBJC_ASSOCIATION_COPY_NONATOMIC);
        object_setClass(label, shown);
    }
    objc_setAssociatedObject(label, &kRoleKey, @(title), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [label setText:objc_getAssociatedObject(label, &kOriginalKey)];
    [label setFont:label.font];
    [label setTextColor:label.textColor];
}

static void refresh(void) {
    UILabel *title = sg_titleLabel, *artist = sg_artistLabel;
    if (title) [title setText:objc_getAssociatedObject(title, &kOriginalKey)];
    if (artist) [artist setText:objc_getAssociatedObject(artist, &kOriginalKey)];
}

void SGRShownTitleRestyle(void) {
    for (UILabel *label in @[sg_titleLabel ?: (id)NSNull.null, sg_artistLabel ?: (id)NSNull.null]) {
        if ([label isKindOfClass:UILabel.class] && ![label.font isEqual:shownFont(isTitle(label), label.font)]) [label setFont:label.font];
    }
}

// The label that draws for a view of Spotify's id: the view itself, or the UILabel an Encore marquee draws through.
static UILabel *drawingLabel(UIView *view) {
    if ([view isKindOfClass:UILabel.class]) return (UILabel *)view;
    for (UIView *sub in view.subviews) {
        if ([sub isKindOfClass:UILabel.class]) return (UILabel *)sub;
    }
    return nil;
}

void SGRShownTitleWatch(UIView *unit) {
    if (!unit) return;
    UILabel *title = drawingLabel(SGRFindByIdentifier(unit, @"now-playing-title-label", NULL));
    UILabel *artist = drawingLabel(SGRFindByIdentifier(unit, @"now-playing-subtitle-label", NULL));
    if ([title isKindOfClass:UILabel.class] && sg_titleLabel != title) {
        sg_titleLabel = title;
        adopt(title, YES);
    }
    if ([artist isKindOfClass:UILabel.class] && sg_artistLabel != artist) {
        sg_artistLabel = artist;
        adopt(artist, NO);
    }
    // A Dynamic Type change or the two columns coming or going reach the type on the row's next pass.
    SGRShownTitleRestyle();
}

%ctor {
    if (!SGRedesignedUI()) return;
    sg_simplify = SGFlag(SGKeyLyricsSimplifyTitles, NO);
    sg_on = sg_simplify || SGFlag(SGKeyLyricsTranslateTitles, NO);
    // The labels take the Music app's type either way; the text is theirs unless one of the two is on.
    if (!sg_on) return;
    [NSNotificationCenter.defaultCenter addObserverForName:SGTranslatedTitleDidChangeNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
        dispatch_async(dispatch_get_main_queue(), ^{ refresh(); });
    }];
    [NSNotificationCenter.defaultCenter addObserverForName:SGTitleTranslationSettingsDidChangeNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
        dispatch_async(dispatch_get_main_queue(), ^{ refresh(); });
    }];
    [NSNotificationCenter.defaultCenter addObserverForName:SGSimplifyTitlesDidChangeNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
        dispatch_async(dispatch_get_main_queue(), ^{
            sg_simplify = SGFlag(SGKeyLyricsSimplifyTitles, NO);
            refresh();
        });
    }];
    SGLog(@"redesign player: titles shown %@%@", sg_simplify ? @"simplified" : @"as they are", SGFlag(SGKeyLyricsTranslateTitles, NO) ? @", translated" : @"");
}
