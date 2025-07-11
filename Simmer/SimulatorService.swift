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
    private let pinnedSimulatorsKey = "PinnedSimulators"
    
    init() {
        loadSimulators()
    }
    
    func loadSimulators() {
        var simulators = getAvailableSimulators()
        loadPinnedState(&simulators)
        self.simulators = sortSimulators(simulators)
    }
    
    func togglePin(for simulator: Simulator) {
        if let index = simulators.firstIndex(where: { $0.id == simulator.id }) {
            simulators[index].isPinned.toggle()
            savePinnedState()
            simulators = sortSimulators(simulators)
        }
    }
    
    private func sortSimulators(_ simulators: [Simulator]) -> [Simulator] {
        return simulators.sorted { first, second in
            if first.isPinned && !second.isPinned {
                return true
            } else if !first.isPinned && second.isPinned {
                return false
            } else {
                return first.name < second.name
            }
        }
    }
    
    private func loadPinnedState(_ simulators: inout [Simulator]) {
        if let pinnedIds = UserDefaults.standard.array(forKey: pinnedSimulatorsKey) as? [String] {
            for (index, simulator) in simulators.enumerated() {
                simulators[index].isPinned = pinnedIds.contains(simulator.id)
            }
        }
    }
    
    private func savePinnedState() {
        let pinnedIds = simulators.filter { $0.isPinned }.map { $0.id }
        UserDefaults.standard.set(pinnedIds, forKey: pinnedSimulatorsKey)
    }
    
    func loadApps(for simulator: Simulator) {
        apps = getApps(for: simulator)
        selectedSimulator = simulator
    }
    
    func loadSnapshots(for app: App) {
        snapshots = getSnapshots(for: app)
        selectedApp = app
        
        // Ensure the app is in the apps array and has loading state set
        if let appIndex = apps.firstIndex(where: { $0.id == app.id }) {
            if !apps[appIndex].isLoadingDocumentsSize && apps[appIndex].documentsSize == 0 && !apps[appIndex].documentsPath.isEmpty {
                apps[appIndex].startLoadingDocumentsSize()
                calculateDocumentsSize(for: apps[appIndex]) { calculatedSize in
                    DispatchQueue.main.async {
                        if let updatedAppIndex = self.apps.firstIndex(where: { $0.id == app.id }) {
                            self.apps[updatedAppIndex].finishLoadingDocumentsSize(calculatedSize)
                        }
                    }
                }
            }
        }
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
                                
                                var app = App(
                                    id: bundleDir,
                                    name: appName,
                                    bundleIdentifier: bundleIdentifier,
                                    iconPath: getAppIconPath(for: bundleIdentifier, in: simulator),
                                    documentsPath: documentsPath,
                                    snapshotsPath: snapshotsPath
                                )
                                
                                // Start loading documents size in background
                                if !documentsPath.isEmpty {
                                    app.startLoadingDocumentsSize()
                                    calculateDocumentsSize(for: app) { calculatedSize in
                                        DispatchQueue.main.async {
                                            if let appIndex = self.apps.firstIndex(where: { $0.id == app.id }) {
                                                self.apps[appIndex].finishLoadingDocumentsSize(calculatedSize)
                                            }
                                        }
                                    }
                                }
                                
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
                let appBundleContents = try FileManager.default.contentsOfDirectory(atPath: appPath)
                for item in appBundleContents {
                    if item.hasSuffix(".app") {
                        let appBundlePath = "\(appPath)/\(item)"
                        let infoPlistPath = "\(appBundlePath)/Info.plist"
                        if let infoPlist = NSDictionary(contentsOfFile: infoPlistPath) {
                            let bundleId = infoPlist["CFBundleIdentifier"] as? String
                            if bundleId == bundleIdentifier {
                                // Try iPhone icons
                                if let icons = infoPlist["CFBundleIcons"] as? [String: Any],
                                   let primaryIcon = icons["CFBundlePrimaryIcon"] as? [String: Any],
                                   let iconFiles = primaryIcon["CFBundleIconFiles"] as? [String] {
                                    for iconFile in iconFiles {
                                        let patterns = [
                                            "\(iconFile)@3x.png", "\(iconFile)@2x.png", "\(iconFile).png"
                                        ]
                                        for pattern in patterns {
                                            let iconPath = "\(appBundlePath)/\(pattern)"
                                            if FileManager.default.fileExists(atPath: iconPath) {
                                                print("Found app icon: \(iconPath)")
                                                return iconPath
                                            }
                                        }
                                    }
                                }
                                // Try iPad icons
                                if let iconsIpad = infoPlist["CFBundleIcons~ipad"] as? [String: Any],
                                   let primaryIconIpad = iconsIpad["CFBundlePrimaryIcon"] as? [String: Any],
                                   let iconFilesIpad = primaryIconIpad["CFBundleIconFiles"] as? [String] {
                                    for iconFile in iconFilesIpad {
                                        let patterns = [
                                            "\(iconFile)@2x~ipad.png", "\(iconFile)~ipad.png", "\(iconFile)@2x.png", "\(iconFile).png"
                                        ]
                                        for pattern in patterns {
                                            let iconPath = "\(appBundlePath)/\(pattern)"
                                            if FileManager.default.fileExists(atPath: iconPath) {
                                                print("Found iPad app icon: \(iconPath)")
                                                return iconPath
                                            }
                                        }
                                    }
                                }
                                // Fallback: scan for any AppIcon*.png
                                if let bundleContents = try? FileManager.default.contentsOfDirectory(atPath: appBundlePath) {
                                    for file in bundleContents {
                                        if file.hasPrefix("AppIcon") && file.hasSuffix(".png") {
                                            let iconPath = "\(appBundlePath)/\(file)"
                                            print("Found app icon (fallback): \(iconPath)")
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
        print("No icon found for bundle ID: \(bundleIdentifier)")
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
                
                // Create snapshot with loading state
                var snapshot = Snapshot(
                    id: snapshotDir,
                    name: snapshotDir,
                    date: creationDate,
                    size: 0,
                    path: snapshotPath
                )
                snapshot.startLoadingSize()
                
                snapshots.append(snapshot)
            }
        } catch {
            print("Error loading snapshots: \(error)")
        }
        
        let sortedSnapshots = snapshots.sorted { $0.date > $1.date }
        
        // Calculate sizes in background for each snapshot
        for (_, snapshot) in sortedSnapshots.enumerated() {
            calculateSnapshotSize(for: snapshot) { calculatedSize in
                DispatchQueue.main.async {
                    // Find the snapshot by ID to update the correct one
                    if let snapshotIndex = self.snapshots.firstIndex(where: { $0.id == snapshot.id }) {
                        self.snapshots[snapshotIndex].finishLoadingSize(calculatedSize)
                    }
                }
            }
        }
        
        return sortedSnapshots
    }
    
    private func calculateSnapshotSize(for snapshot: Snapshot, completion: @escaping (Int64) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var totalSize: Int64 = 0
            
            do {
                let enumerator = FileManager.default.enumerator(atPath: snapshot.path)
                while let file = enumerator?.nextObject() as? String {
                    let filePath = "\(snapshot.path)/\(file)"
                    let fileAttributes = try FileManager.default.attributesOfItem(atPath: filePath)
                    totalSize += fileAttributes[.size] as? Int64 ?? 0
                }
            } catch {
                print("Error calculating snapshot size for \(snapshot.name): \(error)")
            }
            
            completion(totalSize)
        }
    }
    
    private func calculateDocumentsSize(for app: App, completion: @escaping (Int64) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var totalSize: Int64 = 0
            
            do {
                let enumerator = FileManager.default.enumerator(atPath: app.documentsPath)
                while let file = enumerator?.nextObject() as? String {
                    let filePath = "\(app.documentsPath)/\(file)"
                    let fileAttributes = try FileManager.default.attributesOfItem(atPath: filePath)
                    totalSize += fileAttributes[.size] as? Int64 ?? 0
                }
            } catch {
                print("Error calculating documents size for \(app.name): \(error)")
            }
            
            completion(totalSize)
        }
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
                
                // Copy the Documents directory itself to the snapshot
                let documentsDestinationPath = "\(snapshotPath)/Documents"
                try FileManager.default.copyItem(atPath: app.documentsPath, toPath: documentsDestinationPath)
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
            
            // Copy the Documents directory from the snapshot to the app's documents path
            let snapshotDocumentsPath = "\(snapshot.path)/Documents"
            try FileManager.default.copyItem(atPath: snapshotDocumentsPath, toPath: app.documentsPath)
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