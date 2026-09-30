# Stats probe

A read-only dump of the **Statistiche di ascolto** page, taken from that page. It does not call the network, change playback, or edit a model. The Probe pill is **off by default**: turning it on hooks navigation only after a restart. Leave it off unless you need a dump.

The file is `Documents/spotifyplus-stats-probe-<yyyyMMdd-HHmmss>-<page>.txt`. The page hint is a short name for the screen that was up (`home`, `minuti`, `brani`, `brani-amici`, `artisti`, `artisti-amici`, `preferiti`). One line is logged as `stats probe: pill on leaf …` when the visible page changes, and `stats probe: saved …` after a dump. Those lines are also in the on-phone log (`docs/logs.md`).

## Run it

1. Open **Mod Settings → Mod → Debug → Stats probe**.
2. Turn on **Show Probe pill**, then restart Spotify. The pill sits at the lower right on every screen while that switch is on (Spotify hosts Statistiche di ascolto inside a page host with no matching title, so page detection alone never finds it).
3. Open **Statistiche di ascolto** (listening stats). The home grid is enough for the first file.
4. Tap **Probe**. The phone taps back, a toast says the file was saved, and the share sheet opens.
5. AirDrop or save the file.
6. Open each sub-page and tap **Probe** again, one file each:
   - **Minuti di ascolto**
   - **Brani top** (and **Brani top con amici**, if that screen is separate)
   - **Artisti top** (and **Artisti top con amici**)
   - **Brani preferiti**
7. Turn **Show Probe pill** off again and restart when you are done. **Share last probe** on the same Debug page still sends the newest file without the pill.

A second tap while a dump is still writing is ignored.

If the toast says it could not save, the `stats probe:` line in the log says `could not write`.

## What to send back

- One dump file per screen, from the share sheet (or the newest one from **Share last probe**).
- The `stats probe: pill on leaf` / `stats probe: saved` lines from **Share logs**.
- A screenshot of each sub-page you dumped.

The home grid and each sub-page are different files. The page hint in the file name is how they stay apart.

## What the file contains

- The page that matched: class, title, and whether the match was the class, the title, a child controller, or a header label. Italian titles that count are **Statistiche di ascolto**, **Minuti di ascolto**, **Brani top**, **Artisti top**, **Brani preferiti**, and those titles **con amici**.
- The view-controller chain of that page, with class names and titles.
- The visible view tree of the page: every label’s text, accessibility id, label, and value, whether an image view has an image, and frames. The walk does not read arbitrary ivars or call `valueForKey:`.

Fields whose names contain `token`, `secret`, `auth`, `password`, or `cookie` are left out. A string that already looks like a bearer token is replaced with `[redacted]`. The walk stops at about 400 KB.
