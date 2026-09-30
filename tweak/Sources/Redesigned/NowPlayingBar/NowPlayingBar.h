// The redesign's now playing bar: the glass card it becomes (NowPlayingBar.x), Spotify's device button
// on that card hidden on request (BarConnect.x), glass behind the bar's and the tab bar's stand-ins while
// the player opens and closes (BarTransition.x), and the bar's rows on Mod Settings' Player page
// (NowPlayingBarSettings.m). The redesign keeps its own copy of the hide switch and its own key; the
// native look's lives in Native/NowPlayingBar/.
#import <UIKit/UIKit.h>

@class SGModSection;

#define SGRHideBarConnect @"spotifyglass.redesign.hide.barConnect"   // the device button on the card
// The mini player in the tab bar, Apple Music style: the tab bar becomes a UITabBarController's, with
// the mod's own mini player (MiniPlayer.m) as its bottom accessory, and Spotify's bar goes invisible
// under it. Off unless set; read at launch.
#define SGRKeyInlinePlayer @"spotifyglass.redesign.inlinePlayer"
BOOL SGRInlinePlayer(void);

NSArray<SGModSection *> *SGRNowPlayingSections(void);

// The bar's glass card in `host`'s coordinates, with its corner radius; CGRectNull before the bar has
// been styled or while it is out of a window (NowPlayingBar.x). The bar keeps its geometry while
// Spotify hides it for the player's open and close.
CGRect SGRNowPlayingCardFrameIn(UIView *host, CGFloat *radius);
// The round artwork on that card in `host`'s coordinates; CGRectNull when none was found.
CGRect SGRNowPlayingArtworkFrameIn(UIView *host);

// With the mini player on, those two answer for the mini player, and Spotify's bar, invisible, stays
// what the mini player reads and works through:
// the picture Spotify's bar shows now, nil before it has one, and the view that shows it;
UIImage *SGRNowPlayingArtworkImage(void);
UIImageView *SGRNowPlayingArtworkView(void);
// Asks Spotify's bar to open the player, and keeps asking until the player is on screen.
// YES once the request is taken (including when the player is already up).
BOOL SGROpenPlayerFromBar(void);

// MiniPlayer.m: the accessory's content view, and its card and artwork in `host`'s coordinates
// (CGRectNull while it is not in a window).
UIView *SGRMakeMiniPlayer(void);
// Navbar/TabBar.x. An upward drag settles the minimized bar above the tabs without waiting for
// the page to be scrolled to the top. No-op when the mini player is off or the bar is already there.
void SGRExpandInlineBar(void);
CGRect SGRMiniPlayerFrameIn(UIView *host, CGFloat *radius);
CGRect SGRMiniPlayerArtworkFrameIn(UIView *host);
