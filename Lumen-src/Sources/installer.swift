import Cocoa
import SwiftUI

enum Stage { case welcome, installing, done, failed }

final class IModel: ObservableObject {
    @Published var stage = Stage.welcome
    @Published var progress = 0.0
    @Published var status = ""
    @Published var error = ""
    var installed: URL?
}
let model = IModel()

@discardableResult
func run(_ path: String, _ args: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return -1 }
    p.waitUntilExit()
    return p.terminationStatus
}

func step(_ p: Double, _ s: String, _ pause: TimeInterval = 0.6) {
    DispatchQueue.main.async { model.progress = p; model.status = s }
    Thread.sleep(forTimeInterval: pause)
}

func fail(_ msg: String) {
    DispatchQueue.main.async { model.error = msg; model.stage = .failed }
}

func install() {
    let fm = FileManager.default
    step(0.05, "Checking your Mac…")
    guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 13 else { fail("Lumen needs macOS 13 or newer."); return }

    step(0.20, "Locating Lumen…")
    guard let res = Bundle.main.resourceURL else { fail("The installer is damaged."); return }
    let payload = res.appendingPathComponent("Lumen.app")
    guard fm.fileExists(atPath: payload.path) else { fail("The installer is missing its payload."); return }

    var destDir = URL(fileURLWithPath: "/Applications")
    if !fm.isWritableFile(atPath: destDir.path) {
        destDir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        try? fm.createDirectory(at: destDir, withIntermediateDirectories: true)
    }
    let dest = destDir.appendingPathComponent("Lumen.app")

    step(0.35, "Closing any running copy of Lumen…")
    run("/usr/bin/pkill", ["-x", "Lumen"])

    step(0.50, "Copying Lumen to \(destDir.path)…", 0.3)
    do {
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.copyItem(at: payload, to: dest)
    } catch {
        fail("Couldn’t copy Lumen: \(error.localizedDescription)")
        return
    }

    step(0.75, "Removing quarantine flags…")
    run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", dest.path])

    step(0.88, "Verifying the app…")
    run("/usr/bin/codesign", ["--verify", "--deep", dest.path])

    step(0.97, "Finishing up…")
    step(1.0, "Done", 0.4)
    DispatchQueue.main.async { model.installed = dest; model.stage = .done }
}

func leftClick() {
    switch model.stage {
    case .welcome:
        model.stage = .installing
        model.progress = 0
        model.status = "Starting…"
        DispatchQueue.global().async { install() }
    case .done:
        if let u = model.installed { NSWorkspace.shared.open(u) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
    case .failed:
        NSApp.terminate(nil)
    case .installing:
        break
    }
}

func rightClick() {
    if model.stage != .installing { NSApp.terminate(nil) }
}

final class CatchView: NSView {
    var left: () -> Void = {}
    var right: () -> Void = {}
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) { left() }
    override func rightMouseDown(with event: NSEvent) { right() }
}

struct ClickCatcher: NSViewRepresentable {
    let left: () -> Void
    let right: () -> Void
    func makeNSView(context: Context) -> NSView {
        let v = CatchView(); v.left = left; v.right = right; return v
    }
    func updateNSView(_ v: NSView, context: Context) {
        if let c = v as? CatchView { c.left = left; c.right = right }
    }
}

struct InstallerView: View {
    @ObservedObject var m: IModel
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.black)
            RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
            VStack(spacing: 12) {
                Image(systemName: "moon.fill").font(.system(size: 22)).foregroundColor(Color.white)
                switch m.stage {
                case .welcome:
                    Text("Welcome to the Lumen Installer")
                        .font(.system(size: 20, weight: .semibold)).foregroundColor(Color.white)
                    Text("Click anywhere here to start installing.")
                        .font(.system(size: 13)).foregroundColor(Color.white.opacity(0.5))
                case .installing:
                    Text("Installing…")
                        .font(.system(size: 20, weight: .semibold)).foregroundColor(Color.white)
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.14))
                            Capsule().fill(Color.white).frame(width: g.size.width * CGFloat(m.progress))
                        }
                    }
                    .frame(height: 5)
                    .padding(.horizontal, 24)
                    Text(m.status)
                        .font(.system(size: 12, design: .monospaced)).foregroundColor(Color.white.opacity(0.5))
                case .done:
                    Text("Lumen installed successfully")
                        .font(.system(size: 20, weight: .semibold)).foregroundColor(Color.white)
                    Text("Click anywhere to open the app and close the installer.")
                        .font(.system(size: 13)).foregroundColor(Color.white.opacity(0.7))
                    Text("Right click to close the installer and not open the app.")
                        .font(.system(size: 12)).foregroundColor(Color.white.opacity(0.4))
                case .failed:
                    Text("Installation failed")
                        .font(.system(size: 20, weight: .semibold)).foregroundColor(Color.white)
                    Text(m.error)
                        .font(.system(size: 12)).foregroundColor(Color.white.opacity(0.6))
                    Text("Click anywhere to close.")
                        .font(.system(size: 12)).foregroundColor(Color.white.opacity(0.4))
                }
            }
            .padding(28)
            .multilineTextAlignment(.center)
        }
        .animation(.easeOut(duration: 0.35), value: m.progress)
        .overlay(ClickCatcher(left: { leftClick() }, right: { rightClick() }))
        .preferredColorScheme(.dark)
    }
}

final class IWin: NSWindow { override var canBecomeKey: Bool { true } }

final class IDelegate: NSObject, NSApplicationDelegate {
    var win: NSWindow?
    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.regular)
        let w = IWin(contentRect: NSRect(x: 0, y: 0, width: 560, height: 220), styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.level = .floating
        w.appearance = NSAppearance(named: .darkAqua)
        let h = NSHostingView(rootView: InstallerView(m: model))
        h.sizingOptions = []
        w.contentView = h
        w.center()
        win = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let idelegate = IDelegate()
app.delegate = idelegate
app.run()
