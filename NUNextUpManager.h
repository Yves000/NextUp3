#import <UIKit/UIKit.h>

// Posted (NSNotificationCenter) whenever the next-up snapshot changes.
extern NSString *const NUNextUpDidChangeNotification;

@interface NUNextUpManager : NSObject

+ (instancetype)sharedManager;

// Begins/refreshes observation of the system music player's queue.
- (void)start;

// Current next-up snapshot (nil when nothing valid to show).
@property (nonatomic, readonly, getter=isActive) BOOL active;
@property (nonatomic, readonly, copy) NSString *nextTitle;
@property (nonatomic, readonly, copy) NSString *nextSubtitle;
@property (nonatomic, readonly, strong) UIImage *nextArtwork; // may be nil (placeholder shown by view)
@property (nonatomic, readonly) BOOL canSkip;
@property (nonatomic, readonly) BOOL canPrevious; // a previous track exists to enqueue as next

// YES while the current source's artwork is 16:9 rather than square. YouTube thumbnails are
// always 16:9, so a square well would centre-crop a third of every frame. The other four
// sources deliver square cover art and stay square.
@property (nonatomic, readonly) BOOL prefersWideArtwork;

// Carousel neighbour previews (may be nil). "fwd" = what becomes up-next after a
// skip (slides in on a left swipe); "back" = the previously-played track that gets
// enqueued as the new up-next on a right swipe ("Play Next").
@property (nonatomic, readonly, copy) NSString *fwdTitle;
@property (nonatomic, readonly, copy) NSString *fwdSubtitle;
@property (nonatomic, readonly, strong) UIImage *fwdArtwork;
@property (nonatomic, readonly, copy) NSString *backTitle;
@property (nonatomic, readonly, copy) NSString *backSubtitle;
@property (nonatomic, readonly, strong) UIImage *backArtwork;
@property (nonatomic, readonly, copy) NSString *backAdamID; // store id of the previous track (Play-Next target)

// Whether the back/previous swipe is actionable. Music needs a store id to enqueue
// (filters local-only tracks); Podcasts enqueues provider-side by uuid, so a tracked
// previous episode suffices. Use this instead of gating on backAdamID directly.
- (BOOL)canActionPrevious;

// Removes the next track from the queue. No-op if !canSkip.
- (void)skipNextTrack;

// Advances to the next track (plays it now) — the same effect as the player's
// next-track transport button. No-op if !active.
- (void)playNextTrack;

// Enqueues the previously-played track to play next (Apple Music's "Play Next"),
// leaving the current track playing. No-op if !active/!canPrevious/no store id.
- (void)playPreviousTrack;

@end
