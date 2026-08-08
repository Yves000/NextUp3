// iOS 15 lock-screen platter growth (in-process CoverSheet host).
//
// On iOS 15 the now-playing card lives inside the CoverSheet notification list as
// an adjunct item, hosted in-process by SpringBoard's CSMediaControlsViewController
// (not a remote MediaRemoteUI view as on 16/17). That controller sizes the platter
// from -_preferredMediaRemoteHeight, so grow that by our row height when there's a
// live next track. Gated to iOS 15 in %ctor so the 16/17 remote path is untouched.
#import "NUHooksShared.h"

%group NULockScreen15

%hook CSMediaControlsViewController
- (double)_preferredMediaRemoteHeight {
    double h = %orig;
    // In-process iOS 15 lock screen: the only surface here is the lock screen.
    // The suggestions scan must mirror the row's own gate (NUViewShowsRow), or the platter
    // grows while the row stays hidden under Apple's suggestion tiles. This host holds no
    // pointer to the nested player view, hence the subtree scan; not found → grow, as before.
    if (NUNextUpManager.sharedManager.active && NUInterfaceEnabled(NUHostLockScreen)
        && !NUSubtreeShowsSuggestions(self.viewIfLoaded))
        h += [NUNextUpRowView preferredHeight];
    return h;
}
%end

%end // NULockScreen15

%ctor {
    @autoreleasepool {
        NUApplySandbox();
        if (!NUIsSpringBoard()) return;
        if (NUIOSMajor() == 15 && objc_getClass("CSMediaControlsViewController"))
            %init(NULockScreen15);
    }
}
