// iOS 14 lock-screen platter growth (older in-process CoverSheet host).
//
// iOS 14.2's CSMediaControlsViewController has no -_preferredMediaRemoteHeight (that
// arrived with iOS 15). Confirmed live on-device (Frida): the in-process MRUNowPlayingView
// is framed from -_suggestedFrameForMediaControls, and the enclosing PLPlatterView height
// follows -preferredContentSize which itself derives from that same rect. So the single
// growth lever is -_suggestedFrameForMediaControls (hook below); -_layoutMediaControls
// re-reads it, so poking a relayout resizes the card (see nu_invalidateLockScreenHeight).
#import "NUHooksShared.h"

%group NULockScreen14

%hook CSMediaControlsViewController
// The single 14.2 growth lever. -_suggestedFrameForMediaControls frames the in-process
// MRUNowPlayingView, and -preferredContentSize (which drives the enclosing PLPlatterView
// height) derives from it — so growing this one rect grows BOTH the media view and the
// visible platter by the same amount, keeping them equal (confirmed live: platter and
// media view both land at base+row, no dead space). Growing preferredContentSize
// separately double-counts (platter 428 vs media view 355), so we do NOT touch it.
- (CGRect)_suggestedFrameForMediaControls {
    CGRect r = %orig;
    // In-process iOS 14 lock screen: the only surface here is the lock screen.
    // ("suggested frame" is UIKit's naming — unrelated to the media suggestions gated below.)
    // The suggestions scan must mirror the row's own gate (NUViewShowsRow), or this rect
    // grows the media view + platter while the row stays hidden under Apple's suggestion
    // tiles. This host holds no pointer to the nested player view, hence the subtree scan;
    // not found → grow, as before.
    if (NUNextUpManager.sharedManager.active && NUInterfaceEnabled(NUHostLockScreen)
        && !NUSubtreeShowsSuggestions(self.viewIfLoaded))
        r.size.height += [NUNextUpRowView preferredHeight];
    return r;
}
%end

%end // NULockScreen14

%ctor {
    @autoreleasepool {
        NUApplySandbox();
        if (!NUIsSpringBoard()) return;
        if (NUIOSMajor() < 15 && objc_getClass("CSMediaControlsViewController"))
            %init(NULockScreen14);
    }
}
