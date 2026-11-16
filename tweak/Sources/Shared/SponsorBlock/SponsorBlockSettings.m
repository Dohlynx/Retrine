#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "SponsorBlock.h"

SGModSection *SGSponsorBlockSettingsSection(void) {
    NSArray *titles = @[
        SGL(@"settings.sponsorblock.sponsor", @"Sponsors"),
        SGL(@"settings.sponsorblock.selfpromo", @"Self-promotion"),
        SGL(@"settings.sponsorblock.interaction", @"Interaction reminders"),
        SGL(@"settings.sponsorblock.intro", @"Intros"),
        SGL(@"settings.sponsorblock.outro", @"Outros"),
        SGL(@"settings.sponsorblock.preview", @"Previews and recaps"),
        SGL(@"settings.sponsorblock.hook", @"Hooks"),
        SGL(@"settings.sponsorblock.filler", @"Filler"),
        SGL(@"settings.sponsorblock.exclusive_access", @"Exclusive-access promotions"),
    ];
    NSMutableArray *rows = [NSMutableArray arrayWithObject:
        SGOptionRow(SGL(@"settings.sponsorblock.enabled", @"Skip podcast segments"),
            SGL(@"settings.sponsorblock.subtitle", @"Community-marked segments from SponsorBlock. Music is unchanged."),
            SGKeySponsorBlock)];
    NSArray *categories = SGSponsorBlockCategories();
    for (NSUInteger i = 0; i < categories.count; i++) {
        NSString *category = categories[i];
        SGModRow *row = SGOptionRow(titles[i], nil, SGSponsorBlockCategoryKey(category));
        row.defaultOn = SGSponsorBlockCategoryDefault(category);
        row.waitsOn = SGKeySponsorBlock;
        [rows addObject:row];
    }
    return SGNotedSection(SGL(@"settings.sponsorblock.title", @"SponsorBlock"), rows,
        SGL(@"settings.sponsorblock.footer", @"Off by default. Changes apply after restarting Spotify. Sends a short hash prefix of the episode ID and your selected categories to sponsor.ajay.app, not your Spotify account. Undo lets a skipped segment play this session."));
}
