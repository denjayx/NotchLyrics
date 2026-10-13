# Technical overview

NotchLyrics is a native, single-process macOS accessory app. The runtime is in `main.swift`; build and distribution scripts are separate. No package manager dependencies or server are required.

## Component map

| Component | Responsibility |
| --- | --- |
| `Player` | Main-actor observable state, Spotify polling/commands, playback clock, lyrics fetch/cache/parser, artwork loading and preferences |
| `Delegate` | App lifecycle, menu bar item, screen geometry, two NSPanel windows, hover tracking and window transitions |
| `NotchView` | Collapsed artwork/EQ; expanded header, controls, lyrics and optional settings island |
| `ThreeLyrics` | Previous/current/next lines; active line can wrap; identity-based transitions |
| `ToolsPanel` | SF Symbols toolbar for pin, timer-based delay editor, always-show lyrics, refresh and quit; English tooltips and optional timing slider |
| `PersistentLyric` | Separate floating lyric pill; native glass when available, material fallback |
| `NotchSilhouette` | Custom path with concave upper shoulders and rounded lower corners |

## Playback and lyric flow

1. A serial DispatchQueue runs Spotify AppleScript so the main actor remains available for UI work.
2. Metadata polling occurs approximately every 500 ms. A busy flag prevents overlapping polls. Spotify's `com.spotify.client.PlaybackStateChanged` distributed notification also triggers a poll.
3. The response includes track ID, title, artist, album, artwork URL, duration (milliseconds), position (seconds), and playing status.
4. A 30 Hz timer in the common run-loop mode advances an interpolated position using system uptime while playing. New Spotify samples correct its anchor; paused playback stops interpolation.
5. A track change clears lyrics and cancels the previous fetch. `GET https://lrclib.net/api/get` receives title, artist, album and rounded duration. Requests time out after 20 seconds. Successful responses are cached in memory by Spotify track ID.
6. Responses are applied only if their track ID still matches. HTTP 429/503 uses Retry-After, or 60 seconds, to prevent immediate retries. There is no automatic scheduled retry after the backoff; the Retry action or a subsequent track request is needed.
7. Timestamped LRC rows are parsed, including multiple timestamps for one line, and sorted. The active line is the last timestamp at or before `position + lyricAdvanceMS / 1000`.
8. Views observe published state independently of hover. Opening the panel does not start or restart lyric synchronization.

Artwork is loaded independently through URLSession from Spotify's HTTPS URL, with cancellation and stale-result protection. Instrumental, missing, plain-only and failed lyrics produce status text rather than fabricated synchronized lyrics.

## UI and window coordination

There are **two native NSPanel windows**: the main notch panel and the persistent lyric pill. The tools island is a SwiftUI subview inside the main window; it is not a third native window. This keeps the hover region connected across the visual gap.

The main window is borderless and nonactivating, above the menu bar, and configured for Spaces/fullscreen auxiliary behavior. Screen geometry uses the first NSScreen, safeAreaInsets and auxiliary top areas when available, with a status-bar fallback. Coordinates are aligned to backing pixels. External-monitor routing is not implemented.

The main panel tracks the pointer roughly every 30 ms, including the physical top edge. Leaving schedules a short delayed collapse; pin prevents it. Main-window resize animates over 160 ms. Content expand/collapse uses 140 ms; lyric transitions use 460 ms. Reduce Motion disables the corresponding SwiftUI animations and decorative EQ motion.

Expanded width is `max(380, cameraWidth + 100)`. Main content height follows an NSString estimate of the active lyric's multiline height, with a minimum height. There is no vertical screen-height limit for extreme text. Previous/next lines are compact; the active main lyric is not truncated or scrolled horizontally.

A 44 pt toolbar island is always present while the main panel is expanded, with an 8 pt visual gap. Pin and the timing editor trigger live here instead of in the track header. The timing editor is closed by default; opening it grows the island to 92 pt. Collapsing the main panel closes the editor. The timer button opens or closes the timing editor; there is no separate delay-enable toggle. The saved offset always applies. Refresh is always available and evicts the current track cache before polling. Main expanded content fades vertically from black at the screen edge to the toolbar’s charcoal surface, keeping the physical notch camouflaged.

The lyric pill appears only when enabled, playback is running, the main panel is collapsed, and the pointer is outside its suppression bounds. It is centered below the canonical **collapsed** notch frame, not the current animated frame. This prevents the pill from staying under the expanded window until the next lyric change.

The pill follows the text width with a maximum of 420 pt and a screen-width constraint. It is a single centered line; excess text is clipped around the center without a marquee. Pointer proximity expands the hit bounds by 12 pt; a further 4 pt exit margin prevents flicker. Pause or opening the main panel hides it.

The pill uses Liquid Glass on macOS 26+ and standard material on older systems. Reduce Transparency uses a solid fallback. Main and tools panels use dark solid backgrounds. EQ animation is decorative, not derived from audio analysis.

## Preferences and permissions

- `alwaysShowLyric`: persistent bool in UserDefaults.
- `lyricAdvanceMS`: global timing adjustment, -5000 to +5000 ms, 100 ms steps. Positive advances lyrics. Legacy `lyricOffset` is read with inverted sign if the new key does not exist.
- Pin and timing-editor visibility are transient.
- Spotify Apple Events require user permission; Info.plist contains NSAppleEventsUsageDescription.
- No OAuth, login, analytics or listening-history database.
- Track metadata goes to LRCLIB; artwork requests go to Spotify-provided URLs.

The prototype bundle identifier `local.notchlyrics.prototype` is retained for this beta to preserve preference continuity. Changing signing identity or installing a different build can still require reviewing Automation permissions.

## Build and distribution

`build-icon.command` invokes Apple's actool on `Assets/NotchLyrics.icon`, producing Assets.car and an ICNS fallback in `.build-cache/icon-resources`. The original .icon contains three SVG layers and native material settings; edit it using Icon Composer.

`build.command` compiles optimized arm64 and x86_64 binaries with deployment target macOS 13, combines them using lipo, copies the icon resources and Info.plist, and signs the bundle. Xcode 27 is the verified toolchain. The default signature is ad hoc. An optional NOTCHLYRICS_SIGN_IDENTITY enables Developer ID signing, hardened runtime, and the Apple Events entitlement. Signing is not notarization.

`package-dmg.command` builds without launching, creates a clean staging directory, copies the app, adds an Applications symlink and installation notes, creates a compressed UDZO disk image, verifies it, and writes SHA256SUMS.txt. The staging directory is removed on exit. Outputs go to ignored `dist/`.

The first GitHub release is a pre-release and is **not notarized**. Do not claim Gatekeeper approval or imply that a DMG provides trust. A future notarized release requires Developer ID credentials, submission with Apple's notary service, stapling, and download-path testing on a separate Mac.

## Known engineering limits

- No sample-accurate synchronization; polling and interpolation can drift between authoritative samples.
- LRCLIB coverage, timestamps and metadata matching can differ for live/remastered versions.
- No disk cache, automatic provider fallback or word-level lyrics.
- First-display behavior and hard-coded geometry need wider testing across monitors, scaling and Spaces.
- NSString measurement can differ from SwiftUI layout for unusual fonts/emoji/scripts.
- Timers and observers are process-lifetime objects without reusable service teardown.
- Strict Swift 6 concurrency has not been audited; a successful compiler invocation is not proof of strict-concurrency correctness.
- Universal compilation verifies two architectures, not runtime behavior on Intel or every supported macOS version.
- No auto-updater. Users replace the installed app manually after quitting it.

## Release verification

See `docs/RELEASE-NOTES.md` for the checks performed on the actual release artifact. For future releases, verify track changes, stale network responses, pause/resume/seek, timing controls, hover from all directions, pill return position, long lyrics, accessibility preferences, Automation permission prompts, and a quarantined download on another Mac.

### Toolbar tooltip implementation

Toolbar and timing controls use native NSPopover help bubbles anchored to the control bounds, with centered text, system chrome and arrow positioning. PanelHoverRegion uses an AppKit tracking area with activeAlways, so hover detection works while the panel is not key. A cancellable 350 ms delay precedes display; exit or view removal closes the popover. Popovers ignore mouse events and are not animated. Toolbar buttons share this hover state for a subtle background highlight; Reduce Motion disables the highlight animation. This replaces the previously left-aligned SwiftUI overlay.
