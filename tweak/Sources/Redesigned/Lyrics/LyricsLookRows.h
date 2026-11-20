#import "Settings/SGModPage.h"
#import "LyricsLook.h"

static inline SGModRow *SGRLyricsSizeRow(NSString *title, SGRLyricsPlace place) {
    NSArray *names = SGRLyricsSizeNames();
    return SGMenuRow(title, names, ^NSString * { return names[(NSUInteger)SGRLyricsSizeChoice(place)]; },
                     ^(NSInteger index) { SGRSetLyricsSizeChoice(place, index); });
}
