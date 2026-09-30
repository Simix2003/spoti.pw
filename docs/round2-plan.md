# Round 2 plan (beta-simix @ 9b7d975)

Device notes are from build `beta-simix` `9b7d975`. Nothing here was compiled or run: there is no Theos, no Spotify binary, and no device in this environment. Every item stays inside the redesign (`Redesigned/`) and only hooks classes already hooked in this checkout.

## 1. Hiding a navbar tab does not resize the bar

**Hypothesis.** Hiding a tab writes `SGRNavbarHidden` and `SGRRefreshTabBar()` (`NavbarSettings.m` around the row tap that toggles the flag, then `save`). `SGRComposeTabBar` sets `hidden` on Spotify's item (`Navbar.x` in the layout walk) and `placeRow` only frames the visible order, splitting the **full** bar width by the visible count. The glass bar does not follow that width.

`tabItems` (`TabBar.x`, the helper that builds `sources`) keeps any arranged subview that is not `hidden` and is at least 20pt wide. If Spotify's own layout pass turns `hidden` back off before `syncBar` reads the row, the hidden tab stays a source and the glass bar is rebuilt with the old count. Even when the source list does shrink, the glass bar's **frame** stays the stock bar's full width (`syncBar` assigns `host.frame` / the inline controller's bar from the container bounds). `7eb7032` only set `UITabPlacementFixed` and `UITabBarItemPositioningCentered` inside that full-width bar so fewer tabs would not stretch. On device the bar width itself does not change, which matches a platter that still fills the full-width `UITabBar`. `c2474f2` made the last tab a `UISearchTab`; it does not resize the bar when the count changes.

**Approach.**

- Mark each arranged item with whether the navbar list is showing it, and have `tabItems` skip the ones marked hidden, so a layout pass that clears `hidden` cannot put the tab back on the glass bar.
- Remember the full width divided by the largest visible count seen (the unfitted width, never the width after we shrink). When the visible count is smaller, set the glass `UITabBar` frame to `slot * count`, centered in the full width. The inline bar is fitted only while the accessory is expanded; once it is inline, UIKit keeps the full width so the minimized capsule still has the leading tab and the trailing circle.
- Keep `UITabPlacementFixed` and centered positioning from `7eb7032` so the items inside that narrower bar do not stretch. The new part is the frame, which those commits never set.
- Log `tab bar:` with the visible count, full width, fitted width, and slot.

**Alternatives.** Dropping Fixed and going back to Automatic is what `7eb7032` was written to undo (tabs stretch across the gap to Search). Removing Spotify's arranged subviews, or hooking a private platter class, is not proved in this checkout.

**Risks.** The slot is wrong if the first width we see is already a hidden subset (further hides still shrink, showing every tab again recalculates from the full width). Fitting during the minimize animation could hitch; the fit is skipped once the accessory trait is inline. A centered narrower bar leaves untappable margins over Spotify's invisible bar.

**Confidence.** Medium. The frame is the part `7eb7032` did not change. Whether UIKit's iOS 26 platter hugs the tab bar bounds is the assumption the device log has to confirm.

## 2. Now Playing ⋯ needs two outside taps to close

**Hypothesis.** The glass menu opens on the tap (`openEarly` / `openMenu` in `PlayerMenu.x`) and sets `waitingForSheet`. `presentViewController:` then sets `sheetStoleMenu` whenever that menu is already shown, so `menuClosed` treats the dismiss as the sheet stealing the menu and reopens it (`reopenQueued`). That reopen is right for the dismiss **inside** the present (`70b1a9c`). It is wrong for a later outside tap if `sheetStoleMenu` is still set. `adoptClaimedMenu` clears the flag only when `shown && !closed` at adopt time; a menu that was stolen and reopened, or a flag set when the present did not actually dismiss the menu, stays armed. The first outside tap then runs `menuClosed`, reopens, and looks like a no-op. The second tap closes.

The claimed sheet is a second hit target. `hidePresentation` masks and hides the presented view and sets `userInteractionEnabled` off on that view, but the presentation `containerView` stays full screen and able to take a tap (`presentationTransitionWillBegin`, `containerViewDidLayoutSubviews`). One tap can land on that stand-in and leave the glass menu up.

**Approach.**

- Reopen from `menuClosed` only while `presentViewController:` is still on the stack (`sheetStoleMenu` and a presenting flag set around `%orig`). After the present returns, clear `sheetStoleMenu` so an outside tap always takes the normal close path (`closed`, then `finish`).
- While the sheet is claimed, set the container's `userInteractionEnabled` to NO and restore it in `showPresentation`, so the hidden stand-in cannot take the outside tap. `finish` still runs on close, so the sheet is dismissed and nothing invisible is left up.
- Log `redesign player menu:` when a close reopens because a present is in progress, and when a close finishes.

**Alternatives.** Removing the reopen entirely brings back the lag `70b1a9c` fixed (the sheet's present dismisses the menu that opened on the tap). Dismissing the sheet in the same turn as the outside tap, with no pick grace, can drop a row tap that arrives as the menu finishes closing; the grace stays, the container just stops taking hits during it.

**Risks.** If the glass menu is ever inside the sheet container, disabling the container would freeze the menu. The menu is presented from the ⋯ anchor on the player, and the sheet is hidden behind it; the device note is the opposite (the menu stays up). A present that dismisses the menu **after** `presentViewController:` returns would no longer reopen; the claim path still hides the sheet and `openMenu` runs from `adoptClaimedMenu`.

**Confidence.** Medium-high on the flag. Medium on the container, which is the backup if the first tap never reaches the menu.

## 3. Shimmer on Play for a mixed playlist

**Hypothesis.** The big Play control is `SGRPlayCapsule` inside `SGRHeaderInfo`, fed from Spotify's `header-play-button` in `showPlaylist` (`PlaylistHeader.x`). Nothing in that path reads the Mix pill. `PlaylistMenu.x` already finds `ListPlatform.ToolbarActions.MixButton` on the curation toolbar (`pillsIn`, kept on the page by `SGRPlaylistTakeCuration` / `064d3c4`). A playlist of someone else's has no Mix pill (comment in that file). There is no separate "mixed" model flag proved in this checkout.

**Approach.**

- Add `SGRPlaylistIsMixed(page)` next to the pill lookup: YES when that Mix pill is on the page. That is the definition in the device note ("playlists with the Mix pill").
- `showPlaylist` passes the flag into the header each pass, and `SGRPlayCapsule` draws a highlight sweep clipped to the white capsule: a `CAGradientLayer` animation, not a `CADisplayLink` (a 60 Hz link would drag the player; this capsule is not on the player).
- Reduce Motion: do not add the sweep. `didMoveToWindow` removes it when the capsule leaves the window and puts it back when it returns, if the playlist is still mixed.
- Log once when the sweep starts and when Reduce Motion skips it.

**Alternatives.** Shimmer only when the pill's selected trait is on. That is a better reading of "mix mode is active", but the note defines the playlist by the pill being present, and the trait is not proved to flip. Gating on selected is the fallback if presence is too broad; the log will say whether the pill is present.

**Risks.** Every playlist that shows the Mix pill shimmers, including one where Mix is off. The sweep is a white highlight on a white capsule; if it is invisible on device, the gradient alpha is the knob, not a second glass layer (the playlist Play capsule is a solid fill, `SGRHeaderInfo.m`).

**Confidence.** Medium. The pill lookup is the same one the ⋯ sheet already uses. The sweep itself is local drawing.

## 4. Glass thumb on the Now Playing time bar

**Hypothesis.** The time bar is Spotify's `_TtCO17NowPlaying_ECMKit11ProgressBar6Slider`, identifier `SPTNowPlayingSliderV2` (`PlayerControls.x`, `watchForSeekTaps`). It is a `UISlider` subclass that seeks from its own control events (`seekOnTap` already sends `TouchDown` / `ValueChanged` / `TouchUpInside`). No header in this checkout declares `trackConfiguration`, `UISliderTrackConfiguration`, or any other iOS 26 slider style. Calling one would be a guess. The redesign only runs on iOS 26 (`SGRedesignedUI`), so a system `UISlider` created there is the system control, which on iOS 26 is the glass slider, but that appearance is not proved from a header here.

**Approach.**

- Overlay a plain `UISlider` on Spotify's slider, nearly transparent and with a clear thumb until the first touch, then shown for the drag and hidden again on release. Frame follows Spotify's slider from the existing duration-unit layout pass.
- While the overlay is tracking, copy its value onto Spotify's slider and send the same control events `seekOnTap` sends, so Spotify seeks. While it is not tracking, mirror `setValue:animated:` from Spotify so playback keeps the thumb in sync.
- If `setTrackConfiguration:` exists, log that and leave the system default in place. Do not construct a configuration class that is not declared here.
- If the Spotify slider cannot be found, add nothing.

**Alternatives.** Restyle Spotify's own slider (custom thumb image). That fights the subclass that draws the thin bar and is harder to "hide otherwise". A private progress-bar thumb is not in the checkout.

**Limits.** This is a system `UISlider` shown on touch, not a proved `trackConfiguration` / tick API. On iOS 26 it should pick up the system glass thumb; if the SDK on the phone still draws the pre-glass slider, the overlay is still a visible thumb and Spotify still seeks. Not compiled, so the selector check is the only proof we can ship.

**Risks.** The overlay sits in the same band as the tap-to-seek watcher. It must take the drag and still let a stationary tap seek. Hiding with `alpha` 0 drops hit testing; the idle overlay stays just above the hit-test cutoff and clears its thumb so Spotify's bar stays visible.

**Confidence.** Low-medium on "native Liquid Glass", medium on "a thumb appears and Spotify seeks".

## 5. Mini player stays inline until the list is at the top

**Why the last two attempts failed.**

- `a6c8575` sets `tabBarMinimizeBehavior` to `UITabBarMinimizeBehaviorNever` after about 28pt or 350pt/s upward. `OnScrollDown` only expands at offset 0, and `Never` does not animate an accessory that is already inline back out. The log can say it expanded while the trait stays inline.
- `75917ec` (`settleAboveBar`) unlinks the content scroll view, sets `Never`, and on the next turn removes and re-sets `bottomAccessory`, then **links the scroll view again** while the offset is still below the top. UIKit reads that scroll view and minimizes again immediately. Toggling the accessory and flipping the behavior is the same family of fix as `a6c8575`: ask UIKit's scroll-linked minimize to undo itself. The device says it does not.

**Approach, different from both.** Stop asking minimize-on-scroll to expand early.

- On an upward drag (same travel / velocity thresholds, and the same finger-up snap), choose state `pinned-above`: set behavior to `Never`, unlink the scroll view, and **leave it unlinked** until a later downward drag. Do not nil out `bottomAccessory`.
- In `viewDidLayoutSubviews`, after UIKit lays out, if the state is `pinned-above` and the accessory capsule still overlaps the tab bar, move that capsule's frame so it sits above the bar. The capsule walk is the one `miniPlayerHit` already uses (stop at an ancestor much wider than the mini player, so the tab row is not dragged).
- A downward drag clears the pin, sets `OnScrollDown`, and links the scroll view again so minimize-on-scroll-down still works.
- `SGRExpandInlineBar` (the swipe up on the capsule in `MiniPlayer.m`) uses this same pin, not `settleAboveBar`.
- Each decision logs `tab bar:` with the scroll offset, the accessory trait (`inline` / `expanded`), and the chosen state (`pinned-above`, `uikit`, or `minimize-armed`).

**Alternatives.** Never linking the scroll view at all, so the accessory never inlines. That drops the Apple Music minimize, which does work on the way down. Private minimize progress is not in the headers.

**Risks.** UIKit can set the frame again after `viewDidLayoutSubviews` and win a frame; the next layout pass re-pins, which can jitter. The trait may stay `inline` while the frame is already above the bar, so the capsule can be the short inline layout sitting above the tabs until UIKit flips the trait. The log is what tells those apart on device.

**Confidence.** Low-medium. The mechanism is new; the placement numbers are not proved against a tree of the accessory's superview.
