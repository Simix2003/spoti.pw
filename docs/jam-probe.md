# Jam probe

A read-only dump for one phone. It does not join a Jam, change the queue, or open a connection. It does not run at launch. Nothing was hooked: the walk uses the class list, the views on screen, and the player state the mod already reads.

The file is `Documents/spotifyplus-jam-probe-<yyyyMMdd-HHmmss>.txt`. One line is logged as `jam probe:`.

## Run it

1. Start a Jam, or join one. Open the Jam screen and open the queue so the rows (who added each track) are on screen.
2. Open Spotify’s settings, then **Mod Settings**, then **Mod**.
3. In the **Debug** section, open **Jam probe**.
4. Tap **Run Jam probe now**.
5. Within 3 seconds, switch back to the Jam screen (and the queue). The probe reads whatever is on screen when the 3 seconds end.
6. Wait for the toast that says the probe was saved.
7. Go back to **Jam probe** and tap **Share last probe**. AirDrop or save the file.

If the toast says it could not save, the walk still tried; the `jam probe:` line says `could not write`.

## What to send back

- The dump file from **Share last probe**.
- The `jam probe:` line (one summary per run).
- Screenshots of the Jam screen, the participant list, and the queue with who added each track.

## Second run

Do the same steps twice and send both files:

- Once in a Jam you are in alone.
- Once after a friend has joined.
- With several tracks in the queue that different people added, the queue left open.

The two files are how we see what changes when a Jam is active. The probe does not decide that on its own.

## What the file contains

- Loaded classes whose names contain `jam`, `participant`, `collaborat`, `listening`, `party`, `member`, `queue`, `social`, `session`, or `shared`, grouped by image. Each kept class lists its superclass, protocols, ivar names and type encodings, property names, and method names. Methods are not called.
- The view controllers on screen, and views whose class or accessibility text matches those words. Matching controllers get one level of readable fields (strings, numbers, array counts, element class names, string fields on those elements).
- Visible table and collection cells: class, labels, accessibility text, and button targets when the control looks like a Jam or Encore button.
- The current track, artist, URI, paused or playing, position, and the player’s own upcoming tracks, through `SGPlayerState`.

Fields whose names contain `token`, `secret`, `auth`, `password`, or `cookie` are left out. A string that already looks like a bearer token or an access token is replaced with `[redacted]`. Participant names are not masked.
