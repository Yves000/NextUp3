#import "NUPrefsCells.h"
#import <UIKit/UIKit.h>

// Gap between the icon and the label. Apple's own value assumes a tile-sized
// icon and leaves a hole under a symbol-sized one.
static const CGFloat kNUIconToLabel = 8.0;

@implementation NUIconLinkCell

- (void)layoutSubviews {
    [super layoutSubviews];

    UIImageView *icon = self.imageView;
    UILabel *label = self.textLabel;
    if (!icon.image || CGRectIsEmpty(icon.frame) || !label) return;

    CGFloat wanted = CGRectGetMaxX(icon.frame) + kNUIconToLabel;
    CGRect frame = label.frame;
    CGFloat shift = CGRectGetMinX(frame) - wanted;
    if (fabs(shift) < 0.5) return;

    // Widen by exactly what the label moves left, so a long title keeps the same
    // right edge and still truncates against the disclosure arrow, not before it.
    frame.origin.x = wanted;
    frame.size.width += shift;
    label.frame = frame;
}

@end
