//
//  ContentView.swift
//  Simmer
//
//  Created by Scott Denowh on 7/10/25.
//

import SwiftUI

#if os(macOS)
import AppKit
#endif

struct ContentView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var simulatorService: SimulatorService
    @ObservedObject private var mcpStatus = MCPRuntimeStatus.shared
    @State private var selectedSimulator: Simulator?
    @State private var selectedApp: App?
    
    private func getAppVersion() -> String {
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
           let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
            return "\(version) (\(build))"
        }
        return "Unknown"
    }

    private func copyMCPConfig() {
        let entry: [String: Any]
        if mcpStatus.isRunning {
            entry = SimmerMCPConfig.httpServerEntry()
        } else if let executable = Bundle.main.executablePath {
            entry = SimmerMCPConfig.stdioServerEntry(executablePath: executable)
        } else {
            entry = SimmerMCPConfig.httpServerEntry()
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(SimmerMCPConfig.pretty(entry), forType: .string)
        let notification = NSUserNotification()
        notification.title = "Simmer"
        notification.informativeText = "MCP config copied. Add it to Cursor's MCP settings."
        NSUserNotificationCenter.default.deliver(notification)
    }
    
    // Public method to refresh disk usage for expanded app
    public func refreshExpandedAppDiskUsage() {
        if let _ = selectedSimulator, let app = selectedApp {
            simulatorService.loadSnapshots(for: app)
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "iphone")
                    .foregroundColor(.blue)
                Text("Simmer")
                    .font(.headline)
                Spacer()
                
                Menu {
                    Button("Refresh Simulators") {
                        simulatorService.loadSimulators()
                    }

                    Divider()

                    Button("Copy MCP Config") {
                        copyMCPConfig()
                    }

                    Text("MCP \(mcpStatus.detail)")
                        .disabled(true)
                    
                    Divider()
                    
                    Button("Check for Updates…") {
                        #if os(macOS)
                        NSApp.sendAction(#selector(AppDelegate.checkForUpdates(_:)), to: nil, from: nil)
                        #endif
                    }

                    Button("About Simmer") {
                        #if os(macOS)
                        AboutWindowController.shared.showAbout()
                        #endif
                    }
                    
                    Divider()
                    
                    Text("Version \(getAppVersion())")
                        .disabled(true)
                    
                    Divider()
                    
                    Button("Quit Simmer") {
                        NSApplication.shared.terminate(nil)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundColor(.secondary)
                        .font(.system(size: 12))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
                .menuIndicator(.hidden)
            }
            .padding()
            .background(
                VisualEffectView(material: .underWindowBackground, blendingMode: .behindWindow)
            )
            
            Divider()
            
            // Content
            ZStack {
                // Root background
                VisualEffectView(material: .underWindowBackground, blendingMode: .behindWindow)
                    .ignoresSafeArea()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(simulatorService.simulators) { simulator in
                            SimulatorRowView(
                                simulator: simulator,
                                isSelected: selectedSimulator?.id == simulator.id,
                                onTap: {
                                    if selectedSimulator?.id == simulator.id {
                                        selectedSimulator = nil
                                        selectedApp = nil
                                    } else {
                                        selectedSimulator = simulator
                                        selectedApp = nil
                                        simulatorService.loadApps(for: simulator)
                                    }
                                },
                                simulatorService: simulatorService
                            )
                            
                            if selectedSimulator?.id == simulator.id {
                                ForEach(simulatorService.apps) { app in
                                    AppRowView(
                                        app: app,
                                        simulator: simulator,
                                        isSelected: selectedApp?.id == app.id,
                                        onTap: {
                                            if selectedApp?.id == app.id {
                                                selectedApp = nil
                                            } else {
                                                selectedApp = app
                                                simulatorService.loadSnapshots(for: app)
                                            }
                                        },
                                        simulatorService: simulatorService
                                    )

                                    if selectedApp?.id == app.id {
                                        AppActionsView(app: app, simulatorService: simulatorService)
                                    }
                                }
                            }
                        }
                    }
                }
                
                // Progress overlay. The fill sits over the list so clicks cannot reach Take Snapshot while it runs.
            if simulatorService.isSnapshotOperationInProgress {
                ZStack(alignment: .bottom) {
                    Rectangle()
                        .fill(Color.black.opacity(0.001))
                        .contentShape(Rectangle())
                        .onTapGesture {}

                    VStack(spacing: 4) {
                        Text(simulatorService.snapshotOperationMessage)
                            .font(.system(size: 11))
                            .foregroundColor(simulatorService.snapshotOperationFailed ? Color.orange : .white)
                            .multilineTextAlignment(.center)

                        if !simulatorService.snapshotOperationFailed {
                            ProgressView(value: min(max(simulatorService.snapshotOperationProgress, 0), 1))
                                .progressViewStyle(LinearProgressViewStyle(tint: .blue))
                                .scaleEffect(y: 0.8)
                                .transaction { $0.animation = nil }

                            Text(snapshotProgressPercent(simulatorService.snapshotOperationProgress))
                                .font(.system(size: 11))
                                .monospacedDigit()
                                .foregroundColor(.white.opacity(0.8))
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(
                        VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                    )
                    .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(true)
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .move(edge: .bottom).combined(with: .opacity)
                ))
                .animation(.easeInOut(duration: 0.3), value: simulatorService.isSnapshotOperationInProgress)
            }
            }
            .frame(width: 320, height: 450)
        }
    }
}

private func snapshotProgressPercent(_ fraction: Double) -> String {
    let percent = min(max(fraction, 0), 1) * 100
    if percent >= 100 { return "100%" }
    return String(format: "%.1f%%", percent)
}

#if os(macOS)
private func maskedAppIcon(from image: NSImage, cornerRadius: CGFloat = 16) -> NSImage {
    let size = image.size
    let rect = NSRect(origin: .zero, size: size)
    let newImage = NSImage(size: size)
    newImage.lockFocus()
    let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
    path.addClip()
    image.draw(in: rect)
    newImage.unlockFocus()
    return newImage
}

func simmerAppIcon(from iconPath: String?) -> NSImage? {
    guard let iconPath, !iconPath.isEmpty else { return nil }
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: iconPath, isDirectory: &isDirectory) {
        if isDirectory.boolValue {
            return NSWorkspace.shared.icon(forFile: iconPath)
        }
        if let image = NSImage(contentsOfFile: iconPath) {
            return image
        }
    }
    return NSImage(named: iconPath)
}

func presentSimmerAlert(_ alert: NSAlert, window: NSWindow?, completion: @escaping (NSApplication.ModalResponse) -> Void) {
    if let window {
        alert.beginSheetModal(for: window, completionHandler: completion)
    } else if let keyWindow = NSApp.keyWindow {
        alert.beginSheetModal(for: keyWindow, completionHandler: completion)
    } else {
        completion(alert.runModal())
    }
}

func presentSimmerAlert(message: String, window: NSWindow?) {
    let alert = NSAlert()
    alert.messageText = "Simmer"
    alert.informativeText = message
    alert.alertStyle = .warning
    alert.addButton(withTitle: "OK")
    presentSimmerAlert(alert, window: window) { _ in }
}
#endif

struct RowContextMenuItem {
    var title: String
    var action: () -> Void
}

/// Presents an AppKit context menu on right-click without taking the left-click.
/// SwiftUI's context menu never appears here: the row is a button inside a popover,
/// so the right-click toggles the row instead of opening a menu.
struct RowContextMenu: NSViewRepresentable {
    var items: [RowContextMenuItem]

    func makeNSView(context: Context) -> RowContextMenuAnchor {
        RowContextMenuAnchor()
    }

    func updateNSView(_ nsView: RowContextMenuAnchor, context: Context) {
        nsView.items = items
    }
}

final class RowContextMenuAnchor: NSView {
    var items: [RowContextMenuItem] = []
    private var monitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        pinToSuperview()
    }

    override func layout() {
        super.layout()
        pinToSuperview()
    }

    private func pinToSuperview() {
        guard let superview else { return }
        let target = superview.bounds
        if frame != target {
            frame = target
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeMonitor()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
            guard let self else { return event }
            guard self.shouldOpenMenu(for: event) else { return event }
            self.openMenu(with: event)
            return nil
        }
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    private func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func shouldOpenMenu(for event: NSEvent) -> Bool {
        guard !items.isEmpty, let window, event.window === window else { return false }
        let isContextClick = event.type == .rightMouseDown || event.modifierFlags.contains(.control)
        guard isContextClick else { return false }
        let local = convert(event.locationInWindow, from: nil)
        return bounds.contains(local)
    }

    private func openMenu(with event: NSEvent) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (index, item) in items.enumerated() {
            let menuItem = NSMenuItem(title: item.title, action: #selector(performItem(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.tag = index
            menuItem.isEnabled = true
            menu.addItem(menuItem)
        }
        // Pop the menu on the next turn. Doing it inside the right-click monitor
        // makes AppKit treat that same click as a dismissal, so the menu never stays up.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil else { return }
            NotificationCenter.default.post(name: .simmerContextMenuWillOpen, object: nil)
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }

    @objc private func performItem(_ sender: NSMenuItem) {
        guard items.indices.contains(sender.tag) else { return }
        items[sender.tag].action()
    }
}

extension Notification.Name {
    static let simmerContextMenuWillOpen = Notification.Name("SimmerContextMenuWillOpen")
}

struct SimulatorRowView: View {
    let simulator: Simulator
    let isSelected: Bool
    let onTap: () -> Void
    @ObservedObject var simulatorService: SimulatorService
    
    var body: some View {
        HStack(spacing: 0) {
            Button(action: onTap) {
                HStack {
                    Image(systemName: simulator.deviceType.icon)
                        .foregroundColor(.blue)
                        .frame(width: 20)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(simulator.name)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.primary)
                        
                        Text(simulator.formattedVersion)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Image(systemName: isSelected ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())

            Button(action: {
                simulatorService.togglePin(for: simulator)
            }) {
                Image(systemName: simulator.isPinned ? "pin.fill" : "pin")
                    .foregroundColor(simulator.isPinned ? .orange : .secondary)
                    .font(.system(size: 12))
                    .frame(width: 28, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            .padding(.trailing, 4)
        }
        .background(isSelected ? Color.blue.opacity(0.1) : Color.clear)
        .background(RowContextMenu(items: [
            RowContextMenuItem(title: "Open Simulator") {
                simulatorService.openInSimulator(simulator)
            }
        ]))
    }
}

struct AppRowView: View {
    let app: App
    let simulator: Simulator
    let isSelected: Bool
    let onTap: () -> Void
    @ObservedObject var simulatorService: SimulatorService
    
    var body: some View {
        Button(action: onTap) {
            HStack {
                // App icon
                if let image = simmerAppIcon(from: app.iconPath) {
                    Image(nsImage: image)
                        .resizable()
                        .frame(width: 20, height: 20)
                        .cornerRadius(4)
                } else {
                    Image(systemName: "app")
                        .foregroundColor(.gray)
                        .frame(width: 20, height: 20)
                }
                
                Text(app.name)
                    .font(.system(size: 12))
                    .foregroundColor(.primary)
                
                Spacer()
                
                Image(systemName: isSelected ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .padding(.leading, 20)
            .background(isSelected ? Color.blue.opacity(0.1) : Color.clear)
            .contentShape(Rectangle())

        }
        .buttonStyle(PlainButtonStyle())
        .background(RowContextMenu(items: [
            RowContextMenuItem(title: "Launch \(app.name)") {
                simulatorService.launch(app, on: simulator)
            }
        ]))
    }
}

struct AppActionsView: View {
    let app: App
    @ObservedObject var simulatorService: SimulatorService
    @EnvironmentObject var popoverWindowProvider: PopoverWindowProvider
    @State private var isShowingPushSheet: Bool = false
    @State private var pushPayloadText: String = ""
    @State private var pushDescriptionText: String = ""
    @State private var pushSheetError: String = ""
    @State private var lastSendError: String = ""
    
    private var currentApp: App? {
        simulatorService.apps.first { $0.id == app.id }
    }
    
    private var displayApp: App {
        if let currentApp = currentApp {
            return currentApp
        } else {
            // If we don't have a current app yet, show loading state if documents path exists
            var displayApp = app
            if !app.documentsPath.isEmpty {
                displayApp.startLoadingDocumentsSize()
            }
            return displayApp
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Show Documents Folder
            Button(action: {
                if let message = simulatorService.openDocumentsFolder(for: displayApp) {
                    presentSimmerAlert(message: message, window: popoverWindowProvider.window)
                }
            }) {
                HStack {
                    Image(systemName: "folder")
                        .foregroundColor(.blue)
                        .frame(width: 20)
                    
                    Text("Show Documents Folder")
                        .font(.system(size: 12))
                        .foregroundColor(.primary)
                    
                    Spacer()
                    
                    if displayApp.isLoadingDocumentsSize {
                        ProgressView()
                            .scaleEffect(0.4)
                            .frame(width: 8, height: 8)
                    } else {
                        Text(DirectorySize(size: displayApp.documentsSize).formattedSize)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .padding(.leading, 40)
            }
            .buttonStyle(PlainButtonStyle())
            
            // Document Snapshots
            VStack(spacing: 0) {
                let snapshotBusy = simulatorService.isSnapshotOperationInProgress
                Button(action: {
                    guard !simulatorService.isSnapshotOperationInProgress else { return }
                    simulatorService.takeSnapshot(for: app)
                }) {
                    HStack {
                        Image(systemName: "camera")
                            .foregroundColor(snapshotBusy ? .secondary : .green)
                            .frame(width: 20)
                        
                        Text("Take Documents Snapshot")
                            .font(.system(size: 12))
                            .foregroundColor(snapshotBusy ? .secondary : .primary)
                        
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .padding(.leading, 40)
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(snapshotBusy)
                
                // Existing snapshots
                ForEach(simulatorService.snapshots) { snapshot in
                    SnapshotRowView(
                        snapshot: snapshot,
                        app: app,
                        simulatorService: simulatorService
                    )
                }
                
                // Delete All Snapshots
                if !simulatorService.snapshots.isEmpty {
                    Button(action: {
                        showDeleteAllConfirmation()
                    }) {
                        HStack {
                            Image(systemName: "trash")
                                .foregroundColor(.red)
                                .frame(width: 20)
                            
                            Text("Delete All Snapshots")
                                .font(.system(size: 12))
                                .foregroundColor(.red)
                            
                            Spacer()
                            
                            if simulatorService.isLoadingTotalSnapshotsSize {
                                ProgressView()
                                    .scaleEffect(0.4)
                                    .frame(width: 8, height: 8)
                            } else {
                                Text(simulatorService.getAllSnapshotsSize().formattedSize)
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .padding(.leading, 40)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                
                // Push Notifications
                VStack(spacing: 0) {
                    Button(action: {
                        pushSheetError = ""
                        prepareDefaultPushPayload()
                        isShowingPushSheet = true
                    }) {
                        HStack {
                            Image(systemName: "bell")
                                .foregroundColor(.yellow)
                                .frame(width: 20)
                            Text("Send Push Notification")
                                .font(.system(size: 12))
                                .foregroundColor(.primary)
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .padding(.leading, 40)
                    }
                    .buttonStyle(PlainButtonStyle())

                    HStack {
                        Button(action: {
                            if let sim = simulatorService.selectedSimulator {
                                simulatorService.repeatLastPush(for: app, on: sim) { success, error in
                                    if !success {
                                        lastSendError = error ?? "Unknown error"
                                    }
                                }
                            }
                        }) {
                            HStack {
                                Image(systemName: "arrow.uturn.right")
                                    .foregroundColor(.orange)
                                    .frame(width: 20)
                                Text("Repeat Last Notification")
                                    .font(.system(size: 12))
                                    .foregroundColor(.primary)
                                Spacer()
                            }
                        }
                        .buttonStyle(PlainButtonStyle())
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .padding(.leading, 40)

                        Menu {
                            if let sim = simulatorService.selectedSimulator {
                                let history = simulatorService.getPushHistory(for: app, on: sim)
                                if history.isEmpty {
                                    Text("No Saved Notifications").disabled(true)
                                } else {
                                    ForEach(history, id: \.id) { item in
                                        Button(action: {
                                            pushPayloadText = item.payloadJSON
                                            pushDescriptionText = item.name
                                            isShowingPushSheet = true
                                        }) {
                                            HStack {
                                                Text(displayName(for: item))
                                                Spacer()
                                                Text(item.createdAt, style: .date)
                                                    .foregroundColor(.secondary)
                                            }
                                        }
                                    }
                                }
                            }
                        } label: {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                                .foregroundColor(.secondary)
                                .font(.system(size: 12))
                                .frame(width: 24, height: 24)
                        }
                        .menuIndicator(.hidden)
                        .buttonStyle(PlainButtonStyle())
                        .padding(.trailing, 8)
                    }
                    if !lastSendError.isEmpty {
                        Text(lastSendError)
                            .font(.system(size: 10))
                            .foregroundColor(.red)
                            .padding(.leading, 64)
                            .padding(.bottom, 4)
                    }
                }
            }
        }
        .sheet(isPresented: $isShowingPushSheet) {
            PushComposeSheet(
                app: app,
                simulator: simulatorService.selectedSimulator,
                history: (simulatorService.selectedSimulator != nil) ? simulatorService.getPushHistory(for: app, on: simulatorService.selectedSimulator!) : [],
                payloadText: $pushPayloadText,
                descriptionText: $pushDescriptionText,
                onCancel: {
                    isShowingPushSheet = false
                },
                onSend: {
                    guard let sim = simulatorService.selectedSimulator else { return }
                    pushSheetError = ""
                    lastSendError = ""
                    simulatorService.sendPushNotification(payloadJSON: pushPayloadText, name: pushDescriptionText.isEmpty ? nil : pushDescriptionText, for: app, on: sim) { success, error in
                        if success {
                            isShowingPushSheet = false
                        } else {
                            pushSheetError = error ?? "Unknown error"
                            lastSendError = pushSheetError
                        }
                    }
                },
                errorText: pushSheetError
            )
            .frame(width: 520, height: 360)
        }
    }

    private func prepareDefaultPushPayload() {
        if pushPayloadText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            pushPayloadText = """
            {\n  \"aps\": {\n    \"alert\": {\n      \"title\": \"Test Notification\",\n      \"body\": \"Hello from Simmer\"\n    },\n    \"sound\": \"default\"\n  }\n}
            """
        }
    }

    private func displayName(for item: SentNotification) -> String {
        let trimmed = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "(untitled)" : trimmed
    }

    private func showDeleteAllConfirmation() {
        let alert = NSAlert()
        alert.messageText = "Delete All Snapshots"
        alert.informativeText = "This deletes every snapshot for \(app.name). Other apps on this simulator are left alone. This action cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        presentSimmerAlert(alert, window: popoverWindowProvider.window) { response in
            if response == .alertFirstButtonReturn {
                simulatorService.deleteAllSnapshots(for: displayApp)
            }
        }
    }
}

struct SnapshotRowView: View {
    let snapshot: Snapshot
    let app: App
    @ObservedObject var simulatorService: SimulatorService
    @EnvironmentObject var popoverWindowProvider: PopoverWindowProvider
    
    static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()
    
    private var currentApp: App? {
        simulatorService.apps.first { $0.id == app.id }
    }
    
    private var displayApp: App {
        if let currentApp = currentApp {
            return currentApp
        } else {
            return app
        }
    }
    
    var body: some View {
        HStack {
            Button(action: {
                showRestoreConfirmation()
            }) {
                HStack {
                    Image(systemName: "arrow.clockwise")
                        .foregroundColor(.orange)
                        .frame(width: 20)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text((snapshot.displayName?.isEmpty == false ? snapshot.displayName! : snapshot.name))
                            .font(.system(size: 11))
                            .foregroundColor(.primary)
                        
                        Text(SnapshotRowView.dateTimeFormatter.string(from: snapshot.date))
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    if snapshot.isLoadingSize {
                        ProgressView()
                            .scaleEffect(0.4)
                            .frame(width: 8, height: 8)
                    } else {
                        Text(DirectorySize(size: snapshot.size).formattedSize)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .padding(.leading, 60)
            }
            .buttonStyle(PlainButtonStyle())
            .contextMenu {
                Button("Rename") {
                    showRenamePrompt()
                }
            }
            
            Button(action: {
                simulatorService.deleteSnapshot(snapshot)
            }) {
                Image(systemName: "xmark.circle")
                    .foregroundColor(.red)
                    .font(.system(size: 12))
            }
            .buttonStyle(PlainButtonStyle())
            .padding(.trailing, 8)
        }
    }
    
    private func showRenamePrompt() {
        #if os(macOS)
        let alert = NSAlert()
        alert.messageText = "Rename Snapshot"
        alert.informativeText = "Set an optional display name for this snapshot."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        let effectiveName = (snapshot.displayName?.isEmpty == false ? snapshot.displayName! : "")
        textField.stringValue = effectiveName
        alert.accessoryView = textField

        presentSimmerAlert(alert, window: popoverWindowProvider.window) { response in
            if response == .alertFirstButtonReturn {
                simulatorService.renameSnapshotDisplayName(snapshot, to: textField.stringValue)
            }
        }
        #endif
    }

    private func showRestoreConfirmation() {
        let alert = NSAlert()
        alert.messageText = "Restore Snapshot"
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        let formattedDate = dateFormatter.string(from: snapshot.date)
        alert.informativeText = "This will replace the current Documents folder with the snapshot from \(formattedDate). This action cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        #if os(macOS)
        if let image = simmerAppIcon(from: displayApp.iconPath) {
            alert.icon = maskedAppIcon(from: image, cornerRadius: 16)
        }
        #endif
        presentSimmerAlert(alert, window: popoverWindowProvider.window) { response in
            if response == .alertFirstButtonReturn {
                simulatorService.restoreSnapshot(snapshot, for: displayApp)
            }
        }
    }
}

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    
    init(material: NSVisualEffectView.Material, blendingMode: NSVisualEffectView.BlendingMode) {
        self.material = material
        self.blendingMode = blendingMode
    }
    
    func makeNSView(context: Context) -> NSVisualEffectView {
        let visualEffectView = NSVisualEffectView()
        visualEffectView.material = material
        visualEffectView.blendingMode = blendingMode
        visualEffectView.state = .active
        return visualEffectView
    }
    
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

#Preview {
    ContentView(appState: AppState(), simulatorService: SimulatorService())
        .environmentObject(PopoverWindowProvider())
}

// MARK: - Push Compose Sheet

struct PushComposeSheet: View {
    let app: App
    let simulator: Simulator?
    let history: [SentNotification]
    @Binding var payloadText: String
    @Binding var descriptionText: String
    let onCancel: () -> Void
    let onSend: () -> Void
    let errorText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "bell")
                    .foregroundColor(.yellow)
                Text("Compose Push Notification")
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                if let sim = simulator {
                    Text("\(app.name) · \(sim.name)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.bottom, 4)

            // History dropdown to load previous notifications
            HStack(spacing: 8) {
                Menu {
                    if history.isEmpty {
                        Text("No Saved Notifications").disabled(true)
                    } else {
                        ForEach(history, id: \.id) { item in
                            Button(action: {
                                descriptionText = item.name
                                payloadText = item.payloadJSON
                            }) {
                                HStack {
                                    Text(displayName(for: item))
                                    Spacer(minLength: 8)
                                    Text(item.createdAt, style: .date)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "clock.arrow.circlepath")
                        Text("Load Previous")
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.08))
                    .cornerRadius(6)
                }
                .menuIndicator(.hidden)
                Spacer()
            }

            TextField("Description (optional)", text: $descriptionText)
                .textFieldStyle(PlainTextFieldStyle())
                .padding(6)
                .background(Color.black.opacity(0.1))
                .cornerRadius(4)

            MonospaceTextView(text: $payloadText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !errorText.isEmpty {
                Text(errorText)
                    .font(.system(size: 11))
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .buttonStyle(PlainButtonStyle())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                Button("Send") { onSend() }
                    .buttonStyle(PlainButtonStyle())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.blue.opacity(0.8))
                    .foregroundColor(.white)
                    .cornerRadius(6)
            }
            .padding(.top, 4)
        }
        .padding(12)
    }

    private func displayName(for item: SentNotification) -> String {
        let trimmed = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "(untitled)" : trimmed
    }
}

#if os(macOS)
// A native NSTextView wrapped for SwiftUI to provide robust selection,
// copy/cut/paste, and monospaced rendering in the popover sheet.
struct MonospaceTextView: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let contentSize = scrollView.contentSize
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: contentSize.width, height: contentSize.height))
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textColor = .labelColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.delegate = context.coordinator
        textView.string = text

        scrollView.documentView = textView
        scrollView.backgroundColor = NSColor.black.withAlphaComponent(0.06)
        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = 4
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        if let textView = nsView.documentView as? NSTextView, textView.string != text {
            textView.string = text
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MonospaceTextView
        init(_ parent: MonospaceTextView) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            if let tv = notification.object as? NSTextView {
                parent.text = tv.string
            }
        }
    }
}
#endif
