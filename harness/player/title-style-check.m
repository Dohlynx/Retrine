// The player's title and artist styling (PlayerTitle.x, compiled through Logos) on labels shaped as Spotify's: the title
// a marquee view drawing through a UILabel inside it (9.1.90's Encore marquee), the artist a label. Spotify's setters
// are called as Spotify calls them, with a stand-in for its family (Georgia), and the type is read off the labels.
#import <UIKit/UIKit.h>
#import "Core/SGCore.h"
#import "Shared/Fonts/Fonts.h"
#import "Shared/Player/PlayerState.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Redesigned/Player/Player.h"
#import "../harness-fail.h"

@implementation SPTPlayerTrack
@end
@implementation SPTPlayerState
@end

static SGAppFont drawn = SGAppFontSystem;
static BOOL lyricsOpen;
static int checked, failed;

SGAppFont SGAppFontDrawn(void) { return drawn; }
BOOL SGRedesignedUI(void) { return YES; }
BOOL SGFlag(NSString *key, BOOL fallback) { return fallback; }
NSInteger SGInt(NSString *key, NSInteger fallback) { return fallback; }
void SGPresentDark(UIViewController *controller) {}
UIColor *SGRAccentColor(void) { return nil; }
SPTPlayerState *SGPlayerState(void) { return nil; }
BOOL SGRPlayerLyricsOpen(void) { return lyricsOpen; }
BOOL SGRPlayerTwoColumns(void) { return NO; }
NSString *SGLyricsTranslatedTitle(NSString *trackID, NSString *title, NSString *artist, NSString **artistOut) { return nil; }
NSString *SGLyricsSimplifiedTitle(NSString *title) { return title; }
NSNotificationName const SGTranslatedTitleDidChangeNotification = @"title-style.translated";
NSNotificationName const SGTitleTranslationSettingsDidChangeNotification = @"title-style.settings";
NSNotificationName const SGSimplifyTitlesDidChangeNotification = @"title-style.simplify";
UIView *SGRFindByIdentifier(UIView *root, NSString *identifier, const void *cacheKey) {
    if ([root.accessibilityIdentifier isEqualToString:identifier]) return root;
    for (UIView *child in root.subviews) {
        UIView *found = SGRFindByIdentifier(child, identifier, cacheKey);
        if (found) return found;
    }
    return nil;
}

static void check(BOOL ok, NSString *what) {
    checked++;
    if (!ok) failed++;
    printf("%s %s\n", ok ? "PASS" : "FAIL", what.UTF8String);
    fflush(stdout);
}
static CGFloat weightOf(UIFont *font) {
    return [[font.fontDescriptor objectForKey:UIFontDescriptorTraitsAttribute][UIFontWeightTrait] doubleValue];
}
// The height a fresh label gives the same text in `font`: what the row's layout must make room for.
static CGFloat heightFor(NSString *text, UIFont *font) {
    UILabel *label = [UILabel new];
    label.text = text;
    label.font = font;
    return label.intrinsicContentSize.height;
}

static void run(UIWindow *window) {
    NSString *titleText = @"밤양갱", *artistText = @"비비 (BIBI)";
    UIFont *spotifyTitle = [UIFont fontWithName:@"Georgia-Bold" size:24], *spotifyArtist = [UIFont fontWithName:@"Georgia" size:16];
    UIView *unit = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 402, 120)];
    UIView *marquee = [[UIView alloc] initWithFrame:CGRectMake(32, 0, 338, 40)];
    marquee.accessibilityIdentifier = @"now-playing-title-label";
    UILabel *title = [UILabel new], *artist = [UILabel new];
    artist.accessibilityIdentifier = @"now-playing-subtitle-label";
    [marquee addSubview:title];
    [unit addSubview:marquee];
    [unit addSubview:artist];
    [window addSubview:unit];
    title.text = titleText;
    title.font = spotifyTitle;
    artist.text = artistText;
    artist.font = spotifyArtist;
    artist.textColor = UIColor.whiteColor;

    SGRShownTitleWatch(unit);
    UIFont *sfTitle = [UIFont systemFontOfSize:20 weight:UIFontWeightSemibold], *sfArtist = [UIFont systemFontOfSize:20];
    check(title.font.pointSize == 20 && fabs(weightOf(title.font) - UIFontWeightSemibold) < 0.01
          && [title.font.familyName isEqualToString:sfTitle.familyName],
          [NSString stringWithFormat:@"the marquee's title label takes 20 pt semibold in the system family (%@ %.1f)", title.font.fontName, title.font.pointSize]);
    check(artist.font.pointSize == 20 && fabs(weightOf(artist.font) - UIFontWeightRegular) < 0.01 && [artist.textColor isEqual:SGRSecondary()],
          [NSString stringWithFormat:@"the artist takes 20 pt regular in the secondary color (%@ %.1f)", artist.font.fontName, artist.font.pointSize]);
    title.font = spotifyTitle;
    artist.textColor = UIColor.whiteColor;
    check(title.font.pointSize == 20 && [artist.textColor isEqual:SGRSecondary()], @"Spotify's own font and color set again leave the Music app's type");
    title.attributedText = [[NSAttributedString alloc] initWithString:titleText attributes:@{NSFontAttributeName: spotifyTitle}];
    check([title.text isEqualToString:titleText] && title.font.pointSize == 20 && fabs(weightOf(title.font) - UIFontWeightSemibold) < 0.01,
          @"Korean text set with Spotify's attributes keeps its words and takes the Music app's type");
    CGFloat height = title.intrinsicContentSize.height;
    check(fabs(height - heightFor(titleText, sfTitle)) < 0.5 && height < heightFor(titleText, spotifyTitle),
          [NSString stringWithFormat:@"the title's intrinsic height is the 20 pt line's (%.1f, Spotify's %.1f)", height, heightFor(titleText, spotifyTitle)]);
    check(fabs(artist.intrinsicContentSize.height - heightFor(artistText, sfArtist)) < 0.5, @"the artist's intrinsic height is the 20 pt line's");

    lyricsOpen = YES;
    SGRShownTitleRestyle();
    check(title.font.pointSize == 17 && artist.font.pointSize == 17 && fabs(weightOf(title.font) - UIFontWeightSemibold) < 0.01,
          @"with the lyrics open the title and artist are 17 over 17");
    lyricsOpen = NO;
    SGRShownTitleRestyle();
    check(title.font.pointSize == 20 && artist.font.pointSize == 20, @"with the lyrics closed they are 20 again");

    // Spotify's font drawn: the labels keep the family Spotify gives them.
    drawn = SGAppFontSpotify;
    title.font = spotifyTitle;
    artist.font = spotifyArtist;
    check([title.font.familyName isEqualToString:@"Georgia"] && [artist.font.familyName isEqualToString:@"Georgia"]
          && title.font.pointSize == 20 && artist.font.pointSize == 20,
          [NSString stringWithFormat:@"with Spotify's font chosen the labels keep Spotify's family at 20 pt (%@, %@)", title.font.fontName, artist.font.fontName]);
    printf("title style checks: %d of %d right -- %s\n", checked - failed, checked, failed ? "FAIL" : "PASS");
    fflush(stdout);
    exit(failed ? 1 : 0);
}

@interface TitleStyleApp : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end
@implementation TitleStyleApp
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [UIViewController new];
    [self.window makeKeyAndVisible];
    dispatch_async(dispatch_get_main_queue(), ^{ run(self.window); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        HARNESS_FAIL(@"title style checks did not finish");
    });
    return YES;
}
@end
int main(int argc, char **argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(TitleStyleApp.class)); }
}
