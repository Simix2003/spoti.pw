# beta-simix

Changes on top of `beta` (0.23.0-beta). One commit. The Jam probe, the stats probe, and the tab-bar layout experiments are not in this tree.

## Features

- On iOS 26 the redesigned tab bar is a `UITabBarController`. Tabs the Navbar list leaves shown sit in the leading platter with their icon and title. Search is a trailing `UISearchTab`. Picking it opens Spotify's Search page and asks for the field.
- Apple Music style player is on unless turned off (read at launch). It adds the mini player as a `UITabAccessory`. Minimizing and expanding stay UIKit's: scroll down from the top of the page, or a tap on the minimized bar.
- A tap on the mini player opens the full player through Spotify's own card, and keeps trying until the player is on screen. A sideways drag still skips.
- A mixed playlist (Spotify's Mix pill on the curation row) draws a soft gradient halo around Play. It turns once every 9 seconds, can take colours from the cover, and starts the first time the capsule is on screen.
- Playlist ⋯ puts Mix above Sort. Mix takes its word, and a second line when the pill has one, from Spotify's pill. Both rows fire Spotify's buttons.
- A download control Spotify already marks downloaded stays downloaded, and a tap does not start the download again.
- The Now Playing time bar stays white while scrubbing. The glass thumb is the system's.
- A new song crossfades the player field once the next cover is under the middle of the list. A sharper read of the same picture does not fade again. The fade waits until the texture is ready, and that frame runs at 120 Hz.
- The player stays on the current track when the queue changes. Player state ignores a report that an older one overtakes on the main queue.
- Mod shows Build (branch, short commit, `-dirty` when the tree was dirty) beside Version. SGLog also keeps a short on-phone file, with Share logs and Clear logs.

## Fixes

- Search is recognised by Spotify's `spotify:find` URI (the Italian title "Ricerca" does not contain "search"), so it stays the trailing circle after Reset nav bar too.
- Search is the tab bar's prominent tab, so UIKit draws it as the trailing circle and Home and Library stay in the leading platter. The mini player can sit between them. Search does not open UIKit's own field on the empty stand-in page.
- Hidden navbar tabs stay off the glass bar when Spotify lays the row out again.
- The last leading tab is no longer the search circle. Only Search is a `UISearchTab`, so a hidden Create tab cannot turn Library into a one-letter circle.
- The Now Playing sheet stays behind the glass ⋯ menu. One outside tap closes that menu. The menu opens on the tap.
- Search's field focuses on the first tap of the Search tab, including when the tab already looks selected.

## Removed / not included

- Jam probe (Run Jam probe, Share last probe) and its notes.
- Stats probe and the deep stats probe, including their Mod rows. They crashed and are not in this tree.
- Custom tab-bar layout: platter sliding, `itemWidth`, title shortening, and the flags that had turned those passes off.
- Scroll-up expand and the other mini-player expand/minimize hooks. The bar is not driven by hand.
- Navbar view dumps, tab-bar view dumps, and per-scroll / per-layout log spam.
- The Account page edits that landed after this work. They are not part of this diff.
