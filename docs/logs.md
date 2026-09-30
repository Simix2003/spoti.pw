# On-phone logs

`SGLog` still writes to the system log. The same line, with a timestamp, is appended to `Documents/spotifyplus-log.txt` on the phone. The file stays around 1 MB and keeps the newest lines. Nothing is uploaded.

Share it after you have reproduced the problem. The log is not a substitute for a screenshot.

## Share a log

1. Reproduce the issue once. Leave Spotify in the state where it went wrong.
2. Open Spotify’s settings, then **Mod Settings**, then **Mod**.
3. In the **Debug** section, check **Log file** (size and Build), then tap **Share logs**.
4. AirDrop, Save to Files, or Messages.

**Clear logs** deletes that file. Do that before a clean reproduction if the old lines would get in the way.

## What to send back

The shared `spotifyplus-log.txt`, plus what you did just before it. Lines worth keeping start with:

- `mini player:`
- `player transition:`
- `tab bar:`
- `search tab:`
- `redesign player menu:`
- `redesign kit:`
- `jam probe:`
- `stats probe:`
- `stats deep:`
- `build:`

`build:` is written once at launch and is the same branch and commit as the Build row.
