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
                    
                    // Only include simulators that have apps installed
                    if hasAppsInstalled(simulator: simulator) {
                        simulators.append(simulator)
                    }
                }
            }
        } catch {
            print("Error loading simulators: \(error)")
        }
        
        return simulators.sorted { $0.name < $1.name }
    }
    
    private func hasAppsInstalled(simulator: Simulator) -> Bool {
        let containersPath = "\(simulator.dataPath)/data/Containers"
        
        // Check if Containers directory exists
        guard FileManager.default.fileExists(atPath: containersPath) else {
            return false
        }
        
        // Check if Bundle/Application directory exists and has content
        let bundlePath = "\(containersPath)/Bundle/Application"
        guard FileManager.default.fileExists(atPath: bundlePath) else {
            return false
        }
        
        do {
            let bundleDirectories = try FileManager.default.contentsOfDirectory(atPath: bundlePath)
            return !bundleDirectories.isEmpty
        } catch {
            return false
        }
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
        
        print("Loading apps for simulator: \(simulator.name)")
        
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
            print("Found \(bundleDirectories.count) bundle directories in \(bundlePath)")
            
            for bundleDir in bundleDirectories {
                let bundlePath = "\(bundlePath)/\(bundleDir)"
                
                // Look for .app bundles in the bundle directory
                do {
                    let bundleContents = try FileManager.default.contentsOfDirectory(atPath: bundlePath)
                    for item in bundleContents {
                        if item.hasSuffix(".app") {
                            let appPath = "\(bundlePath)/\(item)"
                            let infoPlistPath = "\(appPath)/Info.plist"
                            
                            if let infoPlist = NSDictionary(contentsOfFile: infoPlistPath) {
                                let bundleIdentifier = infoPlist["CFBundleIdentifier"] as? String ?? ""
                                let appName = infoPlist["CFBundleDisplayName"] as? String ?? 
                                             infoPlist["CFBundleName"] as? String ?? 
                                             bundleIdentifier
                                
                                print("Found app: \(appName) (\(bundleIdentifier))")
                                
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
                                                    snapshotsPath = "\(dataAppPath)/Snapshots"
                                                    print("Found data container for \(appName)")
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
                            } else {
                                print("Could not read Info.plist for \(item)")
                            }
                        }
                    }
                } catch {
                    print("Error reading bundle directory \(bundleDir): \(error)")
                }
            }
        } catch {
            print("Error loading apps: \(error)")
        }
        
        print("Returning \(apps.count) apps for simulator \(simulator.name)")
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
                        // Look for the app bundle directory
                        let appBundleContents = try FileManager.default.contentsOfDirectory(atPath: appPath)
                        for item in appBundleContents {
                            if item.hasSuffix(".app") {
                                let appBundlePath = "\(appPath)/\(item)"
                                
                                // Try different icon file patterns
                                let iconPatterns = [
                                    "AppIcon60x60@2x.png",
                                    "AppIcon60x60.png",
                                    "AppIcon76x76@2x~ipad.png",
                                    "AppIcon76x76~ipad.png"
                                ]
                                
                                for pattern in iconPatterns {
                                    let iconPath = "\(appBundlePath)/\(pattern)"
                                    if FileManager.default.fileExists(atPath: iconPath) {
                                        print("Found app icon: \(iconPath)")
                                        return iconPath
                                    }
                                }
                                
                                // If no specific icon found, try to find any PNG file that looks like an app icon
                                if let bundleContents = try? FileManager.default.contentsOfDirectory(atPath: appBundlePath) {
                                    for file in bundleContents {
                                        if file.hasPrefix("AppIcon") && file.hasSuffix(".png") {
                                            let iconPath = "\(appBundlePath)/\(file)"
                                            print("Found app icon: \(iconPath)")
                                            return iconPath
                                        }
                                    }
                                }
                            }
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
        
        // Check if snapshots directory exists
        guard FileManager.default.fileExists(atPath: app.snapshotsPath) else {
            return snapshots
        }
        
        do {
            let snapshotDirectories = try FileManager.default.contentsOfDirectory(atPath: app.snapshotsPath)
            
            for snapshotDir in snapshotDirectories {
                let snapshotPath = "\(app.snapshotsPath)/\(snapshotDir)"
                let attributes = try FileManager.default.attributesOfItem(atPath: snapshotPath)
                let creationDate = attributes[.creationDate] as? Date ?? Date()
                
                // Calculate the total size of all files in the snapshot directory
                var totalSize: Int64 = 0
                do {
                    let enumerator = FileManager.default.enumerator(atPath: snapshotPath)
                    while let file = enumerator?.nextObject() as? String {
                        let filePath = "\(snapshotPath)/\(file)"
                        let fileAttributes = try FileManager.default.attributesOfItem(atPath: filePath)
                        totalSize += fileAttributes[.size] as? Int64 ?? 0
                    }
                } catch {
                    print("Error calculating snapshot size for \(snapshotDir): \(error)")
                }
                
                let snapshot = Snapshot(
                    id: snapshotDir,
                    name: snapshotDir,
                    date: creationDate,
                    size: totalSize,
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
        
        print("Taking snapshot for \(app.name)")
        print("Documents path: \(app.documentsPath)")
        print("Snapshots path: \(app.snapshotsPath)")
        print("Snapshot path: \(snapshotPath)")
        
        do {
            // Check if Documents directory exists
            let documentsExists = FileManager.default.fileExists(atPath: app.documentsPath)
            print("Documents directory exists: \(documentsExists)")
            
            if documentsExists {
                // Create Snapshots directory if it doesn't exist
                let snapshotsExists = FileManager.default.fileExists(atPath: app.snapshotsPath)
                print("Snapshots directory exists: \(snapshotsExists)")
                
                if !snapshotsExists {
                    try FileManager.default.createDirectory(atPath: app.snapshotsPath, withIntermediateDirectories: true)
                    print("Created snapshots directory")
                }
                
                // Create the snapshot directory first
                try FileManager.default.createDirectory(atPath: snapshotPath, withIntermediateDirectories: true)
                print("Created snapshot directory: \(snapshotPath)")
                
                // Copy Documents directory contents, excluding any existing Snapshots directory
                let documentsContents = try FileManager.default.contentsOfDirectory(atPath: app.documentsPath)
                for item in documentsContents {
                    // Skip any existing Snapshots directory to avoid recursion
                    if item == "Snapshots" {
                        print("Skipping existing Snapshots directory to avoid recursion")
                        continue
                    }
                    
                    let sourcePath = "\(app.documentsPath)/\(item)"
                    let destinationPath = "\(snapshotPath)/\(item)"
                    
                    print("Attempting to copy:")
                    print("  Source: \(sourcePath)")
                    print("  Destination: \(destinationPath)")
                    
                    // Check if the source item actually exists before trying to copy it
                    if FileManager.default.fileExists(atPath: sourcePath) {
                        do {
                            // Try to read the file first to ensure it's accessible
                            let data = try Data(contentsOf: URL(fileURLWithPath: sourcePath))
                            try data.write(to: URL(fileURLWithPath: destinationPath))
                            print("Copied: \(item)")
                        } catch {
                            print("Failed to copy \(item): \(error)")
                        }
                    } else {
                        print("Skipping non-existent item: \(item)")
                    }
                }
                loadSnapshots(for: app)
                print("Snapshot created successfully: \(snapshotName)")
            } else {
                print("Documents directory does not exist for \(app.name)")
            }
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