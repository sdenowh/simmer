//
//  ContentView.swift
//  Simmer
//
//  Created by Scott Denowh on 7/10/25.
//

import SwiftUI

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
                Text("(\(appState.popoverAppearanceCount))")
                    .font(.caption)
                    .foregroundColor(.secondary)
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
            .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            // Content
            ZStack {
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
                            .font(.system(size: 10))
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                        
                        ProgressView(value: simulatorService.snapshotOperationProgress)
                            .progressViewStyle(LinearProgressViewStyle(tint: .white))
                            .scaleEffect(y: 0.8)
                        
                        Text("\(Int(simulatorService.snapshotOperationProgress * 100))%")
                            .font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.8))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(
                        VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                    )
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
        }
        .buttonStyle(PlainButtonStyle())
    }
}

struct AppActionsView: View {
    let app: App
    @ObservedObject var simulatorService: SimulatorService
    
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
            }
        }
    }
}

struct SnapshotRowView: View {
    let snapshot: Snapshot
    let app: App
    @ObservedObject var simulatorService: SimulatorService
    @State private var showingRestoreConfirmation = false
    
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
                showingRestoreConfirmation = true
            }) {
                HStack {
                    Image(systemName: "arrow.clockwise")
                        .foregroundColor(.orange)
                        .frame(width: 20)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(snapshot.name)
                            .font(.system(size: 11))
                            .foregroundColor(.primary)
                        
                        Text(snapshot.date, style: .date)
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
        .sheet(isPresented: $showingRestoreConfirmation) {
            RestoreConfirmationView(
                snapshot: snapshot,
                app: displayApp,
                simulatorService: simulatorService,
                isPresented: $showingRestoreConfirmation
            )
        }
    }
}

struct RestoreConfirmationView: View {
    let snapshot: Snapshot
    let app: App
    @ObservedObject var simulatorService: SimulatorService
    @Binding var isPresented: Bool
    
    var body: some View {
        VStack(spacing: 16) {
            // App icon
            if let iconPath = app.iconPath, let image = NSImage(contentsOfFile: iconPath) {
                Image(nsImage: image)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .cornerRadius(12)
            } else {
                Image(systemName: "app")
                    .foregroundColor(.gray)
                    .frame(width: 64, height: 64)
                    .font(.system(size: 32))
            }
            
            Text("Restore Snapshot")
                .font(.headline)
            
            Text("This will replace the current Documents folder with the snapshot from \(snapshot.date, style: .date). This action cannot be undone.")
                .font(.system(size: 14))
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
            
            HStack(spacing: 12) {
                Button("Cancel") {
                    isPresented = false
                }
                .buttonStyle(.bordered)
                
                Button("Restore") {
                    simulatorService.restoreSnapshot(snapshot, for: app)
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }
        }
        .padding(24)
        .frame(width: 300)
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
