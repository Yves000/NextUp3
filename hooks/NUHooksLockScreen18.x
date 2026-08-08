// iOS 18 lock-screen now-playing row. The media controls are a remote MediaRemoteUI
// Live Activity of fixed height, so we render our row SpringBoard-side by growing the
// ACUISActivityHostViewController's platter. MUST stay iOS-18-gated: the same host
// architecture exists on iOS 17, but there the remote scene draws the row itself.
#import "NUHooksShared.h"

// On iPad iOS 18 the lock-screen now-playing card is a Live Activity: the media
// controls are drawn by a remote com.apple.MediaRemoteUI scene (MRULockscreenView),
// hosted by SpringBoard's ACUISActivityHostViewController inside a PLPlatterView. The
// remote scene is fixed at its natural height and can't be grown from our side, BUT
// the SpringBoard-side host's -preferredContentSize DOES size the platter (verified:
// +N grows PLPlatterView/CSActivityItemContentView by N, leaving an empty strip below
// the 167pt remote content). So we render our row entirely in SpringBoard: grow the
// host by the row height and drop NUNextUpRowView into the reclaimed bottom strip.
// Gated to the now-playing media activity via the descriptor's target bundle id, so
// other Live Activities (timers, etc.) are untouched.

@interface ACActivityDescriptor : NSObject
- (NSString *)platterTargetBundleIdentifier;
@end
@interface ACUISActivitySceneDescriptor : NSObject
- (ACActivityDescriptor *)activityDescriptor;
@end
@interface ACUISActivityHostViewController : UIViewController
@property (nonatomic, strong) NUNextUpRowView *nu_row;
- (void)nu_lsEnsureRow;
- (void)nu_lsRegister;
- (void)nu_lsChanged;
- (void)nu_lsLayout;
- (BOOL)nu_lsShouldShow;
@end

// This host = the Apple Music now-playing LA (not a timer / other activity)?
static BOOL NUIsNowPlayingActivityHost(UIViewController *vc) {
    @try {
        id sceneDesc = [vc valueForKey:@"_activitySceneDescriptor"];
        ACActivityDescriptor *ad = [sceneDesc activityDescriptor];
        return [[ad platterTargetBundleIdentifier] isEqualToString:@"com.apple.MediaRemoteUI"];
    } @catch (__unused NSException *e) { return NO; }
}

// The media-suggestions gate for THIS surface only. Everywhere else the row and the player
// share a process, so the gate just reads the player view's -showSuggestionsView directly
// (NUViewShowsSuggestions). Here the player is the remote MediaRemoteUI scene and the row is
// ours in SpringBoard, so the state crosses the boundary on a Darwin token: the MediaRemoteUI
// side publishes it from -[MRULockscreenView setShowSuggestionsView:] (NUSuggest18 below).
//
// SpringBoard gets no local signal when that flips, so watch the token once per process and
// re-broadcast it as the change notification every row host already observes — the same
// re-broadcast trick NUNextUpManager uses for prefs changes. That re-runs nu_lsChanged (and
// the parent's re-measure) at once, instead of waiting for an unrelated layout pass.
static void NUWatchSuggestingFlag(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        static int token;
        notify_register_dispatch(kNUSuggestNotify, &token, dispatch_get_main_queue(), ^(int t) {
            NULog("LS18: suggestions flag -> %llu — re-running row gate", NUSuggestingGet());
            [[NSNotificationCenter defaultCenter] postNotificationName:NUNextUpDidChangeNotification
                                                                object:nil];
        });
    });
}

%group NULockScreen18

%hook ACUISActivityHostViewController
%property (nonatomic, strong) NUNextUpRowView *nu_row;

- (void)viewDidLoad {
    %orig;
    if (!NUIsNowPlayingActivityHost(self)) return;
    [[NUNextUpManager sharedManager] start];
    [self nu_lsEnsureRow];
    [self nu_lsRegister];
}

// Only the media LA reports a grown size; the getter override is what actually
// sizes the platter (verified lever). Guard on a live next track so the card only
// grows when there's something to show.
- (CGSize)preferredContentSize {
    CGSize s = %orig;
    if (s.height > 0 && [self nu_lsShouldShow]) s.height += [NUNextUpRowView preferredHeight];
    return s;
}

- (void)viewDidLayoutSubviews {
    %orig;
    if (!NUIsNowPlayingActivityHost(self)) return;
    [self nu_lsEnsureRow];
    [self nu_lsLayout];
}

%new
- (BOOL)nu_lsShouldShow {
    return NUIsNowPlayingActivityHost(self) && NUNextUpManager.sharedManager.active
        && NUInterfaceEnabled(NUHostLockScreen)
        && !NUSuggestingGet()   // remote scene swapped in iOS's own media suggestions
        && self.isViewLoaded && self.nu_row.hasContent;
}

%new
- (void)nu_lsEnsureRow {
    if (self.nu_row) return;
    NUNextUpRowView *row = [[NUNextUpRowView alloc] initWithFrame:CGRectZero];
    row.hidden = YES;
    self.nu_row = row;
    [self.view addSubview:row];
    // The row can be created from -viewDidLayoutSubviews too (when the activity
    // scene descriptor wasn't wired yet at -viewDidLoad, so its register call was
    // skipped). Register here as well — idempotent (remove-then-add), and without
    // it this host never hears NUNextUpDidChangeNotification: the row goes stale
    // and the platter never grows when a next track appears.
    [self nu_lsRegister];
    NULog("LS18 row attached proc=%{public}@ view=%@ bounds=%@",
          NSProcessInfo.processInfo.processName, NSStringFromClass(self.view.class),
          NSStringFromCGRect(self.view.bounds));
}

%new
- (void)nu_lsRegister {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:NUNextUpDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(nu_lsChanged)
                                                 name:NUNextUpDidChangeNotification
                                               object:nil];
    NUWatchSuggestingFlag();
}

%new
- (void)nu_lsChanged {
    if (![self isViewLoaded]) return;
    [self.nu_row refreshFromManager];
    [self nu_lsLayout];
    // The preferredContentSize getter is overridden, so UIKit doesn't know the value
    // changed — poke the parent to re-measure the platter when the row appears/vanishes.
    UIViewController *p = self.parentViewController;
    if ([p respondsToSelector:@selector(preferredContentSizeDidChangeForChildContentContainer:)])
        [p preferredContentSizeDidChangeForChildContentContainer:self];
    [self.view setNeedsLayout];
}

// Position the row in the bottom strip (the platter is grown by the row height; the
// remote media controls occupy the top, so the row sits below them).
%new
- (void)nu_lsLayout {
    [self.nu_row refreshFromManager];
    BOOL show = [self nu_lsShouldShow];
    self.nu_row.hidden = !show;
    if (!show) return;
    CGRect b = self.view.bounds;
    CGFloat rowH = [NUNextUpRowView preferredHeight];
    self.nu_row.frame = CGRectMake(0, b.size.height - rowH, b.size.width, rowH);
    [self.view bringSubviewToFront:self.nu_row];
}

%end

%end // NULockScreen18

// The publishing half of the gate above, running in the OTHER process (MediaRemoteUI, which
// draws the iOS 18 lock-screen scene). -setShowSuggestionsView: is the player's own edge —
// its -updateVisibility calls it exactly when iOS swaps the transport for the suggestion
// tiles — so it's the cheapest honest place to mirror the state onto the Darwin token.
// MRULockscreenView exists only in MediaRemoteUI, so this group no-ops in SpringBoard
// (nil class), just as NULockScreen18's ACUISActivityHostViewController no-ops here.
%group NUSuggest18
%hook MRULockscreenView

- (void)setShowSuggestionsView:(BOOL)show {
    %orig;
    NUSuggestingSet(show ? 1 : 0);
}

%end
%end // NUSuggest18

%ctor {
    @autoreleasepool {
        NUApplySandbox();
        if (!NUIsDisplaySide()) return;
        if (NUIOSMajor() >= 18) {
            %init(NULockScreen18); %init(NUSuggest18);
            // The suggesting flag persists in notifyd past its publisher: if
            // MediaRemoteUI died while suggestions were up (jetsam, the killall
            // deploy step), a stale 1 would keep suppressing the row after the
            // relaunched scene starts non-suggesting without re-invoking the
            // setter. Clear it when the publisher process comes up; the
            // -setShowSuggestionsView: hook republishes the real state.
            if (!NUIsSpringBoard()) NUSuggestingSet(0);
        }
    }
}
