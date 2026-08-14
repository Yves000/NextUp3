// Pre-iOS-18 Control Center now-playing card (SpringBoard process). Sizes the
// expanded card via MRUControlCenterViewController.preferredExpandedContentHeight,
// hosting the shared MRUNowPlayingViewController. iOS 18 uses NUHooksControlCenter18.
#import "NUHooksShared.h"

// The nested now-playing VC this card hosts, or nil. iOS 16/17 expose it as
// -nowPlayingViewController, iOS 15 as -selectedViewController; both are guarded so
// neither version hard-depends on the other's accessor.
static MRUNowPlayingViewController *NUCCNestedNowPlayingVC(MRUControlCenterViewController *cc) {
    MRUNowPlayingViewController *np = nil;
    if ([cc respondsToSelector:@selector(nowPlayingViewController)])
        np = cc.nowPlayingViewController;
    if (!np && [cc respondsToSelector:@selector(selectedViewController)])
        np = cc.selectedViewController;
    return [np isKindOfClass:objc_getClass("MRUNowPlayingViewController")] ? np : nil;
}

// Force the nested now-playing row hidden (routing up) or restored (routing gone),
// via the shared route key that NUViewShowsRow / nu_shouldShowRow honour.
static void NUCCSetRouting(MRUControlCenterViewController *cc, BOOL routing) {
    MRUNowPlayingViewController *np = NUCCNestedNowPlayingVC(cc);
    if (![np isViewLoaded]) return;
    objc_setAssociatedObject(np.view, kNURouteOpeningKey, routing ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [np.nu_row refreshFromManager];
    [np.view setNeedsLayout];
}

%group NUCCLegacy
// Control Center's now-playing card (SpringBoard process). The card height comes
// from this CCUI content-module hook, so grow it by our row height when there's a
// live next track — the lock-screen preferredContentSize path doesn't apply here.
%hook MRUControlCenterViewController

- (double)preferredExpandedContentHeight {
    double h = %orig;
    // The suggestions check must mirror the row's own gate (NUViewShowsRow /
    // nu_shouldShowRow): while iOS shows its media suggestions the row stays hidden, so
    // growing the card here too would leave a dead strip under the tiles. nil view →
    // "not suggesting" → grow, i.e. unchanged behaviour.
    if (NUNextUpManager.sharedManager.active && NUInterfaceEnabled(NUHostControlCenter)
        && !NUViewShowsSuggestions(NUCCNestedNowPlayingVC(self).viewIfLoaded)) {
        h += [NUNextUpRowView preferredHeightForControlCenter];
        // Earliest expand signal: CCUI queries this (repeatedly) at the START of the
        // expand transition — and only while expanding, never while sitting collapsed
        // (confirmed on-device via oslog). Reveal the row here so it appears as the
        // card grows, instead of popping in later at -didTransitionToExpandedContentMode:.
        [self nu_applyCCExpanded:YES];
    }
    return h;
}

// Early COLLAPSE backstop: fires at the START of a size change (both ways),
// unlike -didTransitionToExpandedContentMode: which only lands at the END. On
// collapse the module starts shrinking with our row still shown, flashing it on the
// small preview for a few frames — so hide it the instant the view begins shrinking.
// (Expand is already handled early by -preferredExpandedContentHeight; the PRIMARY
// early collapse signal is the CCUI will-transition callback added in the %ctor —
// a dismissal that tears the expanded presentation down without resizing this VC's
// view, as iOS 14.2's in-process hosting does, never reaches this hook.)
- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id)coordinator {
    %orig;
    CGFloat cur = self.viewIfLoaded.bounds.size.height;
    CGFloat curW = self.viewIfLoaded.bounds.size.width;
    // A rotation reshapes BOTH axes; the expand/collapse transition changes the
    // height at constant width. Don't misread portrait→landscape (height drops,
    // width grows) with the expanded card open as a collapse — the card is still
    // expanded and the row would vanish mid-rotation, only coming back if CCUI
    // happened to re-query the expanded height.
    if (cur > 1.0 && fabs(size.width - curW) < 0.5) [self nu_applyCCExpanded:(size.height >= cur)];
}

// Authoritative collapsed ⇄ expanded signal — the final backstop at the END of the
// transition (both the early height query and viewWillTransitionToSize precede it).
- (void)didTransitionToExpandedContentMode:(BOOL)expanded {
    %orig;
    [self nu_applyCCExpanded:expanded];
}

// Stamp the expanded state on the nested now-playing view (read by the view-level
// layout hooks and nu_shouldShowRow) and flip the row's visibility — only when it
// actually changes, so the repeated height queries don't thrash layout. Robust
// across iOS 16/17: guarded selector/class checks, no hard dependency on the accessor.
//
// This must stay LIGHTWEIGHT: it runs mid-transition (on the collapse this is the
// only early signal). It only marks the now-playing view for a DEFERRED layout —
// never invalidateIntrinsicContentSize / whole-chain setNeedsLayout / layoutIfNeeded
// (as nu_syncPlatterHeight does): forcing a synchronous relayout of the CC hierarchy
// during the animation flashes the whole screen. CCUI drives the card height via
// -preferredExpandedContentHeight; the row only needs to hide/show + reposition.
%new
- (void)nu_applyCCExpanded:(BOOL)expanded {
    MRUNowPlayingViewController *np = NUCCNestedNowPlayingVC(self);
    if (![np isViewLoaded]) return;
    if (NUViewCCExpanded(np.view) == expanded) return; // no actual change
    NUSetViewCCExpanded(np.view, expanded);
    [np.nu_row refreshFromManager];
    [np.view setNeedsLayout]; // deferred — the view-level layoutSubviews hides/shows the row
}

// The AirPlay route picker ("Control Other Speakers & TVs") is entered via -setState: (routing =
// state 2, verified live on iOS 17 — arg encoding q/NSInteger), NOT the expand/collapse signals
// hooked above. Without this the nested now-playing view keeps laying out as "expanded" and our row
// flashes over the routing transition. Force it hidden while routing is up via the shared route key
// (NUViewShowsRow / nu_shouldShowRow honour it); any other state clears it, so returning to the
// expanded card shows the row again (its NUViewCCExpanded stamp is untouched here). On iOS 16 this
// state signal doesn't land — the -[MRURoutingViewController setOnScreen:] hook below drives it there.
- (void)setState:(NSInteger)state {
    %orig;
    // Where the routing list ships as MRURoutingViewController, its -setOnScreen: hook below is
    // the authoritative signal — and there the routing -setState: value is NOT 2 (seen on iOS 16),
    // so writing here would clear the key -setOnScreen: just set and flash the row back over the
    // list. Defer to -setOnScreen: whenever that class exists; -setState: only governs versions
    // without it (the row can't have two writers racing on one key).
    if (objc_getClass("MRURoutingViewController")) return;
    NUCCSetRouting(self, state == 2);
}

%end

// The routing list's own on-screen lifecycle, and the authoritative routing signal
// wherever this class exists: -setOnScreen: is toggled as the list slides in and out.
// onScreen → hide our row so it doesn't sit under the list; off → restore it.
%hook MRURoutingViewController

- (void)setOnScreen:(BOOL)onScreen {
    %orig;
    NUCCSetRouting((MRUControlCenterViewController *)NUControlCenterAncestor(self), onScreen);
}

%end

%end // NUCCLegacy

// Earliest transition signal, BOTH directions: CCUI's container calls the OPTIONAL
// CCUIContentModuleContentViewController method -willTransitionToExpandedContentMode:
// at the START of the expand/collapse transition — but only on modules that respond
// (Apple's CCUIButtonModule/CCUIMenuModule VCs implement it; MRUControlCenterViewController
// does NOT on any supported version, verified in the 15/16/17 runtime headers). So the
// method is ADDED (class_addMethod, not %hook — there is no original to call), making
// the module respond and giving us the callback. This fixes two observed bugs:
//  - iOS 17: on dismissing the expanded card, the row stayed visible through the
//    shrink animation (the only collapse signal was the END-of-transition
//    -didTransitionToExpandedContentMode:). Now it hides at the dismiss tap.
//  - iOS 14.2: dismissing the expanded card left the row PERMANENTLY on the small
//    tile — the in-process dismissal neither resized this VC's view (no
//    viewWillTransitionToSize:) nor delivered didTransition… (the 14.2 class doesn't
//    implement it, so CCUI's respondsToSelector: check skipped the call). The added
//    method is exactly what makes CCUI deliver the signal there.
// The existing hooks stay as backstops; nu_applyCCExpanded: is idempotent.
static void NUCCWillTransitionToExpandedContentMode(MRUControlCenterViewController *self, SEL _cmd, BOOL expanded) {
    [self nu_applyCCExpanded:expanded];
}

%ctor {
    @autoreleasepool {
        NUApplySandbox();
        if (!NUIsDisplaySide()) return;
        %init(NUCCLegacy);
        Class cc = objc_getClass("MRUControlCenterViewController");
        if (cc && ![cc instancesRespondToSelector:@selector(willTransitionToExpandedContentMode:)]) {
            class_addMethod(cc, @selector(willTransitionToExpandedContentMode:),
                            (IMP)NUCCWillTransitionToExpandedContentMode, "v@:B");
        }
    }
}
