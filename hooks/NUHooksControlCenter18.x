// iOS 18 Control Center now-playing module (MRUMediaControlsModuleNowPlaying*).
// These classes only exist on iOS 18; Logos skips the hooks on <=17 (nil class),
// where NUHooksControlCenterLegacy runs instead.
#import "NUHooksShared.h"
#import <mach-o/dyld.h>

%group NUCC18
#pragma mark - iOS 18 Control Center now-playing module

// These four classes only exist on iOS 18; Logos skips the hooks on <=17 (nil class),
// where the MRUNowPlayingViewController/MRUControlCenterViewController path above runs
// instead. The view is tagged host=ControlCenter so the shared static view helpers
// (NUViewShowsRow / NUViewGrowsFit / NURowHeightForView) apply unchanged.

%hook MRUMediaControlsModuleNowPlayingViewController

%property (nonatomic, strong) NUNextUpRowView *nu_row;

- (void)viewDidLoad {
    %orig;
    [[NUNextUpManager sharedManager] start];
    [self nu_ensureRow];
}

%new
- (void)nu_ensureRow {
    if (self.nu_row) return;
    NUNextUpRowView *row = [[NUNextUpRowView alloc] initWithFrame:CGRectZero];
    row.hidden = YES;
    [row configureForControlCenter];
    self.nu_row = row;
    [self.view addSubview:row];
    objc_setAssociatedObject(self.view, kNUHostViewKey, @(NUHostControlCenter), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // Expanded/collapsed is stamped every layout pass by the view's -layoutSubviews
    // (NUCCModuleExpanded); the row only shows on the expanded card.
    [self nu_registerForChanges];
    NULog("MRU18 CC row attached proc=%{public}@ parent=%{public}@",
          NSProcessInfo.processInfo.processName, NSStringFromClass(self.parentViewController.class));
}

%new
- (void)nu_registerForChanges {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:NUNextUpDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(nu_changed)
                                                 name:NUNextUpDidChangeNotification
                                               object:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    [[NUNextUpManager sharedManager] start];
    [self nu_ensureRow];
    [self nu_registerForChanges];
    [self nu_changed];
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    [[NSNotificationCenter defaultCenter] removeObserver:self name:NUNextUpDidChangeNotification object:nil];
}

// Refresh labels + row visibility, then nudge the enclosing module to re-measure its
// expanded height (which our -preferredExpandedContentHeight hook grows).
%new
- (void)nu_changed {
    if (![self isViewLoaded]) return;
    [self.nu_row refreshFromManager];
    // Visibility is owned by the view's -layoutSubviews (gated on active + expanded).
    [self.view setNeedsLayout];
    UIViewController *mod = self.parentViewController;
    while (mod && ![mod isKindOfClass:objc_getClass("MRUMediaControlsModuleViewController")])
        mod = mod.parentViewController;
    [mod.viewIfLoaded setNeedsLayout];
    [mod.viewIfLoaded.superview setNeedsLayout];
}

// AirPlay routing picker (a sibling view that expands out of our now-playing view):
// hide the row the instant the route button is tapped so the picker has room to open,
// then let it settle — the routing-view height keeps the row hidden while it's up, and
// clearing the opening flag afterwards lets -layoutSubviews restore the row on dismiss.
%new
- (void)nu_routeToggled:(BOOL)wasOpen {
    UIView *v = self.viewIfLoaded;
    if (!v) return;
    void *setKey   = wasOpen ? kNURouteClosingKey : kNURouteOpeningKey; // closing → force show; opening → force hide
    void *clearKey = wasOpen ? kNURouteOpeningKey : kNURouteClosingKey;
    objc_setAssociatedObject(v, clearKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(v, setKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [v setNeedsLayout];
    // Drop the override once the picker's open/close animation has settled; -layoutSubviews
    // then resumes gating on the real routing-view height.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        objc_setAssociatedObject(v, setKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [v setNeedsLayout];
    });
}

- (void)didSelectRouteButton:(id)arg1 { BOOL wasOpen = NUCCRoutingViewOpen(self.viewIfLoaded); %orig; [self nu_routeToggled:wasOpen]; }
- (void)toggleRoutePicker { BOOL wasOpen = NUCCRoutingViewOpen(self.viewIfLoaded); %orig; [self nu_routeToggled:wasOpen]; }

%end

%hook MRUMediaControlsModuleNowPlayingView

// CC grows via -preferredExpandedContentHeight (below), not sizeThatFits — so
// NUViewGrowsFit is NO here and this is a straight pass-through, matching the
// lock-screen MRUNowPlayingView behaviour under Control Center.
- (CGSize)sizeThatFits:(CGSize)size {
    CGSize r = %orig;
    if (NUViewGrowsFit(self)) r.height += NURowHeightForView(self);
    return r;
}

- (void)layoutSubviews {
    // Keep the expanded stamp current every layout pass (covers expand/collapse
    // transitions without hooking the module's own layout machinery).
    NUSetViewCCExpanded(self, NUCCModuleExpanded(self));
    BOOL show = NUViewShowsRow(self);
    %orig; // natural layout

    // Geometry is shared with the iOS 26 module (see NUCCLayoutRow in
    // NUHooksShared.h): the card was rewritten in Swift on 26 and every class name
    // changed, but the problem and the fix did not.
    NUCCLayoutRow(self, show);
}

%end

%end // NUCC18

%group NUCCRoute
#pragma mark - iOS 18+ Control Center routing surfaces (shared with iOS 26)

// Control Center opens its AirPlay routing UI from two controls, on two different classes;
// both must hide the row for the duration so it is not left overlapping the routing content.
// Each action runs synchronously at tap, before the routing UI animates in, so hiding from
// here lands before the transition rather than during it. Both classes and selectors are
// identical on iOS 18 and 26, so one group covers both.

// The transport row's routing button opens the inline picker. The now-playing VC's
// -didSelectRouteButton: / -toggleRoutePicker cover the module's own route buttons, not this
// one. The transport view also backs the lock-screen and Dynamic Island players, so act only
// when a Control Center now-playing view is found above the button.
%hook MRUNowPlayingTransportControlsView

- (void)didSelectRoutingButton:(id)button {
    UIView *np = nil;
    for (UIView *v = ((UIView *)self).superview; v; v = v.superview)
        if (NUViewHostKind(v) == NUHostControlCenter) { np = v; break; }
    BOOL wasOpen = np ? NUCCRoutingViewOpen(np) : NO;
    %orig;
    if (np) NUCCApplyRouteOverride(np, wasOpen);
}

%end

// The "Control Other Speakers & TVs" button opens the full routing list via
// -didSelectListState:, which sets discoveryMode. %orig updates discoveryMode, so relaying
// out the now-playing view here applies the NUCCDiscoveryActive gate on the tap. The row is
// restored on dismissal, when discoveryMode returns to 0 and the next layout runs.
%hook MRUMediaControlsModuleViewController

- (void)didSelectListState:(id)arg1 {
    %orig;
    [NUCCNowPlayingInSubtree(self.viewIfLoaded) setNeedsLayout];
}

%end
%end // NUCCRoute

// MediaControls is loaded up front on iOS 18 but on demand on iOS 26, so gate the routing hooks
// on the class actually existing rather than on constructor timing. _dyld_register_func_for_add_image
// replays already-loaded images, so this fires immediately on 18 and when the module loads on 26.
static void NUCCRouteInitIfLoaded(void) {
    static BOOL done = NO;
    if (done) return;
    if (NUIOSMajor() < 18) return;                                   // 14–17 keep the modal path
    if (!objc_getClass("MRUNowPlayingTransportControlsView")) return;
    done = YES;
    %init(NUCCRoute);
}

static void NUCCRouteImageAdded(const struct mach_header *mh, intptr_t slide) {
    NUCCRouteInitIfLoaded();
}

%ctor {
    @autoreleasepool {
        NUApplySandbox();
        if (!NUIsDisplaySide()) return;
        %init(NUCC18);
        if (NUIOSMajor() >= 18)
            _dyld_register_func_for_add_image(NUCCRouteImageAdded);
    }
}
