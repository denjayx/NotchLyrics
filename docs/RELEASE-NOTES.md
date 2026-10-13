# v0.1.0-beta.2

A more responsive notch interaction, an integrated tool section and a compact lyric-timing ruler.

## Changes since Beta 1

- Hover shows artwork, title, artist and playback controls; click opens the full lyric panel.
- Wider preview and expanded layouts, larger lyrics and rounded expanded corners.
- Continuous spring-based resizing preserves motion when interactions reverse mid-transition. The playback header stays mounted during expansion.
- Tools now share the main panel and its black-to-charcoal gradient: Pin, Audio delay, Always show lyrics, Refresh lyrics and Quit.
- Immediate, exclusive native hover popovers and subtle button hover backgrounds. Plus/minus buttons have no tooltip.
- Compact timing ruler with a narrow center emphasis, small outer ticks and neutral plus/minus buttons. Drag left or press plus for earlier lyrics; drag right or press minus for later lyrics. Audio playback is unchanged.
- Top-edge clicks are handled by mouse-event monitors, including an inclusive physical-pixel boundary check.
- Updated usage and technical documentation. Packaging derives the beta suffix from the bundle build number.

## Install

Download **NotchLyrics-0.1.0-beta.2-universal.dmg**, open it, and drag the app to Applications. Quit the old app before replacing it. Requires Spotify desktop and macOS 13 or newer.

**Not notarized:** this beta is ad-hoc signed. macOS may block first launch. If you trust this release, use System Settings → Privacy & Security → Open Anyway after attempting to open it. Managed Macs may prohibit this. Allow Spotify Automation when prompted. See README for full instructions.

## Verification

Verified on the final release artifact:

- Optimized arm64 and x86_64 builds, with both architectures in the packaged universal executable.
- Bundle version 0.1.0, build 2; native Assets.car and ICNS icon resources.
- Strict ad-hoc signature verification, DMG integrity check and SHA-256 verification.
- Read-only DMG mount; Applications shortcut and Beta 2 install notes present.
- App launched from the final DMG on Apple Silicon; Spotify metadata, synced lyrics, playback controls and integrated tools displayed. Audio-delay editor opened with the saved value.
- Source-derived checks passed for spring convergence and interrupted transitions, timing drag direction/steps/bounds, and top-edge boundary coordinates at 1x/2x/3x scale.

## Known limits

Runtime testing is limited to Apple Silicon. Intel and older macOS runtime behavior remain untested. A separate-Mac, quarantined-download test has not been performed. Automated UI tooling could not click the exact topmost screen pixel; boundary logic was checked independently. Ad-hoc signature verification does not mean Gatekeeper approval or notarization.

Lyrics availability and timing depend on LRCLIB and track version. Spotify web playback and remote Connect are not supported. Only the first display is targeted. No auto-updater. No affiliation with Spotify or Apple.
