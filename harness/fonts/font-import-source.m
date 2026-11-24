// FontImport.m as the tweak compiles it, with Core Text's registration replaced by check.m's double (the same one
// FontLibrary.m uses there), so the imported family's registration can be held and counted like the library's.
#import <CoreText/CoreText.h>
#import "Settings/SGPageStyle.h"
static NSUInteger notices;
static void notice(UIViewController *presenter, NSString *title, NSString *message) {
    notices++;
    SGPresentInformation(presenter, title, message);
}
#define SGPresentInformation notice
bool harnessRegister(CFURLRef url, CTFontManagerScope scope, CFErrorRef *error);
#define CTFontManagerRegisterFontsForURL harnessRegister
#import "Shared/Fonts/FontImport.m"

void harnessRemoveCustom(dispatch_block_t done) { removeImported(importIdentity(), done); }
void harnessImport(NSURL *url, dispatch_block_t done) { import(@[url], done); }

void harnessRejectedImport(NSURL *invalid, void (^done)(BOOL)) {
    NSUInteger before = notices;
    __block BOOL notified = NO;
    import(@[invalid], ^{ notified = notices == before + 1; });
    // Both operations publish on main in submission order. The next fixture needs the
    // stale swipe to have cleared its pending flag before it requests registration.
    removeImported(@{}, ^{ done(notified); });
}
