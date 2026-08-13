#import "NUNextUpRowView.h"
#import "NUNextUpManager.h"
#import "NUShared.h"
#import "NULocalization.h"

// 14pt matches Apple's own now-playing artwork inset from the platter edge
// (measured 42px @3x). Used for horizontal inset, vertical padding, and the
// separator inset so everything is consistent.
static const CGFloat kHPadding = 14.0;
static const CGFloat kArtSize = 44.0;
// Width of the artwork well when the source delivers 16:9 frames (YouTube). Only the width
// grows; the height stays kArtSize, so row height and the Control Center / Dynamic Island
// metrics are untouched.
static const CGFloat kArtWideSize = 78.0; // 44 * 16/9, rounded to a whole point
static const CGFloat kRowHeight = kArtSize + 2 * kHPadding; // 14 top + 14 bottom
static const CGFloat kSeparatorPixels = 3.0; // separator thickness in physical pixels

// Constant per process — cached: this is read from -layoutSubviews and the
// +preferredHeight sizing paths, which run on SpringBoard's main thread.
static CGFloat NUSeparatorHeight(void) {
    static CGFloat h; static dispatch_once_t once;
    dispatch_once(&once, ^{ h = kSeparatorPixels / UIScreen.mainScreen.scale; });
    return h;
}

static const CGFloat kArtCorner = 7.5; // matches Apple's now-playing artwork radius (iOS 16/17)
// Placeholder → artwork crossfade. The YouTube and Spotify providers fetch artwork over the
// network, so the swap lands well after the row is on screen. Close to the swipe crossfade's
// 0.2s.
static const NSTimeInterval kArtFadeDuration = 0.22;

// The pre-iOS-16 lock-screen now-playing uses a 16pt symmetric content inset and
// a 4pt artwork corner (both measured live), where iOS 16/17 use 14pt / 7.5pt.
// Covers iOS 14 AND 15 (14.2 rides the iOS-15 platter path, see the Makefile).
// These pick the right value per OS for the LOCK SCREEN only — Control Center
// overrides both via its own insets/concentric radius. Cached: read per layout pass.
static BOOL NURowUsesLegacyMetrics(void) {
    static BOOL legacy; static dispatch_once_t once;
    dispatch_once(&once, ^{ legacy = NSProcessInfo.processInfo.operatingSystemVersion.majorVersion < 16; });
    return legacy;
}
static CGFloat NULockHInset(void)    { return NURowUsesLegacyMetrics() ? 16.0 : kHPadding; }
static CGFloat NULockArtCorner(void) { return NURowUsesLegacyMetrics() ? 4.0  : kArtCorner; }

// Control Center layout: the card uses 24pt content padding on every side (measured
// live). Adopting it makes the row read as a native section, and the larger bottom
// inset yields a usable concentric artwork corner (40pt card − 24pt = 16pt). The
// separator sits at the row's top edge — the 24pt above it comes free from Apple's
// own margin below the volume slider — so the 24pt goes BELOW the separator.
static const CGFloat kCCHInset    = 24.0; // horizontal content inset (matches the card)
static const CGFloat kCCSepArtGap = 24.0; // separator → artwork/"UP NEXT" (matches horizontal + bottom)
static const CGFloat kCCBottomPad = 24.0; // artwork bottom → card bottom (the concentric inset)
static const CGFloat kSepArtGap   = kHPadding; // separator → artwork, lock screen
static const CGFloat kDIArtCorner = 13.0; // Apple's Dynamic Island artwork radius (continuous), concentric at the 24pt inset
static const CGFloat kSkipGlyph = 26.0;  // renders ~30px, matching Apple's transport glyph footprint inside the 44 circle
static const CGFloat kSkipButton = 44.0; // tap target + highlight circle — matches MRUTransportButton
static const CGFloat kGap = 12.0;

// Values below are lifted 1:1 from MRUTransportButton (verified live via Frida):
// on touch a fully-round white circle fades to 10% behind the glyph, and the
// glyph scales to 0.8. The circle is hidden (alpha 0) at rest.
static const CGFloat kHighlightAlpha = 0.10;
static const CGFloat kGlyphPressScale = 0.80;
static const CGFloat kPressInDuration = 0.25;
static const CGFloat kPressOutDuration = 0.35;
static const CGFloat kPressSpringDamping = 0.90;

// Artwork tap highlight matches Apple's MRUArtworkView (a UIControl): it just
// dims the image to 0.20 on touch — no scale — like the player's album cover.
static const CGFloat kArtworkPressAlpha = 0.20;

// Button Shapes: the X is a bare glyph, so give it a faint always-on circle
// when the user asks for buttons to be visually distinguished.
static const CGFloat kButtonShapeRestAlpha = 0.08;

// Swipe-to-act carousel: the card follows the finger while the neighbour slides
// in (crossfade), committing past a distance OR velocity threshold. In LTR,
// ← left = skip (fwd neighbour from the right) and → right = previous (back
// neighbour from the left); in RTL both verbs mirror — the physical-direction →
// verb mapping lives in nu_isForwardDir:, everything geometric stays physical.
// The carousel moves two NUItemView cards inside the clipped `track` view:
// `currentItem` is the visible card, `incomingItem` the staged neighbour. On
// commit, promoteIncoming copies the neighbour's content into currentItem and
// re-hides incomingItem, ready for the next swipe.
static const CGFloat kSwipeCommitFraction = 0.28;   // of the content width
static const CGFloat kSwipeCommitVelocity = 500.0;  // pt/s — a flick commits below the distance threshold
static const CGFloat kSwipeBackDamping    = 0.82;   // spring for snap-back / settle
static const CGFloat kSettleFallback      = 1.0;    // s to wait for fresh queue data after a commit
static const CGFloat kSwipeDirectionLock  = 8.0;    // pt of travel before the direction locks (hysteresis)
static const CGFloat kSpringVelocityMax   = 10.0;   // clamp for normalized initialSpringVelocity

// Soft fade at the content edges so cards melt away instead of hard-clipping.
// The wide fade (kFadeTrailing) belongs on the edge NEXT TO the pinned X
// button in either layout direction; the narrow one (kFadeLeading) hides under
// the 14pt artwork inset on the opposite edge so nothing dims at rest.
static const CGFloat kFadeLeading  = 10.0;
static const CGFloat kFadeTrailing = 22.0;

// Foreground tint for the row's elements. The lock-screen and Control Center
// now-playing UIs follow light/dark mode on every supported version, so our
// text/glyphs must too: white on dark, black on light (same alpha). The dynamic
// colour resolves against each element's trait collection, so it tracks the platter
// wherever it's hosted.
static UIColor *NURowColor(CGFloat alpha) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
        CGFloat w = (tc.userInterfaceStyle == UIUserInterfaceStyleDark) ? 1.0 : 0.0;
        CGFloat a = alpha;
        // Increase Contrast: lift translucent foregrounds toward opaque by halving
        // their distance to 1.0 (0.5→0.75, 0.6→0.8, 0.9→0.95). Decorative values
        // below 0.4 (the 0.12 separator / placeholder tile) stay quiet.
        if (tc.accessibilityContrast == UIAccessibilityContrastHigh && a >= 0.4) {
            a = a + (1.0 - a) * 0.5;
        }
        return [UIColor colorWithWhite:w alpha:a];
    }];
}

// Reduce Motion gates only autonomous motion (slides, springs, scales) — the
// finger-tracking drag itself is direct manipulation and stays live.
static BOOL NUReduceMotion(void) { return UIAccessibilityIsReduceMotionEnabled(); }

// Clamped Dynamic Type: track the user's text size via UIFontMetrics, capped at
// 1.25× so the label block still fits the fixed 72pt row (the platter height is
// static — Apple's own now-playing labels don't scale here either).
static UIFont *NUScaledFont(CGFloat size, UIFontWeight weight) {
    UIFont *base = [UIFont systemFontOfSize:size weight:weight];
    return [[UIFontMetrics metricsForTextStyle:UIFontTextStyleFootnote]
        scaledFontForFont:base maximumPointSize:size * 1.25];
}

#pragma mark - NUCircleButton (replicates MRUTransportButton's touch feedback)

@interface NUCircleButton : UIButton
// The glyph shown in the button. We render it in a dedicated view (not the
// UIButton imageView) so scaling it never fights UIButton's frame-based layout.
@property (nonatomic, strong) UIImage *glyphImage;
// iOS 15: the lock-screen transport buttons neither scale nor show a highlight
// circle — they just dim on touch, like the album artwork. When set, the button
// matches that (no circle, no glyph scale; a plain alpha dim instead).
@property (nonatomic) BOOL flatHighlight;
@end

@implementation NUCircleButton {
    UIView *_highlightCircle;  // fades in behind the glyph on touch
    UIImageView *_glyphView;   // the glyph we scale on touch
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _highlightCircle = [[UIView alloc] init];
        _highlightCircle.userInteractionEnabled = NO;
        _highlightCircle.backgroundColor = NURowColor(1.0); // adaptive: white on dark, black on light
        _highlightCircle.alpha = 0.0;
        [self addSubview:_highlightCircle];

        _glyphView = [[UIImageView alloc] init];
        _glyphView.userInteractionEnabled = NO;
        _glyphView.contentMode = UIViewContentModeCenter;
        [self addSubview:_glyphView];

        _highlightCircle.alpha = [self nu_restCircleAlpha];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(nu_buttonShapesChanged)
                                                     name:UIAccessibilityButtonShapesEnabledStatusDidChangeNotification
                                                   object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

// The circle's resting alpha: invisible normally, faintly visible under Button
// Shapes so the bare glyph reads as a button.
- (CGFloat)nu_restCircleAlpha {
    return UIAccessibilityButtonShapesEnabled() ? kButtonShapeRestAlpha : 0.0;
}

- (void)nu_buttonShapesChanged {
    if (!self.highlighted) _highlightCircle.alpha = [self nu_restCircleAlpha];
}

- (void)setGlyphImage:(UIImage *)glyphImage {
    _glyphImage = glyphImage;
    _glyphView.image = glyphImage;
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGPoint c = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
    CGFloat d = MIN(self.bounds.size.width, self.bounds.size.height);
    _highlightCircle.bounds = CGRectMake(0, 0, d, d);
    _highlightCircle.center = c;
    _highlightCircle.layer.cornerRadius = d / 2.0;

    _glyphView.bounds = self.bounds;
    _glyphView.center = c;
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    if (_flatHighlight) {
        // iOS 15: just dim the glyph, exactly like the artwork tap — no circle, no scale.
        [UIView animateWithDuration:(highlighted ? kPressInDuration : kPressOutDuration)
                              delay:0
                            options:UIViewAnimationOptionBeginFromCurrentState |
                                    UIViewAnimationOptionAllowUserInteraction |
                                    UIViewAnimationOptionCurveEaseOut
                         animations:^{
            self->_glyphView.alpha = highlighted ? kArtworkPressAlpha : 1.0;
        } completion:nil];
        return;
    }
    if (NUReduceMotion()) {
        // No glyph scale under Reduce Motion — the highlight circle's fade alone
        // carries the pressed state.
        [UIView animateWithDuration:(highlighted ? kPressInDuration : kPressOutDuration)
                              delay:0
                            options:UIViewAnimationOptionBeginFromCurrentState |
                                    UIViewAnimationOptionAllowUserInteraction |
                                    UIViewAnimationOptionCurveEaseOut
                         animations:^{
            self->_highlightCircle.alpha = highlighted ? kHighlightAlpha : [self nu_restCircleAlpha];
            self->_glyphView.transform = CGAffineTransformIdentity;
        } completion:nil];
        return;
    }
    [UIView animateWithDuration:(highlighted ? kPressInDuration : kPressOutDuration)
                          delay:0
         usingSpringWithDamping:kPressSpringDamping
          initialSpringVelocity:0.0
                        options:UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        self->_highlightCircle.alpha = highlighted ? kHighlightAlpha : [self nu_restCircleAlpha];
        self->_glyphView.transform = highlighted
            ? CGAffineTransformMakeScale(kGlyphPressScale, kGlyphPressScale)
            : CGAffineTransformIdentity;
    } completion:nil];
}

@end

// RTL: the row mirrors like the rest of the platter content — artwork on the
// trailing edge, labels right-aligned, skip button on the leading edge. Swipe
// SEMANTICS mirror too ("skip" is the swipe against reading direction, i.e.
// right in RTL); the animation geometry itself stays physical.
static BOOL NUViewIsRTL(UIView *v) {
    return v.effectiveUserInterfaceLayoutDirection == UIUserInterfaceLayoutDirectionRightToLeft;
}

#pragma mark - NUItemView (one "UP NEXT" card: artwork + labels)

@interface NUItemView : UIView
@property (nonatomic, strong) UIImageView *artworkView;
@property (nonatomic, strong) UILabel *captionLabel;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *artistLabel;
// Geometry pushed by the row so both cards match the active (lock-screen or CC) style.
@property (nonatomic) CGFloat nuHInset;      // artwork/label leading inset
@property (nonatomic) CGFloat nuArtworkTop;  // artwork top; skip + labels align to its band
@property (nonatomic) CGFloat nuArtCorner;   // artwork corner radius (concentric in CC)
@property (nonatomic) BOOL nuWideArtwork;   // 16:9 artwork well instead of square
// Last applied content (so a committed neighbour can be promoted to current).
@property (nonatomic, copy, readonly) NSString *itemTitle;
@property (nonatomic, copy, readonly) NSString *itemSubtitle;
@property (nonatomic, strong, readonly) UIImage *itemArtwork;
- (void)applyTitle:(NSString *)title subtitle:(NSString *)subtitle artwork:(UIImage *)artwork;
@end

@implementation NUItemView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        // Lock-screen defaults; the row overrides these for the Control Center style.
        _nuHInset = NULockHInset();
        _nuArtworkTop = NUSeparatorHeight() + kHPadding;
        _nuArtCorner = NULockArtCorner();

        _artworkView = [[UIImageView alloc] init];
        _artworkView.contentMode = UIViewContentModeScaleAspectFill;
        _artworkView.clipsToBounds = YES;
        _artworkView.layer.cornerRadius = NULockArtCorner();
        _artworkView.layer.cornerCurve = kCACornerCurveContinuous;
        _artworkView.backgroundColor = NURowColor(0.12);
        _artworkView.userInteractionEnabled = YES;
        [self addSubview:_artworkView];

        _captionLabel = [[UILabel alloc] init];
        // Translations use natural casing ("Als Nächstes"); uppercasing here is a
        // no-op for caseless scripts (ja/ko/zh/ar/he).
        _captionLabel.text = [NULocalizedString(@"UP_NEXT_CAPTION", @"Up Next") localizedUppercaseString];
        _captionLabel.textColor = NURowColor(0.55);
        // Long localized captions shrink (down to 70%) instead of truncating; the
        // label's frame already ends at the card edge, so it can never reach the
        // skip button regardless.
        _captionLabel.adjustsFontSizeToFitWidth = YES;
        _captionLabel.minimumScaleFactor = 0.7;
        _captionLabel.baselineAdjustment = UIBaselineAdjustmentAlignCenters;
        [self addSubview:_captionLabel];

        _titleLabel = [[UILabel alloc] init];
        _titleLabel.textColor = NURowColor(0.95);
        _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [self addSubview:_titleLabel];

        _artistLabel = [[UILabel alloc] init];
        // iOS 15's main-track subtitle is bright white, so lift ours to match there;
        // iOS 16/17 keep the dimmer 0.6 they were tuned to.
        _artistLabel.textColor = NURowColor(
            NSProcessInfo.processInfo.operatingSystemVersion.majorVersion < 16 ? 0.9 : 0.6);
        _artistLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [self addSubview:_artistLabel];

        [self applyScaledFonts];
        // Scaled fonts are snapshots of the content size category at creation, so
        // re-derive them (and the frame heights that depend on them) when the user
        // changes their text size.
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(contentSizeCategoryChanged:)
                                                     name:UIContentSizeCategoryDidChangeNotification
                                                   object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)applyScaledFonts {
    self.captionLabel.font = NUScaledFont(10.0, UIFontWeightSemibold);
    self.titleLabel.font = NUScaledFont(14.0, UIFontWeightSemibold);
    self.artistLabel.font = NUScaledFont(12.0, UIFontWeightRegular);
}

- (void)contentSizeCategoryChanged:(NSNotification *)note {
    [self applyScaledFonts];
    [self setNeedsLayout];
}

- (void)applyTitle:(NSString *)title subtitle:(NSString *)subtitle artwork:(UIImage *)artwork {
    BOOL sameTitle = (_itemTitle && [_itemTitle isEqualToString:title]);
    // Title alone is ambiguous — require the subtitle to match too; see the
    // NUSameTrack note in NUNextUpManager.m. Subtitles may both be empty.
    BOOL sameSubtitle = (_itemSubtitle == subtitle) ||
        (_itemSubtitle && subtitle && [_itemSubtitle isEqualToString:subtitle]);
    _itemTitle = [title copy];
    _itemSubtitle = [subtitle copy];
    self.titleLabel.text = title;
    self.artistLabel.text = subtitle;
    // Once real artwork is shown for a track, ignore later equivalent images —
    // prevents a re-assign flash after a previous-swipe commit. nil→real
    // upgrades and genuine track changes still apply.
    if (sameTitle && sameSubtitle && _itemArtwork) return;
    // Only the placeholder → artwork upgrade. A track change arrives with its own card
    // animation.
    // _itemArtwork == nil is implied by the early return above: same track, artwork late.
    BOOL fromPlaceholder = (artwork != nil && sameTitle && sameSubtitle);
    _itemArtwork = artwork;
    if (artwork) {
        void (^applyArtwork)(void) = ^{
            self.artworkView.image = artwork;
            self.artworkView.contentMode = UIViewContentModeScaleAspectFill;
        };
        // Reduce Motion asks for a crossfade in place of movement (the swipe commit does the
        // same), so it stays on in both cases. Skipped when nothing can see it: the incoming
        // card sits hidden at rest and the Control Center row parks at alpha 0, not hidden.
        if (fromPlaceholder && self.window && !self.hidden && self.alpha > 0.0) {
            [UIView transitionWithView:self.artworkView
                              duration:kArtFadeDuration
                               options:UIViewAnimationOptionTransitionCrossDissolve |
                                       UIViewAnimationOptionAllowUserInteraction |
                                       UIViewAnimationOptionBeginFromCurrentState
                            animations:applyArtwork
                            completion:nil];
        } else {
            applyArtwork();
        }
    } else {
        UIImageSymbolConfiguration *cfg =
            [UIImageSymbolConfiguration configurationWithPointSize:16.0 weight:UIImageSymbolWeightMedium];
        // Force template rendering + an adaptive muted tint so the glyph reads as a
        // quiet placeholder that sits on the artwork tile — not the default systemBlue.
        UIImage *note = [[UIImage systemImageNamed:@"music.note" withConfiguration:cfg]
            imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        self.artworkView.image = note;
        self.artworkView.tintColor = NURowColor(0.5);
        self.artworkView.contentMode = UIViewContentModeCenter;
    }
}

- (CGFloat)artworkWidth { return _nuWideArtwork ? kArtWideSize : kArtSize; }
- (void)setNuWideArtwork:(BOOL)v { if (_nuWideArtwork != v) { _nuWideArtwork = v; [self setNeedsLayout]; } }
- (void)setNuHInset:(CGFloat)v { if (_nuHInset != v) { _nuHInset = v; [self setNeedsLayout]; } }
- (void)setNuArtworkTop:(CGFloat)v { if (_nuArtworkTop != v) { _nuArtworkTop = v; [self setNeedsLayout]; } }
- (void)setNuArtCorner:(CGFloat)v {
    if (_nuArtCorner == v) return;
    _nuArtCorner = v;
    self.artworkView.layer.cornerRadius = v;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width;
    CGFloat hI = self.nuHInset;
    CGFloat artY = self.nuArtworkTop;
    BOOL rtl = NUViewIsRTL(self);
    CGFloat artW = [self artworkWidth];
    self.artworkView.frame = rtl ? CGRectMake(w - hI - artW, artY, artW, kArtSize)
                                 : CGRectMake(hI, artY, artW, kArtSize);

    // Center the label block on the artwork's vertical band (not the row), so the
    // asymmetric CC top/bottom padding keeps title/artist aligned with the artwork.
    CGFloat artCenterY = artY + kArtSize / 2.0;
    CGFloat textW = MAX(0.0, w - hI - artW - 2 * kGap);
    CGFloat textX = rtl ? kGap : hI + artW + kGap;
    // Alignment stays NSTextAlignmentNatural (the UILabel default): the frame is
    // mirrored, but each string keeps its content-driven alignment — an Arabic
    // title right-aligns on an English system and vice versa, exactly as before.
    // Line heights follow the (clamped) scaled fonts; at the default text size
    // these come out at the original 12/18/15pt block.
    CGFloat capH = ceil(self.captionLabel.font.lineHeight);
    CGFloat titleH = ceil(self.titleLabel.font.lineHeight);
    CGFloat artistH = ceil(self.artistLabel.font.lineHeight);
    CGFloat block = capH + titleH + artistH;
    CGFloat top = artCenterY - block / 2.0;
    self.captionLabel.frame = CGRectMake(textX, top, textW, capH);
    self.titleLabel.frame = CGRectMake(textX, top + capH, textW, titleH);
    self.artistLabel.frame = CGRectMake(textX, top + capH + titleH, textW, artistH);
}

@end

#pragma mark - NUFlagPan

// A pan that flips the cross-process touch flag at touch-DOWN (not at pan
// recognition), so SpringBoard can fail the Dynamic Island's own gesture before it
// starts moving the island. Cleared on touch up/cancel.
@interface NUFlagPan : UIPanGestureRecognizer @end
@implementation NUFlagPan
// NUDITouchSet is read by hooks/NUHooksSpringBoard.x — fails the Dynamic
// Island's own gesture while our swipe is active.
- (void)touchesBegan:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e { NUDITouchSet(1); [super touchesBegan:t withEvent:e]; }
- (void)touchesEnded:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e { NUDITouchSet(0); [super touchesEnded:t withEvent:e]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e { NUDITouchSet(0); [super touchesCancelled:t withEvent:e]; }
@end

#pragma mark - NUNextUpRowView

@interface NUNextUpRowView () <UIGestureRecognizerDelegate>
@property (nonatomic, strong) UIView *separator;
@property (nonatomic, strong) NUCircleButton *skipButton;   // pinned; does not swipe
@property (nonatomic, strong) UIView *track;                // clipped content region holding the two cards
@property (nonatomic, strong) CAGradientLayer *trackMask;  // soft horizontal edge fade
@property (nonatomic, strong) NUItemView *currentItem;
@property (nonatomic, strong) NUItemView *incomingItem;
@property (nonatomic, readwrite, getter=hasContent) BOOL hasContent;
// Swipe state.
@property (nonatomic) CGFloat activeDir;      // physical: -1 = swiping left, +1 = right, 0 = idle (verb via nu_isForwardDir:)
@property (nonatomic) CGFloat incomingSign;   // +1 incoming from right, -1 from left, 0 none
@property (nonatomic) BOOL committing;
@property (nonatomic, copy) NSString *promotedTitle;
@property (nonatomic, strong) NSTimer *settleTimer;
@property (nonatomic) BOOL nuCCStyle; // Control Center layout (larger, card-padding-aware)
@property (nonatomic, strong) UILongPressGestureRecognizer *artworkPress; // cancelled when a swipe locks
@property (nonatomic, strong) UIImpactFeedbackGenerator *haptics; // reused + prepared at touch-down
@end

@implementation NUNextUpRowView

// artwork + 14 top + 14 bottom, plus the separator's thickness so BOTH the
// line→artwork gap and the artwork→bottom gap come out to a full 14pt.
+ (CGFloat)preferredHeight { return kRowHeight + NUSeparatorHeight(); }

// CC: separator (at top) + 24pt gap + artwork + 24pt bottom padding.
+ (CGFloat)preferredHeightForControlCenter {
    return NUSeparatorHeight() + kCCSepArtGap + kArtSize + kCCBottomPad;
}

// Style-dependent geometry. Lock screen keeps the original tight insets; Control
// Center adopts the card's 24pt padding. The separator sits at the row's top edge
// in both styles; CC puts its extra space BELOW the separator (sep → artwork).
- (CGFloat)nu_hInset { return self.nuCCStyle ? kCCHInset : NULockHInset(); }
- (CGFloat)nu_sepArtGap { return self.nuCCStyle ? kCCSepArtGap : kSepArtGap; }
- (CGFloat)nu_artworkTop { return NUSeparatorHeight() + [self nu_sepArtGap]; }
- (CGFloat)nu_concentricInset { return self.nuCCStyle ? kCCBottomPad : kHPadding; }

- (void)configureForControlCenter {
    if (self.nuCCStyle) return;
    self.nuCCStyle = YES;
    // Control Center's now-playing card is always dark (a dark blur), regardless
    // of the system light/dark setting. iOS 17+ stamps a dark trait on the card;
    // iOS 14–16 don't, so in light mode the adaptive NURowColor would resolve
    // dark. Pin a dark trait on every version (a no-op where one already exists).
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    [self setNeedsLayout];
}

- (void)configureForDynamicIsland {
    self.nuCCStyle = YES;                          // same 24pt content padding as the card
    self.currentItem.nuArtCorner = kDIArtCorner;   // adopt Apple's DI artwork radius (concentric at 24pt)
    self.incomingItem.nuArtCorner = kDIArtCorner;
    // The island is always black regardless of the system light/dark setting —
    // same situation as the Control Center card, see configureForControlCenter.
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    [self setNeedsLayout];
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self setupSubviews];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(managerChanged:)
                                                     name:NUNextUpDidChangeNotification
                                                   object:nil];
        [self refreshFromManager];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_settleTimer invalidate];
}

- (void)setupSubviews {
    self.userInteractionEnabled = YES;
    // One VoiceOver element for the whole row: subviews (labels, artwork, skip
    // button, fade mask) fold into it, keeping the crowded platter traversal
    // short. Label/actions are computed on demand — see the Accessibility section.
    self.isAccessibilityElement = YES;

    _separator = [[UIView alloc] init];
    _separator.backgroundColor = NURowColor(0.12);
    [self addSubview:_separator];

    // The track clips the two cards to the content region so nothing spills over
    // the pinned skip button or the row edges.
    _track = [[UIView alloc] init];
    _track.clipsToBounds = YES;
    [self addSubview:_track];

    _trackMask = [CAGradientLayer layer];
    _trackMask.startPoint = CGPointMake(0.0, 0.5);
    _trackMask.endPoint = CGPointMake(1.0, 0.5);
    _trackMask.colors = @[ (id)[UIColor clearColor].CGColor, (id)[UIColor whiteColor].CGColor,
                           (id)[UIColor whiteColor].CGColor, (id)[UIColor clearColor].CGColor ];
    _track.layer.mask = _trackMask;

    _incomingItem = [[NUItemView alloc] initWithFrame:CGRectZero];
    _incomingItem.hidden = YES;
    [_track addSubview:_incomingItem];

    _currentItem = [[NUItemView alloc] initWithFrame:CGRectZero];
    [_track addSubview:_currentItem];

    // Tap the current artwork to play that track now — same as the next button.
    // Kept as a property: a zero-duration long-press recognises at touch-DOWN, so
    // a swipe that starts on the artwork would ALSO fire its Ended on release —
    // the pan cancels it the moment a swipe direction locks (see -panned:).
    UILongPressGestureRecognizer *press =
        [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(artworkPressed:)];
    press.minimumPressDuration = 0.0;
    [_currentItem.artworkView addGestureRecognizer:press];
    _artworkPress = press;

    // Skip button (pinned, on top of the track).
    _skipButton = [[NUCircleButton alloc] initWithFrame:CGRectZero];
    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:kSkipGlyph weight:UIImageSymbolWeightRegular];
    UIImage *xmark = [[UIImage systemImageNamed:@"xmark.circle.fill" withConfiguration:cfg]
        imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    _skipButton.glyphImage = xmark;
    if (NURowUsesLegacyMetrics()) {
        // iOS 15: match the other lock-screen transport glyphs exactly — mode-aware
        // white@0.9 (dark) / black@0.9 (light, measured live), and a plain dim on
        // touch (no highlight circle, no glyph scale).
        _skipButton.tintColor = NURowColor(0.9);
        _skipButton.flatHighlight = YES;
    } else {
        _skipButton.tintColor = NURowColor(0.5); // adaptive: white on dark, black on light
    }
    _skipButton.accessibilityLabel = NULocalizedString(@"AX_SKIP_NEXT_TRACK", @"Skip next track");
    [_skipButton addTarget:self action:@selector(skipTapped) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:_skipButton];

    UIPanGestureRecognizer *pan =
        [[NUFlagPan alloc] initWithTarget:self action:@selector(panned:)];
    pan.delegate = self;
    [self addGestureRecognizer:pan];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;

    CGFloat sepH = NUSeparatorHeight();
    CGFloat hI = [self nu_hInset];
    CGFloat artTop = [self nu_artworkTop];

    self.separator.frame = CGRectMake(hI, 0, w - 2 * hI, sepH);
    BOOL rtl = NUViewIsRTL(self);

    // Skip button aligns with the artwork band (both 44pt); leading edge in RTL.
    self.skipButton.frame = rtl ? CGRectMake(hI, artTop, kSkipButton, kSkipButton)
                                : CGRectMake(w - hI - kSkipButton, artTop, kSkipButton, kSkipButton);
    self.skipButton.hidden = !NUNextUpManager.sharedManager.canSkip;

    // Match the two cards' geometry to the active style.
    self.currentItem.nuHInset = hI;  self.currentItem.nuArtworkTop = artTop;
    self.incomingItem.nuHInset = hI; self.incomingItem.nuArtworkTop = artTop;

    // Content region: everything between the row edge and the skip button.
    CGFloat contentX, contentW;
    if (rtl) {
        contentX = self.skipButton.hidden ? hI : CGRectGetMaxX(self.skipButton.frame);
        contentW = w - contentX;
    } else {
        contentX = 0;
        contentW = self.skipButton.hidden ? (w - hI) : CGRectGetMinX(self.skipButton.frame);
    }
    self.track.frame = CGRectMake(contentX, 0, contentW, h);

    // Update the edge-fade mask (no implicit animation on the layer geometry).
    // Wide fade next to the X button, narrow fade under the artwork inset —
    // in both layout directions (see the kFadeLeading/kFadeTrailing comment).
    if (contentW > 0) {
        CGFloat leftFade  = rtl ? kFadeTrailing : kFadeLeading;
        CGFloat rightFade = rtl ? kFadeLeading  : kFadeTrailing;
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        self.trackMask.frame = self.track.bounds;
        self.trackMask.locations = @[ @0, @(leftFade / contentW), @(1.0 - rightFade / contentW), @1 ];
        [CATransaction commit];
    }

    // Position the two cards by bounds+center so a live swipe transform survives
    // any relayout.
    CGPoint c = CGPointMake(contentW / 2.0, h / 2.0);
    self.currentItem.bounds = CGRectMake(0, 0, contentW, h);
    self.currentItem.center = c;
    self.incomingItem.bounds = CGRectMake(0, 0, contentW, h);
    self.incomingItem.center = c;
}

#pragma mark - Data

- (void)managerChanged:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{ [self refreshFromManager]; });
}

- (void)refreshFromManager {
    NUNextUpManager *mgr = NUNextUpManager.sharedManager;

    // Mid-commit: keep showing the promoted item until the queue settles on it,
    // so a stale snapshot doesn't flash the just-skipped track.
    if (self.committing) {
        if (self.promotedTitle && [mgr.nextTitle isEqualToString:self.promotedTitle]) [self finishCommit];
        return;
    }
    if (self.activeDir != 0) return;   // don't clobber an in-progress drag

    self.hasContent = mgr.active;
    // Set alongside the content, not in -layoutSubviews: a host layout pass runs during the
    // post-commit settle and mid-drag, where this method returns early. Reading the source
    // live there would frame the well for a source whose artwork is not on screen yet.
    BOOL wide = mgr.prefersWideArtwork;
    self.currentItem.nuWideArtwork = wide;
    self.incomingItem.nuWideArtwork = wide;
    [self.currentItem applyTitle:mgr.nextTitle subtitle:mgr.nextSubtitle artwork:mgr.nextArtwork];
    [self setNeedsLayout];
}

- (void)applyConcentricArtworkForCardCornerRadius:(CGFloat)cardRadius {
    // Concentric to the enclosing card's corner: inner radius = card radius minus
    // the artwork's uniform inset from that corner. In the CC style the artwork sits
    // 24pt from both the leading and bottom card edges, so 40pt − 24pt = 16pt.
    CGFloat r = cardRadius > 0 ? MAX(kArtCorner, cardRadius - [self nu_concentricInset]) : NULockArtCorner();
    self.currentItem.nuArtCorner = r;
    self.incomingItem.nuArtCorner = r;
}

- (void)skipTapped {
    // The X mirrors the skip swipe (nu_forwardPhysicalDir), motion included; falls back to an
    // immediate skip when there's no known following track or a swipe is in
    // flight. A tap DURING a commit is dropped — a second skip would remove a
    // track the user can't even see yet (the double-tap-on-X trap).
    if (self.committing) return;
    CGFloat fdir = [self nu_forwardPhysicalDir];
    if (self.activeDir != 0 || ![self swipeAllowedForDir:fdir]) {
        // The system-wide Sounds & Haptics → System Haptics toggle already
        // suppresses UIImpactFeedbackGenerator; no per-app check exists.
        [[self nu_haptics] impactOccurred];
        [NUNextUpManager.sharedManager skipNextTrack];
        return;
    }
    CGFloat W = self.track.bounds.size.width;
    if (W <= 0) { [NUNextUpManager.sharedManager skipNextTrack]; return; }

    // Stage the following track off-screen on its entry side, then run the same
    // commit animation the swipe uses (which handles the haptic, the skip, and
    // promoting the incoming card once the queue settles).
    [self prepareIncomingForDirection:fdir];
    self.incomingItem.hidden = NO;
    // Under Reduce Motion commitDir: crossfades in place — don't stage a slide.
    self.incomingItem.transform = NUReduceMotion()
        ? CGAffineTransformIdentity : CGAffineTransformMakeTranslation(self.incomingSign * W, 0);
    self.incomingItem.alpha = 0.0;
    [self commitDir:fdir velocity:0 width:W];
}

#pragma mark - Artwork tap → play next

- (void)artworkPressed:(UILongPressGestureRecognizer *)press {
    switch (press.state) {
        case UIGestureRecognizerStateBegan:
            [self setArtworkHighlighted:YES];
            break;
        case UIGestureRecognizerStateChanged:
            [self setArtworkHighlighted:[self pressIsInsideArtwork:press]];
            break;
        case UIGestureRecognizerStateEnded: {
            BOOL inside = [self pressIsInsideArtwork:press];
            [self setArtworkHighlighted:NO];
            // Zero-duration press = touch-down recognition; see the note in
            // setupSubviews. Guards the race where pan-cancel and press-end
            // land in the same runloop turn.
            if (inside && self.activeDir == 0 && !self.committing) [self playNextTapped];
            break;
        }
        default:
            [self setArtworkHighlighted:NO];
            break;
    }
}

- (BOOL)pressIsInsideArtwork:(UILongPressGestureRecognizer *)press {
    UIView *art = self.currentItem.artworkView;
    return CGRectContainsPoint(art.bounds, [press locationInView:art]);
}

- (void)setArtworkHighlighted:(BOOL)on {
    [UIView animateWithDuration:(on ? kPressInDuration : kPressOutDuration)
                          delay:0
                        options:UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionAllowUserInteraction |
                                UIViewAnimationOptionCurveEaseOut
                     animations:^{
        self.currentItem.artworkView.alpha = on ? kArtworkPressAlpha : 1.0;
    } completion:nil];
}

- (void)playNextTapped {
    [[self nu_haptics] impactOccurred];
    [NUNextUpManager.sharedManager playNextTrack];
}

// One reused generator, primed at touch-down (see -gestureRecognizer:shouldReceiveTouch:):
// a cold, per-event UIImpactFeedbackGenerator can fire late or drop the first impact.
- (UIImpactFeedbackGenerator *)nu_haptics {
    if (!_haptics) _haptics = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    return _haptics;
}

#pragma mark - Swipe carousel

- (void)panned:(UIPanGestureRecognizer *)pan {
    if (self.committing) return;
    CGFloat W = self.track.bounds.size.width;
    if (W <= 0) return;
    CGFloat tx = [pan translationInView:self].x;

    switch (pan.state) {
        case UIGestureRecognizerStateBegan:
            [self setArtworkHighlighted:NO];
            self.activeDir = 0;
            break;
        case UIGestureRecognizerStateChanged: {
            // Direction hysteresis: only lock a direction once the finger has
            // travelled past a small threshold, and never re-detect it after.
            // This stops a wobble across tx==0 from flipping direction (and
            // re-running the relayout in prepareIncomingForDirection:) mid-drag.
            if (self.activeDir == 0) {
                if (fabs(tx) < kSwipeDirectionLock) break;   // not yet committed to a direction
                CGFloat dir = (tx < 0) ? -1 : 1;
                self.activeDir = dir;
                // Cancel the artwork press: zero-duration press = touch-down
                // recognition; see the note in setupSubviews.
                self.artworkPress.enabled = NO;
                self.artworkPress.enabled = YES;
                [self prepareIncomingForDirection:dir];
            }
            // Remove the direction-lock dead zone so the card engages from 0
            // (no 8pt jump), clamped so dragging back toward centre can't push it
            // past centre the wrong way.
            CGFloat eff = tx - self.activeDir * kSwipeDirectionLock;
            if (self.activeDir < 0) eff = MIN(eff, 0.0); else eff = MAX(eff, 0.0);
            BOOL allowed = [self swipeAllowedForDir:self.activeDir];
            CGFloat adj = allowed ? eff : eff * 0.30;   // 0.30 = rubber-band factor for a disallowed direction
            CGFloat prog = MIN(fabs(adj) / W, 1.0);
            self.currentItem.transform = CGAffineTransformMakeTranslation(adj, 0);
            self.currentItem.alpha = 1.0 - prog;                       // fade the context out
            if (allowed && self.incomingSign != 0) {
                self.incomingItem.hidden = NO;
                self.incomingItem.transform = CGAffineTransformMakeTranslation(adj + self.incomingSign * W, 0);
                self.incomingItem.alpha = prog;                        // and the new row in
            } else {
                self.incomingItem.hidden = YES;
            }
            break;
        }
        case UIGestureRecognizerStateEnded: {
            CGFloat vx = [pan velocityInView:self].x;
            CGFloat dir = self.activeDir;
            BOOL flick = fabs(vx) > kSwipeCommitVelocity && ((vx < 0 ? -1 : 1) == dir);
            BOOL past = fabs(tx) > W * kSwipeCommitFraction;
            if (dir != 0 && [self swipeAllowedForDir:dir] && (flick || past)) {
                [self commitDir:dir velocity:vx width:W];
            } else {
                [self cancelSwipeWithVelocity:vx width:W];
            }
            break;
        }
        case UIGestureRecognizerStateCancelled: {
            // The OS can cancel the touch mid-drag (cross-process gesture
            // arbitration on the lock screen); a drag already past the commit
            // distance still commits instead of snapping back.
            CGFloat dir = self.activeDir;
            CGFloat pos = self.currentItem.transform.tx;
            if (dir != 0 && [self swipeAllowedForDir:dir] && fabs(pos) > W * kSwipeCommitFraction) {
                [self commitDir:dir velocity:0 width:W];
            } else {
                [self cancelSwipeWithVelocity:0 width:W];
            }
            break;
        }
        default:
            [self cancelSwipeWithVelocity:0 width:W];
            break;
    }
}

// The single source of truth for the physical-direction ↔ verb mapping: the
// "skip/forward" swipe is left (-1) in LTR, right (+1) in RTL. Everything
// animation-side stays physical.
- (CGFloat)nu_forwardPhysicalDir {
    return NUViewIsRTL(self) ? 1 : -1;
}

// Physical `dir` (finger direction) → logical verb.
- (BOOL)nu_isForwardDir:(CGFloat)dir {
    return dir == [self nu_forwardPhysicalDir];
}

// The incoming card always enters from the side the finger moves toward
// (physical); WHICH neighbour it shows is the logical part.
- (void)prepareIncomingForDirection:(CGFloat)dir {
    NUNextUpManager *mgr = NUNextUpManager.sharedManager;
    self.incomingSign = (dir < 0) ? +1 : -1;
    if ([self nu_isForwardDir:dir]) {
        [self.incomingItem applyTitle:mgr.fwdTitle subtitle:mgr.fwdSubtitle artwork:mgr.fwdArtwork];
    } else {
        [self.incomingItem applyTitle:mgr.backTitle subtitle:mgr.backSubtitle artwork:mgr.backArtwork];
    }
    [self.incomingItem setNeedsLayout];
    [self.incomingItem layoutIfNeeded];
}

- (BOOL)swipeAllowedForDir:(CGFloat)dir {
    NUNextUpManager *mgr = NUNextUpManager.sharedManager;
    if (dir == 0) return NO;
    if ([self nu_isForwardDir:dir]) return mgr.canSkip && mgr.fwdTitle.length > 0;
    // Previous: Music enqueues via a store id (filters local-only tracks); Podcasts
    // enqueues provider-side by uuid. -canActionPrevious encapsulates the per-source rule.
    return [mgr canActionPrevious];
}

- (void)commitDir:(CGFloat)dir velocity:(CGFloat)vx width:(CGFloat)W {
    self.committing = YES;
    [[self nu_haptics] impactOccurred];

    BOOL forward = [self nu_isForwardDir:dir];
    void (^performAction)(BOOL) = ^(BOOL finished) {
        NUNextUpManager *mgr = NUNextUpManager.sharedManager;
        if (forward) [mgr skipNextTrack]; else [mgr playPreviousTrack];
        [self promoteIncoming];
    };

    if (NUReduceMotion()) {
        // Crossfade in place instead of the slide: both cards centred, only the
        // alphas move. Same completion path as the spring. 0.2s fade, tuned by eye.
        self.currentItem.transform = CGAffineTransformIdentity;
        self.incomingItem.transform = CGAffineTransformIdentity;
        self.incomingItem.hidden = NO;
        [UIView animateWithDuration:0.2 delay:0
                            options:UIViewAnimationOptionCurveLinear | UIViewAnimationOptionAllowUserInteraction
                         animations:^{
            self.currentItem.alpha = 0.0;
            self.incomingItem.alpha = 1.0;
        } completion:performAction];
        return;
    }

    CGFloat currentTargetX = dir * W;   // off-screen the way you swiped
    CGFloat startTx = self.currentItem.transform.tx;
    CGFloat remaining = currentTargetX - startTx;
    // initialSpringVelocity is normalized: (points/second of the gesture) over
    // the distance still to travel. Guard divide-by-zero and clamp so a tiny
    // remaining distance can't produce an explosive overshoot.
    CGFloat springVel = (fabs(remaining) > 0.5) ? fabs(vx / remaining) : 0.0;
    springVel = MIN(springVel, kSpringVelocityMax);

    // 0.32s commit spring, tuned by eye.
    [UIView animateWithDuration:0.32 delay:0
         usingSpringWithDamping:1.0 initialSpringVelocity:springVel
                        options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        self.currentItem.transform = CGAffineTransformMakeTranslation(currentTargetX, 0);
        self.currentItem.alpha = 0.0;
        self.incomingItem.transform = CGAffineTransformIdentity;   // slide to centre
        self.incomingItem.alpha = 1.0;
    } completion:performAction];
}

// The neighbour we just swiped to is the new up-next. Show it as the current
// card immediately (data is prefetched, so no blank gap) and wait for the queue
// to catch up before accepting fresh snapshots.
- (void)promoteIncoming {
    self.promotedTitle = self.incomingItem.itemTitle;
    [self.currentItem applyTitle:self.incomingItem.itemTitle
                        subtitle:self.incomingItem.itemSubtitle
                         artwork:self.incomingItem.itemArtwork];
    self.currentItem.transform = CGAffineTransformIdentity;
    self.currentItem.alpha = 1.0;
    self.incomingItem.hidden = YES;
    self.incomingItem.transform = CGAffineTransformIdentity;
    self.incomingItem.alpha = 0.0;
    self.activeDir = 0;
    self.incomingSign = 0;

    [self.settleTimer invalidate];
    __weak typeof(self) ws = self;
    // Common modes, not the default mode: while the run loop is tracking (user
    // keeps scrolling/paging right after the commit) a default-mode timer is
    // deferred, stretching the window in which refreshFromManager drops snapshots.
    NSTimer *settle = [NSTimer timerWithTimeInterval:kSettleFallback repeats:NO
                                               block:^(NSTimer *t) { [ws finishCommit]; }];
    [[NSRunLoop mainRunLoop] addTimer:settle forMode:NSRunLoopCommonModes];
    self.settleTimer = settle;
}

- (void)finishCommit {
    [self.settleTimer invalidate];
    self.settleTimer = nil;
    self.committing = NO;
    [self refreshFromManager];
    // Let VoiceOver pick up the row's new content after a commit without
    // stealing focus. Gated so it costs nothing when VoiceOver is off.
    if (UIAccessibilityIsVoiceOverRunning()) {
        UIAccessibilityPostNotification(UIAccessibilityLayoutChangedNotification, nil);
    }
}

- (void)cancelSwipeWithVelocity:(CGFloat)vx width:(CGFloat)W {
    CGFloat startTx = self.currentItem.transform.tx;
    // Normalized spring velocity over the distance back to centre (|startTx|),
    // guarded and clamped so a near-centre release can't overshoot violently.
    CGFloat springVel = (fabs(startTx) > 0.5) ? fabs(vx / startTx) : 0.0;
    springVel = MIN(springVel, kSpringVelocityMax);
    CGFloat sign = self.incomingSign;
    if (NUReduceMotion()) {
        // Short plain return instead of the spring — the card is only displaced
        // by the user's own drag, so a quick ease-out back to centre is calmest.
        // 0.2s, tuned by eye.
        [UIView animateWithDuration:0.2 delay:0
                            options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionAllowUserInteraction
                         animations:^{
            self.currentItem.transform = CGAffineTransformIdentity;
            self.currentItem.alpha = 1.0;
            if (sign != 0) self.incomingItem.transform = CGAffineTransformMakeTranslation(sign * W, 0);
            self.incomingItem.alpha = 0.0;
        } completion:^(BOOL finished) {
            self.incomingItem.hidden = YES;
            self.activeDir = 0;
            self.incomingSign = 0;
            [self refreshFromManager]; // apply anything dropped while the drag was live
        }];
        return;
    }
    // 0.40s snap-back spring, tuned by eye.
    [UIView animateWithDuration:0.40 delay:0
         usingSpringWithDamping:kSwipeBackDamping initialSpringVelocity:springVel
                        options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        self.currentItem.transform = CGAffineTransformIdentity;
        self.currentItem.alpha = 1.0;
        if (sign != 0) self.incomingItem.transform = CGAffineTransformMakeTranslation(sign * W, 0);
        self.incomingItem.alpha = 0.0;
    } completion:^(BOOL finished) {
        self.incomingItem.hidden = YES;
        self.activeDir = 0;
        self.incomingSign = 0;
        [self refreshFromManager]; // apply anything dropped while the drag was live
    }];
}

#pragma mark - UIGestureRecognizerDelegate

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gr {
    if (![gr isKindOfClass:[UIPanGestureRecognizer class]]) return YES;
    if (self.committing || !NUNextUpManager.sharedManager.active) return NO;
    CGPoint v = [(UIPanGestureRecognizer *)gr velocityInView:self];
    // Bail only when the drag is clearly vertical, so a platter dismiss passes
    // through; near-zero velocity (no motion yet) lets the pan begin and decide.
    if (fabs(v.x) < 1.0 && fabs(v.y) < 1.0) return YES;   // no clear intent yet — let it begin
    // Horizontal-intent bias — 1.5:1 so diagonal flicks still count as horizontal.
    return fabs(v.x) * 1.5 >= fabs(v.y);
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gr shouldReceiveTouch:(UITouch *)touch {
    // Prime the Taptic Engine at touch-down so the commit impact never fires cold.
    [[self nu_haptics] prepare];
    // A drag that begins on the skip button belongs to the button, not the
    // carousel — don't let the pan claim it, so pressing the X and sliding off
    // never drags the next-up card. (The button's own tap tracking stays intact.)
    if (!self.skipButton.hidden &&
        CGRectContainsPoint(self.skipButton.frame, [touch locationInView:self])) {
        return NO;
    }
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gr
        shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    // Recognise alongside Apple's gestures (SpringBoard's paging over the platter
    // is blocked separately, in the SpringBoard hook).
    return YES;
}

#pragma mark - Accessibility

// The row is one VoiceOver element: "Up Next: Title — Artist". Label and
// actions are computed on demand so they never go stale across refreshes or swipes.

- (NSString *)accessibilityLabel {
    NSString *t = self.currentItem.itemTitle;
    NSString *s = self.currentItem.itemSubtitle;
    if (t.length == 0) return NULocalizedString(@"AX_UP_NEXT", @"Up Next");
    // Positional specifiers so translations may reorder title and artist.
    return s.length ? [NSString stringWithFormat:NULocalizedString(@"AX_UP_NEXT_TITLE_ARTIST", @"Up Next: %1$@ — %2$@"), t, s]
                    : [NSString stringWithFormat:NULocalizedString(@"AX_UP_NEXT_TITLE", @"Up Next: %1$@"), t];
}

- (NSString *)accessibilityHint {
    return NULocalizedString(@"AX_HINT_PLAY_NOW", @"Double-tap to play this track now");
}

- (UIAccessibilityTraits)accessibilityTraits {
    // StartsMediaSession keeps VoiceOver from talking over the music the
    // activate action starts (Apple's recommended pattern for play actions).
    return super.accessibilityTraits | UIAccessibilityTraitButton
                                     | UIAccessibilityTraitStartsMediaSession;
}

// Activate mirrors the sighted primary interaction (tapping the artwork).
- (BOOL)accessibilityActivate {
    if (!NUNextUpManager.sharedManager.active) return NO;
    [NUNextUpManager.sharedManager playNextTrack];
    return YES;
}

// The swipe verbs, gated on the same flags as swipeAllowedForDir:.
- (NSArray<UIAccessibilityCustomAction *> *)accessibilityCustomActions {
    NUNextUpManager *mgr = NUNextUpManager.sharedManager;
    NSMutableArray *actions = [NSMutableArray array];
    __weak typeof(self) ws = self;
    if (mgr.canSkip) {
        [actions addObject:[[UIAccessibilityCustomAction alloc] initWithName:NULocalizedString(@"AX_ACTION_SKIP", @"Skip")
            actionHandler:^BOOL(UIAccessibilityCustomAction *ac) {
                [ws nu_accessibilityCommitForward:YES];
                return YES;
            }]];
    }
    if ([mgr canActionPrevious]) {
        [actions addObject:[[UIAccessibilityCustomAction alloc] initWithName:NULocalizedString(@"AX_ACTION_PLAY_PREVIOUS_NEXT", @"Play previous track next")
            actionHandler:^BOOL(UIAccessibilityCustomAction *ac) {
                [ws nu_accessibilityCommitForward:NO];
                return YES;
            }]];
    }
    return actions;
}

// Bypasses commitDir:'s carousel: the slide is meaningless under VoiceOver, and
// skipping the committing/settle state machine means a never-settling queue
// can't wedge it. Takes the logical verb directly (not a physical dir), so it
// is layout-direction-independent by construction.
- (void)nu_accessibilityCommitForward:(BOOL)forward {
    NUNextUpManager *mgr = NUNextUpManager.sharedManager;
    if (forward) [mgr skipNextTrack]; else [mgr playPreviousTrack];
    UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification,
                                    forward ? NULocalizedString(@"AX_ANNOUNCE_SKIPPED", @"Skipped")
                                            : NULocalizedString(@"AX_ANNOUNCE_PREVIOUS_QUEUED", @"Previous track queued"));
}

@end
