# Round 3 notes (beta-simix, device log 2026-09-30)

Simone's log is from build `94956f9`. Nothing here was compiled: this environment has no Theos and no device. Each item stays in the redesign.

## Mini player

The log minimizes the capsule once (`trait inline`), then keeps reporting `state uikit` at offset `-116`. That offset is the visual top (`-adjustedContentInset.top`). UIKit's `OnScrollDown` only expands at offset 0, so a swipe back up never leaves the inline slot.

Round 2 moved the capsule's frame and unlinked the list (`pinned-above`). The trait stayed `inline`, so the swipe looked like it did nothing. `tab bar: reselects Home` also ran during the drag and cancelled it. `no page list found` in this log is while the bar is hidden (the player is up); the later offset lines are a list that was found.

This round leaves the list linked so UIKit still moves the capsule on the way down. A swipe up, or a drag that starts already at the visual top while inline, unlinks the list, sets `UITabBarMinimizeBehaviorNever`, and puts the same accessory back so the trait can leave `inline`. A swipe down links the list again. The frame is not moved. Reselecting the tab is skipped while a finger is down, and at most once every 1.5s otherwise.

## Navbar

Shrinking the glass bar to `slot * visible` and centering that frame pulled the Search circle off the trailing edge. The bar stays full width. If the controls are still inset, the leading ones are moved to the leading edge and the trailing control to the trailing edge. The log is `tab bar: controls … leading gap … trailing gap`.

## Mix shimmer

`redesign playlist: mixed, the play capsule can shimmer` means the Mix pill was found. The sweep was a white gradient on the white Play capsule, so it did not show. It is now a soft black band, and each pass logs whether the pill, the Play capsule, and the sweep are on or why they are not.

## Time bar

The overlay's track tint was nil, so the press took Spotify green. The overlay track is clear, its tint is white, and Spotify's own bar is tinted white. A zero-height slider frame (the duration unit's first layout) does not get an overlay until the width is at least 40pt; a short bar is grown to 28pt so the thumb is not clipped.

## Download

`SGRReadDownload` let the model byte win. When the identifier is `DownloadButton.Granular.Downloaded` and the byte disagrees, the identifier wins and the glyph is the downloaded one. A tap in that state does not fire Spotify's button.
