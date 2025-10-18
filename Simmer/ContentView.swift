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
    @State private var selectedSimulator: Simulator?
    @State private var selectedApp: App?
    
    private func getAppVersion() -> String {
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
           let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
            return "\(version) (\(build))"
        }
        return "Unknown"
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
                                        isSelected: selectedApp?.id == app.id,
                                        onTap: {
                                            if selectedApp?.id == app.id {
                                                selectedApp = nil
                                            } else {
                                                selectedApp = app
                                                simulatorService.loadSnapshots(for: app)
                                            }
                                        }
                                    )

                                    if selectedApp?.id == app.id {
                                        AppActionsView(app: app, simulatorService: simulatorService)
                                    }
                                }
                            }
                        }
                    }
                }
                
                // Progress Bar Overlay for Snapshot Operations
            if simulatorService.isSnapshotOperationInProgress {
                VStack {
                    Spacer()
                    
                    VStack(spacing: 4) {
                        Text(simulatorService.snapshotOperationMessage)
                            .font(.system(size: 11))
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                        
                        ProgressView(value: simulatorService.snapshotOperationProgress)
                            .progressViewStyle(LinearProgressViewStyle(tint: .blue))
                            .scaleEffect(y: 0.8)
                        
                        Text("\(Int(simulatorService.snapshotOperationProgress * 100))%")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.8))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(
                        VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                    )
//                    .cornerRadius(12)
                    .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
                }
                .allowsHitTesting(false)
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .move(edge: .bottom).combined(with: .opacity)
                ))
                .animation(.easeInOut(duration: 0.3), value: simulatorService.isSnapshotOperationInProgress)
            }
            }
            .frame(width: 300, height: 400)
        }
    }
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
#endif

struct SimulatorRowView: View {
    let simulator: Simulator
    let isSelected: Bool
    let onTap: () -> Void
    @ObservedObject var simulatorService: SimulatorService
    
    var body: some View {
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
                
                // Pin button
                Button(action: {
                    simulatorService.togglePin(for: simulator)
                }) {
                    Image(systemName: simulator.isPinned ? "pin.fill" : "pin")
                        .foregroundColor(simulator.isPinned ? .orange : .secondary)
                        .font(.system(size: 12))
                }
                .buttonStyle(PlainButtonStyle())
                
                // Disclosure chevron
                Image(systemName: isSelected ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .padding(.trailing, 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? Color.blue.opacity(0.1) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .background(Color.clear)
    }
}

struct AppRowView: View {
    let app: App
    let isSelected: Bool
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            HStack {
                // App icon
                if let iconPath = app.iconPath, let image = NSImage(contentsOfFile: iconPath) {
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
    }
}

struct AppActionsView: View {
    let app: App
    @ObservedObject var simulatorService: SimulatorService
    @State private var isShowingPushSheet: Bool = false
    @State private var pushPayloadText: String = ""
    @State private var pushDescriptionText: String = ""
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
                simulatorService.openDocumentsFolder(for: app)
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
                Button(action: {
                    simulatorService.takeSnapshot(for: app)
                }) {
                    HStack {
                        Image(systemName: "camera")
                            .foregroundColor(.green)
                            .frame(width: 20)
                        
                        Text("Take Documents Snapshot")
                            .font(.system(size: 12))
                            .foregroundColor(.primary)
                        
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .padding(.leading, 40)
                }
                .buttonStyle(PlainButtonStyle())
                
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
                        simulatorService.deleteAllSnapshots()
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
                    lastSendError = ""
                    simulatorService.sendPushNotification(payloadJSON: pushPayloadText, name: pushDescriptionText.isEmpty ? nil : pushDescriptionText, for: app, on: sim) { success, error in
                        if success {
                            isShowingPushSheet = false
                        } else {
                            lastSendError = error ?? "Unknown error"
                        }
                    }
                }
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
        guard let window = popoverWindowProvider.window else { return }
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

        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn {
                simulatorService.renameSnapshotDisplayName(snapshot, to: textField.stringValue)
            }
        }
        #endif
    }

    private func showRestoreConfirmation() {
        guard let window = popoverWindowProvider.window else { return }
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
        if let iconPath = displayApp.iconPath, let image = NSImage(contentsOfFile: iconPath) {
            alert.icon = maskedAppIcon(from: image, cornerRadius: 16)
        }
        #endif
        alert.beginSheetModal(for: window) { response in
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
