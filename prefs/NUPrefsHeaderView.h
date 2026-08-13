#import <UIKit/UIKit.h>

// Icon, name and version above the first group — the way a pane introduces itself
// when the Settings row alone is not enough of a title.
//
// Lives in the table's own header view rather than in a specifier, so it scrolls
// out of the way instead of occupying a row, and so its geometry stays readable
// from the controller (see -titleBottom).
@interface NUPrefsHeaderView : UIView

- (instancetype)initWithTitle:(NSString *)title version:(NSString *)version;

@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *version;

// Makes the icon a button — it is the pane's picture of the tweak, so tapping it goes where the
// Source Code row goes. Target and action rather than a block: the controller owns this view, so
// a block capturing it would be the cycle, and UIControl's unsafe-unretained target is exactly
// right for a subview of the controller's own table.
//
// One call rather than a settable target plus a settable label: an icon that acts like a button
// and announces itself as an image is the half-configured state worth making unrepresentable.
- (void)setIconTarget:(id)target action:(SEL)action accessibilityLabel:(NSString *)label;

// Distance from the top of the content to the bottom of the name label. The
// header sits at content origin, so this is directly comparable to a scroll
// view's inset-adjusted offset — the point at which the navigation bar has to
// take the title over.
@property (nonatomic, readonly) CGFloat titleBottom;

@end
