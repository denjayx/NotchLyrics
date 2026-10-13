# NotchLyrics

<img src="Assets/AppIcon.png" width="128" height="128" alt="NotchLyrics icon">

A small macOS menu bar companion for Spotify, with synced lyrics in the notch.
Built with SwiftUI and AppKit. Personal beta, shared with friends.

[**Download the DMG**](https://github.com/denjayx/NotchLyrics/releases/tag/v0.1.0-beta.2) · [Report an issue](https://github.com/denjayx/NotchLyrics/issues)

## Preview

<img src="docs/media/notchlyrics-demo.gif" width="800" alt="NotchLyrics demo showing the idle notch, hover playback preview, expanded lyric panel and floating lyric pill">

Hover for track details and playback controls. Click to open lyrics and tools.

[Watch or download the full demo](docs/media/notchlyrics-demo.mp4) · 20 seconds, no audio.

## Requirements

- macOS 13 or newer.
- Spotify desktop installed locally; browser playback and remote Spotify Connect are not supported.
- Apple Silicon or Intel. The universal binary contains both architectures; runtime verification has only been performed on Apple Silicon.
- Internet access to fetch lyrics and album artwork.

## Install

Download `NotchLyrics-0.1.0-beta.2-universal.dmg` from **Releases → Assets**, open it, then drag **NotchLyrics.app** to **Applications**. Eject the disk image and launch the installed app.

**This beta is ad-hoc signed and not notarized by Apple.** macOS may block the first launch. If you trust the release, attempt to open it once, then go to **System Settings → Privacy & Security → Open Anyway** and confirm. Managed Macs may disallow this. Do not disable Gatekeeper globally. [Apple’s opening instructions](https://support.apple.com/en-us/102445).

Open Spotify and allow NotchLyrics to control it when prompted. No Dock icon appears: the app lives in the menu bar.

## Use

- Hover the notch for a compact artwork, title/artist and playback preview. Click the notch, preview artwork or preview background to open the full lyric panel. Clicking the notch again or clicking outside closes the full panel unless outside dismissal is pinned. Hover alone never opens the lyrics/tools panel.
- Use previous, play/pause and next without switching to Spotify.
- Pin keeps the main panel open when clicking outside. Clicking the notch again still closes it.
- An integrated bottom tool section contains Keep panel open, Audio delay, Always show lyrics, Refresh lyrics, and Quit. SF Symbols use green active states and English native hover popovers and subtle hover backgrounds.
- The timer icon opens the audio-delay ruler within the tool section. Drag the ruler left for earlier lyrics or right for later lyrics, in 100 ms steps. A fixed center pointer selects the value; the plus/minus buttons have no tooltip. Timing is always applied; reset to 0 ms for no offset. Refresh lyrics clears the current track’s cached lyrics before requesting them again.
- Positive timing makes lyrics appear earlier; negative timing makes them appear later. Audio playback itself is unchanged.
- The floating lyric pill hides while paused, while the main panel is open, or when the pointer approaches it.
- Quit using the power icon in the bottom toolbar, the music-note menu bar item → **Keluar**, or right-click the notch.

Lyrics depend on [LRCLIB](https://lrclib.net). Some tracks have no synced lyrics or use different timing for live/remastered versions. Spotify supplies track metadata and playback position; the app fetches timestamps and selects the active lyric locally.

## Screenshots

<details>
<summary>View the lyric panel, timing controls and floating lyrics</summary>

**Synced lyrics** — previous, current and next lines, with playback controls and tools in one panel.

<img src="docs/media/lyrics-panel.png" width="700" alt="Expanded NotchLyrics panel with album artwork, track metadata, playback controls, three lyric lines and the integrated toolbar">

**Lyric timing** — adjust in 100 ms steps. Positive values show lyrics earlier; audio playback stays unchanged.

<img src="docs/media/lyric-timing.png" width="700" alt="Audio delay editor expanded below the toolbar, showing the compact timing ruler, minus and plus controls, reset and a positive 800 ms offset">

**Always show lyrics** — a small current-line pill beneath the idle notch. It hides while paused, while the player is open, or when the pointer approaches.

<img src="docs/media/floating-lyrics.png" width="800" alt="Idle notch with album artwork and animated playback bars, and a floating current-lyric pill below it">

</details>

Screenshots and the demo show third-party album artwork and lyrics as part of the app interface. Those materials remain the property of their respective rightsholders and are not covered by this repository’s MIT license.

## Privacy

Track title, artist, album and duration are sent to LRCLIB to find lyrics. Artwork is fetched from the URL supplied by Spotify. There is no analytics, account system or saved listening history. Preferences are stored locally; lyrics are cached in memory while the app is running.

## Build from source

Use macOS with Xcode 27 (the toolchain verified for this release), its command-line tools selected, and its license accepted. No third-party package dependencies.

```sh
./build.command          # Build universal app and open it
./package-dmg.command    # Build, sign ad hoc, package and verify DMG
```

Outputs: `NotchLyrics.app` and `dist/`. The build compiles `Assets/NotchLyrics.icon` with Apple's `actool`, including native icon resources and an ICNS fallback. Open the `.icon` document in Icon Composer to edit its three vector layers.

For distribution signing, set `NOTCHLYRICS_SIGN_IDENTITY` to your Developer ID Application identity. The build enables hardened runtime and the Apple Events entitlement. **Signing alone does not notarize the app**; submit and staple the distribution separately before claiming it is notarized.

## Beta limitations

Only the first display is targeted. Multi-monitor arrangements, fullscreen behavior and older macOS releases need more testing. Lyric timing is interpolated from Spotify's playback position; it is not sample-accurate audio synchronization. This release has no auto-updater: download future versions from Releases.

See [technical documentation](TECHNICAL.md) for implementation details. [Release notes](docs/RELEASE-NOTES.md) record what was verified for this beta.

## License and credits

[MIT](LICENSE), © 2026 Deni Wijaya. The license applies to this project's code and original assets, not third-party lyrics, album artwork or trademarks. Not affiliated with Spotify or Apple. Lyrics provided by [LRCLIB](https://lrclib.net); native icon authored with Apple Icon Composer.
