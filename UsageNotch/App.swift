import AppKit
import SwiftUI

@main
enum UsageNotchApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = UsageStore()
    private var notch: NotchPanel?
    private var watcher: UsageLogWatcher?
    private var refreshTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        notch = NotchPanel(store: store)
        notch?.reposition()
        notch?.playFirstLaunchMark()
        watcher = UsageLogWatcher { [weak store] in store?.logsChanged() }
        refresh()

        NotificationCenter.default.addObserver(
            self, selector: #selector(screenChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(wokeUp), name: NSWorkspace.didWakeNotification, object: nil
        )
        let timer = Timer(timeInterval: 60, target: self, selector: #selector(refresh), userInfo: nil, repeats: true)
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        watcher?.stop()
        notch?.stopMonitoringMouse()
        CLIConnection.stopAll()
    }

    @objc private func screenChanged() { notch?.reposition() }
    @objc private func refresh() {
        watcher?.updateRoots()
        store.refresh()
    }
    @objc private func wokeUp() {
        notch?.reposition()
        refresh()
    }
}

@MainActor
private final class NotchPanel: NSObject {
    private let displayName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "On pace."
    private let store: UsageStore
    private let panel = PassivePanel(
        contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
    )
    private let surface = NotchSurface()
    private let presentation = NotchPresentation()
    private var placement: Placement?
    private var compactLayout = CompactNotchLayout()
    private var hoverTask: Task<Void, Never>?
    private var displayLink: CADisplayLink?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var inside = false
    private var expanded: Bool { presentation.expanded }
    private var pinned: Bool { presentation.pinned }
    private var menuOpen = false
    private var aboutWindow: NSWindow?
    private var opensOnHover: Bool {
        !UserDefaults.standard.bool(forKey: "opensOnClickOnly")
    }

    init(store: UsageStore) {
        self.store = store
        super.init()
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.acceptsMouseMovedEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.title = displayName
        panel.contentView = surface

        let movement: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: movement) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePointer() }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: movement) { [weak self] event in
            self?.updatePointer()
            return event
        }
    }

    func stopMonitoringMouse() {
        stopTrackingShape()
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        globalMouseMonitor = nil
        localMouseMonitor = nil
    }

    func playFirstLaunchMark() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "hasSeenTrailLaunch") else { return }
        defaults.set(true, forKey: "hasSeenTrailLaunch")
        presentation.showsLaunchMark = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(650))
            self?.presentation.showsLaunchMark = false
        }
    }

    func reposition() {
        hoverTask?.cancel()
        stopTrackingShape()
        let screens = NSScreen.screens
        let screen = screens.first {
            guard let number = $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return $0.safeAreaInsets.top > 0 && CGDisplayIsBuiltin(number.uint32Value) != 0
        } ?? screens.first
        guard let screen else {
            placement = nil
            panel.orderOut(nil)
            return
        }
        let placement = Placement(screen)
        self.placement = placement
        compactLayout = EdgeLight.compactLayout(cameraWidth: placement.cameraWidth, store: store)
        inside = false
        presentation.animates = false
        presentation.expanded = pinned
        panel.setFrame(placement.frame, display: false)
        let host = NotchHostingView(rootView: NotchView(
            store: store, cameraWidth: placement.cameraWidth, detailWidth: placement.detailWidth,
            presentation: presentation,
            togglePin: { [weak self] in self?.togglePin() },
            openSettings: { [weak self] in self?.settingsMenu() },
            compactLayoutChanged: { [weak self] in self?.updateCompactLayout($0) }
        ))
        host.sizingOptions = []
        surface.install(host)
        showShape(on: placement, animated: false)
        panel.orderFrontRegardless()
        updatePointer()
    }

    private func updateCompactLayout(_ layout: CompactNotchLayout) {
        guard layout != compactLayout else { return }
        compactLayout = layout
        guard let placement, !expanded else { return }
        showShape(on: placement, animated: false)
        updatePointer()
    }

    private func showShape(on placement: Placement, animated: Bool) {
        surface.show(size: placement.size(expanded: expanded, collapsedWidth: compactLayout.width),
                     centerOffset: expanded ? 0 : compactLayout.centerOffset,
                     expanded: expanded, animated: animated)
    }

    private func updatePointer() {
        guard placement != nil else { return }
        let screenPoint = NSEvent.mouseLocation
        let hit = panel.frame.contains(screenPoint) && surface.contains(panel.convertPoint(fromScreen: screenPoint))
        if panel.ignoresMouseEvents == hit { panel.ignoresMouseEvents = !hit }
        guard inside != hit else { return }
        inside = hit
        scheduleHover()
    }

    private func scheduleHover() {
        hoverTask?.cancel()
        guard opensOnHover, !pinned, !menuOpen, inside != expanded else { return }
        let entered = inside
        hoverTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(entered ? 100 : 155))
            guard !Task.isCancelled, let self, self.inside == entered, !self.pinned, !self.menuOpen else { return }
            self.setExpanded(entered)
        }
    }

    private func togglePin() {
        hoverTask?.cancel()
        presentation.pinned.toggle()
        setExpanded(pinned || (opensOnHover && inside))
    }

    private func setExpanded(_ expanded: Bool) {
        guard let placement, expanded != self.expanded else { return }
        let animated = panel.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        presentation.animates = animated
        presentation.expanded = expanded
        showShape(on: placement, animated: animated)
        if animated {
            if displayLink == nil {
                let link = surface.displayLink(target: self, selector: #selector(trackMovingShape(_:)))
                link.add(to: .main, forMode: .common)
                displayLink = link
            }
        } else {
            stopTrackingShape()
        }
        updatePointer()
    }

    @objc private func trackMovingShape(_ link: CADisplayLink) {
        // Only hit testing runs on AppKit's display link. Core Animation owns rendering.
        updatePointer()
        if !surface.isAnimating { stopTrackingShape() }
    }

    private func stopTrackingShape() {
        displayLink?.invalidate()
        displayLink = nil
    }

    private func settingsMenu() {
        let menu = NSMenu()
        let hover = item("Open on hover", action: #selector(toggleHoverSetting), in: menu)
        hover.state = opensOnHover ? .on : .off
        menu.addItem(.separator())
        item("About \(displayName)", action: #selector(showAbout), in: menu)
        item("Quit \(displayName)", action: #selector(quit), in: menu)
        showMenu(menu)
    }

    @discardableResult
    private func item(_ title: String, action: Selector, in menu: NSMenu) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func showMenu(_ menu: NSMenu) {
        hoverTask?.cancel()
        menuOpen = true
        let frame = panel.frame
        let anchor = NSPoint(x: frame.maxX - NotchShape.shadowSide - 80, y: frame.maxY - 31)
        menu.popUp(positioning: nil, at: anchor, in: nil)
        menuOpen = false
        updatePointer()
        scheduleHover()
    }

    @objc private func toggleHoverSetting() {
        UserDefaults.standard.set(opensOnHover, forKey: "opensOnClickOnly")
        if !opensOnHover && !pinned {
            setExpanded(false)
        }
    }

    @objc private func showAbout() {
        let window = aboutWindow ?? NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 182),
            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false
        )
        if !window.isVisible {
            window.title = "About \(displayName)"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: AboutOnPace())
            window.center()
        }
        aboutWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

private final class NotchHostingView: NSHostingView<NotchView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class PassivePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct Placement {
    let centerX: CGFloat
    let top: CGFloat
    let cameraWidth: CGFloat
    let detailWidth: CGFloat

    func size(expanded: Bool, collapsedWidth: CGFloat) -> CGSize {
        expanded
            ? CGSize(width: detailWidth, height: NotchShape.expandedHeight)
            : CGSize(width: collapsedWidth, height: NotchShape.compactHeight)
    }

    var frame: NSRect {
        let width = detailWidth + 2 * NotchShape.shadowSide
        let height = NotchShape.expandedHeight + NotchShape.shadowBottom
        return NSRect(x: centerX - width / 2, y: top - height, width: width, height: height)
    }

    @MainActor
    init(_ screen: NSScreen) {
        let notchHeight = screen.safeAreaInsets.top
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
           right.minX > left.maxX {
            centerX = (left.maxX + right.minX) / 2
            cameraWidth = right.minX - left.maxX
        } else {
            centerX = screen.frame.midX
            cameraWidth = notchHeight > 0 ? 185 : 0
        }
        detailWidth = min(NotchShape.expandedWidth, screen.frame.width - 20)
        top = notchHeight > 0 ? screen.frame.maxY : screen.frame.maxY - NSStatusBar.system.thickness - 4
    }
}
