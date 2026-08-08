#import <UIKit/UIKit.h>

// A compact "next up" row: artwork + UP NEXT caption + title + artist + skip (X).
// Pure UIKit; observes NUNextUpManager and refreshes itself.
// To VoiceOver the row is a single element ("Up Next: Title — Artist"): activate
// plays the track now; Skip / Play-previous surface as custom actions.
@interface NUNextUpRowView : UIView

// Preferred height of the row (used by the host to grow the platter).
@property (class, nonatomic, readonly) CGFloat preferredHeight;                 // lock screen
@property (class, nonatomic, readonly) CGFloat preferredHeightForControlCenter; // taller: respects the CC card's padding

// Switch the row to the Control Center layout. Call once after creation.
- (void)configureForControlCenter;

// Switch the row to the Dynamic Island layout. Call once after creation.
- (void)configureForDynamicIsland;

// YES when the manager currently has a valid next track to show.
@property (nonatomic, readonly, getter=hasContent) BOOL hasContent;

// Pull the latest snapshot from the manager and update labels/artwork/visibility.
- (void)refreshFromManager;

// Round the artwork corners concentric to the enclosing card's corner radius;
// pass 0 to fall back to the default artwork radius.
- (void)applyConcentricArtworkForCardCornerRadius:(CGFloat)cardRadius;

@end
