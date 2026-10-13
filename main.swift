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
    @Published var pinned = false
    @Published var cameraWidth: CGFloat = 0
    @Published var barHeight: CGFloat = 24
    @Published var toolsOpen = false
    @Published var alwaysShowLyric = UserDefaults.standard.bool(forKey: "alwaysShowLyric") {
        didSet { UserDefaults.standard.set(alwaysShowLyric, forKey: "alwaysShowLyric") }
    }
    var activeLyricHeight: CGFloat {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 2
        let bounds = (lyricText(relative: 0) as NSString).boundingRect(
            with: NSSize(width: max(380, cameraWidth + 100) - 60, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 16, weight: .semibold), .paragraphStyle: paragraph])
        return max(28, ceil(bounds.height) + 10)
    }
    var mainContentHeight: CGFloat { max(168, activeLyricHeight + 136) }
    var expandedHeight: CGFloat { barHeight + mainContentHeight + (toolsOpen ? 8 + 88 : 0) }
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
    func retry() { trackID = ""; poll() }
}

// Concave shoulders join the screen edge; convex lower corners form the notch.
struct NotchSilhouette: Shape {
    func path(in rect: CGRect) -> Path {
        let shoulder: CGFloat = min(12, rect.height * 0.28)
        let bottom: CGFloat = min(24, rect.height * 0.42)
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
                        .font(.system(size: active ? 16 : 14, weight: active ? .semibold : .regular))
                        .lineSpacing(2)
                        .lineLimit(active ? nil : 1)
                        .fixedSize(horizontal: false, vertical: active)
                        .foregroundStyle(active ? Color.white : Color.white.opacity(0.38))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: active ? player.activeLyricHeight : 26, alignment: .leading)
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
struct ToolsPanel: View {
    @ObservedObject var player: Player
    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                Toggle("Always show lyric", isOn: $player.alwaysShowLyric).toggleStyle(.switch).controlSize(.mini)
                    .font(.system(size: 11))
                Spacer(minLength: 4)
                Text("Audio delay").font(.system(size: 10)).foregroundStyle(.secondary)
                if player.lines.isEmpty { Button("Retry") { player.retry() }.font(.system(size: 10)) }
            }.frame(height: 24)
            HStack(spacing: 8) {
                Button { player.lyricAdvanceMS = max(-5000, player.lyricAdvanceMS - 100) } label: {
                    Image(systemName: "minus.circle").frame(width: 20, height: 24)
                }.accessibilityLabel("Perlambat lirik 100 ms")
                Slider(value: $player.lyricAdvanceMS, in: -5000...5000, step: 100)
                    .accessibilityLabel("Timing lirik dalam milidetik")
                Button { player.lyricAdvanceMS = min(5000, player.lyricAdvanceMS + 100) } label: {
                    Image(systemName: "plus.circle").frame(width: 20, height: 24)
                }.accessibilityLabel("Percepat lirik 100 ms")
                Text(String(format: "%+.0f ms", player.lyricAdvanceMS))
                    .font(.system(size: 11, design: .monospaced)).frame(width: 64)
                Button { player.lyricAdvanceMS = 0 } label: {
                    Image(systemName: "arrow.counterclockwise").font(.system(size: 11)).frame(width: 20, height: 24)
                }.accessibilityLabel("Reset timing lirik")
            }
        }.padding(.horizontal, 18).padding(.vertical, 12)
        .frame(maxWidth: .infinity).frame(height: 88, alignment: .top)
        .background(Color(white: 0.08), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.10), lineWidth: 0.5))
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
struct NotchView: View {
    @ObservedObject var player: Player
    var resize: (Bool) -> Void
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 8) {
                VStack(spacing: 0) {
                    Color.clear.frame(height: player.barHeight)
                    VStack(spacing: 12) {
                        HStack(spacing: 8) {
                            AlbumCover(image: player.cover).frame(width: 32, height: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(player.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                Text(player.artist).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                            }.frame(maxWidth: .infinity, alignment: .leading).layoutPriority(1)
                            HStack(spacing: 3) {
                                Button { player.command("previous track") } label: { Image(systemName: "backward.end.fill").font(.system(size: 11)).frame(width: 24, height: 28) }
                                Button { player.command("playpause") } label: { Image(systemName: player.playing ? "pause.fill" : "play.fill").font(.system(size: 15)).frame(width: 26, height: 28) }
                                Button { player.command("next track") } label: { Image(systemName: "forward.end.fill").font(.system(size: 11)).frame(width: 24, height: 28) }
                            }.fixedSize()
                            Button { player.pinned.toggle() } label: { Image(systemName: player.pinned ? "pin.fill" : "pin").font(.system(size: 12)).frame(width: 24, height: 28) }
                            Button {
                                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { player.toolsOpen.toggle() }
                            } label: {
                                Image(systemName: "slider.horizontal.3").font(.system(size: 12))
                                    .foregroundStyle(player.toolsOpen ? Color.green : Color.white.opacity(0.65))
                                    .frame(width: 24, height: 28)
                            }.accessibilityLabel("Settings").accessibilityValue(player.toolsOpen ? "Terbuka" : "Tertutup")
                        }
                        ThreeLyrics(player: player)
                    }.padding(.horizontal, 30).padding(.vertical, 12).frame(height: player.mainContentHeight)
                    .opacity(player.expanded ? 1 : 0)
                    .blur(radius: reduceMotion ? 0 : (player.expanded ? 0 : 4))
                    .allowsHitTesting(player.expanded).accessibilityHidden(!player.expanded)
                }.frame(width: geometry.size.width, height: player.expanded ? player.barHeight + player.mainContentHeight : player.barHeight, alignment: .top)
                .background(Color.black)
                .overlay(alignment: .top) {
                    HStack(spacing: 0) {
                        AlbumCover(image: player.cover).frame(width: 20, height: 20).frame(width: 34)
                        Spacer(minLength: player.cameraWidth)
                        PlaybackBars(playing: player.playing).frame(width: 34)
                    }.padding(.horizontal, 12).frame(height: player.barHeight)
                    .opacity(player.expanded ? 0 : 1).allowsHitTesting(false)
                }.clipShape(NotchSilhouette())
                .onTapGesture { if !player.expanded { resize(true) } }
                if player.expanded && player.toolsOpen { ToolsPanel(player: player).padding(.horizontal, 12).transition(.opacity) }
            }.frame(width: geometry.size.width, height: geometry.size.height, alignment: .top).clipped()
            .foregroundStyle(.white).buttonStyle(.plain).preferredColorScheme(.dark)
            .onChange(of: player.currentLine) { _ in if player.expanded { resize(true) } }
            .onChange(of: player.toolsOpen) { _ in resize(player.expanded) }
            .contextMenu { Button("Keluar") { NSApp.terminate(nil) } }
        }
    }
}

@MainActor final class Delegate: NSObject, NSApplicationDelegate {
    let player = Player()
    var panel: NSPanel!
    var lyricPanel: NSPanel!
    var collapsedNotchFrame = NSRect.zero
    var subscriptions = Set<AnyCancellable>()
    var status: NSStatusItem!
    var collapseTask: Task<Void, Never>?
    var pointerTimer: Timer?
    var pointerInside = false
    let pillHoverMargin: CGFloat = 12
    let pillNotchGap: CGFloat = 11
    var pillHoverBounds: NSRect?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1); panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = false; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let hosting = NSHostingView(rootView: NotchView(player: player, resize: { [weak self] in self?.resize($0) }))
        hosting.sizingOptions = []
        panel.contentView = hosting
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
        // Window resizing can emit false hover exits. Track screen-space position instead.
        pointerTimer = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let point = NSEvent.mouseLocation
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
                let frame = self.panel.frame
                // Include the physical screen edge: CGRect.contains excludes maxY.
                let inside = (point.x >= frame.minX && point.x <= frame.maxX &&
                     point.y >= frame.minY && point.y <= frame.maxY + 1)
                if inside != self.pointerInside { self.pointerInside = inside; self.hover(inside) }
            }
        }
        RunLoop.main.add(pointerTimer!, forMode: .common)
    }
    func hover(_ inside: Bool) {
        collapseTask?.cancel()
        if inside { if !player.expanded { resize(true) }; return }
        guard !player.pinned else { return }
        collapseTask = Task {
            try? await Task.sleep(nanoseconds: 90_000_000)
            guard !Task.isCancelled else { return }
            resize(false)
        }
    }
    func resize(_ expanded: Bool) {
        guard let screen = NSScreen.screens.first else { return }
        let changed = player.expanded != expanded
        let reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        withAnimation(reducedMotion ? nil : .easeInOut(duration: 0.14)) {
            player.expanded = expanded
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
        let size = NSSize(width: expanded ? max(380, cameraWidth + 100) : cameraWidth + 92,
                          height: expanded ? player.expandedHeight : barHeight)
        let scale = screen.backingScaleFactor
        func pixel(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        // Canonical idle geometry is independent of the animated window frame.
        let idleWidth = cameraWidth + 92
        collapsedNotchFrame = NSRect(x: pixel(centerX - idleWidth / 2),
                                    y: pixel(screen.frame.maxY - barHeight),
                                    width: pixel(idleWidth), height: pixel(barHeight))
        let target = NSRect(x: pixel(centerX - size.width / 2), y: pixel(screen.frame.maxY - size.height),
                              width: pixel(size.width), height: pixel(size.height))
        if (changed || target != panel.frame) && !reducedMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(target, display: true)
            }
        } else { panel.setFrame(target, display: true) }
        positionLyricPanel()
    }
    func positionLyricPanel() {
        guard let screen = NSScreen.screens.first, lyricPanel != nil else { return }
        guard player.alwaysShowLyric && player.playing && !player.expanded else { lyricPanel.orderOut(nil); return }
        guard pillHoverBounds == nil else { lyricPanel.orderOut(nil); return }
        let base = collapsedNotchFrame
        let textWidth = (player.lyricText(relative: 0) as NSString).size(withAttributes:
            [.font: NSFont.systemFont(ofSize: 12, weight: .semibold)]).width
        let width = min(min(420, screen.frame.width - 80), max(44, ceil(textWidth) + 30))
        lyricPanel.setFrame(NSRect(x: base.midX - width / 2, y: base.minY - pillNotchGap - 34, width: width, height: 34), display: true)
        lyricPanel.orderFrontRegardless()
    }
    @objc func reposition() { resize(player.expanded) }
    @objc func toggle() { resize(!player.expanded); panel.orderFrontRegardless() }
    @objc func quit() { NSApp.terminate(nil) }
}
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = Delegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
