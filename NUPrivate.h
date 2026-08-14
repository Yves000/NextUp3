// Private interfaces for NextUp 3. Selectors verified against the iOS 17.0
// class-dump and confirmed live via Frida on-device, and cross-checked against
// the iOS 16 runtime headers (MediaControls.framework /
// MediaPlaybackCore.framework) — the display + provider classes match.
#import <UIKit/UIKit.h>

@class NUNextUpRowView; // our row view, attached to the now-playing VCs below

#pragma mark - MediaPlayer model layer

@class MPArtworkCatalog;

@interface MPPropertySet : NSObject
+ (id)propertySetWithProperties:(NSArray *)properties;
- (id)initWithProperties:(NSArray *)properties relationships:(NSDictionary *)relationships;
@end

@interface MPModelObject : NSObject
- (MPArtworkCatalog *)artworkCatalog;
@end

@interface MPModelPerson : MPModelObject
@property (nonatomic, copy) NSString *name;
+ (id)__name_KEY;
@end

@interface MPModelArtist : MPModelPerson
@end

@interface MPModelSong : MPModelObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, retain) MPModelArtist *artist;
+ (id)__title_KEY;
+ (id)__artist_KEY;
+ (id)__artworkCatalogBlock_KEY;
@end

@interface MPModelGenericObject : MPModelObject
@property (nonatomic, retain) MPModelSong *song;
@property (nonatomic, retain) MPModelArtist *artist;
+ (id)__song_KEY;
+ (id)__artist_KEY;
@end

@interface MPArtworkCatalog : NSObject
@property (nonatomic) CGSize fittingSize;
@property (nonatomic) double destinationScale;
- (void)requestImageWithCompletionHandler:(void (^)(UIImage *image))handler;
@end

@interface MPSectionedCollection : NSObject
- (long long)totalItemCount;
- (NSIndexPath *)indexPathForGlobalIndex:(long long)globalIndex;
- (id)itemAtIndexPath:(NSIndexPath *)indexPath;
- (id)safeItemAtIndexPath:(NSIndexPath *)indexPath;
@end

#pragma mark - MediaPlaybackCore player layer

@interface MPCPlayerPath : NSObject
@property (nonatomic, readonly, copy) NSString *bundleID;
@property (getter=isSystemMusicPath, nonatomic, readonly) BOOL systemMusicPath;
+ (id)deviceActivePlayerPath;
@end

@class MPCPlayerResponseTracklist;

@interface MPCPlayerResponse : NSObject
@property (nonatomic, readonly) MPCPlayerPath *playerPath;
@property (nonatomic, readonly) MPCPlayerResponseTracklist *tracklist;
@end

@interface MPCPlayerResponseItem : NSObject
@property (nonatomic, readonly, copy) NSString *contentItemIdentifier;
@property (getter=isAutoPlay, nonatomic, readonly) BOOL autoPlay;
@property (getter=isPlaceholder, nonatomic, readonly) BOOL placeholder;
@property (nonatomic, readonly) MPModelGenericObject *metadataObject;
- (id)remove; // returns MPCPlayerCommandRequest, or nil if not removable
@end

@interface MPCPlayerResponseTracklist : NSObject
@property (nonatomic, readonly, copy) MPSectionedCollection *items;
@property (nonatomic, readonly) MPCPlayerResponseItem *playingItem;
@property (nonatomic, readonly) long long playingItemGlobalIndex;
@property (nonatomic, readonly) long long upNextItemCount;
@end

@interface MPCPlayerChangeRequest : NSObject
+ (id)requestWithCommandRequests:(NSArray *)commandRequests;
- (void)performWithCompletion:(void (^)(NSError *error))completion;
@end

// tracklistRange is a struct { long long reverseCount; long long forwardCount; }
typedef struct { long long reverseCount; long long forwardCount; } NUTracklistRange;

@interface MPCPlayerRequest : NSObject
@property (nonatomic, retain) MPCPlayerPath *playerPath;
@property (nonatomic, copy) MPPropertySet *queueItemProperties;
@property (nonatomic) NUTracklistRange tracklistRange;
@end

@protocol MPRequestResponseControllerDelegate;

@interface MPRequestResponseController : NSObject
@property (nonatomic, weak) id<MPRequestResponseControllerDelegate> delegate;
@property (nonatomic, retain) id request;
@property (nonatomic, retain) id response;
- (void)beginAutomaticResponseLoading;
- (void)endAutomaticResponseLoading;
- (void)reloadIfNeeded;
- (void)setNeedsReload;
@end

@protocol MPRequestResponseControllerDelegate <NSObject>
@optional
- (void)didFinishLoadingRequestForController:(MPRequestResponseController *)controller;
- (void)willBeginLoadingRequestForController:(MPRequestResponseController *)controller;
@end

// The live queue controller (Music process). Hooked to capture the controller and
// observe queue changes; the provider reads the next track from it.
@interface MPCQueueController : NSObject @end

#pragma mark - MediaRemoteUI now-playing UI (lock-screen player host process)

@class MRUNowPlayingController;

@interface MRUNowPlayingView : UIView
@property (nonatomic, retain) UIView *containerView;
@property (nonatomic, retain) UIView *contentView;
@property (nonatomic, readonly) UIView *headerView;
@property (nonatomic, readonly) UIView *timeControlsView;
@property (nonatomic, readonly) UIView *transportControlsView;
@property (nonatomic, readonly) UIView *volumeControlsView;
@property (nonatomic) long long layout;
// Set by the player's own -updateVisibility when iOS replaces the transport with its
// media-suggestion tiles ("Not Playing" / Siri listening suggestions). The identical
// selector exists on every player view class that can host them, so NUViewShowsSuggestions
// duck-types on it rather than branching per class/version. Present 14.2–18.
@property (nonatomic) BOOL showSuggestionsView;
- (CGSize)sizeThatFits:(CGSize)size;
@end

@interface MRUNowPlayingViewController : UIViewController
@property (nonatomic, retain) MRUNowPlayingView *view;
@property (nonatomic, retain) MRUNowPlayingController *controller;
@property (nonatomic) long long context; // 2 == lock screen (CoverSheet); Control Center uses another value
- (BOOL)_canShowWhileLocked;
// NextUp additions (hooked in NUHooksNowPlaying.x)
@property (nonatomic, strong) NUNextUpRowView *nu_row;
- (void)nu_ensureRow;
- (void)nu_registerForChanges;
- (void)nu_changed;
- (void)nu_syncPlatterHeight;
- (void)nu_invalidateControlCenterHeight;
- (void)nu_invalidateLockScreenHeight;
- (BOOL)nu_shouldShowRow;
@end

// Control Center now-playing card host (SpringBoard process). A CCUI content
// module (conforms to CCUIContentModuleContentViewController); it nests the shared
// MRUNowPlayingViewController and sizes the expanded card via
// -preferredExpandedContentHeight (not preferredContentSize).
@interface MRUControlCenterViewController : UIViewController
@property (nonatomic, retain) MRUNowPlayingViewController *nowPlayingViewController; // iOS 16/17
@property (nonatomic, retain) MRUNowPlayingViewController *selectedViewController;   // iOS 15
- (double)preferredExpandedContentHeight;
- (void)didTransitionToExpandedContentMode:(BOOL)expanded;
- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id)coordinator;
// NextUp additions (hooked in NUHooksControlCenterLegacy.x)
- (void)nu_applyCCExpanded:(BOOL)expanded;
@end

// The full AirPlay routing list ("Control Other Speakers & TVs"), laid over the
// expanded Control Center card (iOS ≤ 17). -setOnScreen: is toggled as it slides
// in/out — the authoritative signal for hiding our row while it covers the card
// (hooked in NUHooksControlCenterLegacy.x).
@interface MRURoutingViewController : UIViewController
- (void)setOnScreen:(BOOL)onScreen;
@end

#pragma mark - iOS 18 Control Center now-playing module

// iOS 18 replaced the MRUControlCenterViewController-hosts-MRUNowPlayingViewController
// design with a self-contained CCUI module:
//   MRUMediaControlsModuleViewController   — the module, owns the expanded height
//     └ MRUMediaControlsModuleNowPlayingViewController — the content VC
//         └ MRUMediaControlsModuleNowPlayingView       — the now-playing view
@interface MRUMediaControlsModuleNowPlayingView : UIView
@property (nonatomic) BOOL showSuggestionsView; // see MRUNowPlayingView.showSuggestionsView
- (CGSize)sizeThatFits:(CGSize)size;
@end

// iOS 18 lock-screen player, rendered by MediaRemoteUI into the Live Activity scene that
// SpringBoard hosts (see NUHooksLockScreen18). We never draw into it — the row is a
// SpringBoard-side sibling — so this is hooked purely to publish -showSuggestionsView
// across the process boundary via NUSuggestingSet.
@interface MRULockscreenView : UIView
@property (nonatomic) BOOL showSuggestionsView; // see MRUNowPlayingView.showSuggestionsView
@end

@interface MRUMediaControlsModuleNowPlayingViewController : UIViewController
@property (nonatomic, strong) NUNextUpRowView *nu_row;
- (void)nu_ensureRow;
- (void)nu_registerForChanges;
- (void)nu_changed;
- (void)nu_routeToggled:(BOOL)wasOpen;
- (void)didSelectRouteButton:(id)arg1;
- (void)toggleRoutePicker;
@end

@interface MRUMediaControlsModuleViewController : UIViewController
- (double)preferredExpandedContentHeight;
- (BOOL)isExpanded;
- (long long)discoveryMode; // 0 = now-playing; non-zero = AirPlay/routing picker is up
@end

#pragma mark - iOS 17 Dynamic Island expanded now-playing (MRUActivityNowPlaying*)

// The DI's expanded player is a separate class family rendered by MediaRemoteUI into
// an ActivityUIServices "SystemAperture" scene. Expanded layout mode == maximumLayoutMode
// (4 on 17.0); size propagates to the aperture via -preferredHeightForBottomSafeArea.
@interface MRUActivityNowPlayingView : UIView
- (double)preferredHeightForBottomSafeArea;
@end

@interface MRUActivityNowPlayingViewController : UIViewController
@property (nonatomic) long long activeLayoutMode;
@property (nonatomic) long long maximumLayoutMode;
@property (nonatomic, strong) NUNextUpRowView *nu_row;
- (double)preferredHeightForBottomSafeArea;
// Apple's own layout-mode refresh; re-queries -preferredHeightForBottomSafeArea so
// the aperture re-reserves room for our row mid-open (per Frida backtraces).
- (void)updateLayoutModesPreferringImmediateTransition:(BOOL)immediate deferInCustomLayout:(BOOL)defer reason:(id)reason;
- (void)nu_ensureRow;
- (void)nu_registerForChanges;
- (void)nu_changed;
- (BOOL)nu_diExpanded;
- (BOOL)nu_shouldShowRow;
@end

#pragma mark - iOS 16 Dynamic Island expanded now-playing (MRUSessionNowPlaying*)

// iOS 16 has no MRUActivityNowPlaying* — the DI's expanded now-playing player is
// MRUSessionNowPlayingViewController / MRUSessionNowPlayingView instead. It exposes
// the same layout-mode / bottom-safe-area / update-layout-modes API as the iOS 17
// activity class, plus a clean -isExpanded.
@interface MRUSessionNowPlayingView : UIView
- (double)preferredHeightForBottomSafeArea;
@end

@interface MRUSessionNowPlayingViewController : UIViewController
@property (nonatomic) long long activeLayoutMode;
@property (nonatomic) long long maximumLayoutMode;
@property (nonatomic, strong) NUNextUpRowView *nu_row;
- (BOOL)isExpanded;
- (double)preferredHeightForBottomSafeArea;
- (void)updateLayoutModesPreferringImmediateTransition:(BOOL)immediate deferInCustomLayout:(BOOL)defer reason:(id)reason;
- (void)nu_ensureRow;
- (void)nu_registerForChanges;
- (void)nu_changed;
- (BOOL)nu_diExpanded;
- (BOOL)nu_shouldShowRow;
@end

#pragma mark - iOS 14/15 in-process lock-screen host (CoverSheet)

// On iOS 14/15 the now-playing card is hosted in-process by SpringBoard's
// CSMediaControlsViewController (not a remote MediaRemoteUI view as on 16/17).
// iOS 15 sizes the platter from -_preferredMediaRemoteHeight; iOS 14 has no such
// selector and frames the media view from -_suggestedFrameForMediaControls.
@interface CSMediaControlsViewController : UIViewController
- (double)_preferredMediaRemoteHeight;        // iOS 15 only
- (void)_updatePreferredContentSize;          // iOS 15 only
- (void)_layoutMediaControls;                 // iOS 14 + 15
- (CGRect)_suggestedFrameForMediaControls;    // iOS 14: frames the media view
@end
