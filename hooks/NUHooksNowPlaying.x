// Lock-screen + (pre-iOS-18) Control Center now-playing core. One class family
// (MRUNowPlayingViewController / MRUNowPlayingView) drives every iOS version 15–18
// with internal NUIOSMajor() branches, so it stays a single shared file rather than
// being split per version. Host detection + view helpers live in NUHooksShared.h.
#import "NUHooksShared.h"

// What we last pushed into Apple's layout for this VC: the show-state and the width
// it was measured at. Used to skip the forced relayout entirely when the platter
// already reflects reality — see -nu_syncPlatterHeight.
static void * const kNUPushedShowKey  = (void *)&kNUPushedShowKey;
static void * const kNUPushedWidthKey = (void *)&kNUPushedWidthKey;

%group NUNowPlaying
%hook MRUNowPlayingViewController

%property (nonatomic, strong) NUNextUpRowView *nu_row;

- (void)viewDidLoad {
    %orig;
    [[NUNextUpManager sharedManager] start];
    [self nu_ensureRow];
}

// Attach the row into the now-playing view, once, for either host. Idempotent and
// safe to call repeatedly: on the Control Center path the parentViewController
// (used to detect the host) may not be wired yet at -viewDidLoad, so appearance /
// height-sync also retry this.
%new
- (void)nu_ensureRow {
    if (self.nu_row) return;
    NUHostKind host = NUHostKindForVC(self);
    if (host == NUHostNone) return;
    NUNextUpRowView *row = [[NUNextUpRowView alloc] initWithFrame:CGRectZero];
    row.hidden = YES;
    self.nu_row = row;
    if (host == NUHostControlCenter) [row configureForControlCenter];
    [self.view addSubview:row];
    objc_setAssociatedObject(self.view, kNUHostViewKey, @(host), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self nu_registerForChanges];
    NULog("MRU row attached: host=%ld ctx=%lld proc=%{public}@ parent=%{public}@",
          (long)host, self.context, NSProcessInfo.processInfo.processName,
          NSStringFromClass(self.parentViewController.class));
}

// (Re-)subscribe to next-up changes, idempotently. This VC is long-lived: the
// lock screen only disappears it (which unsubscribes), so every appearance must
// subscribe again — nu_ensureRow alone can't, its early-return skips the body
// once the row exists. Without this, a next track that turns up after the
// appear-time re-syncs shows the row (layoutSubviews reads `active` directly)
// but never pushes the grown preferredContentSize: the compact-platter bug.
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
    // The provider (Music) can still be coming up when the platter first measures
    // — especially on the first playback after a respring — so `active` is NO at
    // that point and the platter measures at its original compact height. Re-sync
    // a few times as the provider settles so we reach our grown height without any
    // manual re-render. Each pass is idempotent (only pushes a changed size).
    // The early ticks go through -start (not just the height sync): start
    // re-queries the provider, so a query that answered "inactive" mid queue
    // rebuild (album switch → lock screen opened immediately) is actually retried
    // — the bare height sync only re-measured the stale inactive state and could
    // never recover it within this appearance. Only the first three ticks
    // re-query (each sync round-trip can cost up to LIGHTMESSAGING_TIMEOUT on a
    // suspended provider); the provider's own inactive-answer re-poll covers the
    // tail and signals a change, which re-queries anyway.
    if (!NUMasterEnabled()) return;   // disabled: nothing to settle, schedule nothing
    // Logos passes `self` as __unsafe_unretained, so the tick blocks must not capture
    // it raw: the VC can be torn down within the tick window (screen wakes and locks
    // again immediately), and the unretained send then hits freed memory — the
    // objc_msgSend PAC-failure crash loop in MediaRemoteUI. Weak-capture instead;
    // a tick that outlives the VC becomes a no-op.
    __weak MRUNowPlayingViewController *weakSelf = self;
    for (NSNumber *delay in @[ @0.1, @0.3, @0.6, @1.0, @1.5 ]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (delay.doubleValue < 0.7) [[NUNextUpManager sharedManager] start];
            [weakSelf nu_syncPlatterHeight];
        });
    }
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    [[NSNotificationCenter defaultCenter] removeObserver:self name:NUNextUpDidChangeNotification object:nil];
}

%new
- (BOOL)nu_shouldShowRow {
    if (!NUNextUpManager.sharedManager.active || !self.isViewLoaded) return NO;
    NUHostKind host = NUHostKindForVC(self);
    if (host == NUHostNone || !NUInterfaceEnabled(host)) return NO;
    // iOS swapped the transport for its own media suggestions / "Not Playing" box — the
    // player isn't showing our provider's session, so the row has nothing to sit under.
    if (NUViewShowsSuggestions(self.view)) return NO;
    // Control Center only shows the row once the card is expanded (flag stamped on
    // the view by -didTransitionToExpandedContentMode:); collapsed keeps it hidden.
    // Also hide while the route picker is opening/up (see -presentViewController: below).
    if (host == NUHostControlCenter) return NUViewCCExpanded(self.view) && !NUCCRoutingOpen(self.view);
    return YES;
}

// Content changed: refresh labels and re-sync the platter height.
%new
- (void)nu_changed {
    [self nu_syncPlatterHeight];
}

// Re-derive the platter height and push it across the process boundary.
// On iOS 16/17 the lock-screen now-playing UI is an ActivityUIServices scene
// rendered by this process (MediaRemoteUI) and composited by SpringBoard's
// CoverSheet into a PLPlatterView (verified live on 17.0: the scene root is
// MediaRemoteUI.CoverSheetPlatterViewController, an MRUCoverSheetViewController
// subclass, in a MediaRemoteUI.SecureWindow). SpringBoard sizes the platter from
// the SCENE's client content size — a purely local relayout, or even setting
// preferredContentSize on this VC chain, never reaches it. So we recompute the
// fitting size (our -sizeThatFits: hook adds the row height when active), publish
// it, and then make the scene root re-derive + push it to SpringBoard (see
// nu_invalidateLockScreenHeight). Without that last step the host only ever sees
// the size once, at scene creation — the historical grow-only/stuck-platter bug.
%new
- (void)nu_syncPlatterHeight {
    if (![self isViewLoaded]) return;
    [self nu_ensureRow];
    [self.nu_row refreshFromManager];
    BOOL show = [self nu_shouldShowRow];
    self.nu_row.hidden = !show;

    // Only touch Apple's media-controls layout when the platter does not already
    // reflect `show` (or the width changed). Everything below — invalidate,
    // whole-chain setNeedsLayout, SYNCHRONOUS layoutIfNeeded, sizeThatFits: — forces
    // Apple's in-process media UI to re-lay-out, and on iOS 14/15 that UI lives in
    // SpringBoard and re-queries mediaserverd for routes/properties as it does. This
    // used to run unconditionally, five times per appearance (the settle ticks) plus
    // on every change signal, even with nothing to show: a steady stream of
    // remoteSystemController_* RPCs — exactly the calls whose fig timeout gets
    // mediaserverd killed on the 14.2 test device, which stops playback.
    // Row content changes need none of this: the row's height is constant, so only a
    // show/hide flip (or a width change) can change the platter's size.
    NSNumber *pushedShow = objc_getAssociatedObject(self, kNUPushedShowKey);
    CGFloat curW = self.view.bounds.size.width;
    CGFloat pushedW = [objc_getAssociatedObject(self, kNUPushedWidthKey) doubleValue];
    BOOL needSync = (pushedShow == nil) ? show
                                        : (pushedShow.boolValue != show || fabs(pushedW - curW) > 0.5);
    if (!needSync) return;
    objc_setAssociatedObject(self, kNUPushedShowKey, @(show), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, kNUPushedWidthKey, @(curW), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // Control Center sizes the card via -preferredExpandedContentHeight (hooked on
    // MRUControlCenterViewController), not preferredContentSize. Branch BEFORE the
    // synchronous whole-chain layoutIfNeeded below: on 14.2 the CC now-playing is hosted
    // in-process in SpringBoard, so that synchronous relayout cascades through the entire
    // CC hierarchy and, when it lands mid-dismiss (the row hides → layout flip →
    // nu_syncPlatterHeight), flashes the whole screen. A deferred setNeedsLayout is
    // enough — the card height comes from -preferredExpandedContentHeight and the row
    // hide/show happens in the view-level layoutSubviews. (Harmless on 16/17, where the
    // CC now-playing is a remote view so the synchronous pass never flashed anyway.)
    if (NUHostKindForVC(self) == NUHostControlCenter) {
        [self.view setNeedsLayout];
        [self nu_invalidateControlCenterHeight];
        return;
    }

    [self.view invalidateIntrinsicContentSize];
    for (UIView *v = self.view; v; v = v.superview) [v setNeedsLayout];
    [self.view layoutIfNeeded];

    CGFloat w = self.view.bounds.size.width;
    if (w <= 0) return;
    CGSize fit = [self.view sizeThatFits:CGSizeMake(w, CGFLOAT_MAX)];
    if (fit.height <= 0) return;
    if (!CGSizeEqualToSize(self.preferredContentSize, fit)) {
        NULog("MRU: preferredContentSize %.0f -> %.0f (active=%d)",
              self.preferredContentSize.height, fit.height, NUNextUpManager.sharedManager.active);
        self.preferredContentSize = fit;
    }
    // iOS 15: the lock-screen platter is hosted in-process and ignores our
    // preferredContentSize; make CSMediaControlsViewController re-query its
    // -_preferredMediaRemoteHeight (which we grow) so the card actually resizes.
    [self nu_invalidateLockScreenHeight];
}

// Walk up to whatever hosts the lock-screen platter and force it to recompute the
// platter height, so the height tracks `active` in BOTH directions.
%new
- (void)nu_invalidateLockScreenHeight {
    // iOS 16/17 (and the iOS 18 embedded-child case): the MRUCoverSheetViewController
    // ancestor is the scene-root VC whose -updatePreferredContentSize is Apple's own
    // "re-derive my size and tell my host" entry point. On 17.0 (verified live) it
    // re-reads preferredContentSize (which flows from our sizeThatFits: growth) and
    // hands it to the scene delegate (-coverSheetViewController:
    // didUpdatePreferredContentSize:) → FBS scene settings → SpringBoard's
    // ACUISActivityHostViewController/CSActivityItemViewController chain resizes the
    // PLPlatterView — grow AND shrink (239.7 ↔ 167 observed). Unlike
    // -updateContentAnimated: it does not recurse into a content update (no
    // MediaRemoteUI crash loop) and does not toggle the artwork mode.
    // Gated to iOS 16+ so the iOS 15 in-process CSMediaControls path below keeps the
    // exact behavior that was verified on-device there.
    if (NUIOSMajor() >= 16) {
        UIViewController *csheet = NUCoverSheetAncestor(self);
        if (csheet && [csheet respondsToSelector:@selector(updatePreferredContentSize)]) {
            [csheet performSelector:@selector(updatePreferredContentSize)];
            [csheet.viewIfLoaded setNeedsLayout];
            return;
        }
    }
    Class CS = objc_getClass("CSMediaControlsViewController");
    if (!CS) return;
    UIViewController *vc = self;
    while (vc && ![vc isKindOfClass:CS]) vc = vc.parentViewController;
    if (!vc) return;
    if ([vc respondsToSelector:@selector(_updatePreferredContentSize)]) {
        [vc performSelector:@selector(_updatePreferredContentSize)];   // iOS 15
    } else {
        // iOS 14.2: no -_updatePreferredContentSize. The lock-screen platter height is an
        // NSContentSizeLayoutConstraint on the CoverSheet's CSAdjunctItemView, derived from
        // the media controls' content height and *latched when the adjunct is first inserted*
        // (active=YES at track start, so it grows — then never shrinks). Verified live on
        // 14.2 (Frida): preferredContentSize changes, view reframes, and every UIKit
        // child-container callback (preferredContentSizeDidChangeForChildContentContainer:,
        // _layoutMediaControls alone, setNeedsLayout) leave the platter latched — the height
        // constraint is only regenerated by -invalidateIntrinsicContentSize on the view that
        // owns it. So: re-lay the media controls to the active-dependent suggested frame (our
        // NULockScreen14 hook adds the row height only when active), then invalidate the
        // intrinsic size of the adjunct item view (constraint owner) and the platter so UIKit
        // rebuilds the constraint from the fresh content height. Tracks `active` in BOTH
        // directions (grow <-> shrink, 282 <-> 152 observed).
        if ([vc respondsToSelector:@selector(_layoutMediaControls)])
            [vc performSelector:@selector(_layoutMediaControls)];
        Class AdjItem = objc_getClass("CSAdjunctItemView");
        Class Platter = objc_getClass("PLPlatterView");
        UIView *adjItem = nil, *platter = nil;
        for (UIView *v = self.view; v; v = v.superview) {
            if (!platter && Platter && [v isKindOfClass:Platter]) platter = v;
            if (AdjItem && [v isKindOfClass:AdjItem]) { adjItem = v; break; }
        }
        [platter invalidateIntrinsicContentSize];
        [adjItem invalidateIntrinsicContentSize];
        for (UIView *v = platter ?: self.view; v; v = v.superview) [v setNeedsLayout];
        [(platter ?: self.view).window layoutIfNeeded];
    }
    [vc.view setNeedsLayout];
}

// Control Center queries -preferredExpandedContentHeight on the expand transition,
// so the grown height applies whenever the card is opened with a track already
// up-next (the common case). Forcing a re-query while the card is already open has
// no clean public entry point in the CCUI headers; a local relayout is the safe
// best-effort. (Dynamic mid-view growth is a documented follow-up.)
%new
- (void)nu_invalidateControlCenterHeight {
    [NUControlCenterAncestor(self).view setNeedsLayout];
}

%end

%hook MRUNowPlayingView

// Grow the reported size so the platter becomes taller by our row height. This
// is the reliable growth lever (independent of the layout clamp below).
- (CGSize)sizeThatFits:(CGSize)size {
    CGSize r = %orig;
    if (NUViewGrowsFit(self)) r.height += NURowHeightForView(self);
    return r;
}

// During our own layout pass, report the COMPACT height (real minus our row) so
// %orig lays the player's controls out exactly as it would without us — original
// spacing, top-anchored — instead of stretching the top gap and bottom-anchoring
// the transport onto our strip. sizeThatFits (above) does NOT set the flag, so
// the platter still measures at the full grown height.
- (CGRect)bounds {
    CGRect b = %orig;
    if (objc_getAssociatedObject(self, kNULayoutClampKey)) {
        b.size.height -= NURowHeightForView(self);
    }
    return b;
}

- (void)layoutSubviews {
    // iOS 15: remember the PLPlatterView that encloses this in-process now-playing
    // view, so the lock-screen paging blocker targets the media card (not one of the
    // other, smaller CoverSheet platters). No-op on 16/17 (this view is remote there).
    if ([NSStringFromClass(self.window.class) containsString:@"CoverSheet"]) {
        Class PL = objc_getClass("PLPlatterView");
        for (UIView *a = self; a; a = a.superview)
            if (PL && [a isKindOfClass:PL]) { gLSMediaPlatter = a; break; }
    }
    BOOL show = NUViewShowsRow(self);

    // Keep the platter height locked to the row's visibility. The row hides/shows
    // here on every layout (immediately reflecting `active` / the Apple-Music source
    // gate), but the platter height is pushed separately by -nu_syncPlatterHeight —
    // so a source/track change could leave the two out of sync for a beat (grown
    // platter with no row, or a row on a compact platter). Whenever the show-state
    // flips, re-sync the height in the next tick (deferred to avoid recursing inside
    // this layout pass) so height always follows the row.
    NSNumber *lastShow = objc_getAssociatedObject(self, kNUShowStateKey);
    if (!lastShow || lastShow.boolValue != show) {
        objc_setAssociatedObject(self, kNUShowStateKey, @(show), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        UIResponder *r = self.nextResponder;
        while (r && ![r isKindOfClass:objc_getClass("MRUNowPlayingViewController")]) r = r.nextResponder;
        MRUNowPlayingViewController *npVC = (MRUNowPlayingViewController *)r;
        if (npVC) dispatch_async(dispatch_get_main_queue(), ^{ [npVC nu_syncPlatterHeight]; });
    }

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

    // In Control Center the card has a large (40pt) continuous corner; round the
    // artwork concentric to it (card radius minus the artwork's inset). The lock
    // screen keeps the default artwork radius.
    if (NUViewHostKind(self) == NUHostControlCenter) {
        [row applyConcentricArtworkForCardCornerRadius:self.layer.cornerRadius];
    }
}

%end

%end // NUNowPlaying

%ctor {
    @autoreleasepool {
        NUApplySandbox();
        if (!NUIsDisplaySide()) return;
        // The cross-process touch flag survives its setter in notifyd: if this
        // process died mid-touch it is still raised on relaunch, and SpringBoard
        // would keep failing the Dynamic Island's own gestures (the timestamp in
        // NUDITouchGet is the backstop; this clears it deterministically).
        NUDITouchSet(0);
        %init(NUNowPlaying);
    }
}
