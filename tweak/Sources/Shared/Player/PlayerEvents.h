// The full screen player's open and close, for whatever must stand still while it animates (the
// karaoke card puts its display link down, the redesign holds heavy work back). Both looks' players are
// presented by Spotify's own presentation controller, so one announcement serves both.
#import <UIKit/UIKit.h>

// Posted as the player starts to open or close, before the animation runs, and again once it is
// over; SGPlayerTransitionEnds says when it is expected to be over (as CACurrentMediaTime), 0 when none runs.
extern NSString *const SGPlayerTransitionNotification;
extern NSString *const SGPlayerTransitionEndedNotification;
CFTimeInterval SGPlayerTransitionEnds(void);
// When the current transition began (CACurrentMediaTime), or 0 when none has. A tap can tell a
// leftover close from the present it just started.
CFTimeInterval SGPlayerTransitionBegan(void);

// The full player's own background controller (NowPlaying_ScrollImpl.NPVBackgroundViewController),
// the same one whose appearance announces the transition. On screen from viewDidAppear until
// viewWillDisappear. Appearing from viewWillAppear until it is on screen, a dismiss starts, or
// SGPlayerTransitionResetStuck clears a transition that never finished.
BOOL SGPlayerIsOnScreen(void);
BOOL SGPlayerIsAppearing(void);
// Drops a transition flag whose completion has not run, once it has been going for a second.
// No-op while the player is on screen or the transition is younger than that.
void SGPlayerTransitionResetStuck(void);
