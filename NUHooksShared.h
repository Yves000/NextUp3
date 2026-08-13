// Shared building blocks for the NextUp 3 hook translation units.
//
// The hooks were split out of a single Tweak.x into one .x per process / iOS
// version (see hooks/). This header carries what more than one of those files
// needs: process/version guards, the now-playing host detection, the view-level
// row helpers, and the associated-object keys.
//
// The keys and gLSMediaPlatter are declared extern here and defined once in
// NUHooksShared.m: several are set in one hook file and read in another (e.g.
// kNUCCExpandedKey is stamped by the Control Center hook and read by the
// now-playing view hook on the SAME view), so every file must see the same
// address — a per-file `static` key would break the association.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "NUShared.h"
#import "NUPrivate.h"
#import "NUPrefs.h"
#import "NUNextUpManager.h"
#import "NUNextUpRowView.h"

#pragma mark - Process / version

static const long long kLockScreenContext = 2; // MRUNowPlayingViewController lock-screen context

// iOS major version. Used only to pick the lock-screen growth lever: on iOS 16+
// the now-playing platter is a remote view grown via preferredContentSize; on
// iOS 15 it is hosted in-process by CSMediaControlsViewController, which sizes the
// platter from -_preferredMediaRemoteHeight instead (see NUHooksLockScreenLegacy).
static inline NSInteger NUIOSMajor(void) {
    static NSInteger v = 0; static dispatch_once_t once;
    dispatch_once(&once, ^{ v = NSProcessInfo.processInfo.operatingSystemVersion.majorVersion; });
    return v;
}

static inline BOOL NUIsMusic(void) {
    return [NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.Music"];
}
static inline BOOL NUIsPodcasts(void) {
    return [NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.podcasts"];
}
static inline BOOL NUIsYouTubeMusic(void) {
    return [NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.google.ios.youtubemusic"];
}
static inline BOOL NUIsYouTube(void) {
    return [NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.google.ios.youtube"];
}
static inline BOOL NUIsSpotify(void) {
    return [NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.spotify.client"];
}
static inline BOOL NUIsSpringBoard(void) {
    return [NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"];
}
// The display side is every renderer process (MediaRemoteUI + SpringBoard); the Music, Podcasts,
// YouTube Music, YouTube and Spotify apps are the data providers, so they are NOT display side.
// Every new provider app MUST be excluded here, or the display hooks initialise inside it too.
static inline BOOL NUIsDisplaySide(void) {
    return !NUIsMusic() && !NUIsPodcasts() && !NUIsYouTubeMusic() && !NUIsYouTube() && !NUIsSpotify();
}

#pragma mark - Shared state (defined in NUHooksShared.m)

// iOS 15 only: the exact PLPlatterView enclosing the in-process now-playing view.
// Set by the MRUNowPlayingView layout hook, read by the SpringBoard paging blocker
// (same process, different file) to target the media card, not a header platter.
extern UIView * __weak gLSMediaPlatter;

// Associated-object keys (unique addresses; shared across files).
extern void * const kNUHostViewKey;    // host kind stamped on the now-playing view
extern void * const kNULayoutClampKey; // report the compact height during our layout pass
extern void * const kNUDIRowShownKey;  // last row-shown state on a DI VC
extern void * const kNUCCExpandedKey;  // Control Center card is in expanded content mode
extern void * const kNUShowStateKey;   // last row-shown state on the now-playing view
extern void * const kNURouteOpeningKey; // iOS 18 CC route picker opening (force-hide row)
extern void * const kNURouteClosingKey; // iOS 18 CC route picker closing (force-show row)

#pragma mark - Now-playing host detection

// Where a now-playing VC is hosted. The lock screen sets context==2; Control
// Center nests the VC under an MRUControlCenterViewController. The CC context int
// is undocumented, so we detect the ancestor VC instead of a magic number. The
// Dynamic Island uses its own class family.
typedef NS_ENUM(NSInteger, NUHostKind) {
    NUHostNone = 0,
    NUHostLockScreen,
    NUHostControlCenter,
    NUHostDynamicIsland,
};

// Per-interface Settings toggle. The three surfaces are gated independently of the
// per-app / master gate (which lives in -[NUNextUpManager isActive]); a surface must
// check BOTH its show predicate and its height-growth lever against this, or the platter
// grows with no row (or vice-versa). NUHostNone is never a real surface → enabled.
static inline BOOL NUInterfaceEnabled(NUHostKind h) {
    switch (h) {
        case NUHostLockScreen:    return NUPrefBool(@"showLockScreen", YES);
        case NUHostControlCenter: return NUPrefBool(@"showControlCenter", YES);
        case NUHostDynamicIsland: return NUPrefBool(@"showDynamicIsland", YES);
        default:                  return YES;
    }
}

static inline UIViewController *NUControlCenterAncestor(UIViewController *vc) {
    Class CC = objc_getClass("MRUControlCenterViewController");
    if (!CC) return nil;
    for (UIViewController *a = vc; a; a = a.parentViewController)
        if ([a isKindOfClass:CC]) return a;
    return nil;
}

// iOS 16 fallback: the lock-screen `context` int isn't guaranteed to be 2 across
// versions, so when the primary signal misses and the VC is not a Control Center
// descendant, treat it as lock-screen if its view is hosted in a CoverSheet /
// Secure window. No-op on iOS 17 (context == 2 already matches); only rescues a
// changed iOS 16 context value. Window may be nil before the view is on screen —
// callers retry on viewWillAppear, by which point it's attached.
static inline BOOL NUVCInLockScreenWindow(UIViewController *vc) {
    UIWindow *win = vc.viewIfLoaded.window;
    if (!win) return NO;
    NSString *cls = NSStringFromClass(win.class);
    return [cls containsString:@"CoverSheet"] || [cls containsString:@"Secure"];
}

// iOS 18: the lock-screen now-playing MRUNowPlayingViewController is embedded as a
// CHILD of MRUCoverSheetViewController (not context-tagged, and its view isn't in a
// window yet at -viewDidLoad — and -viewWillAppear isn't forwarded to this embedded
// child). So detect the lock screen structurally via the parent chain, which is wired
// before the view loads. On iOS 17 the class exists too (the scene-root
// MediaRemoteUI.CoverSheetPlatterViewController is a subclass of it, verified live),
// but there the primary context==2 check already matches first, so this stays an
// iOS 18 detection path — while nu_invalidateLockScreenHeight deliberately reuses
// the ancestor on 17 as the platter re-measure lever.
static inline UIViewController *NUCoverSheetAncestor(UIViewController *vc) {
    Class CS = objc_getClass("MRUCoverSheetViewController");
    if (!CS) return nil;
    for (UIViewController *a = vc; a; a = a.parentViewController)
        if ([a isKindOfClass:CS]) return a;
    return nil;
}

static inline NUHostKind NUHostKindForVC(MRUNowPlayingViewController *vc) {
    if (!vc) return NUHostNone;
    if (vc.context == kLockScreenContext) return NUHostLockScreen;
    if (NUControlCenterAncestor(vc)) return NUHostControlCenter;
    if (NUCoverSheetAncestor(vc)) return NUHostLockScreen;   // iOS 18 lock screen
    if (NUVCInLockScreenWindow(vc)) return NUHostLockScreen;
    return NUHostNone;
}

#pragma mark - Apple's media suggestions

// iOS's own "listening suggestions" state (iOS 14+): with nothing playing, the now-playing
// player drops its transport and shows Apple Music suggestion tiles — or just a bare "Not
// Playing" box. Users toggle it at Settings › Apple Intelligence & Siri › Suggestions ›
// Show Listening Suggestions. In that state the player isn't presenting our provider's
// session at all, so an "up next" row bolted underneath is meaningless: hide it, and don't
// grow the platter to make room for it.
//
// This CANNOT be gated in NUNextUpManager: MediaRemote still reports Music as the
// now-playing app (paused, queue intact), so -isActive is legitimately YES. MediaControls
// decides independently that the session is stale (MRUMediaSuggestionsController tracks
// isPlaying / lastPlayingDate / device-locked) and swaps the content. It is purely a
// display-side state, so it gates host-side, alongside NUInterfaceEnabled.
//
// The signal is -showSuggestionsView: the bool the player's own -updateVisibility sets to
// lay the tiles out. Verified by class-dump on every version we support (14.2 / 15.8 / 16 /
// 17 / 18) for every player view class we attach a row to:
//     MRUNowPlayingView                     14–18   lock screen 14–17, Control Center ≤17
//     MRUMediaControlsModuleNowPlayingView  18      Control Center 18
//     MRULockscreenView                     18      lock screen 18 (MediaRemoteUI side)
// Same selector on all three, hence the duck-typed check instead of a per-class branch — an
// OS missing the selector simply reports "not suggesting", i.e. today's behaviour.
//
// The Dynamic Island players (MRUSessionNowPlaying* on 16, MRUActivityNowPlaying* on 17/18)
// declare NO suggestions API whatsoever — the island only opens for a live session — so the
// DI hooks deliberately carry no such gate.
static inline BOOL NUViewShowsSuggestions(UIView *playerView) {
    if (![playerView respondsToSelector:@selector(showSuggestionsView)]) return NO;
    return [(MRUNowPlayingView *)playerView showSuggestionsView];
}

// Same question, for a SpringBoard-side host that holds no pointer to the player view: the
// iOS 14/15 CSMediaControlsViewController hosts the now-playing VC in-process, and its
// height levers run before we have any other handle on it. The platter's tree is tiny and
// this only runs on those levers, so a recursive scan is cheap. Not found → NO (grow, as
// today): failing open keeps a missed detection no worse than the current behaviour.
static inline BOOL NUSubtreeShowsSuggestions(UIView *root) {
    if (!root) return NO;
    if (NUViewShowsSuggestions(root)) return YES;
    for (UIView *sub in root.subviews)
        if (NUSubtreeShowsSuggestions(sub)) return YES;
    return NO;
}

#pragma mark - View-level row helpers

// The row belongs only to the EXPANDED Control Center now-playing card, never the
// collapsed module tile (which reuses the same MRUNowPlayingView). The CC VC's
// -didTransitionToExpandedContentMode: hook stamps this on the now-playing view so
// the view-level layout hooks can gate on it. Absent stamp == collapsed.
static inline BOOL NUViewCCExpanded(UIView *view) {
    return [objc_getAssociatedObject(view, kNUCCExpandedKey) boolValue];
}
static inline void NUSetViewCCExpanded(UIView *view, BOOL expanded) {
    objc_setAssociatedObject(view, kNUCCExpandedKey, @(expanded), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static inline NUHostKind NUViewHostKind(UIView *view) {
    NSNumber *n = objc_getAssociatedObject(view, kNUHostViewKey);
    return n ? (NUHostKind)n.integerValue : NUHostNone;
}

// iOS 18 Control Center: the collapsed media tile and the expanded card reuse the SAME
// MRUMediaControlsModuleNowPlayingView, so the row must be gated on the enclosing
// MRUMediaControlsModuleViewController.isExpanded — otherwise it shows on the mini tile.
// The AirPlay routing picker (MRUMediaControlsModuleRoutingView) is a SIBLING of our
// now-playing view; while it's open our extra row throws the container layout off, so
// treat an open picker as "not showable" and hide the row. The opening/closing keys
// override this for the animation window (open: hide early; close: show immediately).
// Is Control Center's AirPlay route picker up? Our extra row throws the container
// layout off while it is, so both generations hide the row for the duration — but the
// signal is completely different.
//
// iOS 18: the picker is a sibling collapsed to height 0 that grows when opened, so
// its height IS the state.
//
// iOS 26: the picker is laid out permanently at full size and PARKED BELOW the
// session container while closed, then slides up into it. Measured live (338pt-wide
// card, 603pt container):
//     closed → picker frame {{0, 627}, {338, 499}}     (origin below the container)
//     open   → picker frame {{0, 108.7}, {338, 494.3}} (inside; the now-playing view
//                                                       shrinks to a 108.7pt header)
// So the test is whether the picker's top edge has moved inside the container. A
// height test reads "open" forever here, which suppressed the row entirely.
static inline BOOL NUCCRoutingViewOpen(UIView *nowPlayingView) {
    UIView *container = nowPlayingView.superview;
    if (!container) return NO;

    Class RV18 = objc_getClass("MRUMediaControlsModuleRoutingView");
    if (RV18) {
        for (UIView *sib in container.subviews)
            if ([sib isKindOfClass:RV18] && sib.frame.size.height > 1.0) return YES;
        return NO;
    }

    // Swift class: the runtime name is mangled, but NSStringFromClass reports the
    // demangled "MediaControls.RoutePickerItemsView". Match the mangled name first
    // and fall back to the readable one so a re-mangling (different module or name
    // length prefix) doesn't silently disable the gate.
    Class RV26 = objc_getClass("_TtC13MediaControls20RoutePickerItemsView");
    for (UIView *sib in container.subviews) {
        BOOL isPicker = RV26 ? [sib isKindOfClass:RV26]
                             : [NSStringFromClass(sib.class) hasSuffix:@"RoutePickerItemsView"];
        if (isPicker)
            return CGRectGetMinY(sib.frame) < CGRectGetHeight(container.bounds) - 1.0;
    }
    return NO;
}

// iOS 26 renders each route-picker entry as another SESSION built from the same Swift
// classes as the module's own card, so the layout hooks run on every entry too.
// Nothing structural identifies the real card: card and entries share the ancestor
// chain
//
//   MediaControlsModuleNowPlayingView < MediaControlsModuleSessionView < UIView
//     < RoutePickerSessionsView<MediaControlsModuleSessionView> < MediaControlsModuleView
//
// and the same sibling set (each entry is a self-contained mini-module, picker button
// included), and mount order is not stable — after a trip through the picker the
// module's own session is no longer first, so an index test misidentifies the card.
// Size is the invariant that holds in every state: entries are 62pt pills (as is the
// module's own card while the picker is up) against a row that needs 111.5pt, so
// "does the row fit" decides — enforced in NUCCLayoutRow.

static inline BOOL NUCCRoutingOpen(UIView *nowPlayingView) {
    if ([objc_getAssociatedObject(nowPlayingView, kNURouteClosingKey) boolValue]) return NO;  // force show
    if ([objc_getAssociatedObject(nowPlayingView, kNURouteOpeningKey) boolValue]) return YES; // force hide
    return NUCCRoutingViewOpen(nowPlayingView);
}

// Pin the row's visibility across the route picker's open/close animation, then hand
// control back to the geometry gate. wasOpen is the picker's state BEFORE the tap that
// triggered this: opening (was closed) → force-hide the row now so the picker has room
// before it animates in; closing (was open) → force-show it immediately. The override is
// dropped once the animation has settled, after which -layoutSubviews resumes gating on
// the real routing-view geometry.
static inline void NUCCApplyRouteOverride(UIView *npView, BOOL wasOpen) {
    void *setKey   = wasOpen ? kNURouteClosingKey : kNURouteOpeningKey; // closing → force show; opening → force hide
    void *clearKey = wasOpen ? kNURouteOpeningKey : kNURouteClosingKey;
    objc_setAssociatedObject(npView, clearKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(npView, setKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [npView setNeedsLayout];
    __weak UIView *weak = npView;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        objc_setAssociatedObject(weak, setKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [weak setNeedsLayout];
    });
}

static inline BOOL NUCCModuleExpanded(UIView *view) {
    Class MOD = objc_getClass("MRUMediaControlsModuleViewController");
    if (!MOD) return NO;
    if (NUCCRoutingOpen(view)) return NO;
    for (UIResponder *r = view.nextResponder; r; r = r.nextResponder)
        if ([r isKindOfClass:MOD]) {
            MRUMediaControlsModuleViewController *mod = (MRUMediaControlsModuleViewController *)r;
            if ([mod respondsToSelector:@selector(isExpanded)]) return mod.isExpanded;  // iOS 18
            // iOS 26 reimplemented this controller in Swift and `isExpanded` became a
            // plain Swift stored property with no ObjC accessor — the selector check
            // above fails and the row would never show. Fall back to the state our own
            // -didTransitionToExpandedContentMode: hook stamps on the controller, which
            // is the same signal Apple drives the transition from.
            id stamp = objc_getAssociatedObject(mod, kNUCCExpandedKey);
            if (stamp) return [stamp boolValue];
        }
    // The iOS 26 route picker re-hosts the card: the responder chain then misses the
    // module controller, or reaches one that never saw a transition — and an unstamped
    // controller must not read as "collapsed" on an expanded card. Fall back to the
    // last transition seen in this process (only one media module is ever up), held on
    // the manager singleton so every hook file reads the same value.
    return [objc_getAssociatedObject(NUNextUpManager.sharedManager, kNUCCExpandedKey) boolValue];
}

// The now-playing card's artwork and full-card backdrop, by class name — the two
// views the row layout has to treat specially (shrink the artwork to make room; never
// slide the backdrop). Renamed wholesale in the iOS 26 Swift rewrite, so both
// generations are listed and the first match wins.
static inline UIView *NUCCViewOfAnyClass(UIView *parent, const char * const *names, size_t count) {
    for (size_t i = 0; i < count; i++) {
        Class cls = objc_getClass(names[i]);
        if (!cls) continue;
        for (UIView *sub in parent.subviews)
            if ([sub isKindOfClass:cls]) return sub;
    }
    return nil;
}

static inline UIView *NUCCArtworkView(UIView *nowPlayingView) {
    static const char * const kNames[] = {
        "MRUArtworkView",                        // iOS ≤ 18
        "_TtC13MediaControls14ArtworkControl",   // iOS 26
        "_TtC13MediaControls11ArtworkView",      // iOS 26 (inside the control)
    };
    return NUCCViewOfAnyClass(nowPlayingView, kNames, sizeof(kNames) / sizeof(*kNames));
}

static inline UIView *NUCCBackdropView(UIView *nowPlayingView) {
    static const char * const kNames[] = {
        "MRUMediaModuleBackdropView",            // iOS 18
        "_TtC13MediaControls12BackdropView",     // iOS 26
    };
    return NUCCViewOfAnyClass(nowPlayingView, kNames, sizeof(kNames) / sizeof(*kNames));
}

// The full AirPlay routing list ("Control Other Speakers & TVs") is up when the module's
// discoveryMode is non-zero; it is 0 while the now-playing content is shown. This is a
// distinct surface from the inline route picker (NUCCRoutingOpen) — a full
// MRURoutingViewController laid over the card — so the row must be gated off separately
// while it is present. Walks the responder chain to the module, as NUCCModuleExpanded does.
static inline BOOL NUCCDiscoveryActive(UIView *view) {
    Class MOD = objc_getClass("MRUMediaControlsModuleViewController");
    if (!MOD) return NO;
    for (UIResponder *r = view.nextResponder; r; r = r.nextResponder)
        if ([r isKindOfClass:MOD]) {
            MRUMediaControlsModuleViewController *mod = (MRUMediaControlsModuleViewController *)r;
            return [mod respondsToSelector:@selector(discoveryMode)] && mod.discoveryMode != 0;
        }
    return NO;
}

// The Control Center now-playing view (tagged kNUHostViewKey == NUHostControlCenter)
// within a subtree. The -didSelectListState: hook uses it to relayout the now-playing view
// on the tap, so the NUCCDiscoveryActive gate applies as the list opens.
static inline UIView *NUCCNowPlayingInSubtree(UIView *root) {
    if (!root) return nil;
    if (NUViewHostKind(root) == NUHostControlCenter) return root;
    for (UIView *sub in root.subviews) {
        UIView *r = NUCCNowPlayingInSubtree(sub);
        if (r) return r;
    }
    return nil;
}

// Show + position the row (either host) when there's a live next track.
static inline BOOL NUViewShowsRow(UIView *view) {
    NUHostKind h = NUViewHostKind(view);
    if (h == NUHostNone || !NUNextUpManager.sharedManager.active) return NO;
    if (!NUInterfaceEnabled(h)) return NO;   // this surface disabled in Settings
    if (NUViewShowsSuggestions(view)) return NO; // iOS is showing its own suggestions here
    if (h == NUHostControlCenter) {
        // Only in the expanded card, not the collapsed module tile.
        if (!NUViewCCExpanded(view)) return NO;
        // The route picker (AirPlay) is opening/up: hide so the row doesn't flash during the
        // transition. On iOS 18 the picker is an inline routing view (detected by height); on
        // iOS 14–17 it's a modal, flagged by the -presentViewController: hook. Both via the keys.
        if (NUCCRoutingOpen(view)) return NO;
        // The full routing list ("Control Other Speakers & TVs") is up.
        if (NUCCDiscoveryActive(view)) return NO;
    }
    return YES;
}

// Grow the reported fitting size — LOCK SCREEN ONLY. Control Center grows via
// MRUControlCenterViewController.preferredExpandedContentHeight instead, so
// adding the row height here too would double-count it.
static inline BOOL NUViewGrowsFit(UIView *view) {
    return NUViewHostKind(view) == NUHostLockScreen && NUNextUpManager.sharedManager.active
        && NUInterfaceEnabled(NUHostLockScreen)
        && !NUViewShowsSuggestions(view);   // must match NUViewShowsRow, or we grow with no row
}

// The row is taller in Control Center and the Dynamic Island (both respect the
// 24pt content padding); the lock screen keeps the tight layout.
static inline CGFloat NURowHeightForView(UIView *view) {
    NUHostKind h = NUViewHostKind(view);
    return (h == NUHostControlCenter || h == NUHostDynamicIsland)
        ? [NUNextUpRowView preferredHeightForControlCenter]
        : [NUNextUpRowView preferredHeight];
}

// Place the row inside a Control Center now-playing card, after Apple's own layout
// pass has run. Shared by the iOS 18 and iOS 26 hooks: the card was rewritten in
// Swift on 26 and every class name changed, but the geometry problem and its
// solution did not, so only the class lookups above differ.
//
// Both generations size the content from a discrete layout constant rather than from
// -bounds, so the pre-18 bounds clamp cannot shrink the artwork and growing the card
// just pushes the controls up until they collide. Instead we keep the card at its
// natural height and make room by shrinking the square artwork and sliding everything
// below it up by the same amount.
static inline void NUCCLayoutRow(UIView *npView, BOOL show) {
    NUNextUpRowView *row = nil;
    for (UIView *sub in npView.subviews)
        if ([sub isKindOfClass:[NUNextUpRowView class]]) { row = (NUNextUpRowView *)sub; break; }
    if (!row) return;

    // Fade rather than toggle `hidden`. Leaving the route picker animates the whole
    // card back, and a hidden-flag flip is not animatable, so the row used to pop in
    // a frame ahead of everything else. This runs inside Apple's animated layout
    // pass, so an alpha change here is carried by that same animation. `hidden`
    // stays NO — UIKit already excludes an alpha-0 view from hit-testing, so the
    // invisible row cannot swallow touches meant for the controls behind it.
    row.hidden = NO;
    if (!show) { row.alpha = 0.0; return; }
    row.alpha = 1.0;

    UIView *artwork  = NUCCArtworkView(npView);
    UIView *backdrop = NUCCBackdropView(npView);
    CGFloat contentBottom = 0;
    for (UIView *sub in npView.subviews) {
        if (sub == row || sub == backdrop) continue;   // ours / the full-card background
        contentBottom = MAX(contentBottom, CGRectGetMaxY(sub.frame));
    }

    CGFloat rowH  = NURowHeightForView(npView);
    CGFloat viewH = npView.bounds.size.height;

    // Sit the separator a small gap below the native content — matched to the vertical
    // gap Apple leaves between the volume slider and the route button (~18pt) — rather
    // than pinning the row to the card bottom, which leaves an uneven larger gap.
    CGFloat gap = 18.0;
    // A card shorter than the row cannot host it — hide. The overflow path below
    // reclaims a few points from the artwork, never a whole card collapsed into the
    // iOS 26 route picker's 62pt pill: there contentBottom still measures a stale
    // 337.5pt suggestions view, driving the row to a negative origin over the artwork.
    if (viewH < rowH + gap) { row.alpha = 0.0; return; }
    CGFloat rowTop = contentBottom + gap;
    CGFloat overflow = (rowTop + rowH) - viewH;

    if (overflow > 0.5 && !artwork) {
        // Nothing to absorb the overflow (a future release renamed the artwork view
        // again): with artMaxY = 0 the "sat below the artwork" test below would match
        // EVERY subview and shove the whole card's content up. Degrade to the stock
        // layout instead — hide the row.
        row.alpha = 0.0;
        return;
    }
    if (overflow > 0.5) {
        CGFloat artMaxY = CGRectGetMaxY(artwork.frame);
        CGRect af = artwork.frame;
        af.size.height = MAX(1, af.size.height - overflow);
        af.size.width  = MAX(1, af.size.width  - overflow);
        af.origin.x    = (npView.bounds.size.width - af.size.width) / 2.0;   // keep centred
        artwork.frame  = af;
        for (UIView *sub in npView.subviews) {
            if (sub == row || sub == backdrop || sub == artwork) continue;
            if (CGRectGetMinY(sub.frame) >= artMaxY - 1.0)                   // sat below the artwork
                { CGRect f = sub.frame; f.origin.y -= overflow; sub.frame = f; }
        }
        rowTop -= overflow;
    }
    [npView bringSubviewToFront:row];
    row.frame = CGRectMake(0, rowTop, npView.bounds.size.width, rowH);
    [row applyConcentricArtworkForCardCornerRadius:npView.layer.cornerRadius];
}

#pragma mark - Dynamic Island shared constants (iOS 16 + 17 families)

static const long long kNUDIExpandedMode = 4;      // activeLayoutMode when fully expanded (17.0)
static const CGFloat kNUDIExpandedMinHeight = 120.0; // the DI now-playing view is reused for the
                                                     // compact pill (~37pt) and the expanded player
                                                     // (~202pt); only show the row above this height.
