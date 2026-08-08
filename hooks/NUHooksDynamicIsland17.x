// iOS 17 Dynamic Island expanded now-playing player (MRUActivityNowPlaying*).
// Rendered by MediaRemoteUI into an ActivityUIServices SystemAperture scene. The
// shared kNUDIExpandedMode / kNUDIExpandedMinHeight constants live in NUHooksShared.h
// (iOS 16 NUHooksDynamicIsland16 reuses them). Whichever DI class family exists on
// the running OS installs; the other no-ops (nil class).
#import "NUHooksShared.h"
#import <mach-o/dyld.h>

%group NUDI17
%hook MRUActivityNowPlayingViewController

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
    [row configureForDynamicIsland];
    self.nu_row = row;
    [self.view addSubview:row];
    objc_setAssociatedObject(self.view, kNUHostViewKey, @(NUHostDynamicIsland), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self nu_registerForChanges];
    NULog("DI row attached: activeMode=%lld maxMode=%lld proc=%{public}@",
          self.activeLayoutMode, self.maximumLayoutMode, NSProcessInfo.processInfo.processName);
}

// Same idempotent re-subscribe as on MRUNowPlayingViewController: viewDidDisappear
// unsubscribes and nu_ensureRow early-returns once the row exists, so without this
// a reappeared island never hears nu_changed again (no mid-open growth).
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

%new
- (BOOL)nu_diExpanded {
    // Deliberately NOT -isExpanded, even though this controller has one: the
    // layout-mode test is what was verified live on iOS 17 and 18, and a class-dump
    // diff of MRUActivityNowPlayingViewController between 18.7.5 and 26.5 comes back
    // identical member for member — so the constant carries to 26 unchanged and
    // switching levers would only put a working surface on an untested path.
    return self.activeLayoutMode >= kNUDIExpandedMode;
}

%new
- (BOOL)nu_shouldShowRow {
    return NUNextUpManager.sharedManager.active && NUInterfaceEnabled(NUHostDynamicIsland)
        && self.isViewLoaded && [self nu_diExpanded];
}

%new
- (void)nu_changed {
    if (![self isViewLoaded]) return;
    [self.nu_row refreshFromManager];
    BOOL show = [self nu_shouldShowRow];
    self.nu_row.hidden = !show;
    [self.view setNeedsLayout];

    // If the row just became showable while the island is already expanded, the
    // aperture reserved its bottom-safe-area height at expand time WITHOUT our
    // row (active was still NO — common right after playback starts). A plain
    // setNeedsLayout doesn't make the aperture re-read our grown height; driving
    // Apple's own layout-mode update does (it re-runs the element/scene-property
    // update that queries -preferredHeightForBottomSafeArea). Only fire on the
    // NO→YES edge so we don't loop on every timer tick / info update.
    BOOL wasShown = [objc_getAssociatedObject(self, kNUDIRowShownKey) boolValue];
    objc_setAssociatedObject(self, kNUDIRowShownKey, @(show), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (show && !wasShown && [self nu_diExpanded]) {
        NULog("DI: row became showable mid-open — forcing layout-mode refresh");
        @try { [self updateLayoutModesPreferringImmediateTransition:NO deferInCustomLayout:NO reason:@"NextUp3 row"]; }
        @catch (__unused NSException *e) {}
    }
}

// The activity reports its preferred content size to ActivityUIServices, which
// sizes the aperture. Grow it by the row height when expanded with a live next
// track, so the Dynamic Island opens tall enough for the row.
// The DI reserves this height at the bottom of the expanded player; grow it by the
// row height so the aperture makes room for the row below the media controls.
- (double)preferredHeightForBottomSafeArea {
    double h = %orig;
    if (NUNextUpManager.sharedManager.active && NUInterfaceEnabled(NUHostDynamicIsland)
        && self.activeLayoutMode >= kNUDIExpandedMode) {
        h += [NUNextUpRowView preferredHeightForControlCenter];
    }
    return h;
}

%end

%hook MRUActivityNowPlayingView

// Clamp to the compact height during our own layout pass so %orig lays the media
// controls out top-anchored and leaves the bottom strip for our row.
- (CGRect)bounds {
    CGRect b = %orig;
    if (objc_getAssociatedObject(self, kNULayoutClampKey)) {
        b.size.height -= NURowHeightForView(self);
    }
    return b;
}

- (void)layoutSubviews {
    // This view is reused for the compact pill and the expanded player; only show
    // the row in the expanded state (gate on the real, unclamped height).
    BOOL show = self.bounds.size.height >= kNUDIExpandedMinHeight
        && NUViewHostKind(self) == NUHostDynamicIsland
        && NUNextUpManager.sharedManager.active
        && NUInterfaceEnabled(NUHostDynamicIsland);
    if (show) {
        objc_setAssociatedObject(self, kNULayoutClampKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        // @finally: if Apple's layout throws, the flag MUST still be cleared —
        // otherwise this view permanently reports a clamped -bounds to everything.
        @try { %orig; }
        @finally { objc_setAssociatedObject(self, kNULayoutClampKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
    } else {
        %orig;
    }

    NUNextUpRowView *row = nil;
    for (UIView *sub in self.subviews) {
        if ([sub isKindOfClass:[NUNextUpRowView class]]) { row = (NUNextUpRowView *)sub; break; }
    }
    if (!row) return;
    row.hidden = !show;
    if (!show) return;
    [self bringSubviewToFront:row];
    CGFloat rowH = NURowHeightForView(self);
    CGRect b = self.bounds; // flag cleared → real grown height
    row.frame = CGRectMake(0, b.size.height - rowH, b.size.width, rowH);
}

%end

%end // NUDI17

// MediaControls.framework is loaded ON DEMAND in SpringBoard, so at constructor time
// these classes do not exist yet and a %init here silently hooks nothing. (Verified on
// iOS 26 via the Control Center module, which failed exactly this way.) Install the
// hooks when the image shows up instead; _dyld_register_func_for_add_image replays
// already-loaded images, so a process that DOES have the framework linked (MediaRemoteUI)
// still initialises at the same moment it used to.
static void NUDI17InitIfLoaded(void) {
    static BOOL done = NO;
    if (done || !objc_getClass("MRUActivityNowPlayingViewController")) return;
    done = YES;
    %init(NUDI17);
    NULog("NUDI17 hooks active (iOS %ld)", (long)NUIOSMajor());
}

static void NUDI17ImageAdded(const struct mach_header *mh, intptr_t slide) {
    NUDI17InitIfLoaded();
}

%ctor {
    @autoreleasepool {
        NUApplySandbox();
        if (!NUIsDisplaySide()) return;
        _dyld_register_func_for_add_image(NUDI17ImageAdded);
    }
}
