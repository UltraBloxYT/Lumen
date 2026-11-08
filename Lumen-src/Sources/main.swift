import Cocoa
import SwiftUI
import ScreenCaptureKit
import AVFoundation
import Carbon.HIToolbox
import ServiceManagement
import CoreImage

// MARK: - Basics
let UD = UserDefaults.standard
func ui(_ f: @escaping () -> Void) { DispatchQueue.main.async(execute: f) }

extension Color {
    static let dim = Color.white.opacity(0.45)
    static let line = Color.white.opacity(0.14)
    static let soft = Color.white.opacity(0.08)
}

func registerDefaults() {
    UD.register(defaults: [
        "recH": 1080, "recFPS": 60, "recMic": false, "recSys": true, "recQ": 2,
        "repOn": true, "repSec": 60, "repH": 1080, "repFPS": 60, "repMic": false, "repSys": true, "repQ": 1,
        "shotH": 0, "launch": true, "notices": true, "setupDone": false,
        "proof": true, "wm": false, "wmPos": "bottomRight", "perfMode": "normal", "perfAnim": true, "perfPin": true, "perfSet": true, "perfUI": true
    ])
}

enum Disp {
    static var screen: NSScreen { NSScreen.main ?? NSScreen.screens[0] }
    static var id: CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }
    static var native: (w: Int, h: Int) {
        if let m = CGDisplayCopyDisplayMode(id) { return (m.pixelWidth, m.pixelHeight) }
        let s = screen.backingScaleFactor
        return (Int(screen.frame.width * s), Int(screen.frame.height * s))
    }
    static var maxFPS: Int { max(60, screen.maximumFramesPerSecond) }
    static var heights: [Int] { [720, 1080, 1440, 2160].filter { $0 < native.h } }
    static var cheapH: Int { native.h > 720 ? 720 : 0 }
    static func dims(_ h: Int) -> (w: Int, h: Int) {
        let n = native
        if h <= 0 || h >= n.h { return (n.w & ~1, n.h & ~1) }
        let w = Int((Double(h) * Double(n.w) / Double(n.h)).rounded())
        return (w & ~1, h & ~1)
    }
}

func resLabel(_ h: Int) -> String { h == 0 ? "Max" : (h == 2160 ? "4K" : "\(h)p") }

// LUMEN-V2: performance mode, streamproof, look
// LUMEN-V3: modes
enum PerfMode: String { case normal, low, lite, cheap }

enum Mode {
    static var liteOn = false          // Lumen Lite lives in memory only, so it never survives a relaunch
    static var liteKeepBuffer = true
    static var current: PerfMode {
        if liteOn { return .lite }
        return PerfMode(rawValue: UD.string(forKey: "perfMode") ?? "normal") ?? .normal
    }
}

enum Perf {
    static var mode: PerfMode { Mode.current }
    static var low: Bool { mode == .low }
    static var lite: Bool { mode == .lite }
    static var cheap: Bool { mode == .cheap }
    static var on: Bool { mode != .normal }
    static var noAnim: Bool { low || (cheap && UD.bool(forKey: "perfAnim")) }
    static var noProof: Bool { on }    // streamproof is off (and locked) in every mode
    static var cheapSet: Bool { cheap && UD.bool(forKey: "perfSet") }
    static var cheapUI: Bool { low || (cheap && UD.bool(forKey: "perfUI")) }
    // LUMEN-V5: the bar stays open and Lumen does not listen for the open/close hotkey
    static var pinned: Bool { low || (cheap && UD.bool(forKey: "perfPin")) }
}

enum Proof { static var on: Bool { UD.bool(forKey: "proof") && !Perf.noProof } }

final class Look: ObservableObject {
    static let shared = Look()
    static func r(_ x: CGFloat) -> CGFloat { Perf.cheapUI ? 0 : x }
    static var pill: CGFloat { Perf.cheapUI ? 0 : 100 }
    @Published var rev = 0
    private var sig = Look.signature()
    private static func signature() -> String { "\(Perf.mode.rawValue)\(Perf.noAnim)\(Perf.cheapSet)\(Perf.cheapUI)\(Perf.pinned)\(Proof.on)" }
    private init() {
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.check()
        }
    }
    func check() {
        let s = Look.signature()
        guard s != sig else { return }
        sig = s
        rev += 1
        Overlay.shared.applyLook()
        Notices.shared.applyLook()
        HotKey.register()
        if Perf.pinned { Overlay.shared.pin() }
    }
}


struct Cfg: Equatable {
    var h: Int, fps: Int, sys: Bool, mic: Bool, q: Int
    var proof = Proof.on
    var potato = false
    var wm = WM.on
    static func load(_ p: String) -> Cfg {
        // Lumen Lite has no settings: always the defaults
        if Perf.lite { return Cfg(h: 1080, fps: 60, sys: true, mic: false, q: p == "rep" ? 1 : 2) }
        var c = Cfg(h: UD.integer(forKey: p + "H"), fps: max(1, UD.integer(forKey: p + "FPS")),
                    sys: UD.bool(forKey: p + "Sys"), mic: UD.bool(forKey: p + "Mic"), q: UD.integer(forKey: p + "Q"))
        if Perf.low {
            c.potato = true      // same settings, lighter capture and encode path
        } else if Perf.cheapSet {
            c.h = Disp.cheapH; c.fps = 30; c.q = 0
        }
        return c
    }
    var size: (w: Int, h: Int) { Disp.dims(h) }
    var bitrate: Int {
        let bpp = [0.05, 0.08, 0.12, 0.18][min(max(q, 0), 3)]
        let s = size
        return Int(Double(s.w * s.h * fps) * bpp)
    }
}

enum Out {
    static func folder(_ d: FileManager.SearchPathDirectory) -> URL {
        let u = FileManager.default.urls(for: d, in: .userDomainMask)[0].appendingPathComponent("Lumen")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    static var movies: URL { folder(.moviesDirectory) }
    static var pictures: URL { folder(.picturesDirectory) }
    static func stamp() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm.ss"; return f.string(from: Date())
    }
}

func openPrivacy() {
    if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(u) }
}

func isComplete(_ sb: CMSampleBuffer) -> Bool {
    guard CMSampleBufferIsValid(sb),
          let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
          let raw = arr.first?[.status] as? Int else { return false }
    return raw == SCFrameStatus.complete.rawValue
}

// MARK: - Hotkey (Carbon, no accessibility permission needed)
func carbonMods(_ f: NSEvent.ModifierFlags) -> UInt32 {
    var m: UInt32 = 0
    if f.contains(.command) { m |= UInt32(cmdKey) }
    if f.contains(.option) { m |= UInt32(optionKey) }
    if f.contains(.control) { m |= UInt32(controlKey) }
    if f.contains(.shift) { m |= UInt32(shiftKey) }
    return m
}
func modSymbols(_ f: NSEvent.ModifierFlags) -> String {
    var s = ""
    if f.contains(.control) { s += "⌃" }
    if f.contains(.option) { s += "⌥" }
    if f.contains(.shift) { s += "⇧" }
    if f.contains(.command) { s += "⌘" }
    return s
}
func keyName(_ e: NSEvent) -> String {
    let special: [UInt16: String] = [49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"]
    return special[e.keyCode] ?? (e.charactersIgnoringModifiers ?? "?").uppercased()
}

enum HotKey {
    static var ref: EventHotKeyRef?
    static var installed = false
    static var action: (() -> Void)?
    static func register() {
        unregister()
        guard UD.object(forKey: "hkCode") != nil, !Perf.pinned else { return }
        if !installed {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in HotKey.action?(); return noErr }, 1, &spec, nil, nil)
            installed = true
        }
        var r: EventHotKeyRef?
        let id = EventHotKeyID(signature: 0x564F5258, id: 1)
        RegisterEventHotKey(UInt32(UD.integer(forKey: "hkCode")), UInt32(UD.integer(forKey: "hkMods")), id, GetApplicationEventTarget(), 0, &r)
        ref = r
    }
    static func unregister() { if let r = ref { UnregisterEventHotKey(r); ref = nil } }
}

final class HotkeyField: ObservableObject {
    static let shared = HotkeyField()
    @Published var label = UD.string(forKey: "hkLabel") ?? "Not set"
    @Published var listening = false
    private var monitor: Any?
    var isSet: Bool { UD.object(forKey: "hkCode") != nil }
    func listen() {
        guard !listening else { return }
        listening = true
        HotKey.unregister()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let s = self else { return e }
            if e.keyCode == 53 { s.stop(); return nil }
            let f = e.modifierFlags.intersection([.command, .option, .control, .shift])
            if f.isEmpty { return nil }
            UD.set(Int(e.keyCode), forKey: "hkCode")
            UD.set(Int(carbonMods(f)), forKey: "hkMods")
            let l = modSymbols(f) + keyName(e)
            UD.set(l, forKey: "hkLabel")
            s.label = l
            s.stop()
            return nil
        }
    }
    private func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil; listening = false
        HotKey.register()
    }
}

enum LoginItem {
    static func set(_ on: Bool) {
        do {
            if on { if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() } }
            else { try SMAppService.mainApp.unregister() }
        } catch {}
    }
}

// MARK: - Capture
final class Capturer: NSObject, SCStreamOutput, SCStreamDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    private var stream: SCStream?
    private var micSession: AVCaptureSession?
    private(set) var micOn = false
    private(set) var q = DispatchQueue(label: "lumen.capture", qos: .userInteractive)
    var onVideo: ((CMSampleBuffer) -> Void)?
    var onSys: ((CMSampleBuffer) -> Void)?
    var onMic: ((CMSampleBuffer) -> Void)?
    var onStop: (() -> Void)?

    // Our own app is excluded from every capture, so the overlay and notices never appear in recordings.
    static func make(_ c: Cfg) async throws -> (SCContentFilter, SCStreamConfiguration) {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let disp = content.displays.first(where: { $0.displayID == Disp.id }) ?? content.displays.first else {
            throw NSError(domain: "lumen", code: 1)
        }
        var me: [SCRunningApplication] = []
        if c.proof { me = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier } }
        var keep: [SCWindow] = []
        if c.proof && c.wm, let n = Watermark.shared.number {
            keep = content.windows.filter { $0.windowID == CGWindowID(n) }
        }
        let filter = SCContentFilter(display: disp, excludingApplications: me, exceptingWindows: keep)
        let cfg = SCStreamConfiguration()
        let s = c.size
        cfg.width = s.w; cfg.height = s.h
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(c.fps))
        cfg.pixelFormat = c.potato ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange : kCVPixelFormatType_32BGRA
        cfg.queueDepth = c.potato ? 3 : 6
        cfg.showsCursor = true
        if c.sys { cfg.capturesAudio = true; cfg.sampleRate = 48000; cfg.channelCount = 2; cfg.excludesCurrentProcessAudio = true }
        return (filter, cfg)
    }

    func start(_ c: Cfg) async throws {
        q = DispatchQueue(label: "lumen.capture", qos: c.potato ? .utility : .userInteractive)
        let (filter, cfg) = try await Capturer.make(c)
        let st = SCStream(filter: filter, configuration: cfg, delegate: self)
        try st.addStreamOutput(self, type: .screen, sampleHandlerQueue: q)
        if c.sys { try st.addStreamOutput(self, type: .audio, sampleHandlerQueue: q) }
        if c.mic, await AVCaptureDevice.requestAccess(for: .audio) { startMic() }
        try await st.startCapture()
        stream = st
    }

    private func startMic() {
        guard let dev = AVCaptureDevice.default(for: .audio), let inp = try? AVCaptureDeviceInput(device: dev) else { return }
        let s = AVCaptureSession(); let out = AVCaptureAudioDataOutput()
        guard s.canAddInput(inp), s.canAddOutput(out) else { return }
        s.addInput(inp); s.addOutput(out)
        out.setSampleBufferDelegate(self, queue: q)
        s.startRunning()
        micSession = s; micOn = true
    }

    func stop() async {
        onVideo = nil; onSys = nil; onMic = nil; onStop = nil
        micSession?.stopRunning(); micSession = nil; micOn = false
        try? await stream?.stopCapture()
        stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .screen: if isComplete(sb) { onVideo?(sb) }
        case .audio: if CMSampleBufferIsValid(sb) { onSys?(sb) }
        default: break
        }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if CMSampleBufferIsValid(sampleBuffer) { onMic?(sampleBuffer) }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { onStop?() }
}

// Lumen Low: when the encoder falls behind, keep every other frame until it recovers (never blocks capture).
// LUMEN-V4: watermark
enum WM {
    static var on: Bool { UD.bool(forKey: "wm") && !Perf.lite }
}

enum WMPos: String {
    case topLeft, topCenter, topRight, bottomLeft, bottomCenter, bottomRight
}

struct WatermarkView: View {
    let icon: NSImage
    var body: some View {
        HStack(spacing: 6) {
            Text("Recorded with").font(.system(size: 12, weight: .medium)).foregroundColor(Color.white.opacity(0.85))
            Image(nsImage: icon).resizable().frame(width: 18, height: 18)
            Text("Lumen").font(.system(size: 12, weight: .semibold)).foregroundColor(Color.white)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.black))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.line, lineWidth: 1))
        .fixedSize()
    }
}

// A real on-screen badge (so it lands in recordings, replays and screenshots without any per-frame work).
// With streamproof on it is explicitly kept in the capture while the rest of Lumen stays hidden.
final class Watermark {
    static let shared = Watermark()
    private var panel: NSPanel?
    private var sig = ""
    private(set) var number: Int?
    private init() {
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
    }
    func refresh() {
        let s = "\(WM.on)\(UD.string(forKey: "wmPos") ?? "")"
        guard s != sig else { return }
        sig = s
        guard WM.on else { panel?.orderOut(nil); number = nil; return }
        if panel == nil { build() }
        guard let p = panel else { return }
        place(p)
        p.orderFrontRegardless()
        number = p.windowNumber
    }
    private func build() {
        let host = NSHostingView(rootView: WatermarkView(icon: NSApp.applicationIconImage))
        var size = host.fittingSize
        if size.width < 10 || size.height < 10 { size = NSSize(width: 176, height: 32) }
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
        p.ignoresMouseEvents = true
        p.level = .screenSaver
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.hidesOnDeactivate = false; p.isFloatingPanel = true
        p.appearance = NSAppearance(named: .darkAqua)
        p.contentView = host
        panel = p
    }
    private func place(_ p: NSPanel) {
        let f = Disp.screen.visibleFrame, s = p.frame.size, m: CGFloat = 12
        let left = f.minX + m, right = f.maxX - s.width - m, midX = f.midX - s.width / 2
        let top = f.maxY - s.height - m, bottom = f.minY + m
        let pos = WMPos(rawValue: UD.string(forKey: "wmPos") ?? "") ?? .bottomRight
        let pt: NSPoint
        switch pos {
        case .topLeft: pt = NSPoint(x: left, y: top)
        case .topCenter: pt = NSPoint(x: midX, y: top)
        case .topRight: pt = NSPoint(x: right, y: top)
        case .bottomLeft: pt = NSPoint(x: left, y: bottom)
        case .bottomCenter: pt = NSPoint(x: midX, y: bottom)
        case .bottomRight: pt = NSPoint(x: right, y: bottom)
        }
        p.setFrameOrigin(pt)
    }
}

struct WMPicker: View {
    @AppStorage("wmPos") var pos = "bottomRight"
    var body: some View {
        VStack(spacing: 6) {
            Seg(opts: [("Top left", "topLeft"), ("Top center", "topCenter"), ("Top right", "topRight")], sel: $pos)
            Seg(opts: [("Bottom left", "bottomLeft"), ("Bottom center", "bottomCenter"), ("Bottom right", "bottomRight")], sel: $pos)
        }
    }
}

final class Governor {
    static let shared = Governor()
    private let lock = NSLock()
    private var late = 0, good = 0
    private var shedding = false
    private var flip = false
    func admit() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard shedding else { return true }
        flip.toggle()
        return flip
    }
    func report(ready: Bool) {
        lock.lock(); defer { lock.unlock() }
        if ready {
            late = max(0, late - 1); good += 1
            if shedding && good > 180 { shedding = false; good = 0 }
        } else {
            good = 0; late += 1
            if late > 6 { shedding = true }
        }
    }
}

final class MediaWriter {
    let url: URL
    var tag = 0
    private let w: AVAssetWriter
    private let v: AVAssetWriterInput
    private var a: AVAssetWriterInput?
    private var m: AVAssetWriterInput?
    private var started = false
    private var t0 = CMTime.zero
    private var last = CMTime.zero
    private let fps: Int
    private let gov: Governor?
    private var wrote = false
    var duration: Double { started ? max(0, (last - t0).seconds) + 1.0 / Double(fps) : 0 }

    init(url: URL, cfg: Cfg, sys: Bool, mic: Bool) throws {
        self.url = url; fps = cfg.fps
        gov = cfg.potato ? Governor.shared : nil
        w = try AVAssetWriter(url: url, fileType: .mp4)
        let s = cfg.size
        let props: [String: Any] = [
            AVVideoAverageBitRateKey: cfg.bitrate,
            AVVideoMaxKeyFrameIntervalDurationKey: cfg.potato ? 2.0 : 1.0,
            AVVideoExpectedSourceFrameRateKey: cfg.fps,
            AVVideoProfileLevelKey: cfg.potato ? AVVideoProfileLevelH264BaselineAutoLevel : AVVideoProfileLevelH264HighAutoLevel,
            AVVideoAllowFrameReorderingKey: false
        ]
        let vs: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: s.w, AVVideoHeightKey: s.h,
            AVVideoCompressionPropertiesKey: props
        ]
        v = AVAssetWriterInput(mediaType: .video, outputSettings: vs)
        v.expectsMediaDataInRealTime = true
        w.add(v)
        func aac(_ ch: Int) -> AVAssetWriterInput {
            let i = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: ch, AVEncoderBitRateKey: 128000
            ])
            i.expectsMediaDataInRealTime = true
            return i
        }
        if sys { let i = aac(2); w.add(i); a = i }
        if mic { let i = aac(1); w.add(i); m = i }
    }

    func video(_ sb: CMSampleBuffer) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        if !started {
            guard w.startWriting() else { return }
            w.startSession(atSourceTime: pts); started = true; t0 = pts
        }
        if wrote, let g = gov, !g.admit() { return }
        let ready = w.status == .writing && v.isReadyForMoreMediaData
        gov?.report(ready: ready)
        if ready { v.append(sb); last = pts; wrote = true }
    }
    func audio(_ sb: CMSampleBuffer, mic isMic: Bool) {
        guard started, w.status == .writing, CMSampleBufferGetPresentationTimeStamp(sb) >= t0 else { return }
        if let i = (isMic ? m : a), i.isReadyForMoreMediaData { i.append(sb) }
    }
    func finish() async -> Bool {
        guard started else { w.cancelWriting(); return false }
        v.markAsFinished(); a?.markAsFinished(); m?.markAsFinished()
        await w.finishWriting()
        return w.status == .completed
    }
}

// Manual recording
final class Recorder {
    let cap = Capturer()
    private let lock = NSLock()
    private var w: MediaWriter?
    private var cfg = Cfg.load("rec")
    private var url = Out.movies
    private(set) var isOn = false

    func start() async throws {
        cfg = Cfg.load("rec")
        url = Out.movies.appendingPathComponent("Recording \(Out.stamp()).mp4")
        cap.onVideo = { [weak self] sb in self?.video(sb) }
        cap.onSys = { [weak self] sb in self?.audio(sb, false) }
        cap.onMic = { [weak self] sb in self?.audio(sb, true) }
        cap.onStop = { Ctl.shared.toggleRecord() }
        try await cap.start(cfg)
        isOn = true
    }
    private func video(_ sb: CMSampleBuffer) {
        lock.lock(); defer { lock.unlock() }
        if w == nil { w = try? MediaWriter(url: url, cfg: cfg, sys: cfg.sys, mic: cap.micOn) }
        w?.video(sb)
    }
    private func audio(_ sb: CMSampleBuffer, _ mic: Bool) { lock.lock(); w?.audio(sb, mic: mic); lock.unlock() }
    private func take() -> MediaWriter? { lock.lock(); defer { lock.unlock() }; let x = w; w = nil; return x }

    func stop() async -> URL? {
        await cap.stop()
        let x = take()
        isOn = false
        guard let x = x else { return nil }
        return await x.finish() ? x.url : nil
    }
}

// Rolling replay buffer: short segments on disk, stitched together on save
final class ReplayBuffer {
    let cap = Capturer()
    private let lock = NSLock()
    private let group = DispatchGroup()
    private var cur: MediaWriter?
    private var curStart = CMTime.zero
    private var segs: [(n: Int, url: URL, dur: Double)] = []
    private var n = 0
    private let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-replay")
    private(set) var running: Cfg?
    var isOn: Bool { running != nil }
    private var length: Double { Perf.lite ? 60 : Double(UD.integer(forKey: "repSec")) }
    private var segDur: Double { Perf.low ? min(15, max(5, length / 10)) : min(10, max(2, length / 12)) }

    func start() async throws {
        let c = Cfg.load("rep")
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        cap.onVideo = { [weak self] sb in self?.video(sb, c) }
        cap.onSys = { [weak self] sb in self?.audio(sb, false) }
        cap.onMic = { [weak self] sb in self?.audio(sb, true) }
        try await cap.start(c)
        running = c
    }

    private func video(_ sb: CMSampleBuffer, _ c: Cfg) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        lock.lock()
        var old: MediaWriter?
        if let w = cur, (pts - curStart).seconds >= segDur { old = w; cur = nil }
        if cur == nil {
            n += 1
            cur = try? MediaWriter(url: dir.appendingPathComponent("s\(n).mp4"), cfg: c, sys: c.sys, mic: cap.micOn)
            cur?.tag = n
            curStart = pts
        }
        cur?.video(sb)
        lock.unlock()
        if let o = old { close(o) }
    }
    private func audio(_ sb: CMSampleBuffer, _ mic: Bool) { lock.lock(); cur?.audio(sb, mic: mic); lock.unlock() }
    private func takeCur() -> MediaWriter? { lock.lock(); defer { lock.unlock() }; let c = cur; cur = nil; return c }
    private func snapshot() -> [(n: Int, url: URL, dur: Double)] { lock.lock(); defer { lock.unlock() }; return segs }
    private func clear() { lock.lock(); segs = []; lock.unlock() }
    private func addSeg(_ t: Int, _ u: URL, _ d: Double) {
        lock.lock(); defer { lock.unlock() }
        segs.append((t, u, d)); segs.sort { $0.n < $1.n }
        var total = segs.reduce(0) { $0 + $1.dur }
        while segs.count > 1, total - segs[0].dur >= length {
            let r = segs.removeFirst(); total -= r.dur
            try? FileManager.default.removeItem(at: r.url)
        }
    }
    private func close(_ w: MediaWriter) {
        group.enter()
        Task {
            if await w.finish() { self.addSeg(w.tag, w.url, w.duration) }
            self.group.leave()
        }
    }
    private func drain() async {
        await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
            group.notify(queue: .global()) { k.resume() }
        }
    }

    func stop() async {
        await cap.stop()
        running = nil
        if let o = takeCur() { _ = await o.finish() }
        await drain()
        clear()
        try? FileManager.default.removeItem(at: dir)
    }

    func save() async -> URL? {
        if let o = takeCur() { close(o) }
        await drain()
        let list = snapshot()
        guard !list.isEmpty else { return nil }
        // hard-link the segments so trimming can't delete them mid-export
        let tmp = dir.appendingPathComponent("x\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        var files: [URL] = []
        for s in list {
            let l = tmp.appendingPathComponent(s.url.lastPathComponent)
            if (try? FileManager.default.linkItem(at: s.url, to: l)) != nil { files.append(l) }
        }
        let comp = AVMutableComposition()
        let vT = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        let aT = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        let mT = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        var t = CMTime.zero
        do {
            for f in files {
                let asset = AVURLAsset(url: f)
                let d = try await asset.load(.duration)
                let vs = try await asset.loadTracks(withMediaType: .video)
                let au = try await asset.loadTracks(withMediaType: .audio)
                if let src = vs.first {
                    let r = try await src.load(.timeRange)
                    try vT?.insertTimeRange(r, of: src, at: t + r.start)
                }
                for (i, src) in au.prefix(2).enumerated() {
                    let r = try await src.load(.timeRange)
                    try (i == 0 ? aT : mT)?.insertTimeRange(r, of: src, at: t + r.start)
                }
                t = t + d
            }
        } catch { return nil }
        for tr in [aT, mT] { if let tr = tr, tr.segments.isEmpty { comp.removeTrack(tr) } }
        let out = Out.movies.appendingPathComponent("Replay \(Out.stamp()).mp4")
        guard let ex = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough) else { return nil }
        ex.outputURL = out; ex.outputFileType = .mp4
        await ex.export()
        return ex.status == .completed ? out : nil
    }
}

// One-frame grabber (macOS 13 has no SCScreenshotManager)
final class Grabber: NSObject, SCStreamOutput {
    private var cont: CheckedContinuation<CGImage?, Never>?
    private var stream: SCStream?
    private let lock = NSLock()
    func grab(_ f: SCContentFilter, _ c: SCStreamConfiguration) async -> CGImage? {
        await withCheckedContinuation { (k: CheckedContinuation<CGImage?, Never>) in
            lock.lock(); cont = k; lock.unlock()
            let s = SCStream(filter: f, configuration: c, delegate: nil)
            stream = s
            do { try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: .global()) } catch { finish(nil); return }
            s.startCapture { err in if err != nil { self.finish(nil) } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { self.finish(nil) }
        }
    }
    private func finish(_ i: CGImage?) {
        lock.lock(); let k = cont; cont = nil; lock.unlock()
        guard let k = k else { return }
        k.resume(returning: i)
        stream?.stopCapture { _ in }
    }
    func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of t: SCStreamOutputType) {
        guard t == .screen, isComplete(sb), let px = CMSampleBufferGetImageBuffer(sb) else { return }
        let ci = CIImage(cvPixelBuffer: px)
        finish(CIContext().createCGImage(ci, from: ci.extent))
    }
}

enum Shot {
    static func take() async -> URL? {
        let c = Cfg(h: Perf.lite ? 0 : UD.integer(forKey: "shotH"), fps: 30, sys: false, mic: false, q: 0)
        guard let (filter, cfg) = try? await Capturer.make(c) else { return nil }
        var img: CGImage?
        img = await Grabber().grab(filter, cfg)
        guard let i = img, let data = NSBitmapImageRep(cgImage: i).representation(using: .png, properties: [:]) else { return nil }
        let u = Out.pictures.appendingPathComponent("Screenshot \(Out.stamp()).png")
        do { try data.write(to: u) } catch { return nil }
        return u
    }
}

// MARK: - Controller
final class Ctl {
    static let shared = Ctl()
    let rec = Recorder()
    let rep = ReplayBuffer()
    private var busy = false
    private var failed: Cfg?
    private var debounce: DispatchWorkItem?

    private init() {
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.debounce?.cancel()
            let w = DispatchWorkItem { self?.sync() }
            self?.debounce = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: w)
        }
    }

    func fail(openSettings: Bool) {
        Notices.show("Capture failed. Allow Screen Recording in System Settings.")
        if openSettings && !CGPreflightScreenCaptureAccess() { openPrivacy() }
    }

    func toggleRecord() {
        Task {
            if rec.isOn {
                let u = await rec.stop()
                ui { Model.shared.recording = false }
                Notices.show(u != nil ? "Recording saved" : "Recording failed")
            } else {
                do {
                    try await rec.start()
                    ui { Model.shared.recording = true }
                    Notices.show("Recording started")
                } catch { fail(openSettings: true) }
            }
        }
    }

    func saveReplay() {
        Task {
            guard rep.isOn else { Notices.show("Replay buffer is off"); return }
            Notices.show("Saving replay…")
            let u = await rep.save()
            Notices.show(u != nil ? "Replay saved" : "Replay failed")
        }
    }

    func screenshot() {
        Task {
            if await Shot.take() != nil { Notices.show("Screenshot saved") } else { fail(openSettings: true) }
        }
    }

    // Keeps the replay buffer in line with the settings
    func sync() {
        guard !busy else { return }
        let want = Perf.lite ? Mode.liteKeepBuffer : UD.bool(forKey: "repOn"), cfg = Cfg.load("rep"), have = rep.running
        if !want { failed = nil }
        let need = want ? (have != cfg && failed != cfg) : (have != nil)
        guard need else { return }
        busy = true
        Task {
            if have != nil { await rep.stop() }
            var ok = false
            if want {
                do { try await rep.start(); ok = true }
                catch { Notices.show("Replay couldn’t start. Allow Screen Recording, then relaunch.") }
            }
            ui {
                if want && !ok { self.failed = cfg }
                Model.shared.bufferOn = ok
                self.busy = false
                self.sync()
            }
        }
    }
}

// MARK: - Model
final class Model: ObservableObject {
    static let shared = Model()
    @Published var expanded = false { didSet { Overlay.shared.setExpanded(expanded) } }
    @Published var tab = 0
    @Published var recording = false
    @Published var bufferOn = false
}

// MARK: - Windows
enum Metrics {
    static let small = NSSize(width: 184, height: 54)
    static let big = NSSize(width: 440, height: 450)
}

final class KeyPanel: NSPanel { override var canBecomeKey: Bool { true } }

func styleP(_ p: NSPanel) {
    p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
    p.level = .screenSaver
    p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    p.sharingType = Proof.on ? .none : .readOnly
    p.hidesOnDeactivate = false; p.isFloatingPanel = true
    p.appearance = NSAppearance(named: .darkAqua)
}

final class Overlay {
    static let shared = Overlay()
    let panel: KeyPanel
    private let anchor: NSWindow
    private(set) var visible = true
    private var gen = 0
    private init() {
        // Invisible 1px window so Lumen is always listed as an on-screen app and can be excluded from captures.
        let a = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1), styleMask: [.borderless], backing: .buffered, defer: false)
        a.isOpaque = false; a.backgroundColor = .clear; a.hasShadow = false
        a.ignoresMouseEvents = true; a.isReleasedWhenClosed = false
        a.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        anchor = a
        panel = KeyPanel(contentRect: NSRect(origin: .zero, size: Metrics.small), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        styleP(panel)
        panel.hasShadow = !Perf.cheapUI
        panel.isMovableByWindowBackground = true
        let h = NSHostingView(rootView: OverlayView())
        h.sizingOptions = []
        panel.contentView = h
    }
    func place() {
        let f = Disp.screen.visibleFrame, s = Metrics.small
        panel.setFrame(NSRect(x: f.midX - s.width / 2, y: f.maxY - s.height - 10, width: s.width, height: s.height), display: true)
        anchor.setFrameOrigin(Disp.screen.frame.origin)
        anchor.orderFrontRegardless()
    }
    func setExpanded(_ e: Bool) {
        let s = e ? Metrics.big : Metrics.small, f = panel.frame
        panel.setFrame(NSRect(x: f.midX - s.width / 2, y: f.maxY - s.height, width: s.width, height: s.height), display: true, animate: !Perf.noAnim)
    }
    // Hidden means ordered out (not just transparent), so it can't flash while you swipe between desktops.
    func setVisible(_ v: Bool) {
        visible = v
        gen += 1
        let g = gen
        panel.ignoresMouseEvents = !v
        if v {
            panel.alphaValue = Perf.noAnim ? 1 : 0
            panel.orderFrontRegardless()
            if !Perf.noAnim {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.15
                    self.panel.animator().alphaValue = 1
                }
            }
        } else if Perf.noAnim {
            panel.orderOut(nil)
        } else {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.15
                self.panel.animator().alphaValue = 0
            }, completionHandler: {
                if !self.visible && self.gen == g { self.panel.orderOut(nil) }
            })
        }
    }
    func toggle() {
        if Perf.pinned { Notices.show("Performance mode is on"); return }
        setVisible(!visible)
    }
    func pin() { if !visible { setVisible(true) } }
    func applyLook() {
        panel.hasShadow = !Perf.cheapUI
        panel.invalidateShadow()
        panel.sharingType = Proof.on ? .none : .readOnly
    }
}

final class NoticeModel: ObservableObject { @Published var text = "" }

struct NoticeView: View {
    @ObservedObject var model: NoticeModel
    var body: some View {
        Text(model.text)
            .font(.system(size: 12, weight: .medium)).foregroundColor(.white)
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: Look.pill, style: .continuous).fill(Color.black))
            .overlay(RoundedRectangle(cornerRadius: Look.pill, style: .continuous).strokeBorder(Color.line, lineWidth: 1))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

final class Notices {
    static let shared = Notices()
    private var panel: NSPanel?
    private let model = NoticeModel()
    private var work: DispatchWorkItem?
    private var gen = 0
    func setup() {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 44), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        styleP(p); p.ignoresMouseEvents = true
        let h = NSHostingView(rootView: NoticeView(model: model)); h.sizingOptions = []
        p.contentView = h
        panel = p   // stays ordered out until a notice is shown
    }
    func applyLook() { panel?.sharingType = Proof.on ? .none : .readOnly }
    static func show(_ t: String) { DispatchQueue.main.async { if Perf.lite { Lite.shared.flash(t) } else { shared.display(t) } } }
    private func display(_ t: String) {
        guard UD.bool(forKey: "notices"), let p = panel else { return }
        model.text = t
        let o = Overlay.shared.panel.frame, sf = Disp.screen.visibleFrame
        let vis = Overlay.shared.visible
        p.setFrameOrigin(NSPoint(x: (vis ? o.midX : sf.midX) - p.frame.width / 2, y: vis ? o.minY - 50 : sf.maxY - 54))
        work?.cancel()
        gen += 1
        let g = gen
        let quick = Perf.noAnim
        if !p.isVisible { p.alphaValue = quick ? 1 : 0 }
        p.orderFrontRegardless()
        if quick { p.alphaValue = 1 } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                p.animator().alphaValue = 1
            }
        }
        let w = DispatchWorkItem { [weak self] in
            if quick { p.orderOut(nil); return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                p.animator().alphaValue = 0
            }, completionHandler: {
                if let s = self, s.gen == g { p.orderOut(nil) }
            })
        }
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4, execute: w)
    }
}

// MARK: - Mono UI components
struct IconBtn: View {
    let sym: String
    var on = false
    var dot = false
    let act: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: act) {
            Image(systemName: sym)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(on ? Color.black : Color.white)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: Look.r(9), style: .continuous).fill(on ? Color.white : Color.white.opacity(hover ? 0.18 : 0.08)))
                .overlay(RoundedRectangle(cornerRadius: Look.r(9), style: .continuous).strokeBorder(Color.line, lineWidth: 1))
                .overlay(alignment: .topTrailing) {
                    if dot { RoundedRectangle(cornerRadius: Look.pill, style: .continuous).fill(Color.white).frame(width: 5, height: 5).padding(4) }
                }
        }
        .buttonStyle(.plain)
        .onHover { if !Perf.cheapUI { hover = $0 } }
    }
}

struct MonoBtn: ButtonStyle {
    var primary = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(primary ? Color.black : Color.white)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: Look.r(8), style: .continuous).fill(primary ? Color.white : Color.white.opacity(0.1)))
            .overlay(RoundedRectangle(cornerRadius: Look.r(8), style: .continuous).strokeBorder(Color.line, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct Sec<C: View>: View {
    let t: String; let c: C
    init(_ t: String, @ViewBuilder _ c: () -> C) { self.t = t; self.c = c() }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(t.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(1.2).foregroundColor(Color.dim)
            c
        }
    }
}

struct Note: View {
    let t: String
    init(_ t: String) { self.t = t }
    var body: some View { Text(t).font(.system(size: 11)).foregroundColor(Color.dim).fixedSize(horizontal: false, vertical: true) }
}

struct Tog: View {
    let t: String; let s: String?
    @Binding var on: Bool
    init(_ t: String, _ s: String?, _ on: Binding<Bool>) { self.t = t; self.s = s; self._on = on }
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(t).font(.system(size: 13)).foregroundColor(.white)
                if let s = s { Text(s).font(.system(size: 11)).foregroundColor(Color.dim) }
            }
            Spacer()
            ZStack(alignment: on ? Alignment.trailing : Alignment.leading) {
                RoundedRectangle(cornerRadius: Look.pill, style: .continuous).fill(on ? Color.white : Color.white.opacity(0.14)).frame(width: 36, height: 20)
                RoundedRectangle(cornerRadius: Look.pill, style: .continuous).fill(on ? Color.black : Color.white).frame(width: 14, height: 14).padding(3)
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(Perf.noAnim ? nil : Animation.easeOut(duration: 0.12)) { on.toggle() } }
        }
    }
}

struct Seg<T: Hashable>: View {
    let opts: [(String, T)]
    @Binding var sel: T
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<opts.count, id: \.self) { i in
                let o = opts[i]
                Text(o.0)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(sel == o.1 ? Color.black : Color.white.opacity(0.8))
                    .frame(maxWidth: .infinity).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: Look.r(7), style: .continuous).fill(sel == o.1 ? Color.white : Color.soft))
                    .contentShape(Rectangle())
                    .onTapGesture { sel = o.1 }
            }
        }
    }
}

struct ResPicker: View {
    @AppStorage var h: Int
    let key: String
    init(_ key: String) { self.key = key; _h = AppStorage(wrappedValue: 1080, key) }
    var body: some View {
        let nat = Disp.native
        let locked = Perf.cheapSet && key != "shotH"
        let cur = locked ? Disp.cheapH : h
        let opts: [(String, Int)] = Disp.heights.map { (resLabel($0), $0) } + [("Max", 0)]
        VStack(alignment: .leading, spacing: 6) {
            Seg(opts: opts, sel: Binding(get: { cur >= nat.h ? 0 : cur }, set: { v in
                if locked { Notices.show("Performance mode is on") } else { h = v }
            }))
            Text(locked ? "Locked by Performance mode" : "Display max \(nat.w) × \(nat.h)")
                .font(.system(size: 10)).foregroundColor(Color.dim)
        }
    }
}

struct FPSPicker: View {
    @AppStorage var f: Int
    let key: String
    init(_ key: String) { self.key = key; _f = AppStorage(wrappedValue: 60, key) }
    var body: some View {
        let locked = Perf.cheapSet
        let cur = locked ? 30 : f
        let opts: [(String, Int)] = [30, 60, 120].filter { $0 <= Disp.maxFPS }.map { ("\($0) fps", $0) }
        Seg(opts: opts, sel: Binding(get: { cur }, set: { v in
            if locked { Notices.show("Performance mode is on") } else { f = v }
        }))
    }
}

func fmtLen(_ s: Int) -> String {
    if s < 60 { return "\(s)s" }
    return s % 60 == 0 ? "\(s / 60)m" : "\(s / 60)m \(s % 60)s"
}
func snapLen(_ s: Double) -> Int {
    let v = s < 30 ? s.rounded() : (s < 120 ? (s / 5).rounded() * 5 : (s < 600 ? (s / 15).rounded() * 15 : (s / 60).rounded() * 60))
    return Int(min(1800, max(5, v)))
}

struct LenSlider: View {
    @AppStorage("repSec") var sec = 60
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Length").font(.system(size: 13)).foregroundColor(.white)
                Spacer()
                Text(fmtLen(sec)).font(.system(size: 13, design: .monospaced)).foregroundColor(.white)
            }
            GeometryReader { g in
                let t = CGFloat(log(Double(max(5, sec)) / 5) / log(360.0))
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: Look.pill, style: .continuous).fill(Color.line).frame(height: 4)
                    RoundedRectangle(cornerRadius: Look.pill, style: .continuous).fill(Color.white).frame(width: max(4, g.size.width * t), height: 4)
                    RoundedRectangle(cornerRadius: Look.pill, style: .continuous).fill(Color.white).frame(width: 14, height: 14).offset(x: (g.size.width - 14) * t)
                }
                .frame(height: 14)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                    let p = min(1, max(0, v.location.x / g.size.width))
                    sec = snapLen(5 * pow(360.0, Double(p)))
                })
            }
            .frame(height: 14)
            HStack {
                Text("5s").font(.system(size: 10)).foregroundColor(Color.dim)
                Spacer()
                Text("30m").font(.system(size: 10)).foregroundColor(Color.dim)
            }
        }
    }
}

// MARK: - Tabs
struct RecTab: View {
    @AppStorage("recMic") var mic = false
    @AppStorage("recSys") var sys = true
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Sec("Resolution") { ResPicker("recH") }
            Sec("Frame rate") { FPSPicker("recFPS") }
            Tog("Microphone", "Off by default", $mic)
            Tog("System audio", "Game and app sound", $sys)
            Note("Recordings are saved to Movies / Lumen.")
        }
    }
}

struct RepTab: View {
    @AppStorage("repOn") var on = true
    @AppStorage("repQ") var q = 1
    @AppStorage("repSys") var sys = true
    @AppStorage("repMic") var mic = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Tog("Replay buffer", "Keeps the last moments ready to save", $on)
            LenSlider()
            Sec("Resolution") { ResPicker("repH") }
            Sec("Frame rate") { FPSPicker("repFPS") }
            Sec("Quality") {
                Seg(opts: [("Low", 0), ("Medium", 1), ("High", 2), ("Ultra", 3)],
                    sel: Binding(get: { Perf.cheapSet ? 0 : q }, set: { v in
                        if Perf.cheapSet { Notices.show("Performance mode is on") } else { q = v }
                    }))
            }
            Tog("System audio", "Game and app sound", $sys)
            Tog("Microphone", "Off by default", $mic)
            Note("Press the replay button to save a clip. The buffer is kept on disk while running, so long lengths at high quality use more space.")
        }
    }
}

struct ShotTab: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Sec("Resolution") { ResPicker("shotH") }
            Note("Screenshots are saved as PNG to Pictures / Lumen.")
        }
    }
}

func locked(_ b: Binding<Bool>, _ lock: Bool) -> Binding<Bool> {
    Binding(get: { lock ? false : b.wrappedValue }, set: { v in
        if lock { Notices.show("Performance mode is on") } else { b.wrappedValue = v }
    })
}

struct ModeBtn: View {
    let t: String; let s: String; let act: () -> Void
    var body: some View {
        Button(action: act) {
            VStack(alignment: .leading, spacing: 4) {
                Text(t).font(.system(size: 14, weight: .semibold)).foregroundColor(Color.white)
                Text(s).font(.system(size: 11)).foregroundColor(Color.dim).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: Look.r(12), style: .continuous).fill(Color.soft))
            .overlay(RoundedRectangle(cornerRadius: Look.r(12), style: .continuous).strokeBorder(Color.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct PerfTab: View {
    @AppStorage("perfAnim") var anim = true
    @AppStorage("perfSet") var cheapSet = true
    @AppStorage("perfUI") var cheapUI = true
    @AppStorage("perfPin") var pin = true
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch Perf.mode {
            case .normal, .lite:
                ModeBtn(t: "Lumen Low", s: "Built for very slow Macs. Keeps your normal settings but runs a much lighter capture pipeline that backs off by itself when your Mac struggles. Flat UI, no animations. The bar stays open and the hotkey is off.") { PerfActions.enterLow() }
                ModeBtn(t: "Lumen Lite", s: "Swaps the overlay for a plain macOS menu opened with your hotkey. No settings. Resets when Lumen closes.") { PerfActions.askLite() }
                ModeBtn(t: "Cheap", s: "Lowest recording and replay settings, no animations, a flat UI and an always-open bar. Each can be switched off.") { PerfActions.enterCheap() }
                Note("Performance modes turn streamproof off. Screenshots keep their own resolution setting.")
            case .low:
                Note("Lumen Low is on. Your normal settings apply, but capture and encoding use a lighter pipeline that sheds frames by itself when your Mac falls behind. Flat UI, no animations, streamproof off. The bar stays open and the hotkey is off.")
                Button("Exit performance mode") { PerfActions.exit() }.buttonStyle(MonoBtn(primary: true))
            case .cheap:
                Tog("No animations", "Instant windows and controls", $anim)
                Tog("No streamproof", "Locked on in performance mode", Binding(get: { true }, set: { _ in Notices.show("Performance mode is on") }))
                Tog("Cheap settings", "Locks recording and replay to the lowest resolution, frame rate and quality", $cheapSet)
                Tog("Cheap UI", "Square corners, no shadow or hover effects", $cheapUI)
                Tog("Always-open UI", "The bar stays on screen and the hotkey is not checked", $pin)
                Button("Exit performance mode") { PerfActions.exit() }.buttonStyle(MonoBtn(primary: true))
            }
        }
    }
}

enum PerfActions {
    static func enterLow() { UD.set("low", forKey: "perfMode"); Notices.show("Lumen Low is on") }
    static func enterCheap() { UD.set("cheap", forKey: "perfMode"); Notices.show("Cheap mode is on") }
    static func exit() { UD.set("normal", forKey: "perfMode"); Notices.show("Performance mode is off") }
    static func askLite() {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.messageText = "Do you want to keep replay buffer?"
            a.informativeText = "Lumen Lite replaces the overlay with a plain macOS menu and has no settings. It resets the next time Lumen opens."
            a.addButton(withTitle: "Yes")
            a.addButton(withTitle: "No")
            a.addButton(withTitle: "Cancel")
            let r = a.runModal()
            if r == .alertThirdButtonReturn { return }
            Lite.shared.begin(keepBuffer: r == .alertFirstButtonReturn)
        }
    }
}

// Lumen Lite: no custom UI. The hotkey opens a standard macOS menu from the menu bar item.
final class Lite: NSObject, NSMenuDelegate {
    static let shared = Lite()
    private var isOpen = false
    private var gen = 0
    private var recItem: NSMenuItem?
    private var saveItem: NSMenuItem?
    private var statusItem: NSStatusItem? { (NSApp.delegate as? AppDelegate)?.item }

    func begin(keepBuffer: Bool) {
        Mode.liteOn = true
        Mode.liteKeepBuffer = keepBuffer
        Model.shared.expanded = false
        Overlay.shared.setVisible(false)
        statusItem?.menu = makeMenu()
        Look.shared.check()
        Watermark.shared.refresh()
        Ctl.shared.sync()
        flash("Lumen Lite is on")
    }

    private func makeMenu() -> NSMenu {
        let m = NSMenu(title: "Lumen Lite")
        m.delegate = self
        m.autoenablesItems = false
        let head = NSMenuItem(title: "Lumen Lite", action: nil, keyEquivalent: "")
        head.isEnabled = false
        m.addItem(head)
        m.addItem(NSMenuItem.separator())
        let s = NSMenuItem(title: "Save Replay", action: #selector(saveReplay), keyEquivalent: "")
        let r = NSMenuItem(title: "Start Recording", action: #selector(toggleRecord), keyEquivalent: "")
        let p = NSMenuItem(title: "Take Screenshot", action: #selector(shot), keyEquivalent: "")
        for i in [s, r, p] { i.target = self; m.addItem(i) }
        m.addItem(NSMenuItem.separator())
        let x = NSMenuItem(title: "Exit Lumen Lite", action: #selector(exitLite), keyEquivalent: "")
        x.target = self
        m.addItem(x)
        saveItem = s; recItem = r
        return m
    }

    func menuWillOpen(_ menu: NSMenu) {
        isOpen = true
        recItem?.title = Ctl.shared.rec.isOn ? "Stop Recording" : "Start Recording"
        saveItem?.isEnabled = Mode.liteKeepBuffer
    }
    func menuDidClose(_ menu: NSMenu) { isOpen = false }

    @objc private func saveReplay() { Ctl.shared.saveReplay() }
    @objc private func toggleRecord() { Ctl.shared.toggleRecord() }
    @objc private func shot() { Ctl.shared.screenshot() }
    @objc private func exitLite() { Lite.relaunch() }

    func toggleMenu() {
        guard let it = statusItem, let b = it.button else { return }
        if isOpen { it.menu?.cancelTracking() } else { b.performClick(nil) }
    }

    func flash(_ t: String) {
        guard let b = statusItem?.button else { return }
        b.imagePosition = .imageLeading
        b.title = " " + t
        gen += 1
        let g = gen
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self] in
            if let s = self, s.gen == g { b.title = "" }
        }
    }

    // Quit, then reopen Lumen once this process is gone. Lite is never saved, so it starts normal.
    static func relaunch() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$2\"", "sh", "\(pid)", Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }
}

struct RowCard<C: View>: View {
    let t: String; let s: String; let c: C
    init(_ t: String, _ s: String, @ViewBuilder _ c: () -> C) { self.t = t; self.s = s; self.c = c() }
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(t).font(.system(size: 13, weight: .medium)).foregroundColor(.white)
                Text(s).font(.system(size: 11)).foregroundColor(Color.dim)
            }
            Spacer()
            c
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: Look.r(12), style: .continuous).fill(Color.soft))
    }
}

struct OtherTab: View {
    @AppStorage("launch") var launch = true
    @AppStorage("notices") var notices = true
    @AppStorage("proof") var proof = true
    @AppStorage("wm") var wm = false
    @ObservedObject var hk = HotkeyField.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Tog("Launch on startup", "Open Lumen when you log in", $launch)
            Tog("On-screen notices", "Short pop-ups for actions", $notices)
            Tog("Streamproof", Perf.noProof ? "Locked off by Performance mode" : "Keeps the overlay and notices out of recordings", locked($proof, Perf.noProof))
            Tog("Watermark", "Shows a Recorded with Lumen badge on screen and in your captures", $wm)
            Sec("Watermark position") { WMPicker() }
            RowCard("Overlay hotkey", Perf.pinned ? "Off while the UI is always open" : "Shows and hides the overlay") {
                Button(hk.listening ? "Press keys…" : hk.label) { hk.listen() }.buttonStyle(MonoBtn())
            }
            HStack(spacing: 8) {
                Button("Open recordings") { NSWorkspace.shared.open(Out.movies) }.buttonStyle(MonoBtn())
                Button("Open screenshots") { NSWorkspace.shared.open(Out.pictures) }.buttonStyle(MonoBtn())
            }
            Button("Quit Lumen") { NSApp.terminate(nil) }.buttonStyle(MonoBtn())
        }
        .onChange(of: launch) { v in LoginItem.set(v) }
    }
}

// MARK: - Overlay root
struct OverlayView: View {
    @ObservedObject var m = Model.shared
    @ObservedObject var look = Look.shared
    var tabs: [String] { ["Recording", "Replay", "Screenshot", Perf.low ? "Exit performance mode" : "Performance", "Other"] }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                IconBtn(sym: "gobackward", dot: m.bufferOn) { Ctl.shared.saveReplay() }
                IconBtn(sym: m.recording ? "stop.fill" : "record.circle", on: m.recording) { Ctl.shared.toggleRecord() }
                IconBtn(sym: "camera") { Ctl.shared.screenshot() }
                IconBtn(sym: "gearshape", on: m.expanded) { withAnimation(Perf.noAnim ? nil : Animation.easeOut(duration: 0.2)) { m.expanded.toggle() } }
            }
            .padding(10)
            if m.expanded {
                Rectangle().fill(Color.line).frame(height: 1)
                HStack(spacing: 4) {
                    ForEach(0..<5, id: \.self) { i in
                        Text(tabs[i])
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(m.tab == i ? Color.black : Color.white.opacity(0.7))
                            .padding(.horizontal, 8).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: Look.pill, style: .continuous).fill(m.tab == i ? Color.white : Color.clear))
                            .contentShape(RoundedRectangle(cornerRadius: Look.pill, style: .continuous))
                            .onTapGesture { m.tab = i }
                    }
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                ScrollView(showsIndicators: false) {
                    Group {
                        switch m.tab {
                        case 0: RecTab()
                        case 1: RepTab()
                        case 2: ShotTab()
                        case 3: PerfTab()
                        default: OtherTab()
                        }
                    }
                    .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .id(look.rev)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: Look.r(16), style: .continuous).fill(Color.black))
        .overlay(RoundedRectangle(cornerRadius: Look.r(16), style: .continuous).strokeBorder(Color.line, lineWidth: 1))
        .preferredColorScheme(.dark)
    }
}

// MARK: - Setup
struct SetupView: View {
    @ObservedObject var hk = HotkeyField.shared
    @State private var granted = CGPreflightScreenCaptureAccess()
    @State private var micOK = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    let done: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Lumen").font(.system(size: 26, weight: .semibold)).foregroundColor(.white)
            Text("A lightweight overlay and recorder. It captures your display and never injects into games.")
                .font(.system(size: 13)).foregroundColor(Color.dim).fixedSize(horizontal: false, vertical: true)
            RowCard("1  Screen recording", "Required to record and take screenshots") {
                Button(granted ? "Granted" : "Allow") {
                    _ = CGRequestScreenCaptureAccess()
                    granted = CGPreflightScreenCaptureAccess()
                }.buttonStyle(MonoBtn())
            }
            RowCard("2  Microphone", "For recording and replay audio. Off by default") {
                Button(micOK ? "Granted" : "Allow") {
                    if AVCaptureDevice.authorizationStatus(for: .audio) == .denied {
                        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") { NSWorkspace.shared.open(u) }
                    } else {
                        AVCaptureDevice.requestAccess(for: .audio) { ok in ui { micOK = ok } }
                    }
                }.buttonStyle(MonoBtn())
            }
            RowCard("3  Overlay hotkey", "Press a combo with at least one modifier") {
                Button(hk.listening ? "Press keys…" : hk.label) { hk.listen() }.buttonStyle(MonoBtn())
            }
            Note("If macOS asks you to quit and reopen after allowing Screen Recording, do that. The app lives in the menu bar and the hotkey shows or hides the overlay.")
            Spacer()
            HStack {
                Spacer()
                Button("Finish") { done() }.buttonStyle(MonoBtn(primary: true)).disabled(!hk.isSet)
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black)
        .preferredColorScheme(.dark)
        .onReceive(timer) { _ in
            granted = CGPreflightScreenCaptureAccess()
            micOK = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        }
    }
}

// MARK: - App
final class AppDelegate: NSObject, NSApplicationDelegate {
    var setupWin: NSWindow?
    var item: NSStatusItem?

    func applicationDidFinishLaunching(_ n: Notification) {
        registerDefaults()
        NSApp.setActivationPolicy(.accessory)
        buildMenu()
        Notices.shared.setup()
        if UD.bool(forKey: "setupDone") && UD.object(forKey: "hkCode") != nil { go() } else { showSetup() }
    }

    func go() {
        Overlay.shared.place()
        Overlay.shared.panel.orderFrontRegardless()
        HotKey.action = { if Perf.lite { Lite.shared.toggleMenu() } else { Overlay.shared.toggle() } }
        HotKey.register()
        LoginItem.set(UD.bool(forKey: "launch"))
        Watermark.shared.refresh()
        Ctl.shared.sync()
    }

    func buildMenu() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let b = item?.button {
            let img = NSImage(systemSymbolName: "tornado", accessibilityDescription: "Lumen")
            b.image = img
            if img == nil { b.title = "◎" }
        }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show / Hide Overlay", action: #selector(toggleOverlay), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Open Recordings", action: #selector(openRecordings), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Setup…", action: #selector(showSetup), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        for i in menu.items { i.target = self }
        item?.menu = menu
    }

    @objc func toggleOverlay() { Overlay.shared.toggle() }
    @objc func openRecordings() { NSWorkspace.shared.open(Out.movies) }
    @objc func quit() { NSApp.terminate(nil) }

    @objc func showSetup() {
        if let w = setupWin { NSApp.activate(ignoringOtherApps: true); w.makeKeyAndOrderFront(nil); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 580),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true; w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true; w.isReleasedWhenClosed = false
        w.backgroundColor = .black; w.appearance = NSAppearance(named: .darkAqua)
        let hv = NSHostingView(rootView: SetupView { [weak self] in self?.finishSetup() })
        hv.sizingOptions = []
        w.contentView = hv
        w.center()
        setupWin = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func finishSetup() {
        UD.set(true, forKey: "setupDone")
        setupWin?.close(); setupWin = nil
        go()
    }

    func applicationShouldTerminate(_ s: NSApplication) -> NSApplication.TerminateReply {
        Task {
            if Ctl.shared.rec.isOn { _ = await Ctl.shared.rec.stop() }
            await Ctl.shared.rep.stop()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
