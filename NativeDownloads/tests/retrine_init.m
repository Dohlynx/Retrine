// Exercise the production SGModPage init hook, including init replacement/nil.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "../../harness/harness-fail.h"
#import "AudioProbeUI.h"
#import "PixiePageController.h"
#import "PixiePageNavigation.h"

@interface FixturePageOwner : UIViewController
@property(nonatomic,strong) UIViewController *sheet;
@end
@implementation FixturePageOwner
- (void)presentViewController:(UIViewController *)page animated:(BOOL)animated completion:(void (^)(void))completion {
    self.sheet=page;
}
@end
@interface FixtureHostStack : UINavigationController @end
@implementation FixtureHostStack @end
@interface FixtureIncompletePage : UIViewController @end
@implementation FixtureIncompletePage @end

static NSUInteger destroyed;
static NSArray *receivedSections;
static __weak id allocatedReceiver;
static __weak id replacement;
static NSUInteger mode;

@interface SGModPage : NSObject
- (instancetype)initWithTitle:(NSString *)title intro:(NSString *)intro
                     sections:(NSArray *)sections footer:(NSString *)footer;
@end
@implementation SGModPage
- (instancetype)initWithTitle:(NSString *)title intro:(NSString *)intro
                     sections:(NSArray *)sections footer:(NSString *)footer {
    receivedSections=sections;
    if(mode==1) {
        self=(id)[NSObject new];
        replacement=self;
        return self;
    }
    if(mode==2)return nil;
    return [super init];
}
- (void)dealloc {destroyed++;}
@end

// Keep the actual navigation factory in the row, as the host does.
__attribute__((visibility("default")))
id SGPageRow(NSString *title,UIViewController *(^page)(void)) {return @[title,[page copy]];}
__attribute__((visibility("default")))
id SGActionRow(NSString *title,NSString *subtitle,void (^action)(void)) {return title;}
__attribute__((visibility("default")))
id SGWithTile(id row,NSString *symbol,UIColor *color) {return row;}
__attribute__((visibility("default")))
id SGSection(NSString *title,NSArray *rows) {return rows;}

int main(void) {
    @autoreleasepool {
        SAPInstallDownloadSettings();
        for(NSString *title in @[@"Retrine",@"Vitrine"]) for(mode=0;mode<3;mode++) {
            NSUInteger before=destroyed;
            __weak id result;
            @autoreleasepool {
                SGModPage *page=[SGModPage alloc];
                allocatedReceiver=page;
                page=[page initWithTitle:title intro:nil sections:@[@"existing"] footer:nil];
                result=page;
                HARNESS_CHECK(receivedSections.count==2);
                HARNESS_CHECK([receivedSections[0] isEqual:@"existing"]);
                HARNESS_CHECK([receivedSections[1] count]==2);
                if(mode==0) {
                    HARNESS_CHECK(page==allocatedReceiver && destroyed==before);
                    NSArray *row=receivedSections[1][0];
                    HARNESS_CHECK([row[0] isEqual:@"Pixie Download Manager"]);
                    UIViewController *(^open)(void)=row[1];
                    UINavigationController *nav=[[UINavigationController alloc] initWithRootViewController:UIViewController.new];
                    [nav pushViewController:open() animated:NO];
                    [nav.topViewController loadViewIfNeeded];
                    HARNESS_CHECK([nav.topViewController.title isEqual:@"Pixie Download Manager"]);
                }
                if(mode==1)HARNESS_CHECK(allocatedReceiver==nil && page==replacement && destroyed==before+1);
                if(mode==2)HARNESS_CHECK(page==nil && allocatedReceiver==nil && destroyed==before+1);
            }
            HARNESS_CHECK(result==nil && replacement==nil && destroyed==before+1);
        }
        mode=0;
        @autoreleasepool {
            id page=[[SGModPage alloc] initWithTitle:@"Other" intro:nil sections:@[@"existing"] footer:nil];
            HARNESS_CHECK(page && receivedSections.count==1);
        }
        FixturePageOwner *owner=[FixturePageOwner new];
        UINavigationController *stack=[[FixtureHostStack alloc]initWithRootViewController:owner];
        SAPPixiePageController *page=[[SAPPixiePageController alloc]initWithStyle:UITableViewStyleGrouped];
        SAPShowPixiePage(owner,page);
        HARNESS_CHECK(stack.topViewController==page && !owner.sheet);
        [stack popViewControllerAnimated:NO];
        // Reproduce stale conformance metadata without creating a duplicate
        // runtime protocol. The host fixture already declares both spellings.
        FixtureIncompletePage *incomplete=[FixtureIncompletePage new];
        for(NSString *name in @[@"SPTPageController",@"_TtP19Tome_PageAttributes17SPTPageController_"]) {
            Protocol *protocol=NSProtocolFromString(name);
            HARNESS_CHECK(protocol!=nil);
            class_addProtocol(incomplete.class,protocol);
            HARNESS_CHECK([incomplete conformsToProtocol:protocol]);
        }
        SAPShowPixiePage(owner,incomplete);
        UINavigationController *sheet=(id)owner.sheet;
        HARNESS_CHECK(stack.topViewController==owner && [sheet isKindOfClass:UINavigationController.class] && sheet.topViewController==incomplete);
        UIViewController *child=[UIViewController new];
        SAPShowPixiePage(incomplete,child);
        HARNESS_CHECK(sheet.topViewController==child);
        puts("PASS: both roots open Pixie; incompatible page presents separately with working nested navigation");
    }
    return 0;
}
