// iOS 16 Dynamic Island expanded now-playing player (MRUSessionNowPlaying*). iOS 16
// has no MRUActivityNowPlaying*; this mirrors NUHooksDynamicIsland17 with the same
// layout-mode / bottom-safe-area API plus a clean -isExpanded.
#import "NUHooksShared.h"
#import <mach-o/dyld.h>

%group NUDI16
%hook MRUSessionNowPlayingViewController

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
    NULog("DI(session) row attached: expanded=%d activeMode=%lld proc=%{public}@",
          [self isExpanded], self.activeLayoutMode, NSProcessInfo.processInfo.processName);
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

// iOS 16 exposes a clean -isExpanded; fall back to the layout-mode threshold.
%new
- (BOOL)nu_diExpanded {
    @try { if ([self respondsToSelector:@selector(isExpanded)]) return [self isExpanded]; } @catch (__unused NSException *e) {}
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
    // Force the aperture to re-reserve room if the row became showable mid-open.
    BOOL wasShown = [objc_getAssociatedObject(self, kNUDIRowShownKey) boolValue];
    objc_setAssociatedObject(self, kNUDIRowShownKey, @(show), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (show && !wasShown && [self nu_diExpanded]) {
        NULog("DI(session): row became showable mid-open — forcing layout-mode refresh");
        @try { [self updateLayoutModesPreferringImmediateTransition:NO deferInCustomLayout:NO reason:@"NextUp3 row"]; }
        @catch (__unused NSException *e) {}
    }
}

- (double)preferredHeightForBottomSafeArea {
    double h = %orig;
    if (NUNextUpManager.sharedManager.active && NUInterfaceEnabled(NUHostDynamicIsland)
        && [self nu_diExpanded]) {
        h += [NUNextUpRowView preferredHeightForControlCenter];
    }
    return h;
}

%end

%hook MRUSessionNowPlayingView

- (CGRect)bounds {
    CGRect b = %orig;
    if (objc_getAssociatedObject(self, kNULayoutClampKey)) {
        b.size.height -= NURowHeightForView(self);
    }
    return b;
}

- (void)layoutSubviews {
    // Reused for the compact pill and the expanded player; only show the row when
    // the real (unclamped) height is in the expanded range.
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

%end // NUDI16

// MediaControls.framework is loaded ON DEMAND in SpringBoard, so at constructor time
// these classes do not exist yet and a %init here silently hooks nothing. (Verified on
// iOS 26 via the Control Center module, which failed exactly this way.) Install the
// hooks when the image shows up instead; _dyld_register_func_for_add_image replays
// already-loaded images, so a process that DOES have the framework linked (MediaRemoteUI)
// still initialises at the same moment it used to.
static void NUDI16InitIfLoaded(void) {
    static BOOL done = NO;
    if (done || !objc_getClass("MRUSessionNowPlayingViewController")) return;
    done = YES;
    %init(NUDI16);
    NULog("NUDI16 hooks active (iOS %ld)", (long)NUIOSMajor());
}

static void NUDI16ImageAdded(const struct mach_header *mh, intptr_t slide) {
    NUDI16InitIfLoaded();
}

%ctor {
    @autoreleasepool {
        NUApplySandbox();
        if (!NUIsDisplaySide()) return;
        _dyld_register_func_for_add_image(NUDI16ImageAdded);
    }
}
