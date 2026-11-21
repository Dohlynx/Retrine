#import <UIKit/UIKit.h>
#import "../harness-fail.h"
#import "Redesigned/Player/Player.h"

extern void SGHarnessTap(UIWindow *, CGPoint);

// Unlike the static cover used for screenshots, this cell must be selectable by UIKit.
@interface PreviewTapPager : NSObject <UICollectionViewDataSource, UICollectionViewDelegate>
@property(nonatomic) NSUInteger selections;
@end

@implementation PreviewTapPager
- (NSInteger)collectionView:(UICollectionView *)view numberOfItemsInSection:(NSInteger)section { return 1; }
- (UICollectionViewCell *)collectionView:(UICollectionView *)view cellForItemAtIndexPath:(NSIndexPath *)path {
    return [view dequeueReusableCellWithReuseIdentifier:@"cover" forIndexPath:path];
}
- (void)collectionView:(UICollectionView *)view didSelectItemAtIndexPath:(NSIndexPath *)path {
    self.selections++;
    [view deselectItemAtIndexPath:path animated:NO];
}
@end

static PreviewTapPager *pager;
UICollectionViewCell *SGHarnessSelectableCover(UICollectionView *covers, Class cellClass) {
    pager = [PreviewTapPager new];
    covers.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    ((UICollectionViewFlowLayout *)covers.collectionViewLayout).itemSize = covers.bounds.size;
    [covers registerClass:cellClass forCellWithReuseIdentifier:@"cover"];
    covers.dataSource = pager;
    covers.delegate = pager;
    [covers layoutIfNeeded];
    UICollectionViewCell *cell = [covers cellForItemAtIndexPath:[NSIndexPath indexPathForItem:0 inSection:0]];
    HARNESS_CHECK(cell);
    cell.accessibilityIdentifier = @"nowplaying-contentlayer-cell-0";
    return cell;
}

static void tapPreview(UIView *preview, dispatch_block_t settled) {
    UIWindow *window = preview.window;
    CGPoint point = [preview convertPoint:CGPointMake(CGRectGetMidX(preview.bounds), CGRectGetMidY(preview.bounds)) toView:window];
    UIView *hit = [window hitTest:point withEvent:nil];
    if (![hit isDescendantOfView:preview]) HARNESS_FAIL(@"preview touch would hit %@ instead", hit);
    SGHarnessTap(window, point);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), settled);
}

void SGHarnessCheckPreviewTap(UIView *preview, dispatch_block_t givePreviewBack) {
    HARNESS_CHECK(preview.layer.mask && !SGRPlayerLyricsOpen());
    tapPreview(preview, ^{
        if (SGRPlayerLyricsOpen() || pager.selections != 1)
            HARNESS_FAIL(@"masked preview: lyrics open=%d, selections=%lu (wanted NO, 1)", SGRPlayerLyricsOpen(), (unsigned long)pager.selections);
        givePreviewBack();
        HARNESS_CHECK(!preview.layer.mask && SGRPlayerLyricsAvailable());
        tapPreview(preview, ^{
            if (!SGRPlayerLyricsOpen() || pager.selections != 1)
                HARNESS_FAIL(@"visible preview: lyrics open=%d, new selections=%lu (wanted YES, 0)", SGRPlayerLyricsOpen(), (unsigned long)(pager.selections - 1));
            NSLog(@"[harness] preview-tap checks: 2 of 2 right -- PASS");
            exit(0);
        });
    });
}
