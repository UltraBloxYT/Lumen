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
        "shotH": 0, "launch": true, "notices": true, "setupDone": false
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
    static func dims(_ h: Int) -> (w: Int, h: Int) {
        let n = native
        if h <= 0 || h >= n.h { return (n.w & ~1, n.h & ~1) }
        let w = Int((Double(h) * Double(n.w) / Double(n.h)).rounded())
        return (w & ~1, h & ~1)
    }
}

func resLabel(_ h: Int) -> String { h == 0 ? "Max" : (h == 2160 ? "4K" : "\(h)p") }

struct Cfg: Equatable {
    var h: Int, fps: Int, sys: Bool, mic: Bool, q: Int
    static func load(_ p: String) -> Cfg {
        Cfg(h: UD.integer(forKey: p + "H"), fps: max(1, UD.integer(forKey: p + "FPS")),
            sys: UD.bool(forKey: p + "Sys"), mic: UD.bool(forKey: p + "Mic"), q: UD.integer(forKey: p + "Q"))
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
        guard UD.object(forKey: "hkCode") != nil else { return }
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
    let q = DispatchQueue(label: "lumen.capture", qos: .userInteractive)
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
        let me = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let filter = SCContentFilter(display: disp, excludingApplications: me, exceptingWindows: [])
        let cfg = SCStreamConfiguration()
        let s = c.size
        cfg.width = s.w; cfg.height = s.h
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(c.fps))
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.queueDepth = 6
        cfg.showsCursor = true
        if c.sys { cfg.capturesAudio = true; cfg.sampleRate = 48000; cfg.channelCount = 2; cfg.excludesCurrentProcessAudio = true }
        return (filter, cfg)
    }

    func start(_ c: Cfg) async throws {
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
    var duration: Double { started ? max(0, (last - t0).seconds) + 1.0 / Double(fps) : 0 }

    init(url: URL, cfg: Cfg, sys: Bool, mic: Bool) throws {
        self.url = url; fps = cfg.fps
        w = try AVAssetWriter(url: url, fileType: .mp4)
        let s = cfg.size
        let props: [String: Any] = [
            AVVideoAverageBitRateKey: cfg.bitrate,
            AVVideoMaxKeyFrameIntervalDurationKey: 1.0,
            AVVideoExpectedSourceFrameRateKey: cfg.fps,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
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
        if w.status == .writing, v.isReadyForMoreMediaData { v.append(sb); last = pts }
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
    private var length: Double { Double(UD.integer(forKey: "repSec")) }
    private var segDur: Double { min(10, max(2, length / 12)) }

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
        let c = Cfg(h: UD.integer(forKey: "shotH"), fps: 30, sys: false, mic: false, q: 0)
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
        let want = UD.bool(forKey: "repOn"), cfg = Cfg.load("rep"), have = rep.running
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
    static let big = NSSize(width: 420, height: 450)
}

final class KeyPanel: NSPanel { override var canBecomeKey: Bool { true } }

func styleP(_ p: NSPanel) {
    p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
    p.level = .screenSaver
    p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    p.sharingType = .none
    p.hidesOnDeactivate = false; p.isFloatingPanel = true
    p.appearance = NSAppearance(named: .darkAqua)
}

final class Overlay {
    static let shared = Overlay()
    let panel: KeyPanel
    private(set) var visible = true
    private init() {
        panel = KeyPanel(contentRect: NSRect(origin: .zero, size: Metrics.small), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        styleP(panel)
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        let h = NSHostingView(rootView: OverlayView())
        h.sizingOptions = []
        panel.contentView = h
    }
    func place() {
        let f = Disp.screen.visibleFrame, s = Metrics.small
        panel.setFrame(NSRect(x: f.midX - s.width / 2, y: f.maxY - s.height - 10, width: s.width, height: s.height), display: true)
    }
    func setExpanded(_ e: Bool) {
        let s = e ? Metrics.big : Metrics.small, f = panel.frame
        panel.setFrame(NSRect(x: f.midX - s.width / 2, y: f.maxY - s.height, width: s.width, height: s.height), display: true, animate: true)
    }
    // Hidden = fully transparent and click-through, so the app always owns an on-screen window to exclude from capture.
    func setVisible(_ v: Bool) {
        visible = v
        panel.ignoresMouseEvents = !v
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; self.panel.animator().alphaValue = v ? 1 : 0 }
    }
    func toggle() { setVisible(!visible) }
}

final class NoticeModel: ObservableObject { @Published var text = "" }

struct NoticeView: View {
    @ObservedObject var model: NoticeModel
    var body: some View {
        Text(model.text)
            .font(.system(size: 12, weight: .medium)).foregroundColor(.white)
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background(Capsule().fill(Color.black))
            .overlay(Capsule().strokeBorder(Color.line, lineWidth: 1))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

final class Notices {
    static let shared = Notices()
    private var panel: NSPanel?
    private let model = NoticeModel()
    private var work: DispatchWorkItem?
    func setup() {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 44), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        styleP(p); p.ignoresMouseEvents = true; p.alphaValue = 0
        let h = NSHostingView(rootView: NoticeView(model: model)); h.sizingOptions = []
        p.contentView = h; p.orderFrontRegardless(); panel = p
    }
    static func show(_ t: String) { DispatchQueue.main.async { shared.display(t) } }
    private func display(_ t: String) {
        guard UD.bool(forKey: "notices"), let p = panel else { return }
        model.text = t
        let o = Overlay.shared.panel.frame, sf = Disp.screen.visibleFrame
        let vis = Overlay.shared.visible
        p.setFrameOrigin(NSPoint(x: (vis ? o.midX : sf.midX) - p.frame.width / 2, y: vis ? o.minY - 50 : sf.maxY - 54))
        work?.cancel()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.18; p.animator().alphaValue = 1 }
        let w = DispatchWorkItem { NSAnimationContext.runAnimationGroup { $0.duration = 0.3; p.animator().alphaValue = 0 } }
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
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(on ? Color.white : Color.white.opacity(hover ? 0.18 : 0.08)))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.line, lineWidth: 1))
                .overlay(alignment: .topTrailing) {
                    if dot { Circle().fill(Color.white).frame(width: 5, height: 5).padding(4) }
                }
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct MonoBtn: ButtonStyle {
    var primary = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(primary ? Color.black : Color.white)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(primary ? Color.white : Color.white.opacity(0.1)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.line, lineWidth: 1))
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
                Capsule().fill(on ? Color.white : Color.white.opacity(0.14)).frame(width: 36, height: 20)
                Circle().fill(on ? Color.black : Color.white).frame(width: 14, height: 14).padding(3)
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeOut(duration: 0.12)) { on.toggle() } }
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
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(sel == o.1 ? Color.white : Color.soft))
                    .contentShape(Rectangle())
                    .onTapGesture { sel = o.1 }
            }
        }
    }
}

struct ResPicker: View {
    @AppStorage var h: Int
    init(_ key: String) { _h = AppStorage(wrappedValue: 1080, key) }
    var body: some View {
        let nat = Disp.native
        let opts: [(String, Int)] = Disp.heights.map { (resLabel($0), $0) } + [("Max", 0)]
        VStack(alignment: .leading, spacing: 6) {
            Seg(opts: opts, sel: Binding(get: { h >= nat.h ? 0 : h }, set: { h = $0 }))
            Text("Display max \(nat.w) × \(nat.h)").font(.system(size: 10)).foregroundColor(Color.dim)
        }
    }
}

struct FPSPicker: View {
    @AppStorage var f: Int
    init(_ key: String) { _f = AppStorage(wrappedValue: 60, key) }
    var body: some View {
        let opts: [(String, Int)] = [30, 60, 120].filter { $0 <= Disp.maxFPS }.map { ("\($0) fps", $0) }
        Seg(opts: opts, sel: $f)
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
                    Capsule().fill(Color.line).frame(height: 4)
                    Capsule().fill(Color.white).frame(width: max(4, g.size.width * t), height: 4)
                    Circle().fill(Color.white).frame(width: 14, height: 14).offset(x: (g.size.width - 14) * t)
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
            Sec("Quality") { Seg(opts: [("Low", 0), ("Medium", 1), ("High", 2), ("Ultra", 3)], sel: $q) }
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
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.soft))
    }
}

struct OtherTab: View {
    @AppStorage("launch") var launch = true
    @AppStorage("notices") var notices = true
    @ObservedObject var hk = HotkeyField.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Tog("Launch on startup", "Open Lumen when you log in", $launch)
            Tog("On-screen notices", "Shown on screen, never recorded", $notices)
            RowCard("Overlay hotkey", "Shows and hides the overlay") {
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
    let tabs = ["Recording", "Replay", "Screenshot", "Other"]
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                IconBtn(sym: "gobackward", dot: m.bufferOn) { Ctl.shared.saveReplay() }
                IconBtn(sym: m.recording ? "stop.fill" : "record.circle", on: m.recording) { Ctl.shared.toggleRecord() }
                IconBtn(sym: "camera") { Ctl.shared.screenshot() }
                IconBtn(sym: "gearshape", on: m.expanded) { withAnimation(.easeOut(duration: 0.2)) { m.expanded.toggle() } }
            }
            .padding(10)
            if m.expanded {
                Rectangle().fill(Color.line).frame(height: 1)
                HStack(spacing: 4) {
                    ForEach(0..<4, id: \.self) { i in
                        Text(tabs[i])
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(m.tab == i ? Color.black : Color.white.opacity(0.7))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Capsule().fill(m.tab == i ? Color.white : Color.clear))
                            .contentShape(Capsule())
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
                        default: OtherTab()
                        }
                    }
                    .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.black))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.line, lineWidth: 1))
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
        .frame(width: 460, height: 470, alignment: .topLeading)
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
        HotKey.action = { Overlay.shared.toggle() }
        HotKey.register()
        LoginItem.set(UD.bool(forKey: "launch"))
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
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 470),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true; w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true; w.isReleasedWhenClosed = false
        w.backgroundColor = .black; w.appearance = NSAppearance(named: .darkAqua)
        w.contentView = NSHostingView(rootView: SetupView { [weak self] in self?.finishSetup() })
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
