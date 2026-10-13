# Technical overview

NotchLyrics is a native, single-process macOS accessory app. The runtime is in `main.swift`; build and distribution scripts are separate. No package manager dependencies or server are required.

## Component map

| Component | Responsibility |
| --- | --- |
| `Player` | Main-actor observable state, Spotify polling/commands, playback clock, lyrics fetch/cache/parser, artwork loading and preferences |
| `Delegate` | App lifecycle, menu bar item, screen geometry, two NSPanel windows, hover tracking and window transitions |
| `NotchView` | Collapsed artwork/EQ; shared preview/full header, lyrics and integrated tool section |
| `ThreeLyrics` | Previous/current/next lines; active line can wrap; identity-based transitions |
| `ToolSection` | SF Symbols toolbar for pin, timer-based delay editor, always-show lyrics, refresh and quit; English tooltips and optional timing ruler |
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

There are **two native NSPanel windows**: the main notch panel and the persistent lyric pill. The tool section is inside the same continuous gradient and notch silhouette as the main content, without an island gap or divider. It is not a separate native window.

The main window is borderless and nonactivating, above the menu bar, and configured for Spaces/fullscreen auxiliary behavior. Screen geometry uses the first NSScreen, safeAreaInsets and auxiliary top areas when available, with a status-bar fallback. Coordinates are aligned to backing pixels. External-monitor routing is not implemented.

The main panel has idle, hover-preview and click-expanded states. Hover expands only to a 52 pt playback row below the menu bar, with 32 pt artwork, title/artist and previous/play/next controls. Preview width is max(380, cameraWidth + 156), compared to cameraWidth + 92 at idle. The same persistent header is used at preview and full sizes; content and animatable corner radius use a spring(response: 0.32, dampingFraction: 0.96). Leaving preview schedules a cancellable 100 ms collapse checked against current pointer bounds. Clicking the strip, preview artwork/background or menu action opens the full panel. Global and local mouse-down monitors close it for clicks outside its frame unless pinned; monitor handles are removed on app termination. Leaving hover does not close a click-expanded panel. The 30 ms pointer timer coordinates preview hover, exclusive tool hover and pill proximity suppression. NotchFrameMotion integrates an exact critically damped size spring (omega 24) on a common-run-loop timer up to 120 Hz, anchoring the window top edge and center. Interrupted transitions preserve velocity and retarget from continuous internal geometry instead of rounded window coordinates; repeated requests for the same target do not restart motion. The timer stops after settling. Lyric transitions use 460 ms. Reduce Motion disables the corresponding SwiftUI animations and decorative EQ motion.

Expanded width is `max(460, cameraWidth + 180)`; the same value drives active-lyric height measurement. Main content height follows an NSString estimate of the active lyric's multiline height, with a minimum height. Active lyrics use 20 pt semibold; adjacent lines use 16 pt. Expanded bottom corners morph to 36 pt (preview 24 pt, idle 14 pt). There is no vertical screen-height limit for extreme text. Previous/next lines are compact; the active main lyric is not truncated or scrolled horizontally.

The integrated tool section occupies 52 pt while its editor is closed, or 114 pt when open. The main window height is barHeight + mainContentHeight + toolSectionHeight. Pin and the timer-based editor trigger live here instead of in the track header. Collapsing the main panel closes the editor. The compact editor uses the full panel width minus 18 pt on each side and is 56 pt tall, with a 24 pt ruler plus 4 pt padding above/below only the ruler and 13 pt value readout. TimingRulerMarks interpolates drawn values for button/reset changes, while direct drag remains unanimated to follow the pointer. LyricTimingRuler draws ticks with Canvas using a localized Gaussian peak (18 pt spread) around the fixed center. Center ticks reach 14 pt regardless of major/minor status, while outer heights remain 3.6/2.7 pt and strokes remain 0.65 pt. The editor height remains compact. Scale and opacity smoothly follow position during drag/animation. Plus/minus use neutral white at 65% opacity; the value readout remains green. The ruler has a fixed centered pointer; DragGesture moves the scale by 10 pt per 100 ms, snapping and clamping to ±5000 ms. VoiceOver increment/decrement also adjust by 100 ms. The saved offset always applies. Plus/minus buttons intentionally have no hover tooltip. The control/value/reset row has an extra 12 pt horizontal inset on top of the section’s 18 pt, matching the 30 pt lyric/header and toolbar inset, while the ruler retains the wider 18 pt inset. Refresh evicts the current track cache before polling. One shared gradient runs from black at the screen edge to charcoal below.

The lyric pill appears only when enabled, playback is running, the main panel is idle (neither preview nor full), and the pointer is outside its suppression bounds. It is centered below the canonical **collapsed** notch frame, not the current animated frame. This prevents the pill from staying under the expanded window until the next lyric change.

The pill follows the text width with a maximum of 420 pt and a screen-width constraint. It is a single centered line; excess text is clipped around the center without a marquee. Pointer proximity expands the hit bounds by 12 pt; a further 4 pt exit margin prevents flicker. Pause or opening the main panel hides it.

The pill uses Liquid Glass on macOS 26+ and standard material on older systems. Reduce Transparency uses a solid fallback. The main panel and integrated tool section share a black-to-charcoal gradient. EQ animation is decorative, not derived from audio analysis.

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

ToolHoverRegionsKey collects the exact SwiftUI button bounds in the named notchContent coordinate space. Toolbar buttons explicitly occupy 32 × 28 pt. The existing 30 ms pointer timer converts screen position to hosting-view coordinates and selects at most one matching target. Player.hoveredTool drives the highlight; Delegate owns one NSPopover. Changing targets closes the old popover before immediately showing the new one; there is no intentional tooltip delay. Display rechecks the current target. Closing the main panel clears hover. There are no independent per-button timers or AppKit tracking rectangles. Reset also registers a region; plus/minus deliberately do not. Popovers have native chrome, ignore mouse events, and do not animate.

### Physical top-edge clicks

NotchTopEdgeHit explicitly includes screen.maxY and both horizontal endpoints in a two-physical-pixel band, using the display backing scale. Both local and global mouse-down monitors route left clicks in this band to the panel toggle, covering events delivered to the app or menu-bar system window. Local routing uses the event window location converted to screen coordinates and consumes handled edge events to prevent a second SwiftUI button toggle. Other panel controls keep their normal click handling. Boundary checks were tested at 1x, 2x, and 3x with a nonzero screen origin.
