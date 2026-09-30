# Stats probe

A read-only dump of the **Statistiche di ascolto** page, taken from that page. It does not call the network, change playback, or edit a model. It does not run at launch. The walk reads classes already loaded, the view controllers on that screen, their ivars, and the views and cells that already exist.

The file is `Documents/spotifyplus-stats-probe-<yyyyMMdd-HHmmss>-<page>.txt`. The page hint is a short name for the screen that was up (`home`, `minuti`, `brani`, `brani-amici`, `artisti`, `artisti-amici`, `preferiti`). One line is logged as `stats probe: page <class> title <...>` when a stats page is detected. That line is also in the on-phone log (`docs/logs.md`), so **Share logs** can confirm the page was recognised before any dump.

## Run it

1. Open **Statistiche di ascolto** (listening stats). The home grid is enough for the first file.
2. A small **Probe** pill sits at the lower right while that page is on screen. It is only there for this family of pages.
3. Tap **Probe**. The phone taps back, a toast says the file was saved, and the share sheet opens.
4. AirDrop or save the file.
5. Open each sub-page and tap **Probe** again, one file each:
   - **Minuti di ascolto**
   - **Brani top** (and **Brani top con amici**, if that screen is separate)
   - **Artisti top** (and **Artisti top con amici**)
   - **Brani preferiti**
6. If the share sheet was dismissed, the same files are under **Mod Settings → Mod → Debug → Share last stats probe** (the newest file only). The Jam probe row is unchanged.

The pill follows the page that is visible. Leaving the stats screens hides it. A second tap while a dump is still writing is ignored.

If the toast says it could not save, the `stats probe:` line in the log says `could not write`.

## What to send back

- One dump file per screen, from the share sheet (or the newest one from **Share last stats probe**).
- The `stats probe: page` lines from **Share logs**, so the detected class and title are in the same note.
- A screenshot of each sub-page you dumped.

The home grid and each sub-page are different files. The page hint in the file name is how they stay apart.

## What the file contains

- The page that matched: class, title, and whether the match was the class, the title, or a header label. Italian titles that count are **Statistiche di ascolto**, **Minuti di ascolto**, **Brani top**, **Artisti top**, **Brani preferiti**, and those titles **con amici**.
- The view controllers of that page, including children, with class names and ivars. Strings, numbers, dates, and URLs are printed. Arrays and dictionaries are expanded. Other objects are followed to a depth of 4. A cycle is marked and not walked again. Swift ivars that are not readable values still list the class name in the type encoding.
- The visible view tree of the page: every label’s text, accessibility id, label, and value, whether an image view has an image, and each scroll view’s content size. Image views also list string ivars one level down (an avatar URL often sits there).
- Every table and collection cell that already exists, including cells that are off screen but still held by the collection. Cells are not asked to load. Each cell lists its labels and the model objects on the cell, its view model, its presenter, and the collection’s data source, to the same depth.
- A short index of ivars whose names look like minutes listened, a friend leaderboard, avatars, play counts, trend, a weeks-in-top streak, a week or date range, or a friend who is playing now.
- Combine publishers and other observable-looking ivars, when the class or ivar name says so.
- Loaded classes whose names contain `Stats`, `Statistic`, `Insights`, `Wrapped`, `Leaderboard`, `TopItems`, `ListeningHistory`, `Minutes`, `Recap`, or `Charts`. Each kept class lists ivar names and method names. Methods are not called.
- The current track title, through `SGPlayerState`, so a friend-now-playing row can be compared with what is playing.

Fields whose names contain `token`, `secret`, `auth`, `password`, or `cookie` are left out. A string that already looks like a bearer token is replaced with `[redacted]`. The walk stops at about 400 KB. A line at the end says when the time budget or the size cap stopped it.
