import AppKit
import SwiftUI
import QuartzCore
import Combine

struct Lyric: Identifiable { let id: Int; let time: Double; let text: String }
struct LyricsResponse: Decodable { let syncedLyrics: String?; let plainLyrics: String?; let instrumental: Bool }

@MainActor final class Player: ObservableObject {
    @Published var title = "Buka Spotify, lalu putar lagu"
    @Published var artist = "Spotify desktop • prototype"
    @Published var artwork = ""
    @Published var cover: NSImage?
    var coverTask: Task<Void, Never>?
    @Published var playing = false
    @Published var position = 0.0 { didSet { updateActiveLine() } }
    @Published var duration = 1.0
    @Published var lines: [Lyric] = [] { didSet { updateActiveLine() } }
    @Published var currentLine: Int?
    @Published var message = "Lyrics dari LRCLIB"
    @Published var expanded = false
    @Published var previewing = false
    @Published var pinned = false
    @Published var cameraWidth: CGFloat = 0
    @Published var barHeight: CGFloat = 24
    @Published var toolsOpen = false
    @Published var hoveredTool: String?
    @Published var alwaysShowLyric = UserDefaults.standard.bool(forKey: "alwaysShowLyric") {
        didSet { UserDefaults.standard.set(alwaysShowLyric, forKey: "alwaysShowLyric") }
    }
    var previewWidth: CGFloat { max(380, cameraWidth + 156) }
    var expandedWidth: CGFloat { max(460, cameraWidth + 180) }
    var activeLyricHeight: CGFloat {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 2
        let bounds = (lyricText(relative: 0) as NSString).boundingRect(
            with: NSSize(width: expandedWidth - 60, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 20, weight: .semibold), .paragraphStyle: paragraph])
        return max(28, ceil(bounds.height) + 10)
    }
    var mainContentHeight: CGFloat { max(168, activeLyricHeight + 136) }
    var toolSectionHeight: CGFloat { toolsOpen ? 114 : 52 }
    var expandedHeight: CGFloat { barHeight + mainContentHeight + toolSectionHeight }
    var lyricElapsed: Double {
        guard let currentLine, lines.indices.contains(currentLine) else { return 0 }
        return max(0, position + lyricAdvanceMS / 1000 - lines[currentLine].time)
    }
    var visibleLyrics: [Lyric] {
        let center = currentLine ?? -1
        return lines.filter { $0.time.isFinite && abs($0.id - center) <= 1 }
    }
    @Published var lyricAdvanceMS = (UserDefaults.standard.object(forKey: "lyricAdvanceMS") as? Double)
        ?? (-UserDefaults.standard.double(forKey: "lyricOffset") * 1000) {
        didSet { UserDefaults.standard.set(lyricAdvanceMS, forKey: "lyricAdvanceMS"); updateActiveLine() }
    }
    var hasSyncedLyrics: Bool { lines.contains { $0.time.isFinite } }
    func lyricText(relative: Int) -> String {
        guard hasSyncedLyrics else {
            return relative == 0 ? (lines.isEmpty ? message : "Lirik ini belum punya timestamp") : ""
        }
        let center = currentLine ?? -1
        let index = center + relative
        if index < 0 || index >= lines.count { return relative == 0 ? "♪" : "" }
        return lines[index].text.isEmpty ? "♪" : lines[index].text
    }
    var sampledPosition = 0.0
    var sampledAt = ProcessInfo.processInfo.systemUptime
    var lastPoll = 0.0
    var playbackObserver: NSObjectProtocol?
    var trackID = ""
    var fetching: Task<Void, Never>?
    var timer: Timer?
    var busy = false
    var blockedUntil = Date.distantPast
    var cache: [String: LyricsResponse] = [:]
    let queue = DispatchQueue(label: "spotify.applescript")
    func updateActiveLine() {
        let active = lines.last(where: { $0.time <= position + lyricAdvanceMS / 1000 })?.id
        if active != currentLine { currentLine = active }
    }
    func start() {
        playbackObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.poll() }
            }
        // Interpolate the playback clock between authoritative Spotify samples.
        timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let now = ProcessInfo.processInfo.systemUptime
                if self.playing { self.position = min(self.duration, self.sampledPosition + now - self.sampledAt) }
                if now - self.lastPoll >= 0.5 { self.poll() }
            }
        }
        RunLoop.main.add(timer!, forMode: .common)
        poll()
    }
    func loadCover(_ url: String) {
        guard artwork != url else { return }
        artwork = url; cover = nil; coverTask?.cancel()
        guard let remote = URL(string: url), remote.scheme == "https" else { return }
        coverTask = Task {
            guard let (data, _) = try? await URLSession.shared.data(from: remote),
                  !Task.isCancelled, self.artwork == url else { return }
            self.cover = NSImage(data: data)
        }
    }
    func script(_ source: String, completion: @escaping (NSAppleEventDescriptor?, String?) -> Void) {
        queue.async {
            var error: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
            let detail = error?[NSAppleScript.errorMessage] as? String
            DispatchQueue.main.async { completion(result, detail) }
        }
    }
    func poll() {
        guard !busy else { return }; busy = true
        lastPoll = ProcessInfo.processInfo.systemUptime
        script("""
        if application "Spotify" is not running then return {}
        tell application "Spotify"
            if player state is stopped then return {}
            set t to current track
            return {id of t, name of t, artist of t, album of t, artwork url of t, duration of t, player position, (player state is playing)}
        end tell
        """) { [weak self] result, error in
            guard let self else { return }; self.busy = false
            if let error {
                self.message = "Akses Spotify gagal: \(error)"
                self.playing = false
                return
            }
            guard let r = result, r.numberOfItems == 8 else {
                self.trackID = ""; self.fetching?.cancel(); self.lines = []
                self.title = "Buka Spotify, lalu putar lagu"; self.artist = "Spotify desktop"
                self.loadCover(""); self.playing = false; self.position = 0; self.duration = 1
                self.message = "Belum ada lagu aktif"; return
            }
            func value(_ n: Int) -> String { r.atIndex(n)?.stringValue ?? "" }
            let id = value(1)
            self.title = value(2); self.artist = value(3); self.loadCover(value(5))
            // Spotify desktop reports track duration in milliseconds.
            self.duration = max(1, (Double(value(6)) ?? 1000) / 1000)
            self.sampledPosition = r.atIndex(7)?.doubleValue ?? 0
            self.sampledAt = ProcessInfo.processInfo.systemUptime
            self.position = self.sampledPosition
            self.playing = r.atIndex(8)?.booleanValue ?? false
            if id != self.trackID {
                self.trackID = id; self.lines = []; self.fetching?.cancel()
                self.fetchLyrics(id: id, album: value(4))
            }
        }
    }
    func command(_ command: String) {
        script("tell application \"Spotify\" to \(command)") { [weak self] _, error in
            if let error { self?.message = error }; self?.poll()
        }
    }
    func apply(_ response: LyricsResponse) {
        if response.instrumental { message = "Instrumental"; return }
        if let lrc = response.syncedLyrics, !lrc.isEmpty {
            let regex = try! NSRegularExpression(pattern: #"\[(\d+):(\d+(?:\.\d+)?)\]"#)
            var parsed: [(Double, String)] = []
            for row in lrc.components(separatedBy: .newlines) {
                let ns = row as NSString
                let matches = regex.matches(in: row, range: NSRange(location: 0, length: ns.length))
                guard let last = matches.last else { continue }
                let text = ns.substring(from: last.range.location + last.range.length).trimmingCharacters(in: .whitespaces)
                for match in matches {
                    let minute = Double(ns.substring(with: match.range(at: 1))) ?? 0
                    let second = Double(ns.substring(with: match.range(at: 2))) ?? 0
                    parsed.append((minute * 60 + second, text))
                }
            }
            lines = parsed.sorted { $0.0 < $1.0 }.enumerated().map { Lyric(id: $0.offset, time: $0.element.0, text: $0.element.1) }
            message = lines.isEmpty ? "Lyrics belum tersedia" : "Synced lyrics • LRCLIB"
        } else if let plain = response.plainLyrics, !plain.isEmpty {
            lines = plain.components(separatedBy: .newlines).enumerated().map { Lyric(id: $0.offset, time: .infinity, text: $0.element) }
            message = "Lyrics tanpa timestamp • LRCLIB"
        } else { message = "Lyrics belum tersedia" }
    }
    func fetchLyrics(id: String, album: String) {
        if let cached = cache[id] { apply(cached); return }
        guard Date() >= blockedUntil else { message = "LRCLIB lagi membatasi akses. Coba lagi nanti."; return }
        message = "Mencari lyrics…"
        var url = URLComponents(string: "https://lrclib.net/api/get")!
        url.queryItems = [URLQueryItem(name: "track_name", value: title), URLQueryItem(name: "artist_name", value: artist), URLQueryItem(name: "album_name", value: album), URLQueryItem(name: "duration", value: String(Int(duration.rounded())))]
        fetching = Task {
            do {
                var request = URLRequest(url: url.url!); request.timeoutInterval = 20
                request.setValue("NotchLyrics/0.1 (personal macOS prototype)", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await URLSession.shared.data(for: request)
                try Task.checkCancellation()
                guard self.trackID == id, let http = response as? HTTPURLResponse else { return }
                if http.statusCode == 429 || http.statusCode == 503 {
                    self.blockedUntil = Date().addingTimeInterval(Double(http.value(forHTTPHeaderField: "Retry-After") ?? "60") ?? 60)
                    self.message = "LRCLIB lagi sibuk. Coba lagi nanti."; return
                }
                guard http.statusCode == 200 else { self.message = http.statusCode == 404 ? "Lyrics belum tersedia untuk versi lagu ini" : "Lyrics gagal dimuat (\(http.statusCode))"; return }
                let lyrics = try JSONDecoder().decode(LyricsResponse.self, from: data)
                self.cache[id] = lyrics; self.apply(lyrics)
            } catch {
                if !Task.isCancelled && self.trackID == id { self.message = "Lyrics gagal dimuat. Cek koneksi, lalu Retry." }
            }
        }
    }
    func retry() { cache.removeValue(forKey: trackID); trackID = ""; poll() }
}

// Concave shoulders join the screen edge; convex lower corners form the notch.
struct NotchSilhouette: Shape {
    var bottomRadius: CGFloat = 24
    var animatableData: CGFloat { get { bottomRadius } set { bottomRadius = newValue } }
    func path(in rect: CGRect) -> Path {
        let shoulder: CGFloat = min(12, rect.height * 0.28)
        let bottom: CGFloat = min(bottomRadius, rect.height * 0.42)
        let left = rect.minX + shoulder
        let right = rect.maxX - shoulder
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addCurve(to: CGPoint(x: right, y: rect.minY + shoulder),
                   control1: CGPoint(x: right, y: rect.minY),
                   control2: CGPoint(x: right, y: rect.minY + shoulder * 0.45))
        p.addLine(to: CGPoint(x: right, y: rect.maxY - bottom))
        p.addQuadCurve(to: CGPoint(x: right - bottom, y: rect.maxY),
                       control: CGPoint(x: right, y: rect.maxY))
        p.addLine(to: CGPoint(x: left + bottom, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: left, y: rect.maxY - bottom),
                       control: CGPoint(x: left, y: rect.maxY))
        p.addLine(to: CGPoint(x: left, y: rect.minY + shoulder))
        p.addCurve(to: CGPoint(x: rect.minX, y: rect.minY),
                   control1: CGPoint(x: left, y: rect.minY + shoulder * 0.45),
                   control2: CGPoint(x: left, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

struct AlbumCover: View {
    let image: NSImage?
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFill() }
            else { Image(systemName: "music.note").frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.gray.opacity(0.3)) }
        }.clipped().clipShape(RoundedRectangle(cornerRadius: 5))
    }
}
struct PlaybackBars: View {
    let playing: Bool
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: !playing || reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<4) { index in
                    Capsule().fill(Color.green).frame(width: 1.5,
                        height: playing && !reduceMotion ? 3 + 9 * (0.5 + 0.5 * sin(t * (4.5 + Double(index)) + Double(index) * 1.8)) : 3)
                }
            }.frame(width: 16, height: 14)
        }.accessibilityLabel(playing ? "Lagu diputar" : "Playback dijeda")
    }
}

// Fixed-size text never wraps or gains ellipses. Long lines pan gently end-to-end.
struct FullLyricLine: View {
    let text: String
    let elapsed: Double
    var size: CGFloat = 16
    var active = true
    var centered = false
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    var textWidth: CGFloat {
        (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: active ? .semibold : .regular)]).width
    }
    var body: some View {
        GeometryReader { geometry in
            let overflow = max(0, textWidth - geometry.size.width)
            let travel = max(0.1, Double(overflow) / 42)
            let phase = elapsed.truncatingRemainder(dividingBy: travel * 2 + 3)
            let distance = phase < 1.5 ? 0 : (phase < travel + 1.5 ? min(Double(overflow), (phase - 1.5) * 42) :
                (phase < travel + 3 ? Double(overflow) : max(0, Double(overflow) - (phase - travel - 3) * 42)))
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text).font(.system(size: size, weight: active ? .semibold : .regular))
                    .fixedSize(horizontal: true, vertical: false)
                    .offset(x: reduceMotion ? (centered ? -overflow / 2 : 0) :
                        (centered ? -Double(overflow) / 2 : -distance))
                    .frame(width: max(textWidth, geometry.size.width), height: geometry.size.height, alignment: .leading)
            }.scrollDisabled(!reduceMotion)
            .accessibilityLabel(text)
        }.frame(height: 28).clipped()
    }
}
struct LyricDissolve: ViewModifier {
    let hidden: Bool
    func body(content: Content) -> some View {
        content.opacity(hidden ? 0 : 1).blur(radius: hidden ? 3 : 0)
    }
}
struct ThreeLyrics: View {
    @ObservedObject var player: Player
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if player.hasSyncedLyrics {
                ForEach(player.visibleLyrics) { line in
                    let active = line.id == player.currentLine
                    Text(line.text.isEmpty ? "♪" : line.text)
                        .font(.system(size: active ? 20 : 16, weight: active ? .semibold : .regular))
                        .lineSpacing(2)
                        .lineLimit(active ? nil : 1)
                        .fixedSize(horizontal: false, vertical: active)
                        .foregroundStyle(active ? Color.white : Color.white.opacity(0.38))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: active ? player.activeLyricHeight : 28, alignment: .leading)
                        .transition(.modifier(active: LyricDissolve(hidden: true), identity: LyricDissolve(hidden: false)))
                }
                if player.currentLine == nil { Text("♪").foregroundStyle(.white).frame(height: 28) }
            } else {
                Text(player.lyricText(relative: 0)).font(.system(size: 13)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: player.mainContentHeight - 68, alignment: .center)
        .animation(reduceMotion || !player.expanded ? nil : .easeInOut(duration: 0.46), value: player.currentLine)
    }
}
private enum PanelStyle { static let surface = Color(white: 0.08) }

// Capture exact SwiftUI control bounds; one coordinator owns hover and the popover.
private struct ToolHoverRegionsKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, newest in newest })
    }
}
private extension View {
    func panelTooltip(_ text: String) -> some View {
        background(GeometryReader { geometry in
            Color.clear.preference(key: ToolHoverRegionsKey.self,
                                   value: [text: geometry.frame(in: .named("notchContent"))])
        })
    }
}

struct ToolbarAction: View {
    @ObservedObject var player: Player
    let symbol: String
    let label: String
    var active = false
    var state: String? = nil
    var destructive = false
    let action: () -> Void
    private var hovering: Bool { player.hoveredTool == label }
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(destructive ? Color.red.opacity(0.85) : (active ? Color.green : Color.white.opacity(0.65)))
                .frame(width: 32, height: 28)
                .background(active ? Color.green.opacity(hovering ? 0.20 : 0.12) : Color.white.opacity(hovering ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 8))
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
                .contentShape(Rectangle())
        }.frame(width: 32, height: 28).panelTooltip(label).accessibilityLabel(label).accessibilityValue(state ?? "")
    }
}
private enum LyricTimingScale {
    static let step = 100.0
    static let spacing = 10.0
    static func clamped(_ value: Double) -> Double {
        min(5000, max(-5000, (value / step).rounded() * step))
    }
    static func dragged(start: Double, translation: Double) -> Double {
        clamped(start - translation / spacing * step)
    }
}
private struct TimingPointer: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
private struct TimingRulerMarks: View, Animatable {
    var value: Double
    var animatableData: Double { get { value } set { value = newValue } }
    var body: some View {
        Canvas { context, size in
            let center = size.width / 2
            for tick in -50...50 {
                let milliseconds = Double(tick) * LyricTimingScale.step
                let x = center + (milliseconds - value) / LyricTimingScale.step * LyricTimingScale.spacing
                guard x >= -20 && x <= size.width + 20 else { continue }
                let major = tick.isMultiple(of: 5)
                let selectedSide = milliseconds <= value
                // Localized bell-shaped peak matches the reference without enlarging the editor.
                let distance = abs(x - center)
                let emphasis = exp(-pow(distance / 18, 2))
                let minimumHeight = major ? 3.6 : 2.7
                let height = minimumHeight + (14 - minimumHeight) * emphasis
                let width = 0.65 + 0.70 * emphasis
                let tint = (selectedSide ? Color.green : Color.white.opacity(0.23))
                    .opacity(0.6 + 0.4 * emphasis)
                let mark = CGRect(x: x - width / 2, y: 16 - height / 2, width: width, height: height)
                context.fill(Path(roundedRect: mark, cornerRadius: width / 2), with: .color(tint))
                if major {
                    let label = milliseconds == 0 ? "0" : String(format: "%+.0f", milliseconds)
                    context.draw(Text(label).font(.system(size: 8 * (0.8 + 0.2 * emphasis), weight: .medium, design: .rounded))
                        .foregroundColor(selectedSide ? Color.green : Color.white.opacity(0.4)),
                        at: CGPoint(x: x, y: 4))
                }
            }
        }
    }
}
struct LyricTimingRuler: View {
    @Binding var value: Double
    @State private var dragStart: Double?
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    var body: some View {
        TimingRulerMarks(value: value)
            .animation(reduceMotion || dragStart != nil ? nil : .spring(response: 0.24, dampingFraction: 0.95), value: value)
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.12),
                                     .init(color: .black, location: 0.88), .init(color: .clear, location: 1)],
                             startPoint: .leading, endPoint: .trailing))
        .overlay(alignment: .bottom) {
            TimingPointer().fill(Color.green).frame(width: 6, height: 3).offset(y: 3).allowsHitTesting(false)
        }
        .frame(height: 24).contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { event in
                if dragStart == nil { dragStart = value }
                value = LyricTimingScale.dragged(start: dragStart ?? value, translation: event.translation.width)
            }
            .onEnded { _ in dragStart = nil })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Audio delay")
        .accessibilityValue(String(format: "%+.0f milliseconds", value))
        .accessibilityHint("Drag left to show lyrics earlier, or right to show them later")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = LyricTimingScale.clamped(value + 100)
            case .decrement: value = LyricTimingScale.clamped(value - 100)
            @unknown default: break
            }
        }
    }
}
struct ToolSection: View {
    @ObservedObject var player: Player
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                ToolbarAction(player: player, symbol: player.pinned ? "pin.fill" : "pin", label: "Keep panel open",
                              active: player.pinned, state: player.pinned ? "On" : "Off") { player.pinned.toggle() }
                ToolbarAction(player: player, symbol: "timer", label: "Audio delay",
                              active: player.toolsOpen, state: player.toolsOpen ? "Expanded" : "Collapsed") {
                    withAnimation(reduceMotion ? nil : NotchMotion.content) { player.toolsOpen.toggle() }
                }
                ToolbarAction(player: player, symbol: player.alwaysShowLyric ? "quote.bubble.fill" : "quote.bubble", label: "Always show lyrics",
                              active: player.alwaysShowLyric, state: player.alwaysShowLyric ? "On" : "Off") {
                    player.alwaysShowLyric.toggle()
                }
                ToolbarAction(player: player, symbol: "arrow.clockwise", label: "Refresh lyrics") { player.retry() }
                Spacer(minLength: 8)
                ToolbarAction(player: player, symbol: "power", label: "Quit NotchLyrics", destructive: true) { NSApp.terminate(nil) }
            }.padding(.horizontal, 12).frame(height: 28)
            if player.toolsOpen {
                VStack(spacing: 2) {
                    LyricTimingRuler(value: $player.lyricAdvanceMS).padding(.vertical, 4)
                    ZStack {
                        Text(String(format: "%+.0f", player.lyricAdvanceMS))
                            .font(.system(size: 13, weight: .medium, design: .rounded)).monospacedDigit()
                        + Text(" ms").font(.system(size: 9, weight: .medium))
                        HStack(spacing: 4) {
                            Button { player.lyricAdvanceMS = LyricTimingScale.clamped(player.lyricAdvanceMS - 100) } label: {
                                Image(systemName: "minus.circle").font(.system(size: 12)).frame(width: 24, height: 22)
                            }.foregroundStyle(Color.white.opacity(0.65)).accessibilityLabel("Show lyrics 100 ms later")
                            Spacer(minLength: 0)
                            Button { player.lyricAdvanceMS = LyricTimingScale.clamped(player.lyricAdvanceMS + 100) } label: {
                                Image(systemName: "plus.circle").font(.system(size: 12)).frame(width: 24, height: 22)
                            }.foregroundStyle(Color.white.opacity(0.65)).accessibilityLabel("Show lyrics 100 ms earlier")
                        }
                    }.foregroundStyle(.green).frame(height: 22)
                    .overlay(alignment: .trailing) {
                        Button { player.lyricAdvanceMS = 0 } label: {
                            Image(systemName: "arrow.counterclockwise").font(.system(size: 10)).frame(width: 20, height: 22)
                        }.panelTooltip("Reset audio delay").accessibilityLabel("Reset audio delay")
                            .foregroundStyle(Color.white.opacity(0.6)).offset(x: -32)
                    }.padding(.horizontal, 12)
                }.frame(maxWidth: .infinity).frame(height: 56).transition(.opacity)
            }
        }.padding(.horizontal, 18).padding(.vertical, 12)
        .frame(maxWidth: .infinity).frame(height: player.toolSectionHeight, alignment: .top)
        .foregroundStyle(.white).buttonStyle(.plain).preferredColorScheme(.dark)
    }
}
struct PersistentLyric: View {
    @ObservedObject var player: Player
    @Environment(\.accessibilityReduceTransparency) var reduceTransparency
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    var line: some View {
        FullLyricLine(text: player.lyricText(relative: 0), elapsed: player.lyricElapsed, size: 12, centered: true)
            .foregroundStyle(.white).padding(.horizontal, 12)
            .id("\(player.trackID)-\(player.currentLine ?? -1)")
            .transition(.opacity)
    }
    var body: some View {
        Group {
            if #available(macOS 26.0, *), !reduceTransparency {
                line.glassEffect(.regular, in: Capsule())
            } else {
                line.background(reduceTransparency ? AnyShapeStyle(Color.black) : AnyShapeStyle(.regularMaterial), in: Capsule())
            }
        }.padding(3)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.46), value: player.currentLine)
        .preferredColorScheme(.dark)
    }
}
private enum NotchMotion {
    static let content = Animation.spring(response: 0.32, dampingFraction: 0.96, blendDuration: 0.1)
}
// One persistent header keeps artwork, metadata and controls continuous across modes.
struct NotchPlaybackHeader: View {
    @ObservedObject var player: Player
    let open: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Button(action: open) {
                HStack(spacing: 10) {
                    AlbumCover(image: player.cover).frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(player.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Text(player.artist).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.contentShape(Rectangle())
            }.accessibilityLabel("Open player: \(player.title), \(player.artist)")
                .frame(maxWidth: .infinity, alignment: .leading).layoutPriority(1)
            HStack(spacing: 3) {
                Button { player.command("previous track") } label: {
                    Image(systemName: "backward.end.fill").font(.system(size: 11)).frame(width: 26, height: 30)
                }.accessibilityLabel("Previous track")
                Button { player.command("playpause") } label: {
                    Image(systemName: player.playing ? "pause.fill" : "play.fill").font(.system(size: 15)).frame(width: 28, height: 30)
                }.accessibilityLabel(player.playing ? "Pause" : "Play")
                Button { player.command("next track") } label: {
                    Image(systemName: "forward.end.fill").font(.system(size: 11)).frame(width: 26, height: 30)
                }.accessibilityLabel("Next track")
            }.fixedSize()
        }.padding(.horizontal, player.expanded ? 30 : 22).frame(height: player.expanded ? 56 : 52)
        .background {
            Button(action: open) { Color.clear.contentShape(Rectangle()) }
                .buttonStyle(.plain).accessibilityHidden(true)
        }
        .foregroundStyle(.white).buttonStyle(.plain)
    }
}

struct NotchView: View {
    @ObservedObject var player: Player
    var resize: (Bool) -> Void
    var updateToolRegions: ([String: CGRect]) -> Void
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    var body: some View {
        GeometryReader { geometry in
            let showingHeader = player.expanded || player.previewing
            VStack(spacing: 0) {
                Color.clear.frame(height: player.barHeight)
                NotchPlaybackHeader(player: player, open: { resize(true) })
                    .opacity(showingHeader ? 1 : 0)
                    .blur(radius: reduceMotion || showingHeader ? 0 : 2)
                    .allowsHitTesting(showingHeader).accessibilityHidden(!showingHeader)
                ThreeLyrics(player: player)
                    .padding(.horizontal, 30).padding(.bottom, 12)
                    .frame(height: player.expanded ? player.mainContentHeight - 56 : 0, alignment: .top)
                    .opacity(player.expanded ? 1 : 0)
                    .blur(radius: reduceMotion || player.expanded ? 0 : 2)
                    .offset(y: player.expanded || reduceMotion ? 0 : -6)
                    .clipped().allowsHitTesting(player.expanded).accessibilityHidden(!player.expanded)
                ToolSection(player: player)
                    .frame(height: player.expanded ? player.toolSectionHeight : 0, alignment: .top)
                    .opacity(player.expanded ? 1 : 0).clipped()
                    .allowsHitTesting(player.expanded).accessibilityHidden(!player.expanded)
            }.frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
            .background {
                LinearGradient(stops: [.init(color: .black, location: 0),
                                       .init(color: .black, location: 0.16),
                                       .init(color: player.expanded ? PanelStyle.surface : .black, location: 0.7)],
                               startPoint: .top, endPoint: .bottom)
            }
            .overlay(alignment: .top) {
                Button { resize(!player.expanded) } label: {
                    ZStack {
                        Color.clear
                        HStack(spacing: 0) {
                            AlbumCover(image: player.cover).frame(width: 20, height: 20).frame(width: 34)
                            Spacer(minLength: player.cameraWidth)
                            PlaybackBars(playing: player.playing).frame(width: 34)
                        }.padding(.horizontal, 12).opacity(showingHeader ? 0 : 1)
                    }.frame(height: player.barHeight).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(player.expanded ? "Close player" : "Open player")
            }
            .clipShape(NotchSilhouette(bottomRadius: player.expanded ? 36 : (player.previewing ? 24 : 14)))
            .foregroundStyle(.white).buttonStyle(.plain).preferredColorScheme(.dark)
            .coordinateSpace(name: "notchContent")
            .onPreferenceChange(ToolHoverRegionsKey.self) { regions in updateToolRegions(regions) }
            .onChange(of: player.currentLine) { _ in if player.expanded { resize(true) } }
            .onChange(of: player.toolsOpen) { _ in if player.expanded { resize(true) } }
            .contextMenu { Button("Keluar") { NSApp.terminate(nil) } }
        }
    }
}

// Exact critically damped integration preserves momentum when a gesture reverses.
private enum PanelSpring {
    static func step(value: Double, velocity: Double, target: Double, dt: Double) -> (Double, Double) {
        let omega = 24.0
        let offset = value - target
        let coefficient = velocity + omega * offset
        let decay = exp(-omega * dt)
        return (target + (offset + coefficient * dt) * decay,
                (velocity - omega * coefficient * dt) * decay)
    }
}
@MainActor private final class NotchFrameMotion {
    weak var window: NSWindow?
    private var target = NSRect.zero
    private var velocity = NSSize.zero
    private var currentSize = NSSize.zero
    private var timer: Timer?
    private var sampledAt = 0.0
    init(window: NSWindow) { self.window = window }
    func move(to next: NSRect, reducedMotion: Bool) {
        guard let window else { return }
        if reducedMotion || !window.isVisible {
            stop(); target = next; currentSize = next.size; window.setFrame(next, display: true); return
        }
        guard next != target else { return }
        target = next
        guard timer == nil else { return }
        velocity = .zero; currentSize = window.frame.size; sampledAt = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private func tick() {
        guard let window else { stop(); return }
        let now = ProcessInfo.processInfo.systemUptime
        let dt = min(0.05, now - sampledAt); sampledAt = now
        let width = PanelSpring.step(value: currentSize.width, velocity: velocity.width, target: target.width, dt: dt)
        let height = PanelSpring.step(value: currentSize.height, velocity: velocity.height, target: target.height, dt: dt)
        velocity = NSSize(width: width.1, height: height.1)
        let size = NSSize(width: max(1, width.0), height: max(1, height.0))
        currentSize = size
        // Keep the top edge and horizontal center fixed throughout the morph.
        window.setFrame(NSRect(x: target.midX - size.width / 2, y: target.maxY - size.height,
                               width: size.width, height: size.height), display: true)
        if abs(size.width - target.width) < 0.1 && abs(size.height - target.height) < 0.1 &&
            abs(velocity.width) + abs(velocity.height) < 1 {
            window.setFrame(target, display: true); stop()
        }
    }
    func stop() { timer?.invalidate(); timer = nil; velocity = .zero }
}

private enum NotchTopEdgeHit {
    static func contains(_ point: NSPoint, panelFrame: NSRect, screenFrame: NSRect, scale: CGFloat) -> Bool {
        // A two-physical-pixel band includes the top boundary that CGRect.contains excludes.
        let tolerance = 2 / max(1, scale)
        return point.x >= panelFrame.minX && point.x <= panelFrame.maxX &&
            point.y >= screenFrame.maxY - tolerance && point.y <= screenFrame.maxY + tolerance
    }
}

@MainActor final class Delegate: NSObject, NSApplicationDelegate {
    let player = Player()
    var panel: NSPanel!
    private var frameMotion: NotchFrameMotion?
    var lyricPanel: NSPanel!
    var collapsedNotchFrame = NSRect.zero
    var subscriptions = Set<AnyCancellable>()
    var status: NSStatusItem!
    var toolRegions: [String: CGRect] = [:]
    var toolTip: NSPopover?
    var previewHideTask: Task<Void, Never>?
    var globalClickMonitor: Any?
    var localClickMonitor: Any?
    var pointerTimer: Timer?
    let pillHoverMargin: CGFloat = 12
    let pillNotchGap: CGFloat = 11
    var pillHoverBounds: NSRect?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1); panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = false; panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let hosting = NSHostingView(rootView: NotchView(player: player, resize: { [weak self] in self?.resize($0) },
                                                 updateToolRegions: { [weak self] regions in
                                                     DispatchQueue.main.async { self?.updateToolRegions(regions) }
                                                 }))
        hosting.sizingOptions = []
        panel.contentView = hosting
        frameMotion = NotchFrameMotion(window: panel)
        lyricPanel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        lyricPanel.level = panel.level; lyricPanel.isOpaque = false; lyricPanel.backgroundColor = .clear
        lyricPanel.hasShadow = false; lyricPanel.hidesOnDeactivate = false
        lyricPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let lyricHosting = NSHostingView(rootView: PersistentLyric(player: player))
        lyricHosting.sizingOptions = []; lyricPanel.contentView = lyricHosting
        player.$alwaysShowLyric.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.positionLyricPanel() }
        }.store(in: &subscriptions)
        player.$playing.removeDuplicates().dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.positionLyricPanel() }
        }.store(in: &subscriptions)
        Publishers.Merge(player.$currentLine.map { _ in () }, player.$message.map { _ in () })
            .sink { [weak self] _ in DispatchQueue.main.async { self?.positionLyricPanel() } }
            .store(in: &subscriptions)
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "NotchLyrics")
        let menu = NSMenu()
        menu.addItem(withTitle: "Buka / tutup panel", action: #selector(toggle), keyEquivalent: "")
        menu.addItem(withTitle: "Keluar", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }; status.menu = menu
        NotificationCenter.default.addObserver(self, selector: #selector(reposition), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        resize(false); panel.orderFrontRegardless(); player.start(); positionLyricPanel()
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            let point = NSEvent.mouseLocation
            let leftClick = event.type == .leftMouseDown
            Task { @MainActor in
                guard let self else { return }
                if leftClick && self.handleTopEdgeClick(point) { return }
                self.dismissForOutsideClick(point)
            }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            let point = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
            let leftClick = event.type == .leftMouseDown
            let consumed = MainActor.assumeIsolated {
                guard let self else { return false }
                // Consume only edge clicks; otherwise the SwiftUI button would toggle a second time.
                if leftClick && self.handleTopEdgeClick(point) { return true }
                self.dismissForOutsideClick(point)
                return false
            }
            return consumed ? nil : event
        }
        // Hover reveals only playback preview; the full panel still requires a click.
        pointerTimer = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let point = NSEvent.mouseLocation
                self.refreshNotchPreview(point)
                self.refreshToolHover()
                // Retain the hidden pill's hit region until the pointer leaves it.
                // Otherwise hiding the window would immediately cause it to reappear.
                if let bounds = self.pillHoverBounds {
                    if !bounds.insetBy(dx: -4, dy: -4).contains(point) {
                        self.pillHoverBounds = nil
                        self.positionLyricPanel()
                    }
                } else if self.lyricPanel.isVisible && self.lyricPanel.frame.insetBy(dx: -self.pillHoverMargin, dy: -self.pillHoverMargin).contains(point) {
                    self.pillHoverBounds = self.lyricPanel.frame.insetBy(dx: -self.pillHoverMargin, dy: -self.pillHoverMargin)
                    self.lyricPanel.orderOut(nil)
                }
            }
        }
        RunLoop.main.add(pointerTimer!, forMode: .common)
    }
    func updateToolRegions(_ regions: [String: CGRect]) {
        guard toolRegions != regions else { return }
        toolRegions = regions
        refreshToolHover()
        if let text = player.hoveredTool, let tip = toolTip, tip.isShown,
           let host = panel.contentView, var rect = toolRegions[text] {
            if !host.isFlipped { rect.origin.y = host.bounds.height - rect.maxY }
            tip.show(relativeTo: rect, of: host, preferredEdge: host.isFlipped ? .minY : .maxY)
        }
    }
    func toolAtPointer() -> String? {
        guard player.expanded, panel.isVisible, let host = panel.contentView,
              panel.frame.contains(NSEvent.mouseLocation) else { return nil }
        var point = host.convert(panel.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        if !host.isFlipped { point.y = host.bounds.height - point.y }
        return toolRegions.filter { $0.value.width > 0 && $0.value.height > 0 && $0.value.contains(point) }
            .sorted { $0.value.width * $0.value.height < $1.value.width * $1.value.height }
            .first?.key
    }
    func refreshToolHover() { setHoveredTool(toolAtPointer()) }
    func setHoveredTool(_ label: String?) {
        guard player.hoveredTool != label else { return }
        toolTip?.close(); toolTip = nil
        player.hoveredTool = label
        guard let label else { return }
        showToolTip(label)
    }

    func showToolTip(_ text: String) {
        guard toolAtPointer() == text, let host = panel.contentView, var rect = toolRegions[text] else { return }
        if !host.isFlipped { rect.origin.y = host.bounds.height - rect.maxY }
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .medium); label.alignment = .center
        let size = NSSize(width: ceil(label.fittingSize.width) + 24, height: 30)
        let controller = NSViewController()
        controller.view = NSView(frame: NSRect(origin: .zero, size: size))
        label.frame = NSRect(x: 12, y: (size.height - label.fittingSize.height) / 2,
                             width: size.width - 24, height: label.fittingSize.height)
        controller.view.addSubview(label)
        let tip = NSPopover()
        tip.contentViewController = controller; tip.contentSize = size
        tip.behavior = .applicationDefined; tip.animates = false
        tip.appearance = NSAppearance(named: .darkAqua)
        toolTip?.close(); toolTip = tip
        tip.show(relativeTo: rect, of: host, preferredEdge: host.isFlipped ? .minY : .maxY)
        controller.view.window?.ignoresMouseEvents = true
    }
    func pointerIsOverNotch(_ point: NSPoint) -> Bool {
        let frame = panel.frame
        return point.x >= frame.minX && point.x <= frame.maxX &&
            point.y >= frame.minY && point.y <= frame.maxY + 1
    }
    func refreshNotchPreview(_ point: NSPoint) {
        guard !player.expanded else { previewHideTask?.cancel(); previewHideTask = nil; return }
        if pointerIsOverNotch(point) {
            previewHideTask?.cancel(); previewHideTask = nil
            if !player.previewing { resize(false, preview: true) }
        } else if player.previewing && previewHideTask == nil {
            previewHideTask = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
                guard let self, !Task.isCancelled, !self.player.expanded,
                      !self.pointerIsOverNotch(NSEvent.mouseLocation) else { return }
                self.previewHideTask = nil
                self.resize(false)
            }
        }
    }
    @discardableResult func handleTopEdgeClick(_ point: NSPoint) -> Bool {
        guard let screen = NSScreen.screens.first, panel.isVisible,
              NotchTopEdgeHit.contains(point, panelFrame: panel.frame,
                                       screenFrame: screen.frame, scale: screen.backingScaleFactor) else { return false }
        resize(!player.expanded)
        panel.orderFrontRegardless()
        return true
    }
    func dismissForOutsideClick(_ point: NSPoint) {
        guard player.expanded, !player.pinned, !panel.frame.contains(point) else { return }
        resize(false)
    }
    func applicationWillTerminate(_ notification: Notification) {
        setHoveredTool(nil)
        previewHideTask?.cancel()
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        pointerTimer?.invalidate()
        frameMotion?.stop()
    }
    func resize(_ expanded: Bool, preview: Bool = false) {
        if !expanded { setHoveredTool(nil) }
        guard let screen = NSScreen.screens.first else { return }
        let preview = preview && !expanded
        let reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        withAnimation(reducedMotion ? nil : NotchMotion.content) {
            player.expanded = expanded
            player.previewing = preview
            if !expanded { player.toolsOpen = false }
        }
        let left = screen.auxiliaryTopLeftArea
        let right = screen.auxiliaryTopRightArea
        let hasCamera = screen.safeAreaInsets.top > 0 && left != nil && right != nil
        let cameraMinX = left?.maxX ?? screen.frame.midX
        let cameraMaxX = right?.minX ?? screen.frame.midX
        let cameraWidth = hasCamera ? max(0, cameraMaxX - cameraMinX) : 0
        let centerX = hasCamera ? (cameraMinX + cameraMaxX) / 2 : screen.frame.midX
        let barHeight = hasCamera ? screen.safeAreaInsets.top : NSStatusBar.system.thickness
        player.cameraWidth = cameraWidth
        player.barHeight = barHeight
        let size = NSSize(width: expanded ? player.expandedWidth : (preview ? player.previewWidth : cameraWidth + 92),
                          height: expanded ? player.expandedHeight : (preview ? barHeight + 52 : barHeight))
        let scale = screen.backingScaleFactor
        func pixel(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        // Canonical idle geometry is independent of the animated window frame.
        let idleWidth = cameraWidth + 92
        collapsedNotchFrame = NSRect(x: pixel(centerX - idleWidth / 2),
                                    y: pixel(screen.frame.maxY - barHeight),
                                    width: pixel(idleWidth), height: pixel(barHeight))
        let target = NSRect(x: pixel(centerX - size.width / 2), y: pixel(screen.frame.maxY - size.height),
                              width: pixel(size.width), height: pixel(size.height))
        if let frameMotion { frameMotion.move(to: target, reducedMotion: reducedMotion) }
        else { panel.setFrame(target, display: true) }
        positionLyricPanel()
    }
    func positionLyricPanel() {
        guard let screen = NSScreen.screens.first, lyricPanel != nil else { return }
        guard player.alwaysShowLyric && player.playing && !player.expanded && !player.previewing else { lyricPanel.orderOut(nil); return }
        guard pillHoverBounds == nil else { lyricPanel.orderOut(nil); return }
        let base = collapsedNotchFrame
        let textWidth = (player.lyricText(relative: 0) as NSString).size(withAttributes:
            [.font: NSFont.systemFont(ofSize: 12, weight: .semibold)]).width
        let width = min(min(420, screen.frame.width - 80), max(44, ceil(textWidth) + 30))
        lyricPanel.setFrame(NSRect(x: base.midX - width / 2, y: base.minY - pillNotchGap - 34, width: width, height: 34), display: true)
        lyricPanel.orderFrontRegardless()
    }
    @objc func reposition() { resize(player.expanded, preview: player.previewing) }
    @objc func toggle() { resize(!player.expanded); panel.orderFrontRegardless() }
    @objc func quit() { NSApp.terminate(nil) }
}
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = Delegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
