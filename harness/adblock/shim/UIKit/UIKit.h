#import <Foundation/Foundation.h>
@class UIViewController;
@interface UIView : NSObject
@property BOOL hidden;
@property BOOL userInteractionEnabled;
@property UIView *superview;
- (void)removeFromSuperview;
- (void)didMoveToSuperview;
@end
