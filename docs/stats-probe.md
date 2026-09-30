# Stats probe

Read-only dumps of **Statistiche di ascolto**. Nothing fetches, changes playback, or edits a model. The pills are **off by default** (Mod → Debug → Stats probe → Show Probe pills, then restart). Leave them off unless you need a dump.

Two pills sit at the lower right while the switch is on:

| Pill | File | Purpose |
|---|---|---|
| **Probe** | `spotifyplus-stats-probe-<stamp>-<page>.txt` | View tree (labels, frames, a11y) |
| **Deep** | `spotifyplus-stats-deep-<stamp>-<page>.txt` | HighlightsStats ElementKit **Props / ivars** + class index — what a redesign needs |

The page hint is `home`, `minuti`, `brani`, `brani-amici`, `artisti`, `artisti-amici`, or `preferiti`. Log lines: `stats probe:` and `stats deep:` (`docs/logs.md`).

## Run Deep (for redesign data)

1. Open **Mod Settings → Mod → Debug → Stats probe**.
2. Turn on **Show Probe pills**, then restart Spotify.
3. Open each screen and tap **Deep** (not Probe):
   - **Statistiche di ascolto** (home grid)
   - **Minuti di ascolto**
   - **I brani top con gli amici** (and top without friends if separate)
   - **Gli artisti top con gli amici**
   - **Brani preferiti**
   - **Artisti preferiti** if that screen exists
4. AirDrop or save each file from the share sheet.
5. Turn the switch **off** and restart when done.

**Share last probe** sends the newest UI or Deep file.

## What Deep contains

- Loaded classes whose names contain `HighlightsStats`, with ivar names and type encodings (methods are not called).
- Every on-screen HighlightsStats / StatsDetails / ElementKit-looking view: class, frame, a11y, nested labels, and **safe** ivars only (Foundation strings/numbers/collections). Swift / ElementKit Props show as `ivar … unread \`…\`` — reading those as objects crashed Spotify, so values are not dereferenced.
- No `valueForKey:`, no `objc_msgSend` of `props`/`model`. File is flushed after each view so a later failure still leaves a partial dump.

## What Probe contains

The lighter view-tree dump (labels, buttons, image sizes, a11y). Useful for layout; not enough for models.

## What to send back (redesign)

- One **Deep** file per screen.
- Optional matching screenshots.
- `stats deep: saved …` lines from **Share logs**.
