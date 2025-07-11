//
//  SimulatorService.swift
//  Simmer
//
//  Created by Scott Denowh on 7/10/25.
//

import Foundation
import AppKit

class SimulatorService: ObservableObject {
    @Published var simulators: [Simulator] = []
    @Published var selectedSimulator: Simulator?
    @Published var apps: [App] = []
    @Published var selectedApp: App?
    @Published var snapshots: [Snapshot] = []
    
    private let simulatorPath = "~/Library/Developer/CoreSimulator/Devices"
    private let expandedSimulatorPath = NSString(string: "~/Library/Developer/CoreSimulator/Devices").expandingTildeInPath
    
    init() {
        loadSimulators()
    }
    
    func loadSimulators() {
        simulators = getAvailableSimulators()
    }
    
    func loadApps(for simulator: Simulator) {
        apps = getApps(for: simulator)
        selectedSimulator = simulator
    }
    
    func loadSnapshots(for app: App) {
        snapshots = getSnapshots(for: app)
        selectedApp = app
    }
    
    private func getAvailableSimulators() -> [Simulator] {
        var simulators: [Simulator] = []
        
        do {
            let deviceDirectories = try FileManager.default.contentsOfDirectory(atPath: expandedSimulatorPath)
            
            for deviceDir in deviceDirectories {
                let devicePath = "\(expandedSimulatorPath)/\(deviceDir)"
                let devicePlistPath = "\(devicePath)/device.plist"
                
                if let deviceData = NSDictionary(contentsOfFile: devicePlistPath) {
                    let name = deviceData["name"] as? String ?? "Unknown"
                    let runtime = deviceData["runtime"] as? String ?? "Unknown"
                    let deviceType = deviceData["deviceType"] as? String ?? "iPhone"
                    
                    let simulator = Simulator(
                        id: deviceDir,
                        name: name,
                        iOSVersion: runtime.replacingOccurrences(of: "com.apple.CoreSimulator.SimRuntime.", with: ""),
                        deviceType: getDeviceType(from: deviceType),
                        udid: deviceDir,
                        dataPath: devicePath
                    )
                    
                    simulators.append(simulator)
                }
            }
        } catch {
            print("Error loading simulators: \(error)")
        }
        
        return simulators.sorted { $0.name < $1.name }
    }
    
    private func getDeviceType(from deviceTypeString: String) -> Simulator.DeviceType {
        if deviceTypeString.contains("iPhone") {
            return .iPhone
        } else if deviceTypeString.contains("iPad") {
            return .iPad
        } else if deviceTypeString.contains("AppleTV") {
            return .appleTV
        } else if deviceTypeString.contains("Watch") {
            return .appleWatch
        }
        return .iPhone
    }
    
    private func getApps(for simulator: Simulator) -> [App] {
        var apps: [App] = []
        let dataPath = simulator.dataPath
        
        // First, check if Containers directory exists
        let containersPath = "\(dataPath)/data/Containers"
        guard FileManager.default.fileExists(atPath: containersPath) else {
            print("No Containers directory found for simulator \(simulator.name)")
            return apps
        }
        
        // Get installed apps from Bundle/Application
        let bundlePath = "\(containersPath)/Bundle/Application"
        guard FileManager.default.fileExists(atPath: bundlePath) else {
            print("No Bundle/Application directory found for simulator \(simulator.name)")
            return apps
        }
        
        do {
            let bundleDirectories = try FileManager.default.contentsOfDirectory(atPath: bundlePath)
            
            for bundleDir in bundleDirectories {
                let appPath = "\(bundlePath)/\(bundleDir)"
                let infoPlistPath = "\(appPath)/Info.plist"
                
                if let infoPlist = NSDictionary(contentsOfFile: infoPlistPath) {
                    let bundleIdentifier = infoPlist["CFBundleIdentifier"] as? String ?? ""
                    let appName = infoPlist["CFBundleDisplayName"] as? String ?? 
                                 infoPlist["CFBundleName"] as? String ?? 
                                 bundleIdentifier
                    
                    // Find corresponding data container
                    let dataPath = "\(containersPath)/Data/Application"
                    var documentsPath = ""
                    var snapshotsPath = ""
                    
                    if FileManager.default.fileExists(atPath: dataPath) {
                        do {
                            let dataDirectories = try FileManager.default.contentsOfDirectory(atPath: dataPath)
                            for dataDir in dataDirectories {
                                let dataAppPath = "\(dataPath)/\(dataDir)"
                                let metadataPath = "\(dataAppPath)/.com.apple.mobile_container_manager.metadata.plist"
                                
                                if let metadata = NSDictionary(contentsOfFile: metadataPath) {
                                    let dataBundleId = metadata["MCMMetadataIdentifier"] as? String ?? ""
                                    if dataBundleId == bundleIdentifier {
                                        documentsPath = "\(dataAppPath)/Documents"
                                        snapshotsPath = "\(dataAppPath)/Documents/Snapshots"
                                        break
                                    }
                                }
                            }
                        } catch {
                            print("Error finding data container for \(bundleIdentifier): \(error)")
                        }
                    }
                    
                    let app = App(
                        id: bundleDir,
                        name: appName,
                        bundleIdentifier: bundleIdentifier,
                        iconPath: getAppIconPath(for: bundleIdentifier, in: simulator),
                        documentsPath: documentsPath,
                        snapshotsPath: snapshotsPath
                    )
                    
                    apps.append(app)
                }
            }
        } catch {
            print("Error loading apps: \(error)")
        }
        
        return apps.sorted { $0.name < $1.name }
    }
    
    private func getAppName(for bundleIdentifier: String, in simulator: Simulator) -> String {
        // This method is now deprecated since we get app names directly from Bundle/Application
        return bundleIdentifier
    }
    
    private func getAppIconPath(for bundleIdentifier: String, in simulator: Simulator) -> String? {
        let bundlePath = "\(simulator.dataPath)/data/Containers/Bundle/Application"
        
        do {
            let bundleDirectories = try FileManager.default.contentsOfDirectory(atPath: bundlePath)
            
            for bundleDir in bundleDirectories {
                let appPath = "\(bundlePath)/\(bundleDir)"
                let infoPlistPath = "\(appPath)/Info.plist"
                
                if let infoPlist = NSDictionary(contentsOfFile: infoPlistPath) {
                    let bundleId = infoPlist["CFBundleIdentifier"] as? String
                    if bundleId == bundleIdentifier {
                        if let iconFiles = infoPlist["CFBundleIcons"] as? [String: Any],
                           let primaryIcon = iconFiles["CFBundlePrimaryIcon"] as? [String: Any],
                           let iconFilesList = primaryIcon["CFBundleIconFiles"] as? [String],
                           let firstIcon = iconFilesList.first {
                            return "\(appPath)/\(firstIcon)@2x.png"
                        }
                    }
                }
            }
        } catch {
            print("Error getting app icon: \(error)")
        }
        
        return nil
    }
    
    private func getSnapshots(for app: App) -> [Snapshot] {
        var snapshots: [Snapshot] = []
        
        do {
            let snapshotDirectories = try FileManager.default.contentsOfDirectory(atPath: app.snapshotsPath)
            
            for snapshotDir in snapshotDirectories {
                let snapshotPath = "\(app.snapshotsPath)/\(snapshotDir)"
                let attributes = try FileManager.default.attributesOfItem(atPath: snapshotPath)
                let creationDate = attributes[.creationDate] as? Date ?? Date()
                let fileSize = attributes[.size] as? Int64 ?? 0
                
                let snapshot = Snapshot(
                    id: snapshotDir,
                    name: snapshotDir,
                    date: creationDate,
                    size: fileSize,
                    path: snapshotPath
                )
                
                snapshots.append(snapshot)
            }
        } catch {
            print("Error loading snapshots: \(error)")
        }
        
        return snapshots.sorted { $0.date > $1.date }
    }
    
    func getDirectorySize(for path: String) -> DirectorySize {
        var totalSize: Int64 = 0
        
        do {
            let enumerator = FileManager.default.enumerator(atPath: path)
            while let file = enumerator?.nextObject() as? String {
                let filePath = "\(path)/\(file)"
                let attributes = try FileManager.default.attributesOfItem(atPath: filePath)
                totalSize += attributes[.size] as? Int64 ?? 0
            }
        } catch {
            print("Error calculating directory size: \(error)")
        }
        
        return DirectorySize(size: totalSize)
    }
    
    func getAllSnapshotsSize() -> DirectorySize {
        var totalSize: Int64 = 0
        
        for app in apps {
            do {
                let enumerator = FileManager.default.enumerator(atPath: app.snapshotsPath)
                while let file = enumerator?.nextObject() as? String {
                    let filePath = "\(app.snapshotsPath)/\(file)"
                    let attributes = try FileManager.default.attributesOfItem(atPath: filePath)
                    totalSize += attributes[.size] as? Int64 ?? 0
                }
            } catch {
                print("Error calculating snapshots size: \(error)")
            }
        }
        
        return DirectorySize(size: totalSize)
    }
    
    func openDocumentsFolder(for app: App) {
        NSWorkspace.shared.open(URL(fileURLWithPath: app.documentsPath))
    }
    
    func takeSnapshot(for app: App) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let snapshotName = "snapshot_\(timestamp)"
        let snapshotPath = "\(app.snapshotsPath)/\(snapshotName)"
        
        do {
            try FileManager.default.copyItem(atPath: app.documentsPath, toPath: snapshotPath)
            loadSnapshots(for: app)
        } catch {
            print("Error taking snapshot: \(error)")
        }
    }
    
    func restoreSnapshot(_ snapshot: Snapshot, for app: App) {
        do {
            // Remove current documents
            try FileManager.default.removeItem(atPath: app.documentsPath)
            
            // Copy snapshot to documents
            try FileManager.default.copyItem(atPath: snapshot.path, toPath: app.documentsPath)
        } catch {
            print("Error restoring snapshot: \(error)")
        }
    }
    
    func deleteSnapshot(_ snapshot: Snapshot) {
        do {
            try FileManager.default.removeItem(atPath: snapshot.path)
            loadSnapshots(for: selectedApp!)
        } catch {
            print("Error deleting snapshot: \(error)")
        }
    }
    
    func deleteAllSnapshots() {
        for app in apps {
            do {
                let snapshotDirectories = try FileManager.default.contentsOfDirectory(atPath: app.snapshotsPath)
                for snapshotDir in snapshotDirectories {
                    let snapshotPath = "\(app.snapshotsPath)/\(snapshotDir)"
                    try FileManager.default.removeItem(atPath: snapshotPath)
                }
            } catch {
                print("Error deleting snapshots: \(error)")
            }
        }
        
        if let selectedApp = selectedApp {
            loadSnapshots(for: selectedApp)
        }
    }
} 