# v0.1.0-beta.1

First public beta of NotchLyrics, a Spotify lyrics companion for the macOS notch.

## Included

- Now Playing artwork, playback controls and decorative EQ.
- Three-line synchronized lyric panel and optional floating current-lyric pill.
- One-click settings island with lyric timing adjustment.
- Native Icon Composer app icon with ICNS fallback.
- Universal binary for Apple Silicon and Intel; macOS 13+.
- MIT-licensed source and reproducible local build/DMG scripts.

## Install

Download **NotchLyrics-0.1.0-beta.1-universal.dmg**, open it, and drag the app to Applications. Requires Spotify desktop.

**Not notarized:** this beta is ad-hoc signed. macOS may block first launch. If you trust this release, use System Settings → Privacy & Security → Open Anyway after attempting to open it. Managed Macs may prohibit this. Allow Spotify Automation when prompted. See README for full instructions.

## Verification

Verified on the release artifact:

- Optimized arm64 and x86_64 compilation; both architectures present in the universal executable.
- Native Assets.car and NotchLyrics.icns packaged with matching bundle icon keys.
- Strict ad-hoc signature verification after packaging.
- DMG checksum verification and read-only mount; Applications symlink and install notes present.
- App launched from the final DMG on Apple Silicon; Spotify metadata and paused state displayed.
- Main panel opened and Settings exposed the toggle and timing slider in one click; missing-lyrics state displayed correctly.

Intel and older macOS runtime behavior remain untested. A separate-Mac, quarantined-download test has not been performed. Ad-hoc signature verification does not mean Gatekeeper approval or notarization.

## Known limits

Lyrics availability and timing depend on LRCLIB and track version. Spotify web playback and remote Connect are not supported. First-display placement, no auto-updater. No affiliation with Spotify or Apple.
