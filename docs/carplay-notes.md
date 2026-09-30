# CarPlay

Research only. No code. Checked against this checkout on 2026-09-30. There is no `trees/` dump and no Spotify binary, so no CarPlay class was available to prove, and none was hooked.

## What a sideloaded tweak can and cannot be

spoti.pw is a tweak inside Spotify, not a CarPlay app of its own. CarPlay only shows an audio app that has the restricted entitlement `com.apple.developer.carplay-audio` (CarPlay Developer Guide, the audio row; `CPNowPlayingTemplate` is documented as available only with that entitlement). Apple grants it per App ID. A development or free provisioning profile does not include it, and a tweak dylib cannot add it to the process.

`scripts/install.sh` re-signs the IPA with the user's profile (`zsign`). A restricted entitlement that the profile does not carry does not survive as a CarPlay entitlement the car will honour. After that resign, the sideloaded Spotify typically does not appear as a CarPlay audio app, even though the stock App Store build does. The pipeline does not try to keep or invent this key.

TrollStore's fakesign path in `scripts/pipeline.sh` keeps the entitlements already on a sliced binary (`ldid -S` of the dumped plist, for the widget). That is not a CarPlay grant. If the dumped entitlements still contain `com.apple.developer.carplay-audio` and the device accepts them, Spotify's own CarPlay session is Spotify's. The mod still has no scene of its own: Info.plist would need a `CPTemplateApplicationSceneSessionRoleApplication` scene, and the entitlement above, before CarPlay would load a template the tweak registered. This repo's plist merge (`plist/liquid-glass.plist`) does not add one.

`scripts/install.sh` also notes a related limit that is not CarPlay-specific: MediaRemote opens the now-playing app by the `application-identifier` entitlement. A profile whose App ID is not a wildcard and does not match the bundle id leaves the lock-screen card unable to open the app.

So the only CarPlay surface this mod can affect is one Spotify already has, on a build whose signature still carries the audio entitlement. A resigned IPA without that entitlement has no CarPlay UI for the tweak to change.

## Lyrics and MPNowPlayingInfo

`Shared/LockScreenLyrics/LockScreenLyrics.x` already writes the line being sung into the system now-playing dictionary, under `MPMediaItemPropertyArtist`, and refreshes `MPNowPlayingInfoPropertyElapsedPlaybackTime` so the scrubber does not jump. The timer is 0.25 s and runs only while playback is moving. It does not set `MPMediaItemPropertyLyrics`. `LockScreenLyrics.h` names CarPlay as one of the places that read this dictionary, next to the lock screen, the Dynamic Island, and Control Center.

That matches the public Now Playing path. `CPNowPlayingTemplate` displays `MPNowPlayingInfoCenter` / `MPNowPlayingSession`: title, artist, album, artwork, elapsed time, playback rate, and the buttons on the shared template. It does not draw a lyrics region. The older audio guide lists the same keys (title, artist, artwork, rate, queue index) and does not list a lyrics key. Putting the line in `MPMediaItemPropertyLyrics` would not create a lyrics view on the car or on the lock screen.

Where the artist substitution can show is the artist slot of that same template, and only while CarPlay is actually presenting this process's now-playing info. Two limits sit on top of that:

- Apple's CarPlay rules for audio apps say never to show song lyrics on the CarPlay screen, and to use the now-playing artwork slot for an album cover. A line written into the artist field is lyrics on that screen. This pass does not add a path that pushes lines to the car, and it does not turn the existing lock-screen switch off either: that switch is the lock screen's, and whether a head unit repaints the artist row on each 0.25 s update was not run.
- Head units often keep the artist string from the track change and ignore later edits. There is no way to know that from this checkout.

`Shared/LockScreenArtwork/LockScreenArtwork.x` adds an animated clip under an iOS 26 `MPNowPlayingInfoCenter` animated-artwork key, through its own `setNowPlayingInfo:` hook, so the lock-screen lyrics rewrite does not drop it. Those keys are the lock screen's. CarPlay's now-playing artwork is `MPMediaItemPropertyArtwork`, which this file leaves as Spotify set it.

There is no proved Spotify CarPlay class (`CPTemplateApplicationScene`, `CPNowPlayingTemplate`, or a Spotify wrapper) in `tweak/Sources/Headers` or in a tree. Hooking one to add a button or a list of lines would be an unproved hook, and a lyrics list would be the thing the CarPlay rules forbid. Not done.

## Entitlements, short list

| Key | What it gates here |
|---|---|
| `com.apple.developer.carplay-audio` | Spotify's CarPlay audio UI, including the shared now-playing template. Restricted. Not in a normal sideload profile. The tweak cannot add it. |
| `CPTemplateApplicationSceneSessionRoleApplication` | The scene CarPlay loads for that audio app. Spotify's own binary may already declare it. This repo does not add one. |
| `application-identifier` | Which bundle MediaRemote launches from the lock-screen card (`scripts/install.sh`). A mismatched resign opens nothing. |
| Animated-artwork keys (`MPNowPlayingInfoProperty3x4AnimatedArtwork` and the 1:1 key) | Lock screen on iOS 26 (`LockScreenArtwork.m`). Not a CarPlay entitlement, and not what the car's artwork slot reads. |
