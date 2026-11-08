import AppKit
import SwiftUI
import Combine

// MARK: - 状态

enum Phase: Equatable {
    case idle
    case picking
    case running
    case paused
    case done
}

let themeGreen = Color(red: 0.196, green: 0.843, blue: 0.294) // #32D74B

let topEdgeOverlap: CGFloat = 1

func islandHeight(expanded: Bool, barH: CGFloat, phase: Phase) -> CGFloat {
    // Compensate for the 1pt above-screen overlap so the lower edge matches hardware.
    barH + topEdgeOverlap + (expanded ? 96 : 0)
}
func islandWidth(expanded: Bool, notch: CGFloat) -> CGFloat { expanded ? max(276, notch + 120) : notch + 112 }

// MARK: - 计时模型

final class CountdownModel: ObservableObject {
    @Published var phase: Phase = .idle
    @Published var expanded = true
    @Published var shake: CGFloat = 0
    @Published var bellAngle: Double = 0
    @Published var remaining: TimeInterval = 0
    @Published var total: TimeInterval = 0
    @Published var soundOn: Bool = true

    private var timer: Timer?
    private var endDate: Date?
    private var alertTimer: Timer?
    private var alertTick = 0
    @Published private(set) var alerting = false

    var progress: Double {
        guard total > 0 else { return 0 }
        return max(0, min(1, remaining / total))
    }

    var timeText: String {
        let s = Int(max(0, remaining).rounded(.up))
        if s >= 3600 {
            return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
        }
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    func primaryTap() {
        let wasAlerting = alerting
        acknowledge()
        expanded = wasAlerting ? true : !expanded
    }

    func openPanel() {
        acknowledge()
        expanded = true
    }

    func acknowledge() {
        alertTimer?.invalidate()
        alertTimer = nil
        alerting = false
        shake = 0
        bellAngle = 0
    }

    func restart() {
        guard total > 0 else { return }
        start(minutes: total / 60)
    }

    func shutdown() {
        acknowledge()
        stopTimer()
        endDate = nil
    }

    func stop() {
        acknowledge()
        stopTimer()
        endDate = nil
        remaining = 0
        phase = .idle
        expanded = true
    }

    func start(minutes: Double) {
        guard minutes > 0 else { return }
        acknowledge()
        total = minutes * 60
        remaining = total
        endDate = Date().addingTimeInterval(total)
        phase = .running
        expanded = false
        startTimer()
    }

    func pause() {
        guard phase == .running else { return }
        if let e = endDate {
            remaining = max(0, e.timeIntervalSinceNow)
        }
        endDate = nil
        stopTimer()
        phase = .paused
    }

    func resume() {
        guard phase == .paused else { return }
        endDate = Date().addingTimeInterval(remaining)
        phase = .running
        expanded = false
        startTimer()
    }

    func reset() {
        acknowledge()
        stopTimer()
        endDate = nil
        phase = .idle
        expanded = true
        remaining = 0
        total = 0
    }

    private func startTimer() {
        stopTimer()
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    private func tick() {
        guard phase == .running, let e = endDate else { return }
        remaining = max(0, e.timeIntervalSinceNow)
        if remaining <= 0 {
            finish()
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func finish() {
        stopTimer()
        endDate = nil
        phase = .done
        if soundOn {
            NSSound(named: "Glass")?.play()
        }
        expanded = false
        alerting = true
        alertTick = 0
        // Keep vibrating in short repeating bursts until explicitly acknowledged.
        let t = Timer(timeInterval: 0.045, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.alertTick += 1
            let step = self.alertTick % 40
            let wave = step < 20 ? sin(Double(step) * 2.3) : 0
            // A shared waveform and animation transaction keep swing and translation in phase.
            withAnimation(.linear(duration: 0.045)) {
                self.shake = wave * 4
                self.bellAngle = wave * 18
            }
        }
        RunLoop.main.add(t, forMode: .common)
        alertTimer = t
    }
}

// MARK: - 岛体形状：与屏幕相切的肩部和连续柔和的底部弧线

struct IslandShape: Shape {
    var bottomRadius: CGFloat
    var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let t: CGFloat = 7
        let r = min(bottomRadius, rect.height - t)
        let l = rect.minX + t, right = rect.maxX - t
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: 0))
        p.addLine(to: CGPoint(x: rect.maxX, y: 0))
        p.addCurve(to: CGPoint(x: right, y: t),
                   control1: CGPoint(x: rect.maxX - t * 0.58, y: 0),
                   control2: CGPoint(x: right, y: t * 0.42))
        p.addLine(to: CGPoint(x: right, y: rect.maxY-r))
        let k: CGFloat = 0.62
        p.addCurve(to: CGPoint(x: right-r, y: rect.maxY),
                   control1: CGPoint(x: right, y: rect.maxY-r+r*k),
                   control2: CGPoint(x: right-r+r*k, y: rect.maxY))
        p.addLine(to: CGPoint(x: l+r, y: rect.maxY))
        p.addCurve(to: CGPoint(x: l, y: rect.maxY-r),
                   control1: CGPoint(x: l+r-r*k, y: rect.maxY),
                   control2: CGPoint(x: l, y: rect.maxY-r+r*k))
        p.addLine(to: CGPoint(x: l, y: t))
        p.addCurve(to: CGPoint(x: rect.minX, y: 0),
                   control1: CGPoint(x: l, y: t * 0.42),
                   control2: CGPoint(x: rect.minX + t * 0.58, y: 0))
        p.closeSubpath()
        return p
    }
}

// MARK: - 界面

struct IslandRoot: View {
    @ObservedObject var model: CountdownModel
    let notch: CGFloat
    let barH: CGFloat
    let canvasW: CGFloat
    let canvasH: CGFloat
    private let presets = [1, 5, 10, 25, 45, 60]
    private var shapeW: CGFloat { islandWidth(expanded: model.expanded, notch: notch) }
    private var shapeH: CGFloat { islandHeight(expanded: model.expanded, barH: barH, phase: model.phase) }
    private var active: Bool { model.phase == .running || model.phase == .paused }
    private var tint: Color { model.phase == .done ? .orange : themeGreen }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                IslandShape(bottomRadius: model.expanded ? 22 : 11).fill(.black)
                VStack(spacing: 0) {
                    Button { model.primaryTap() } label: {
                        HStack(spacing: 0) {
                            ZStack {
                                if active {
                                    Circle().stroke(Color.white.opacity(0.22), lineWidth: 2.5)
                                    Circle().trim(from: 0, to: model.progress)
                                        .stroke(themeGreen, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                                        .rotationEffect(.degrees(-90))
                                    if model.phase == .paused {
                                        Image(systemName: "pause.fill").font(.system(size: 8, weight: .bold))
                                    }
                                } else {
                                    Image(systemName: model.phase == .done ? "bell.fill" : "timer")
                                        .font(.system(size: 17, weight: .semibold))
                                        .rotationEffect(.degrees(model.phase == .done && model.alerting ? model.bellAngle : 0), anchor: .top)
                                        // Cancel island translation so the upper suspension point stays fixed.
                                        .offset(x: model.phase == .done && model.alerting ? -model.shake : 0)
                                }
                            }
                            .foregroundColor(tint)
                            .frame(width: 19, height: 19)
                            .frame(width: (shapeW - notch) / 2)
                            Color.clear.frame(width: notch)
                            Group {
                                if active || model.phase == .done {
                                    Text(model.phase == .done ? "Done" : model.timeText)
                                        .font(.system(size: model.timeText.count > 5 && active ? 12 : 15, weight: .semibold, design: .rounded))
                                        .monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
                                        .frame(width: (shapeW - notch) / 2, alignment: .leading)
                                        .offset(x: active ? 0 : 6)
                                } else {
                                    Text("Star")
                                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                                        .frame(width: (shapeW - notch) / 2)
                                }
                            }.foregroundColor(.white)
                        }.frame(height: barH + topEdgeOverlap).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel(model.expanded ? "收起计时面板" : "展开计时面板")
                    if model.expanded {
                        VStack(spacing: 6) {
                            HStack(spacing: 6) {
                                if active {
                                    action(model.phase == .running ? "暂停" : "继续", icon: model.phase == .running ? "pause.fill" : "play.fill") {
                                        if model.phase == .running { model.pause() } else { model.resume(); model.expanded = true }
                                    }
                                    action("停止", icon: "stop.fill") { model.stop() }
                                    action("重置", icon: "arrow.counterclockwise") { model.restart() }
                                }
                                Spacer(minLength: 0)
                                action("关闭倒计时", icon: "power") { NSApp.terminate(nil) }
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                                    ForEach(presets, id: \.self) { m in
                                        Button { model.start(minutes: Double(m)) } label: {
                                            Text("\(m) min").font(.system(size: 14, weight: .medium))
                                                .frame(maxWidth: .infinity).frame(height: 26)
                                                .background(Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 11))
                                        }.buttonStyle(.plain)
                                    }
                                }
                            }
                        }.foregroundColor(.white).padding(.horizontal, 16).padding(.top, 4)
                            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                    }
                }
            }
            .frame(width: shapeW, height: shapeH)
            .clipShape(IslandShape(bottomRadius: model.expanded ? 22 : 11))
            .contentShape(IslandShape(bottomRadius: model.expanded ? 22 : 11))
            .offset(x: model.shake)
            .contextMenu {
                Button("展开计时面板") { model.openPanel() }
                Button("关闭倒计时") { NSApp.terminate(nil) }
            }
            Spacer(minLength: 0)
        }
        .frame(width: canvasW, height: canvasH, alignment: .top)
        .ignoresSafeArea()
        .animation(.spring(response: 0.42, dampingFraction: 0.76), value: model.expanded)
    }

    private func action(_ title: String, icon: String, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 24)
                .background(Color.white.opacity(0.13), in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain).accessibilityLabel(title).help(title)
    }
}

// MARK: - 只在岛体区域拦截鼠标的宿主视图

final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    var activeRects: () -> [CGRect] = { [] }

    override func hitTest(_ point: NSPoint) -> NSView? {
        for r in activeRects() where r.contains(point) {
            return super.hitTest(point)
        }
        return nil
    }
}

/// 允许窗口浮到菜单栏 / 刘海之上，不被系统约束回可见区域
final class NotchPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        return frameRect
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSPanel?
    private var hosting: PassthroughHostingView<IslandRoot>!
    private let model = CountdownModel()

    private var screen: NSScreen = NSScreen.main ?? NSScreen.screens[0]
    private var notch: CGFloat = 185
    private var barH: CGFloat = 34
    private var canvasW: CGFloat = 225
    private var canvasH: CGFloat = 175
    private var clickMonitor: Any?
    private var localClickMonitor: Any?
    private var isTerminating = false
    private var pendingOpen = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let id = Bundle.main.bundleIdentifier,
           let other = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            other.activate(options: [.activateAllWindows])
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.regular)
        updateMetrics()
        buildWindow()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        // Screen-space routing remains stable while SwiftUI animates or shakes.
        // A 5pt invisible strip below the hardware edge is an additional click target.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            guard let self, !self.isTerminating else { return }
            if self.headerContains(NSEvent.mouseLocation) {
                self.model.primaryTap()
                self.window?.orderFrontRegardless()
            } else {
                self.model.expanded = false
            }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            guard let self, !self.isTerminating else { return event }
            if self.headerContains(NSEvent.mouseLocation) {
                self.model.primaryTap()
                self.window?.orderFrontRegardless()
                return nil
            }
            return event
        }
        if let path = Bundle.main.path(forResource: "AppIcon", ofType: "icns") {
            NSApp.applicationIconImage = NSImage(contentsOfFile: path)
        }

        // 演示 / 自检入口
        if let demo = ProcessInfo.processInfo.environment["CI_DEMO"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self else { return }
                if demo == "pick" {
                    self.model.expanded = true
                } else if let m = Double(demo) {
                    self.model.start(minutes: m)
                }
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !isTerminating else { return false }
        guard let window else {
            // macOS can deliver reopen before didFinishLaunching constructs the panel.
            pendingOpen = true
            return false
        }
        model.openPanel()
        window.orderFrontRegardless()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        isTerminating = true
        model.shutdown()
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        clickMonitor = nil
        localClickMonitor = nil
        NotificationCenter.default.removeObserver(self)
        window?.orderOut(nil)
        return .terminateNow
    }

    private func headerContains(_ point: NSPoint) -> Bool {
        let width = islandWidth(expanded: model.expanded, notch: notch)
        return NSRect(x: screen.frame.midX - width / 2 - 5,
                      y: screen.frame.maxY - barH - 5,
                      width: width + 10, height: barH + 5).contains(point)
    }

    @objc private func screensChanged() {
        updateMetrics()
        rebuildContent()
        layout()
    }

    private func updateMetrics() {
        let s = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? NSScreen.screens[0]
        screen = s

        var raw: CGFloat = 0
        if let left = s.auxiliaryTopLeftArea, let right = s.auxiliaryTopRightArea {
            raw = s.frame.width - left.width - right.width
        }
        notch = raw > 40 ? raw : 150
        barH = s.safeAreaInsets.top > 0 ? s.safeAreaInsets.top : 26
        canvasW = max(340, notch + 156)
        canvasH = barH + 172
    }

    private func makeRoot() -> IslandRoot {
        IslandRoot(
            model: model,
            notch: notch,
            barH: barH,
            canvasW: canvasW,
            canvasH: canvasH
        )
    }

    private func buildWindow() {
        let rect = NSRect(x: 0, y: 0, width: canvasW, height: canvasH)
        let p = NotchPanel(
            contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isReleasedWhenClosed = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .statusBar
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.isMovable = false
        p.isMovableByWindowBackground = false
        p.acceptsMouseMovedEvents = true
        p.animationBehavior = .none
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let hv = PassthroughHostingView(rootView: makeRoot())
        hv.frame = rect
        hv.autoresizingMask = [.width, .height]
        hv.activeRects = { [weak self] in self?.hitRects() ?? [] }
        if #available(macOS 13.0, *) {
            hv.safeAreaRegions = []
        }

        // 用普通 NSView 作为容器，隔离窗口注入的刘海安全区
        let container = NSView(frame: rect)
        container.addSubview(hv)
        p.contentView = container

        window = p
        hosting = hv

        layout()
        if pendingOpen { model.openPanel(); pendingOpen = false }
        p.orderFrontRegardless()
    }

    private func rebuildContent() {
        guard let hv = hosting else { return }
        hv.rootView = makeRoot()
    }

    private func layout() {
        guard let w = window else { return }
        let x = screen.frame.midX - canvasW / 2
        let y = screen.frame.maxY - canvasH + topEdgeOverlap
        w.setFrame(NSRect(x: x, y: y, width: canvasW, height: canvasH), display: true)
        hosting?.frame = NSRect(x: 0, y: 0, width: canvasW, height: canvasH)
    }

    /// 只有岛体本身接收鼠标，其余区域点击穿透到下层窗口
    private func hitRects() -> [CGRect] {
        let w = islandWidth(expanded: model.expanded, notch: notch)
        let h = islandHeight(expanded: model.expanded, barH: barH, phase: model.phase)
        return [CGRect(x: (canvasW - w) / 2 - 5, y: canvasH - h - 5, width: w + 10, height: h + 5)]
    }
}

// MARK: - 入口

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
