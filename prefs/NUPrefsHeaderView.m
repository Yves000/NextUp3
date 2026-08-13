#import "NUPrefsHeaderView.h"

static const CGFloat kNUIconSide    = 96.0;   // the icon ships at 96 pt (@1x/@2x/@3x)
static const CGFloat kNUPadTop      = 28.0;
static const CGFloat kNUIconToName  = 12.0;
static const CGFloat kNUNameToVer   = 2.0;
static const CGFloat kNUPadBottom   = 22.0;
static const CGFloat kNUSideInset   = 24.0;

// A system font at the current Dynamic Type size for `style`, in `weight`. The
// descriptor's point size is already scaled for the user's content-size setting,
// so it must not be run through UIFontMetrics again.
static UIFont *NUHeaderFont(UIFontTextStyle style, UIFontWeight weight) {
    UIFontDescriptor *descriptor = [UIFontDescriptor preferredFontDescriptorWithTextStyle:style];
    return [UIFont systemFontOfSize:descriptor.pointSize weight:weight];
}

#pragma mark - Icon button

// How far the icon sinks under a finger. The Home Screen's own icon press is the reference;
// below about 0.97 the movement stops reading at this size, and past 0.9 it reads as a bounce
// rather than as a press.
static const CGFloat kNUIconPressScale = 0.95;

// The tappable icon. A UIButton subclass rather than a tap recogniser on an image view, because
// -setHighlighted: is already driven by UIControl's own tracking — including the finger sliding
// off the icon and back onto it, which a recogniser would have to reimplement.
//
// The class name carries the prefix for the usual reason: Settings loads this bundle and every
// other tweak's pane into one process, so an unprefixed name is a duplicate-class collision
// waiting for the first pane that also calls something HeaderIconButton.
@interface NUHeaderIconButton : UIButton
@end

@implementation NUHeaderIconButton

- (void)setHighlighted:(BOOL)highlighted {
    BOOL changed = (highlighted != self.highlighted);
    [super setHighlighted:highlighted];
    // UIKit re-asserts the same value while tracking; re-entering the animation would restart
    // the spring under a stationary finger.
    if (!changed) return;

    CGAffineTransform target = highlighted
        ? CGAffineTransformMakeScale(kNUIconPressScale, kNUIconPressScale)
        : CGAffineTransformIdentity;

    // Reduce Motion asks for no travel. The press state still shows — it just arrives without
    // being animated there.
    if (UIAccessibilityIsReduceMotionEnabled()) {
        self.transform = target;
        return;
    }

    // Down is critically damped so the press feels solid and lands immediately; only the release
    // springs, and lightly. BeginFromCurrentState is what makes a tap released mid-animation
    // continue from where it is instead of snapping, and AllowUserInteraction keeps the button
    // pressable while it is still settling.
    [UIView animateWithDuration:(highlighted ? 0.18 : 0.42)
                          delay:0.0
         usingSpringWithDamping:(highlighted ? 1.0 : 0.62)
          initialSpringVelocity:0.0
                        options:UIViewAnimationOptionAllowUserInteraction |
                                UIViewAnimationOptionBeginFromCurrentState
                     animations:^{ self.transform = target; }
                     completion:nil];
}

@end

#pragma mark - Header

@implementation NUPrefsHeaderView {
    UIButton *_iconButton;
    UILabel *_nameLabel;
    UILabel *_versionLabel;
}

- (instancetype)initWithTitle:(NSString *)title version:(NSString *)version {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;

    _title = [title copy];
    _version = [version copy];

    UIImage *icon = [UIImage imageNamed:@"header-icon"
                               inBundle:[NSBundle bundleForClass:self.class]
          compatibleWithTraitCollection:nil];
    // A button rather than a UIImageView because the icon is tappable (see -setIconTarget:…).
    // -initWithFrame: rather than +buttonWithType:, which is only documented to return the
    // receiver's own class for UIButtonTypeCustom; a plain init is that type anyway. Not the
    // System type: it would tint this non-template image with the accent colour, and its iOS 15
    // configuration would lay the image out to metrics of its own.
    //
    // The press feedback is the scale in -setHighlighted: above. The same image is set for the
    // highlighted state as well, which is what suppresses the legacy dim underneath it — a dim
    // on top of the scale reads as two effects answering one touch. (-adjustsImageWhenHighlighted
    // would say so directly, but it is deprecated as of iOS 15.)
    //
    // The fill alignments make the image follow the frame if the asset and kNUIconSide ever
    // disagree.
    _iconButton = [[NUHeaderIconButton alloc] initWithFrame:CGRectZero];
    [_iconButton setImage:icon forState:UIControlStateNormal];
    [_iconButton setImage:icon forState:UIControlStateHighlighted];
    _iconButton.imageView.contentMode = UIViewContentModeScaleAspectFit;
    _iconButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentFill;
    _iconButton.contentVerticalAlignment = UIControlContentVerticalAlignmentFill;
    // Nothing is wired to it yet, so it is decoration: not touchable, and not an element
    // VoiceOver stops on to announce a button with no name.
    _iconButton.userInteractionEnabled = NO;
    _iconButton.isAccessibilityElement = NO;
    // The squircle is baked into the asset's alpha, so no corner rounding here — a UIKit corner
    // radius is a circular arc and would not match the icon shape the Settings row and the Home
    // Screen use.
    [self addSubview:_iconButton];

    _nameLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _nameLabel.textAlignment = NSTextAlignmentCenter;
    _nameLabel.textColor = UIColor.labelColor;
    _nameLabel.adjustsFontSizeToFitWidth = YES;
    _nameLabel.minimumScaleFactor = 0.6;
    [self addSubview:_nameLabel];

    _versionLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _versionLabel.textAlignment = NSTextAlignmentCenter;
    _versionLabel.textColor = UIColor.secondaryLabelColor;
    [self addSubview:_versionLabel];

    [self applyFonts];
    [self applyText];
    return self;
}

- (void)setIconTarget:(id)target action:(SEL)action accessibilityLabel:(NSString *)label {
    [_iconButton removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];
    [_iconButton addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];

    BOOL wired = (target != nil && action != NULL);
    _iconButton.userInteractionEnabled = wired;
    _iconButton.isAccessibilityElement = wired;
    _iconButton.accessibilityTraits = UIAccessibilityTraitButton;
    // The Source Code row's own title, handed in already localised — the icon does what that row
    // does, so announcing it as anything else would describe two things where there is one.
    _iconButton.accessibilityLabel = label;
}

- (void)applyFonts {
    _nameLabel.font = NUHeaderFont(UIFontTextStyleLargeTitle, UIFontWeightBold);
    _versionLabel.font = NUHeaderFont(UIFontTextStyleTitle3, UIFontWeightRegular);
}

- (void)applyText {
    _nameLabel.text = _title;
    _versionLabel.text = _version;
    _versionLabel.hidden = (_version.length == 0);
}

- (void)setTitle:(NSString *)title {
    if ([_title isEqualToString:title]) return;
    _title = [title copy];
    [self applyText];
    [self setNeedsLayout];
}

- (void)setVersion:(NSString *)version {
    if ([_version isEqualToString:version]) return;
    _version = [version copy];
    [self applyText];
    [self setNeedsLayout];
}

// Dynamic Type changes the fonts, and with them the header's height; the
// controller re-measures on its next layout pass.
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    if (previous.preferredContentSizeCategory == self.traitCollection.preferredContentSizeCategory) return;
    [self applyFonts];
    [self setNeedsLayout];
}

- (CGSize)sizeThatFits:(CGSize)size {
    CGFloat textWidth = MAX(size.width - 2.0 * kNUSideInset, 1.0);
    CGFloat height = kNUPadTop + kNUIconSide + kNUIconToName;
    height += [_nameLabel sizeThatFits:CGSizeMake(textWidth, CGFLOAT_MAX)].height;
    if (!_versionLabel.hidden)
        height += kNUNameToVer + [_versionLabel sizeThatFits:CGSizeMake(textWidth, CGFLOAT_MAX)].height;
    return CGSizeMake(size.width, height + kNUPadBottom);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = self.bounds.size.width;
    CGFloat textWidth = MAX(width - 2.0 * kNUSideInset, 1.0);

    // Bounds and centre rather than -setFrame:, and the labels below are placed from iconRect
    // rather than from the button's own frame: the press animation leaves a scale transform on
    // the button, and with one applied a frame is neither safe to set nor the rect the icon
    // occupies at rest — reading it back would walk the name and version up the header on every
    // press.
    CGRect iconRect = CGRectMake((width - kNUIconSide) / 2.0, kNUPadTop, kNUIconSide, kNUIconSide);
    _iconButton.bounds = CGRectMake(0.0, 0.0, iconRect.size.width, iconRect.size.height);
    _iconButton.center = CGPointMake(CGRectGetMidX(iconRect), CGRectGetMidY(iconRect));

    CGFloat y = CGRectGetMaxY(iconRect) + kNUIconToName;
    CGFloat nameHeight = [_nameLabel sizeThatFits:CGSizeMake(textWidth, CGFLOAT_MAX)].height;
    _nameLabel.frame = CGRectMake(kNUSideInset, y, textWidth, nameHeight);

    if (_versionLabel.hidden) {
        _versionLabel.frame = CGRectMake(kNUSideInset, CGRectGetMaxY(_nameLabel.frame), textWidth, 0.0);
        return;
    }
    y = CGRectGetMaxY(_nameLabel.frame) + kNUNameToVer;
    CGFloat versionHeight = [_versionLabel sizeThatFits:CGSizeMake(textWidth, CGFLOAT_MAX)].height;
    _versionLabel.frame = CGRectMake(kNUSideInset, y, textWidth, versionHeight);
}

- (CGFloat)titleBottom {
    // Measured rather than read off the frame: the controller asks for this
    // before the first layout pass, to decide the navigation title's start state.
    if (!CGRectIsEmpty(_nameLabel.frame)) return CGRectGetMaxY(_nameLabel.frame);
    CGFloat textWidth = MAX(self.bounds.size.width - 2.0 * kNUSideInset, 1.0);
    return kNUPadTop + kNUIconSide + kNUIconToName +
           [_nameLabel sizeThatFits:CGSizeMake(textWidth, CGFLOAT_MAX)].height;
}

@end
