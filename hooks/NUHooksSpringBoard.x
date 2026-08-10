// SpringBoard gesture blockers: stop lock-screen paging over the now-playing
// platter, and fail the Dynamic Island resize/dismiss gesture while our row is
// being swiped. gLSMediaPlatter (set by the iOS 15 now-playing view hook) is read
// here; it is declared extern in NUHooksShared.h.
#import "NUHooksShared.h"

// The lock-screen camera/widgets paging is a SYSTEM gesture
// (UIScrollViewPagingSwipeGestureRecognizer on a UISystemGestureView), running
// in SpringBoard beneath the platter. It preempts and cancels our in-window
// swipe (verified live via Frida). Apple's own player area blocks it the same
// way we do here: make that system gesture fail when the touch is over the
// now-playing platter (PLPlatterView in the SBCoverSheetWindow), which contains
// our row. Everything else (home-screen paging, etc.) is untouched because we
// only act when the gesture's view is a UISystemGestureView.

static UIView *NUFindViewOfClass(UIView *root, Class cls) {
    if (!root || !cls) return nil;
    if ([root isKindOfClass:cls]) return root;
    for (UIView *sub in root.subviews) {
        UIView *r = NUFindViewOfClass(sub, cls);
        if (r) return r;
    }
    return nil;
}

// The lock-screen now-playing platter (PLPlatterView). It's a descendant of the
// CoverSheet pager; fall back to a cached global on-screen search.
static UIView *NULockScreenPlatter(UIView *pager) {
    Class PL = objc_getClass("PLPlatterView");
    if (!PL) return nil;
    // iOS 15: prefer the exact media platter we cached (the CoverSheet tree has
    // several PLPlatterViews; a naive search finds a small header one first).
    UIView *media = gLSMediaPlatter;
    if (media && media.window && !media.isHidden && media.bounds.size.height > 1) return media;
    UIView *p = NUFindViewOfClass(pager, PL);   // descendant of the gesture's own view
    if (p) return p;
    static __weak UIView *cached = nil;
    UIView *c = cached;
    if (c && c.window && !c.isHidden && c.bounds.size.height > 1) return c;
    for (UIWindow *w in UIApplication.sharedApplication.windows) {
        if (w.isHidden || w.alpha < 0.01) continue;
        UIView *q = NUFindViewOfClass(w, PL);
        if (q && q.window && !q.isHidden && q.bounds.size.height > 1) { cached = q; return q; }
    }
    return nil;
}

// YES when one of the gesture's touches is over the now-playing platter's ROW
// strip. We no longer scope to a specific scroll-view class: whatever
// scroll/paging gesture tries to claim a touch there (and would otherwise cancel
// our swipe) is made to fail. Cheap CoverSheet-window scope keeps this off the
// home screen and other scroll views; the platter only exists on the lock screen
// anyway. Two deliberate limits keep this from stealing gestures that aren't
// ours to steal:
//  - Pref gate: with the tweak (or the lock-screen surface) off there is no row,
//    so nothing may be blocked. Prefs only — NUNextUpManager.active is NOT
//    trustworthy here: on iOS 16/17 the row lives in the remote MediaRemoteUI
//    scene and SpringBoard's manager instance is never started.
//  - Strip hit-test: only the bottom band the row occupies (+ a small grace
//    above), not the whole platter — a vertical notification-list scroll that
//    starts on the upper platter (artwork/transport) must keep working.
static BOOL NUShouldBlockPaging(UIGestureRecognizer *gr, NSSet<UITouch *> *touches) {
    if (!NUMasterEnabled() || !NUInterfaceEnabled(NUHostLockScreen)) return NO;
    UIView *v = gr.view;
    if (!v) return NO;
    UIWindow *win = v.window;
    if (!win || ![NSStringFromClass(win.class) containsString:@"CoverSheet"]) return NO;
    UIView *platter = NULockScreenPlatter(v);
    if (!platter) return NO;
    CGFloat rowH = [NUNextUpRowView preferredHeight] + 12.0; // grace band above the separator
    CGRect strip = platter.bounds;
    strip.origin.y = MAX(0.0, strip.size.height - rowH);
    strip.size.height = MIN(rowH, strip.size.height);
    for (UITouch *t in touches) {
        if (CGRectContainsPoint(strip, [t locationInView:platter])) return YES;
    }
    return NO;
}

@interface UIScrollViewPanGestureRecognizer : UIGestureRecognizer @end
@interface UIScrollViewPagingSwipeGestureRecognizer : UIGestureRecognizer @end

// The Dynamic Island's resize/dismiss gesture (SBSystemApertureResizeGestureRecognizer
// + the long-press, on a window-level UISystemGestureView) preempts our row's swipe
// carousel the same way lock-screen paging did — the DI reads the drag as a
// dismiss/move. The aperture content is scaled/transformed, so geometry-based
// hit-testing of our row is unreliable; instead our row (in MediaRemoteUI) raises a
// cross-process flag while it is being touched, and we fail the island's gesture
// whenever that flag is set. See kNUDITouchNotify.
static BOOL NUShouldBlockApertureSwipe(void) {
    return NUDITouchGet() != 0;
}

@interface SBSystemApertureResizeGestureRecognizer : UIGestureRecognizer @end
@interface SBSystemApertureLongPressGestureRecognizer : UIGestureRecognizer @end

%group SpringBoard

%hook UIScrollViewPagingSwipeGestureRecognizer
- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    if (NUShouldBlockPaging(self, touches)) { self.state = UIGestureRecognizerStateFailed; return; }
    %orig;
}
%end

%hook UIScrollViewPanGestureRecognizer
- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    if (NUShouldBlockPaging(self, touches)) { self.state = UIGestureRecognizerStateFailed; return; }
    %orig;
}
%end

%hook SBSystemApertureResizeGestureRecognizer
- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    if (NUShouldBlockApertureSwipe()) { self.state = UIGestureRecognizerStateFailed; return; }
    %orig;
}
- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event {
    if (NUShouldBlockApertureSwipe()) { self.state = UIGestureRecognizerStateFailed; return; }
    %orig;
}
%end

// The long-press that opens the DI can keep tracking into a drag; fail it too while
// our row is being touched so the continued drag doesn't dismiss/move the island.
// (It only matters once expanded — the flag is only set when our row exists.)
%hook SBSystemApertureLongPressGestureRecognizer
- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event {
    if (NUShouldBlockApertureSwipe()) { self.state = UIGestureRecognizerStateFailed; return; }
    %orig;
}
%end

%end // SpringBoard

%ctor {
    @autoreleasepool {
        NUApplySandbox();
        if (!NUIsSpringBoard()) return;
        // Re-seed the live toggle word from the persisted prefs. notify_state is not
        // durable storage: notifyd discards a name's state once the last process
        // registered for it exits, and a respring tears down every injected process
        // that held "com.yves.nextup3.state" at once — so the published state (a
        // disabled master switch included) is gone by the time the tweak reloads, and
        // NUPrefBool would fall back to the fail-open default. SpringBoard relaunches on
        // every respring and can read the prefs domain, so it republishes the token here;
        // being system-global, that one seed restores the state for every reader process.
        NUPrefsPublishState();
        %init(SpringBoard);
    }
}
