# Sorting a mixed playlist by Recently added

Research only. No hook was added. Checked against this checkout on 2026-09-30: no `trees/` dump and no Spotify binary, so a class that is not already named here cannot be proved.

## What the mod already does

The redesigned playlist closes Spotify's pill row and puts Sort on the ⋯ sheet (`Redesigned/Playlist/PlaylistMenu.x`). That row fires a control Spotify already drew:

- the header button `Components.Header.UI.Toolbar.Button`, when the page has one (`PlaylistHeader.x`, `SGRPlaylistTakeSort`)
- otherwise the curation pill whose Encore glyph name contains `sort`, `arrowupdown`, or `filter`

The sheet that opens, the rows on it, and the order it applies are Spotify's. Recently added is one of the choices Spotify documents for a playlist sort (mobile: the sort control above the list, then Recently added, including the direction arrow). The safe way to use it is that sheet: ⋯, Sort, then the row Spotify shows.

## Why the mod does not pick Recently added itself

Nothing in this checkout names the sort sheet's class, a row identifier, or a selector that applies a sort. The same limit is why `PlaylistMenu.x` does not insert rows into Spotify's menu table: the sheet's items come from Swift factories with no object to read. Choosing "Recently added" from here would mean matching a localized label ("Recently added", "Aggiunti di recente", and the rest) and synthesizing a tap on an unproven view. That is the hack this pass does not do.

## What Mix changes about order

Mix (`ListPlatform.ToolbarActions.MixButton`) is Spotify's playlist-transition control, not a sort. Spotify's help calls the result a mixed playlist (Italian: playlist mixata; the button is Mixa). Turning it on stores transitions between adjacent tracks and shows BPM and key. Spotify's own reorder for that state is Smart Reorder, by BPM and key, reached from Mix and then Edit (Spotify newsroom, 2026-02-25). That screen is not proved here either, and it is not Recently added.

Support does not describe Recently added as rewriting a mixed playlist's stored order. A view sort and the order the transitions were saved against are different things. Forcing a sort from the mod could leave a transition on a pair it was not saved for, and there is no proved call that rebinds them.

If Spotify still offers Recently added on the sort sheet while Mix is on, tapping that row is Spotify's behavior and the mod already opens the sheet. If the row is absent, the order Spotify keeps for a mix is the one Smart Reorder edits, or the regular playlist order after Mix is turned off with the same pill.
