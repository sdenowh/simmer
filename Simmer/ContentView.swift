//
//  ContentView.swift
//  Simmer
//
//  Created by Scott Denowh on 7/10/25.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var simulatorService = SimulatorService()
    @State private var selectedSimulator: Simulator?
    @State private var selectedApp: App?
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "iphone")
                    .foregroundColor(.blue)
                Text("Simmer")
                    .font(.headline)
                Spacer()
                Button(action: {
                    simulatorService.loadSimulators()
                }) {
                    Image(systemName: "arrow.clockwise")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            // Progress Bar for Snapshot Operations
            if simulatorService.isSnapshotOperationInProgress {
                VStack(spacing: 8) {
                    Text(simulatorService.snapshotOperationMessage)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    
                    ProgressView(value: simulatorService.snapshotOperationProgress)
                        .progressViewStyle(LinearProgressViewStyle())
                        .scaleEffect(y: 0.5)
                    
                    Text("\(Int(simulatorService.snapshotOperationProgress * 100))%")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                
                Divider()
            }
            
            // Content
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
        }
        .frame(width: 300, height: 400)
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
        .confirmationDialog("Restore Snapshot", isPresented: $showingRestoreConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Restore", role: .destructive) {
                simulatorService.restoreSnapshot(snapshot, for: displayApp)
            }
        } message: {
            VStack(spacing: 8) {
                // App icon
                if let iconPath = displayApp.iconPath, let image = NSImage(contentsOfFile: iconPath) {
                    Image(nsImage: image)
                        .resizable()
                        .frame(width: 32, height: 32)
                        .cornerRadius(6)
                } else {
                    Image(systemName: "app")
                        .foregroundColor(.gray)
                        .frame(width: 32, height: 32)
                }
                
                Text("This will replace the current Documents folder with the snapshot from \(snapshot.date, style: .date). This action cannot be undone.")
                    .font(.system(size: 12))
                    .multilineTextAlignment(.center)
            }
        }
    }
}

#Preview {
    ContentView()
}
