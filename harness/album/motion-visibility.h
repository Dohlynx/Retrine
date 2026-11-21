#import <AVFoundation/AVFoundation.h>
#import "../harness-fail.h"

extern __weak UIView *harnessSettledPlayerField;
extern NSNotificationName const SGRPlayerVisibilityDidChangeNotification;
@interface UIView (HarnessMotionFile)
- (void)showFile:(NSURL *)file;
- (void)showMotion:(NSURL *)file;
@end

// A local mp4 (motion-fixture.mp4 in the harness bundle); only the covering player is a double.
static void motionVisibilityCheck(UIView *root, BOOL artist) {
    if (![NSProcessInfo.processInfo.arguments containsObject:@"motion-visibility"]) return;
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil
        queue:nil usingBlock:^(NSNotification *note) {
        UIScrollView *list = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 0, 240, 150)];
        list.contentSize = CGSizeMake(240, 1000);
        [root addSubview:list];
        UIView *header = [[NSClassFromString(artist ? @"SGRArtistMotionView" : @"SGRAlbumHero") alloc]
            initWithFrame:CGRectMake(0, 0, 240, 100)];
        [list addSubview:header];
        NSURL *file = [NSBundle.mainBundle URLForResource:@"motion-fixture" withExtension:@"mp4"];
        HARNESS_CHECK(file && header.window);
        UIView *field = [[UIView alloc] initWithFrame:CGRectMake(240, 0, 80, 150)];
        [root addSubview:field];
        harnessSettledPlayerField = field;
        if (artist) [header showFile:file]; else [header showMotion:file];
        AVPlayer *player = [header valueForKey:@"player"];
        HARNESS_CHECK(player.rate > 0);
        field.frame = CGRectMake(0, 0, 239, 150);
        [NSNotificationCenter.defaultCenter postNotificationName:SGRPlayerVisibilityDidChangeNotification object:nil];
        HARNESS_CHECK(player.rate > 0); // One uncovered column, even though the field overlaps.
        field.frame = list.frame;
        [NSNotificationCenter.defaultCenter postNotificationName:SGRPlayerVisibilityDidChangeNotification object:nil];
        HARNESS_CHECK(player.rate == 0);
        harnessSettledPlayerField = nil;
        [NSNotificationCenter.defaultCenter postNotificationName:SGRPlayerVisibilityDidChangeNotification object:nil];
        HARNESS_CHECK(player.rate > 0);
        list.contentOffset = CGPointMake(0, 100);
        HARNESS_CHECK(player.rate == 0);
        list.contentOffset = CGPointMake(0, 99);
        HARNESS_CHECK(player.rate > 0);
        list.hidden = YES;
        HARNESS_CHECK(player.rate == 0);
        list.hidden = NO;
        HARNESS_CHECK(player.rate > 0);
        [header removeFromSuperview];
        HARNESS_CHECK(player.rate == 0);
        NSLog(@"PASS %@ header playback: covered, uncovering, clipped, partial, hidden, detached", header.class);
        exit(0);
    }];
}
