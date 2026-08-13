// iOS 26 Control Center now-playing module.
//
// iOS 26 rewrote Control Center's media module in Swift. What the iOS 18 hooks
// (NUHooksControlCenter18.x) attach to is gone:
//
//   | role                | iOS 18                                     | iOS 26                                    |
//   |---------------------|--------------------------------------------|-------------------------------------------|
//   | module controller   | MRUMediaControlsModuleViewController        | same name, Swift implementation           |
//   | now-playing VC      | MRUMediaControlsModuleNowPlayingViewController | GONE — no view controller at all       |
//   | now-playing view    | MRUMediaControlsModuleNowPlayingView        | MediaControls.MediaControlsModuleNowPlayingView (Swift) |
//   | session container   | MRUMediaControlsModuleContainerView         | MediaControls.MediaControlsModuleSessionView (Swift) |
//   | route picker        | MRUMediaControlsModuleRoutingView           | MediaControls.RoutePickerItemsView (Swift) |
//   | artwork             | MRUArtworkView                              | MediaControls.ArtworkControl (Swift)      |
//
// Two consequences drive the design here:
//
// 1. There is no now-playing view controller any more, so the row cannot be attached
//    from -viewDidLoad the way it is on 18. It is attached lazily from the view's own
//    -layoutSubviews instead. Swift classes still dispatch UIView overrides through
//    the ObjC runtime, so -layoutSubviews / -sizeThatFits: are hookable by mangled
//    class name; the Swift-only methods are not, and nothing here needs them.
//
// 2. `MRUMediaControlsModuleViewController.isExpanded` became a plain Swift stored
//    property with no ObjC accessor, so the expanded/collapsed gate that iOS 18 reads
//    directly cannot be read at all. We stamp it ourselves from
//    -didTransitionToExpandedContentMode: (the same signal Apple drives the
//    transition from) and NUCCModuleExpanded falls back to that stamp.
//
// The geometry work is unchanged and shared with iOS 18 via NUCCLayoutRow().
#import "NUHooksShared.h"

// Swift classes have no headers. Declaring the mangled name as the UIView subclass it
// actually is, is enough for both %hook and the plain UIView messaging below — we only
// ever touch inherited UIView API on it.
@interface _TtC13MediaControls33MediaControlsModuleNowPlayingView : UIView
@end

@interface MRUMediaControlsModuleViewController (NUCC26)
- (void)nu_cc26Register;
- (void)nu_cc26Changed;
@end

// Attach the row to a Swift now-playing view. Idempotent — called from every layout
// pass because there is no earlier hook point.
static NUNextUpRowView *NUCC26EnsureRow(UIView *npView) {
    for (UIView *sub in npView.subviews)
        if ([sub isKindOfClass:[NUNextUpRowView class]]) return (NUNextUpRowView *)sub;

    NUNextUpRowView *row = [[NUNextUpRowView alloc] initWithFrame:CGRectZero];
    row.alpha = 0.0;   // visibility is alpha-driven so it animates with the card
    [row configureForControlCenter];
    [npView addSubview:row];
    objc_setAssociatedObject(npView, kNUHostViewKey, @(NUHostControlCenter),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NULog("CC26 row attached proc=%{public}@ view=%{public}@ bounds=%{public}@",
          NSProcessInfo.processInfo.processName, NSStringFromClass(npView.class),
          NSStringFromCGRect(npView.bounds));
    return row;
}

%group NUCC26

#pragma mark - Module controller (lifecycle + expanded state)

%hook MRUMediaControlsModuleViewController

- (void)viewDidLoad {
    %orig;
    [[NUNextUpManager sharedManager] start];
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    [[NUNextUpManager sharedManager] start];
    [self nu_cc26Register];
    [self nu_cc26Changed];
}

- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:NUNextUpDidChangeNotification object:nil];
    // Drop the process-wide expanded stamp with the module: dismissing Control Center
    // while the card is expanded need not deliver a collapse transition, and the next
    // presentation builds a fresh controller that would inherit the stale YES and stamp
    // the collapsed tile as expanded.
    objc_setAssociatedObject(NUNextUpManager.sharedManager, kNUCCExpandedKey,
                             nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// The expanded gate. `isExpanded` is unreadable from ObjC on iOS 26 (see the file
// comment), so mirror the transition onto the controller where NUCCModuleExpanded
// can find it. Both edges are hooked: -willTransition… so the row is gated correctly
// during the animation, -didTransition… so the final state is right even if the
// transition is cancelled and re-driven.
- (void)willTransitionToExpandedContentMode:(BOOL)expanded {
    %orig;
    objc_setAssociatedObject(self, kNUCCExpandedKey, @(expanded), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // Process-wide too: the route picker re-hosts the card under a controller that
    // never sees a transition (see NUCCModuleExpanded).
    objc_setAssociatedObject(NUNextUpManager.sharedManager, kNUCCExpandedKey,
                             @(expanded), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self.viewIfLoaded setNeedsLayout];
}

- (void)didTransitionToExpandedContentMode:(BOOL)expanded {
    %orig;
    objc_setAssociatedObject(self, kNUCCExpandedKey, @(expanded), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // Process-wide too: the route picker re-hosts the card under a controller that
    // never sees a transition (see NUCCModuleExpanded).
    objc_setAssociatedObject(NUNextUpManager.sharedManager, kNUCCExpandedKey,
                             @(expanded), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self.viewIfLoaded setNeedsLayout];
    NULog("CC26 expanded=%d", expanded);
}

%new
- (void)nu_cc26Register {
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:NUNextUpDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(nu_cc26Changed)
                                                 name:NUNextUpDidChangeNotification
                                               object:nil];
}

// Content changed: the row's own labels are refreshed in the view's layout pass, so
// all this has to do is ask for one. Nothing here can grow the card — the row is made
// to fit inside the natural height (NUCCLayoutRow), exactly as on iOS 18.
%new
- (void)nu_cc26Changed {
    [self.viewIfLoaded setNeedsLayout];
}

%end

#pragma mark - Now-playing view (row attach + placement)

%hook _TtC13MediaControls33MediaControlsModuleNowPlayingView

- (void)layoutSubviews {
    NUNextUpRowView *row = NUCC26EnsureRow(self);
    // Re-stamp every pass: this view is reused for the collapsed tile and the
    // expanded card, and the module never tells the view which one it currently is.
    BOOL expanded = NUCCModuleExpanded(self);
    NUSetViewCCExpanded(self, expanded);
    [row refreshFromManager];
    %orig;                       // Apple's natural layout
    // Computed after %orig, which is what collapses the card into the route picker's
    // 62pt pill — a verdict taken before it describes the previous frame's geometry.
    NUCCLayoutRow(self, NUViewShowsRow(self));   // shared with iOS 18
}

// The route picker expands out of a sibling view; while it is open our extra row
// throws the container layout off, so hide it for the duration. Same treatment as
// iOS 18, driven from the Swift delegate callback instead of -didSelectRouteButton:.
- (void)didSelectRouteButtonWithButton:(id)button {
    BOOL wasOpen = NUCCRoutingViewOpen(self);
    %orig;
    void *setKey   = wasOpen ? kNURouteClosingKey : kNURouteOpeningKey;
    void *clearKey = wasOpen ? kNURouteOpeningKey : kNURouteClosingKey;
    objc_setAssociatedObject(self, clearKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, setKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self setNeedsLayout];
    __weak UIView *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        objc_setAssociatedObject(weakSelf, setKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [weakSelf setNeedsLayout];
    });
}

%end

%end // NUCC26

// MediaControls.framework is NOT loaded when our %ctor runs: Control Center's media
// module bundle is brought in on demand, so the classes above do not exist yet and a
// %init at constructor time silently hooks nothing (observed — no "CC26 hooks active"
// line, no row). Install the hooks the moment the image shows up instead.
// _dyld_register_func_for_add_image also replays already-loaded images, so this covers
// both orders without a separate up-front check.
#import <mach-o/dyld.h>

static void NUCC26InitIfLoaded(void) {
    static BOOL done = NO;
    if (done) return;
    if (!objc_getClass("_TtC13MediaControls33MediaControlsModuleNowPlayingView")) return;
    done = YES;
    %init(NUCC26);
    NULog("CC26 hooks active (iOS %ld)", (long)NUIOSMajor());
}

static void NUCC26ImageAdded(const struct mach_header *mh, intptr_t slide) {
    NUCC26InitIfLoaded();
}

%ctor {
    @autoreleasepool {
        NUApplySandbox();
        if (!NUIsDisplaySide()) return;
        // Gate on the classes actually existing rather than on a version number: the
        // iOS 18 group hooks a different set of classes, and each generation's classes
        // are absent on the other OS.
        _dyld_register_func_for_add_image(NUCC26ImageAdded);
    }
}
