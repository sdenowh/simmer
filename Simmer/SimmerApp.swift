//
//  SimmerApp.swift
//  Simmer
//
//  Created by Scott Denowh on 7/10/25.
//

import SwiftUI
import AppKit
import Sparkle

class PopoverWindowProvider: ObservableObject {
    weak var window: NSWindow?
}

@main
struct SimmerApp {
    static func main() {
        if CommandLine.arguments.contains("--mcp") {
            MCPProcess.stdio = true
            let service = SimulatorService()
            MCPStdioServer(backend: service).run()
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

class AppState: ObservableObject {
    @Published var popoverAppearanceCount: Int = 0
}

class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private let appState = AppState()
    private let simulatorService = SimulatorService() // Shared instance
    private var contentView: ContentView?
    private let popoverWindowProvider = PopoverWindowProvider()
    private var updaterController: SPUStandardUpdaterController?
    private var mcpHTTP: MCPHTTPServer?
    private var outsideClickMonitors: [Any] = []
    private var resignActiveObserver: NSObjectProtocol?
    private var menuTrackingObservers: [NSObjectProtocol] = []
    private var contextMenuIsOpen = false
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupPopover()
        setupKeyboardShortcuts()
        setupEditMenu()
        // Initialize Sparkle updater
        updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        startMCPServer()
        // Show the popover automatically on launch, after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.togglePopover()
        }
    }

    @objc func checkForUpdates(_ sender: Any?) {
        updaterController?.checkForUpdates(sender)
    }

    private func startMCPServer() {
        let server = MCPHTTPServer(backend: simulatorService, publishesStatus: true)
        mcpHTTP = server
        do {
            try server.start()
        } catch {
            NSLog("[Simmer] MCP server failed to start: \(error.localizedDescription)")
            MCPRuntimeStatus.shared.noteFailure(error.localizedDescription)
        }
    }
    
    private func setupKeyboardShortcuts() {
        #if DEBUG
        // Debug-only. The monitor swallows the key, so it must not ship:
        // ⌘M is Minimize, and mock mode can overwrite saved pins.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags == .command, event.charactersIgnoringModifiers == "m", !event.isARepeat {
                self.toggleMockData()
                return nil
            }
            return event
        }
        #endif
    }
    
    private func setupEditMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        NSApp.mainMenu = mainMenu
        
        // App menu (about/quit minimal)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Simmer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        
        // Edit menu with standard selectors so cmd-x/c/v/z work
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
    }
    
    private func toggleMockData() {
        // Toggle mock data state
        let currentState = UserDefaults.standard.bool(forKey: "UseMockData")
        let newState = !currentState
        UserDefaults.standard.set(newState, forKey: "UseMockData")
        
        // Enable/disable mock data in the service
        simulatorService.enableMockData(newState)
        
        // Show a notification
        let notification = NSUserNotification()
        notification.title = "Simmer"
        notification.informativeText = newState ? "Mock data enabled (⌘+M to disable)" : "Mock data disabled (⌘+M to enable)"
        notification.soundName = NSUserNotificationDefaultSoundName
        NSUserNotificationCenter.default.deliver(notification)
    }
    
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "iphone", accessibilityDescription: "Simmer")
            button.action = #selector(togglePopover)
            button.target = self
        }
    }
    
    private func setupPopover() {
        popover = NSPopover()
        popover?.contentSize = NSSize(width: 320, height: 500)
        // AppKit's transient behavior misses clicks in other apps while this agent
        // is inactive (the panel stays stuck open) and swallows the click when it
        // does dismiss. Dismissal is handled in startOutsideClickMonitoring().
        popover?.behavior = .applicationDefined
        popover?.delegate = self
        let hostingController = NSHostingController(rootView: ContentView(appState: appState, simulatorService: simulatorService).environmentObject(popoverWindowProvider))
        // Force dark appearance for the popover content
        hostingController.view.appearance = NSAppearance(named: .darkAqua)
        popover?.contentViewController = hostingController
        observeContextMenus()
        // Set window reference after popover is shown
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.popoverWindowProvider.window = hostingController.view.window
        }
    }

    /// Menus resign key on the popover. If AppKit asks to close while one is
    /// tracking, keep the popover up so the menu can finish.
    private func observeContextMenus() {
        let center = NotificationCenter.default
        menuTrackingObservers = [
            center.addObserver(forName: .simmerContextMenuWillOpen, object: nil, queue: .main) { [weak self] _ in
                self?.contextMenuIsOpen = true
            },
            center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                self?.contextMenuIsOpen = true
            },
            center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                self?.contextMenuIsOpen = false
            }
        ]
    }
    
    @objc private func togglePopover() {
        if let button = statusItem?.button {
            if popover?.isShown == true {
                closePopover()
            } else {
                popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                // Set window reference after popover is shown
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    if let window = self.popover?.contentViewController?.view.window {
                        self.popoverWindowProvider.window = window
                        // Ensure the popover window uses dark appearance
                        window.appearance = NSAppearance(named: .darkAqua)
                    }
                }
            }
        }
    }

    private func closePopover() {
        guard popover?.isShown == true else { return }
        // close() still dismisses when a sheet or menu is attached. performClose
        // bails out in those cases, and it also consults popoverShouldClose, which
        // intentionally vetoes the right-click that opens a context menu.
        popover?.close()
    }

    /// Closes the popover on an outside click without consuming that click.
    /// Global monitors only observe events posted to other apps, so the click still lands.
    private func startOutsideClickMonitoring() {
        stopOutsideClickMonitoring()

        let mouseDown: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mouseDown, handler: { [weak self] event in
            // Delivered only for other apps, and only as a copy, so the click still lands.
            // Ignore the status item: that click is the toggle, and closing here would
            // make the subsequent mouse-up open the popover again.
            guard let self, !(event.type == .leftMouseDown && self.eventHitsStatusItem(event)) else { return }
            DispatchQueue.main.async {
                self.closePopover()
            }
        }) {
            outsideClickMonitors.append(monitor)
        }

        if let monitor = NSEvent.addLocalMonitorForEvents(matching: mouseDown, handler: { [weak self] event in
            guard let self else { return event }
            if self.shouldDismissPopover(for: event) {
                // Close after this event is dispatched so the click reaches its target.
                DispatchQueue.main.async {
                    self.closePopover()
                }
            }
            return event
        }) {
            outsideClickMonitors.append(monitor)
        }

        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self, self.shouldClosePopover(forEscape: event) else { return event }
            self.closePopover()
            return nil
        }) {
            outsideClickMonitors.append(monitor)
        }

        // Subscribe next turn so a resign posted while the popover is being shown
        // does not immediately dismiss it. Keyboard app switches have no click to pass through.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.popover?.isShown == true, self.resignActiveObserver == nil else { return }
            self.resignActiveObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self, !self.contextMenuIsOpen else { return }
                self.closePopover()
            }
        }
    }

    private func stopOutsideClickMonitoring() {
        for monitor in outsideClickMonitors {
            NSEvent.removeMonitor(monitor)
        }
        outsideClickMonitors.removeAll()
        if let resignActiveObserver {
            NotificationCenter.default.removeObserver(resignActiveObserver)
            self.resignActiveObserver = nil
        }
    }

    private func shouldDismissPopover(for event: NSEvent) -> Bool {
        if contextMenuIsOpen { return false }
        // The status item action toggles on left mouse up. Dismissing on mouse down
        // would close the popover and then the action would open it again.
        if event.type == .leftMouseDown, eventHitsStatusItem(event) {
            return false
        }
        guard let window = event.window else { return true }
        // Menu tracking usually consumes its own clicks. If one reaches us, leave it alone.
        if window.level == .popUpMenu {
            return false
        }
        return !isPopoverWindow(window)
    }

    private func shouldClosePopover(forEscape event: NSEvent) -> Bool {
        guard event.keyCode == 53 else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock)
        guard flags.isEmpty else { return false }
        guard let popoverWindow = popover?.contentViewController?.view.window,
              popoverWindow.isKeyWindow,
              popoverWindow.sheets.isEmpty else {
            return false
        }
        return true
    }

    private func eventHitsStatusItem(_ event: NSEvent) -> Bool {
        guard let button = statusItem?.button, let buttonWindow = button.window else { return false }
        if event.window === buttonWindow {
            return true
        }
        let screenPoint = screenLocation(of: event)
        let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        return buttonRect.contains(screenPoint)
    }

    private func screenLocation(of event: NSEvent) -> NSPoint {
        guard let window = event.window else { return event.locationInWindow }
        return window.convertPoint(toScreen: event.locationInWindow)
    }

    private func popoverWindows() -> [NSWindow] {
        guard let popoverWindow = popover?.contentViewController?.view.window else { return [] }
        var windows = [popoverWindow]
        windows.append(contentsOf: popoverWindow.sheets)
        if let children = popoverWindow.childWindows {
            windows.append(contentsOf: children)
        }
        return windows
    }

    private func isPopoverWindow(_ window: NSWindow) -> Bool {
        let roots = popoverWindows()
        var current: NSWindow? = window
        var seen = Set<ObjectIdentifier>()
        while let candidate = current {
            if roots.contains(where: { $0 === candidate }) {
                return true
            }
            if !seen.insert(ObjectIdentifier(candidate)).inserted {
                return false
            }
            current = candidate.sheetParent ?? candidate.parent
        }
        return false
    }
    
    // MARK: - NSPopoverDelegate
    
    func popoverShouldClose(_ popover: NSPopover) -> Bool {
        if contextMenuIsOpen { return false }
        if let event = NSApp.currentEvent {
            switch event.type {
            case .rightMouseDown, .rightMouseUp, .rightMouseDragged:
                return false
            default:
                break
            }
        }
        return true
    }

    func popoverDidShow(_ notification: Notification) {
        appState.popoverAppearanceCount += 1
        startOutsideClickMonitoring()
        if let window = popover?.contentViewController?.view.window {
            popoverWindowProvider.window = window
            window.appearance = NSAppearance(named: .darkAqua)
        }

        // Reload apps first so selectedApp points at the current container,
        // then refresh snapshots from that updated record.
        if let selectedSimulator = simulatorService.selectedSimulator {
            simulatorService.loadApps(for: selectedSimulator)
            simulatorService.refreshSelectedAppDiskUsage()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        stopOutsideClickMonitoring()
    }
}
