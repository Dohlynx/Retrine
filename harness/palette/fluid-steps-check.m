// The production Fluid layer with Smooth chosen, laid out as the player's field is (Player/PlayerField.x: the plane
// plus 200 pt above and 600 pt below) while the plane grows 4 pt a frame from 874 to 2144 pt, as the player's list
// scrolls. Smooth's drawables are made again whenever their size changes, so the size may change only a handful of
// times over the scroll, and the GPU layer still covers the whole field with the same visible rect.
#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import "Redesigned/Kit/SGRFluid.h"
#import "Redesigned/Kit/SGRFluidGPU.h"

UIColor *SGRAccentColor(void) { return UIColor.greenColor; }
BOOL SGRPlayerIsTransitioning(void) { return NO; }
void SGRObservePlayerTransition(id owner, void (^changed)(id)) {}

static int failures;
static void check(BOOL passed, const char *description) {
    printf("%s %s\n", passed ? "PASS" : "FAIL", description);
    if (!passed) failures++;
}

int main(void) {
    @autoreleasepool {
        if (!MTLCreateSystemDefaultDevice()) {
            fprintf(stderr, "FAIL no Metal device for Smooth\n");
            return 1;
        }
        [NSUserDefaults.standardUserDefaults setInteger:SGRFluidRendererSmooth forKey:@"spotifyglass.redesign.fluid.renderer"];
        SGRFluidLayer *fluid = [SGRFluidLayer layer];
        [NSUserDefaults.standardUserDefaults removeObjectForKey:@"spotifyglass.redesign.fluid.renderer"];
        SGRFluidGPULayer *gpu = nil;
        for (CALayer *layer in fluid.sublayers)
            if ([layer isKindOfClass:SGRFluidGPULayer.class]) gpu = (SGRFluidGPULayer *)layer;
        check(gpu != nil, "Smooth chosen puts its GPU layer in the field");
        if (!gpu) return 1;
        CGRect visible = CGRectMake(0, 200, 390, 844);
        NSUInteger sizes = 0;
        CGSize last = CGSizeZero;
        BOOL covers = YES, sameVisible = YES;
        for (CGFloat plane = 874; plane <= 2144; plane += 4) {
            fluid.frame = CGRectMake(0, -200, 390, plane + 800);
            fluid.visibleRect = visible;
            [fluid layoutIfNeeded];
            if (!CGSizeEqualToSize(gpu.drawableSize, last)) sizes++;
            last = gpu.drawableSize;
            covers = covers && CGPointEqualToPoint(gpu.frame.origin, fluid.bounds.origin) &&
                     CGRectGetWidth(gpu.frame) == CGRectGetWidth(fluid.bounds) && CGRectGetHeight(gpu.frame) >= CGRectGetHeight(fluid.bounds);
            sameVisible = sameVisible && CGRectEqualToRect(gpu.visibleRect, visible);
        }
        printf("drawable sizes over the scroll: %lu\n", (unsigned long)sizes);
        check(sizes <= 6, "1270 pt of growth makes Smooth's drawables again at most 6 times, not on every frame");
        check(covers, "the GPU layer starts where the field does, as wide, and reaches its foot at every height");
        check(sameVisible, "the GPU layer places the picture by the field's visible rect throughout");
    }
    return failures ? 1 : 0;
}
