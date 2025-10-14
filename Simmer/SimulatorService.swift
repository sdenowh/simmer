//
//  SimulatorService.swift
//  Simmer
//
//  Created by Scott Denowh on 7/10/25.
//

import Foundation
import AppKit
import os.log

class SimulatorService: ObservableObject {
    private let logger = Logger(subsystem: "com.simmer.app", category: "SimulatorService")
    
    // MARK: - Mock Data Configuration
    private var useMockData: Bool {
        get {
            return UserDefaults.standard.bool(forKey: "UseMockData")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "UseMockData")
        }
    }
    
    // Method to enable/disable mock data
    func enableMockData(_ enabled: Bool) {
        useMockData = enabled
        loadSimulators() // Reload with new data
    }
    
    private func log(_ message: String, type: OSLogType = .default) {
        // Use NSLog for release builds to ensure visibility in Console.app
        #if DEBUG
        logger.log(level: type, "\(message)")
        #endif
        NSLog("[Simmer] \(message)")
        print("[Simmer] \(message)")
    }
    
    @Published var simulators: [Simulator] = []
    @Published var selectedSimulator: Simulator?
    @Published var apps: [App] = []
    @Published var selectedApp: App?
    @Published var snapshots: [Snapshot] = []
    @Published var totalSnapshotsSize: Int64 = 0
    @Published var isLoadingTotalSnapshotsSize: Bool = false
    @Published var isSnapshotOperationInProgress: Bool = false
    @Published var snapshotOperationProgress: Double = 0.0
    @Published var snapshotOperationMessage: String = ""
    @Published var pushHistoryChangeTick: Int = 0
    
    private let simulatorPath = "~/Library/Developer/CoreSimulator/Devices"
    private let expandedSimulatorPath = NSString(string: "~/Library/Developer/CoreSimulator/Devices").expandingTildeInPath
    private let pinnedSimulatorsKey = "PinnedSimulators"
    
    init() {
        loadSimulators()
    }
    
    func loadSimulators() {
        if useMockData {
            simulators = getMockSimulators()
        } else {
            var simulators = getAvailableSimulators()
            loadPinnedState(&simulators)
            self.simulators = sortSimulators(simulators)
        }
        
        // Debug: Log simulator information
        log("=== Simulator Debug Info ===")
        log("Found \(simulators.count) simulators")
        for simulator in simulators {
            log("Simulator: \(simulator.name) (\(simulator.iOSVersion))")
            log("  Data Path: \(simulator.dataPath)")
            log("  Bundle Path: \(simulator.dataPath)/data/Containers/Bundle/Application")
            
            let bundlePath = "\(simulator.dataPath)/data/Containers/Bundle/Application"
            if FileManager.default.fileExists(atPath: bundlePath) {
                do {
                    let bundleContents = try FileManager.default.contentsOfDirectory(atPath: bundlePath)
                    log("  Bundle Contents: \(bundleContents.count) items")
                } catch {
                    log("  Error reading bundle contents: \(error)", type: .error)
                }
            } else {
                log("  Bundle path does not exist")
            }
            log("---")
        }
    }

    // MARK: - Push Notifications

    private func pushHistoryKey(udid: String, bundleId: String) -> String {
        return "PushHistory-\(udid)-\(bundleId)"
    }

    func getPushHistory(for app: App, on simulator: Simulator) -> [SentNotification] {
        let key = pushHistoryKey(udid: simulator.udid, bundleId: app.bundleIdentifier)
        if let data = UserDefaults.standard.data(forKey: key) {
            do {
                let items = try JSONDecoder().decode([SentNotification].self, from: data)
                return items.sorted { $0.createdAt > $1.createdAt }
            } catch {
                log("Failed to decode push history: \(error)", type: .error)
                return []
            }
        }
        return []
    }

    private func savePushHistory(_ items: [SentNotification], for app: App, on simulator: Simulator) {
        let key = pushHistoryKey(udid: simulator.udid, bundleId: app.bundleIdentifier)
        do {
            let data = try JSONEncoder().encode(items)
            UserDefaults.standard.set(data, forKey: key)
            DispatchQueue.main.async {
                self.pushHistoryChangeTick &+= 1
                self.objectWillChange.send()
            }
        } catch {
            log("Failed to encode push history: \(error)", type: .error)
        }
    }

    private func extractAlertTitle(from jsonString: String) -> String? {
        guard let data = jsonString.data(using: .utf8) else { return nil }
        do {
            let obj = try JSONSerialization.jsonObject(with: data, options: [])
            if let dict = obj as? [String: Any],
               let aps = dict["aps"] as? [String: Any] {
                if let alert = aps["alert"] as? [String: Any], let title = alert["title"] as? String { return title }
                if let title = aps["alert"] as? String { return title }
            }
        } catch {
            return nil
        }
        return nil
    }

    func sendPushNotification(payloadJSON: String, name: String?, for app: App, on simulator: Simulator, completion: ((Bool, String?) -> Void)? = nil) {
        // Validate JSON
        guard let data = payloadJSON.data(using: .utf8) else {
            completion?(false, "Invalid UTF-8 payload")
            return
        }
        do {
            _ = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            completion?(false, "Payload is not valid JSON: \(error.localizedDescription)")
            return
        }

        // Write to temp .apns file
        let tempDir = NSTemporaryDirectory()
        let filePath = (tempDir as NSString).appendingPathComponent("simmer-\(UUID().uuidString).apns")
        do {
            try payloadJSON.write(toFile: filePath, atomically: true, encoding: .utf8)
        } catch {
            completion?(false, "Failed to write temp file: \(error.localizedDescription)")
            return
        }

        // Run simctl push
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.launchPath = "/usr/bin/xcrun"
            process.arguments = ["simctl", "push", simulator.udid, app.bundleIdentifier, filePath]

            let pipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = pipe
            process.standardError = errPipe

            do {
                try process.run()
            } catch {
                DispatchQueue.main.async {
                    self.log("Failed to run simctl push: \(error)", type: .error)
                    completion?(false, "Failed to run simctl push: \(error.localizedDescription)")
                }
                try? FileManager.default.removeItem(atPath: filePath)
                return
            }

            process.waitUntilExit()

            let success = process.terminationStatus == 0
            let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: outputData, encoding: .utf8) ?? ""
            let errOutput = String(data: errData, encoding: .utf8) ?? ""

            // Clean up temp
            try? FileManager.default.removeItem(atPath: filePath)

            DispatchQueue.main.async {
                if success {
                    self.log("Push sent successfully: \(output)")
                    // Persist history
                    var existing = self.getPushHistory(for: app, on: simulator)
                    let fallbackName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let finalName = (fallbackName?.isEmpty == false ? fallbackName! : (self.extractAlertTitle(from: payloadJSON) ?? ""))
                    let item = SentNotification(id: UUID().uuidString, name: finalName, createdAt: Date(), payloadJSON: payloadJSON)
                    existing.append(item)
                    self.savePushHistory(existing, for: app, on: simulator)

                    // User notification
                    let n = NSUserNotification()
                    n.title = "Simmer"
                    n.informativeText = "Push sent to \(app.name) on \(simulator.name)"
                    NSUserNotificationCenter.default.deliver(n)
                    completion?(true, nil)
                } else {
                    self.log("Push failed: \(errOutput)", type: .error)
                    let n = NSUserNotification()
                    n.title = "Simmer"
                    n.informativeText = "Push failed: \(errOutput)"
                    NSUserNotificationCenter.default.deliver(n)
                    completion?(false, errOutput.isEmpty ? output : errOutput)
                }
            }
        }
    }

    func repeatLastPush(for app: App, on simulator: Simulator, completion: ((Bool, String?) -> Void)? = nil) {
        let history = getPushHistory(for: app, on: simulator)
        guard let last = history.first else {
            completion?(false, "No previous notification to repeat")
            return
        }
        sendPushNotification(payloadJSON: last.payloadJSON, name: last.name.isEmpty ? nil : last.name, for: app, on: simulator, completion: completion)
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
        if useMockData {
            apps = getMockApps(for: simulator)
        } else {
            apps = getApps(for: simulator)
        }
        selectedSimulator = simulator
    }
    
    func loadSnapshots(for app: App) {
        if useMockData {
            snapshots = getMockSnapshots(for: app)
            totalSnapshotsSize = snapshots.reduce(0) { $0 + $1.size }
        } else {
            snapshots = getSnapshots(for: app)
            
            // Calculate total snapshots size if there are snapshots
            if !snapshots.isEmpty {
                calculateTotalSnapshotsSize()
            }
            
            // Always refresh documents size for the expanded app to keep sizes accurate
            if let appIndex = apps.firstIndex(where: { $0.id == app.id }) {
                if !apps[appIndex].documentsPath.isEmpty {
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
            log("Error loading simulators: \(error)", type: .error)
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
        
        log("Loading apps for simulator: \(simulator.name)")
        
        // First, check if Containers directory exists
        let containersPath = "\(dataPath)/data/Containers"
        guard FileManager.default.fileExists(atPath: containersPath) else {
            log("No Containers directory found for simulator \(simulator.name)")
            return apps
        }
        
        // Get installed apps from Bundle/Application
        let bundlePath = "\(containersPath)/Bundle/Application"
        guard FileManager.default.fileExists(atPath: bundlePath) else {
            log("No Bundle/Application directory found for simulator \(simulator.name)")
            return apps
        }
        
        do {
            let bundleDirectories = try FileManager.default.contentsOfDirectory(atPath: bundlePath)
            log("Found \(bundleDirectories.count) bundle directories in \(bundlePath)")
            
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
                                
                                log("Found app: \(appName) (\(bundleIdentifier))")
                                
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
                                                    log("Found data container for \(appName)")
                                                    break
                                                }
                                            }
                                        }
                                    } catch {
                                        log("Error finding data container for \(bundleIdentifier): \(error)", type: .error)
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
                                log("Could not read Info.plist for \(item)")
                            }
                        }
                    }
                } catch {
                    log("Error reading bundle directory \(bundleDir): \(error)", type: .error)
                }
            }
        } catch {
            log("Error loading apps: \(error)", type: .error)
        }
        
        log("Returning \(apps.count) apps for simulator \(simulator.name)")
        return apps.sorted { $0.name < $1.name }
    }
    
    private func getAppName(for bundleIdentifier: String, in simulator: Simulator) -> String {
        // This method is now deprecated since we get app names directly from Bundle/Application
        return bundleIdentifier
    }
    
    private func getAppIconPath(for bundleIdentifier: String, in simulator: Simulator) -> String? {
        let bundlePath = "\(simulator.dataPath)/data/Containers/Bundle/Application"
        
        // Check if the bundle path exists
        guard FileManager.default.fileExists(atPath: bundlePath) else {
            log("Bundle path does not exist: \(bundlePath)")
            return nil
        }
        
        do {
            let bundleDirectories = try FileManager.default.contentsOfDirectory(atPath: bundlePath)
            for bundleDir in bundleDirectories {
                // Skip system files like .DS_Store
                if bundleDir.hasPrefix(".") {
                    continue
                }
                
                let appPath = "\(bundlePath)/\(bundleDir)"
                
                // Check if app path exists and is a directory
                guard FileManager.default.fileExists(atPath: appPath) else {
                    continue
                }
                
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: appPath, isDirectory: &isDirectory) && isDirectory.boolValue else {
                    continue
                }
                
                let appBundleContents = try FileManager.default.contentsOfDirectory(atPath: appPath)
                for item in appBundleContents {
                    // Skip system files like .DS_Store
                    if item.hasPrefix(".") {
                        continue
                    }
                    
                    if item.hasSuffix(".app") {
                        let appBundlePath = "\(appPath)/\(item)"
                        let infoPlistPath = "\(appBundlePath)/Info.plist"
                        
                        // Check if Info.plist exists
                        guard FileManager.default.fileExists(atPath: infoPlistPath) else {
                            log("Info.plist not found at: \(infoPlistPath)")
                            continue
                        }
                        
                        if let infoPlist = NSDictionary(contentsOfFile: infoPlistPath) {
                            let bundleId = infoPlist["CFBundleIdentifier"] as? String
                            if bundleId == bundleIdentifier {
                                log("Found matching bundle for \(bundleIdentifier) at: \(appBundlePath)")
                                
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
                                                                                            log("Found app icon: \(iconPath)")
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
                                                log("Found iPad app icon: \(iconPath)")
                                                return iconPath
                                            }
                                        }
                                    }
                                }
                                
                                // Fallback: scan for any AppIcon*.png
                                if let bundleContents = try? FileManager.default.contentsOfDirectory(atPath: appBundlePath) {
                                    for file in bundleContents {
                                        // Skip system files like .DS_Store
                                        if file.hasPrefix(".") {
                                            continue
                                        }
                                        
                                        if file.hasPrefix("AppIcon") && file.hasSuffix(".png") {
                                            let iconPath = "\(appBundlePath)/\(file)"
                                            log("Found app icon (fallback): \(iconPath)")
                                            return iconPath
                                        }
                                    }
                                }
                                
                                // Additional fallback: scan for any .png files that might be icons
                                if let bundleContents = try? FileManager.default.contentsOfDirectory(atPath: appBundlePath) {
                                    for file in bundleContents {
                                        // Skip system files like .DS_Store
                                        if file.hasPrefix(".") {
                                            continue
                                        }
                                        
                                        if file.hasSuffix(".png") && (file.contains("Icon") || file.contains("icon")) {
                                            let iconPath = "\(appBundlePath)/\(file)"
                                            log("Found app icon (additional fallback): \(iconPath)")
                                            return iconPath
                                        }
                                    }
                                }
                                
                                log("No icon files found for bundle: \(bundleIdentifier)")
                                
                                // Final fallback: try to get icon from system app store
                                let systemIconPath = self.getSystemAppIcon(for: bundleIdentifier)
                                if let systemIconPath = systemIconPath {
                                                                    log("Found system app icon: \(systemIconPath)")
                                return systemIconPath
                                }
                                
                                return nil
                            }
                        } else {
                            log("Could not read Info.plist at: \(infoPlistPath)")
                        }
                    }
                }
            }
        } catch {
            log("Error getting app icon: \(error)", type: .error)
        }
        log("No icon found for bundle ID: \(bundleIdentifier)")
        return nil
    }
    
    private func getMockAppIcon(for appName: String) -> String {
        // Map app names to their asset catalog names
        switch appName {
        case "PhotoGram":
            return "MockAppIcons/photogram"
        case "BikBok":
            return "MockAppIcons/bikbok"
        case "Smudgify":
            return "MockAppIcons/smudgify"
        case "FlixStream":
            return "MockAppIcons/flixstream"
        case "HiLoThere":
            return "MockAppIcons/hilothere"
        default:
            return ""
        }
    }
    
    private func getSystemAppIcon(for bundleIdentifier: String) -> String? {
        // Try to find the app in the system Applications folder
        let systemAppPaths = [
            "/Applications",
            "/System/Applications",
            "/System/Applications/Utilities"
        ]
        
        for appPath in systemAppPaths {
            do {
                let appContents = try FileManager.default.contentsOfDirectory(atPath: appPath)
                for appName in appContents {
                    // Skip system files like .DS_Store
                    if appName.hasPrefix(".") {
                        continue
                    }
                    
                    if appName.hasSuffix(".app") {
                        let fullAppPath = "\(appPath)/\(appName)"
                        let infoPlistPath = "\(fullAppPath)/Contents/Info.plist"
                        
                        if FileManager.default.fileExists(atPath: infoPlistPath),
                           let infoPlist = NSDictionary(contentsOfFile: infoPlistPath) {
                            let bundleId = infoPlist["CFBundleIdentifier"] as? String
                            if bundleId == bundleIdentifier {
                                // Try to find icon in the app bundle
                                let iconPath = "\(fullAppPath)/Contents/Resources/AppIcon.icns"
                                if FileManager.default.fileExists(atPath: iconPath) {
                                    return iconPath
                                }
                                
                                // Try other common icon locations
                                let resourcePath = "\(fullAppPath)/Contents/Resources"
                                if let resourceContents = try? FileManager.default.contentsOfDirectory(atPath: resourcePath) {
                                    for file in resourceContents {
                                        // Skip system files like .DS_Store
                                        if file.hasPrefix(".") {
                                            continue
                                        }
                                        
                                        if file.hasSuffix(".icns") || (file.hasSuffix(".png") && file.contains("Icon")) {
                                            let iconPath = "\(resourcePath)/\(file)"
                                            return iconPath
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            } catch {
                // Continue to next path
                continue
            }
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
                // Skip system files like .DS_Store
                if snapshotDir.hasPrefix(".") {
                    continue
                }
                
                let snapshotPath = "\(app.snapshotsPath)/\(snapshotDir)"
                
                // Verify it's actually a directory
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: snapshotPath, isDirectory: &isDirectory) && isDirectory.boolValue else {
                    continue
                }
                
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
            log("Error loading snapshots: \(error)", type: .error)
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
                self.log("Error calculating snapshot size for \(snapshot.name): \(error)", type: .error)
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
                self.log("Error calculating documents size for \(app.name): \(error)", type: .error)
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
            log("Error calculating directory size: \(error)", type: .error)
        }
        
        return DirectorySize(size: totalSize)
    }
    
    func calculateTotalSnapshotsSize() {
        isLoadingTotalSnapshotsSize = true
        
        DispatchQueue.global(qos: .userInitiated).async {
            var totalSize: Int64 = 0
            
            for app in self.apps {
                do {
                    let enumerator = FileManager.default.enumerator(atPath: app.snapshotsPath)
                    while let file = enumerator?.nextObject() as? String {
                        let filePath = "\(app.snapshotsPath)/\(file)"
                        let attributes = try FileManager.default.attributesOfItem(atPath: filePath)
                        totalSize += attributes[.size] as? Int64 ?? 0
                    }
                } catch {
                    self.log("Error calculating snapshots size: \(error)", type: .error)
                }
            }
            
            DispatchQueue.main.async {
                self.totalSnapshotsSize = totalSize
                self.isLoadingTotalSnapshotsSize = false
            }
        }
    }
    
    func getAllSnapshotsSize() -> DirectorySize {
        return DirectorySize(size: totalSnapshotsSize)
    }
    
    // MARK: - Path Validation and Refresh
    
    private func validateAppPaths(_ app: App) -> Bool {
        let documentsExists = FileManager.default.fileExists(atPath: app.documentsPath)
        let snapshotsExists = FileManager.default.fileExists(atPath: app.snapshotsPath)
        
        log("Validating paths for \(app.name):")
        log("Documents path: \(app.documentsPath) - exists: \(documentsExists)")
        log("Snapshots path: \(app.snapshotsPath) - exists: \(snapshotsExists)")
        
        return documentsExists && snapshotsExists
    }
    
    private func refreshSimulatorDataIfNeeded(for app: App) -> Bool {
        // If paths are valid, no refresh needed
        if validateAppPaths(app) {
            log("Paths are valid for \(app.name), no refresh needed")
            return true
        }
        
        log("Paths are invalid for \(app.name), refreshing simulator data...")
        
        // Refresh the current simulators data
        if let selectedSimulator = selectedSimulator {
            log("Refreshing data for simulator: \(selectedSimulator.name)")
            
            // Reload apps for the current simulator
            loadApps(for: selectedSimulator)
            
            // Try to find the updated app
            if let updatedApp = apps.first(where: { $0.bundleIdentifier == app.bundleIdentifier }) {
                log("Found updated app: \(updatedApp.name)")
                
                // Update the selected app if it's the same one
                if selectedApp?.bundleIdentifier == app.bundleIdentifier {
                    selectedApp = updatedApp
                    log("Updated selected app to: \(updatedApp.name)")
                }
                
                // Validate the updated app's paths
                if validateAppPaths(updatedApp) {
                    log("Updated app paths are valid")
                    return true
                } else {
                    log("Updated app paths are still invalid", type: .error)
                    return false
                }
            } else {
                log("Could not find updated app for bundle identifier: \(app.bundleIdentifier)", type: .error)
                return false
            }
        } else {
            log("No selected simulator to refresh", type: .error)
            return false
        }
    }
    
    private func getValidatedApp(_ app: App) -> App? {
        // First try to validate the current app
        if validateAppPaths(app) {
            return app
        }
        
        // If validation fails, try to refresh and get the updated app
        if refreshSimulatorDataIfNeeded(for: app) {
            // Return the updated app from the refreshed data
            return apps.first(where: { $0.bundleIdentifier == app.bundleIdentifier })
        }
        
        return nil
    }

    // Returns an app whose Documents path exists, refreshing simulator data if needed.
    // Does not require the Snapshots directory to exist.
    private func getAppWithValidDocuments(_ app: App) -> App? {
        // If documents exists, we're good
        if FileManager.default.fileExists(atPath: app.documentsPath) {
            return app
        }
        // Try to refresh and get updated app
        if refreshSimulatorDataIfNeeded(for: app) {
            if let updatedApp = apps.first(where: { $0.bundleIdentifier == app.bundleIdentifier }) {
                if FileManager.default.fileExists(atPath: updatedApp.documentsPath) {
                    return updatedApp
                }
            }
        }
        return nil
    }
    
    // MARK: - Updated Functions with Path Validation
    
    func openDocumentsFolder(for app: App) {
        // Only require a valid Documents path; Snapshots is irrelevant for opening
        guard !app.documentsPath.isEmpty else {
            log("Documents path is empty for \(app.name); cannot open", type: .error)
            return
        }

        let documentsPath = app.documentsPath

        // Ensure the Documents directory exists; create if missing
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: documentsPath, isDirectory: &isDirectory) || !isDirectory.boolValue {
            do {
                try FileManager.default.createDirectory(atPath: documentsPath, withIntermediateDirectories: true)
                log("Created Documents directory for \(app.name) at \(documentsPath)")
            } catch {
                log("Failed to create Documents directory at \(documentsPath): \(error)", type: .error)
                return
            }
        }

        // Try to select the first visible file in Documents; fallback to opening the folder
        do {
            let contents = try FileManager.default.contentsOfDirectory(atPath: documentsPath)
                .filter { !$0.hasPrefix(".") } // skip hidden
                .sorted()

            var selectedFileURL: URL?
            for item in contents {
                let fullPath = "\(documentsPath)/\(item)"
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDir), !isDir.boolValue {
                    selectedFileURL = URL(fileURLWithPath: fullPath, isDirectory: false)
                    break
                }
            }

            if let fileURL = selectedFileURL {
                log("Revealing first file in Documents for \(app.name): \(fileURL.path)")
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                return
            }
        } catch {
            log("Failed to enumerate Documents at \(documentsPath): \(error)", type: .error)
        }

        let url = URL(fileURLWithPath: documentsPath, isDirectory: true)
        log("Opening documents folder for \(app.name) at \(documentsPath)")
        NSWorkspace.shared.open(url)
    }
    
    func takeSnapshot(for app: App) {
        // Only require a valid Documents directory. Snapshots directory will be created if needed.
        guard let validatedApp = getAppWithValidDocuments(app) else {
            log("Documents path invalid for \(app.name), cannot take snapshot", type: .error)
            return
        }
        
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let snapshotName = "snapshot_\(timestamp)"
        let snapshotPath = "\(validatedApp.snapshotsPath)/\(snapshotName)"
        
        log("Taking snapshot for \(validatedApp.name)")
        log("Documents path: \(validatedApp.documentsPath)")
        log("Snapshots path: \(validatedApp.snapshotsPath)")
        log("Snapshot path: \(snapshotPath)")
        
        // Start progress tracking
        DispatchQueue.main.async {
            self.isSnapshotOperationInProgress = true
            self.snapshotOperationProgress = 0.0
            self.snapshotOperationMessage = "Preparing snapshot..."
        }
        
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // Check if Documents directory exists
                let documentsExists = FileManager.default.fileExists(atPath: validatedApp.documentsPath)
                self.log("Documents directory exists: \(documentsExists)")
                
                if documentsExists {
                    DispatchQueue.main.async {
                        self.snapshotOperationProgress = 0.2
                        self.snapshotOperationMessage = "Creating directories..."
                    }
                    
                    // Create Snapshots directory if it doesn't exist
                    let snapshotsExists = FileManager.default.fileExists(atPath: validatedApp.snapshotsPath)
                    self.log("Snapshots directory exists: \(snapshotsExists)")
                    
                    if !snapshotsExists {
                        try FileManager.default.createDirectory(atPath: validatedApp.snapshotsPath, withIntermediateDirectories: true)
                        self.log("Created snapshots directory")
                    }
                    
                    // Create the snapshot directory first
                    try FileManager.default.createDirectory(atPath: snapshotPath, withIntermediateDirectories: true)
                    self.log("Created snapshot directory: \(snapshotPath)")
                    
                    DispatchQueue.main.async {
                        self.snapshotOperationProgress = 0.4
                        self.snapshotOperationMessage = "Copying documents..."
                    }
                    
                    // Copy the Documents directory itself to the snapshot
                    let documentsDestinationPath = "\(snapshotPath)/Documents"
                    try FileManager.default.copyItem(atPath: validatedApp.documentsPath, toPath: documentsDestinationPath)

                    // Validate the snapshot integrity against the source Documents
                    DispatchQueue.main.async {
                        self.snapshotOperationProgress = 0.6
                        self.snapshotOperationMessage = "Validating snapshot..."
                    }

                    let isValid = self.validateSnapshot(sourcePath: validatedApp.documentsPath, snapshotDocumentsPath: documentsDestinationPath)

                    if isValid {
                        DispatchQueue.main.async {
                            self.snapshotOperationProgress = 0.8
                            self.snapshotOperationMessage = "Finalizing snapshot..."
                        }

                        DispatchQueue.main.async {
                            self.loadSnapshots(for: validatedApp)
                            self.isSnapshotOperationInProgress = false
                            self.snapshotOperationProgress = 1.0
                            self.snapshotOperationMessage = "Snapshot created successfully!"
                            
                            // Reset progress after a short delay
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                self.snapshotOperationProgress = 0.0
                                self.snapshotOperationMessage = ""
                            }
                        }
                        
                        self.log("Snapshot created successfully: \(snapshotName)")
                    } else {
                        // Clean up the incomplete snapshot folder
                        do {
                            try FileManager.default.removeItem(atPath: snapshotPath)
                            self.log("Removed incomplete snapshot at: \(snapshotPath)")
                        } catch {
                            self.log("Failed to remove incomplete snapshot at \(snapshotPath): \(error)", type: .error)
                        }

                        // Surface a clear error message to the user and keep the HUD visible briefly
                        DispatchQueue.main.async {
                            self.snapshotOperationProgress = 1.0
                            self.snapshotOperationMessage = "Snapshot failed: Some files could not be copied. Close the app using these files and try again."
                            
                            // Hide after a delay
                            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                                self.isSnapshotOperationInProgress = false
                                self.snapshotOperationProgress = 0.0
                                self.snapshotOperationMessage = ""
                            }
                        }

                        self.log("Snapshot validation failed for \(validatedApp.name). Likely due to files in use during copy.", type: .error)
                    }
                } else {
                    DispatchQueue.main.async {
                        self.isSnapshotOperationInProgress = false
                        self.snapshotOperationMessage = "Documents directory does not exist"
                        
                        // Reset progress after a short delay
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                            self.snapshotOperationProgress = 0.0
                            self.snapshotOperationMessage = ""
                        }
                    }
                    self.log("Documents directory does not exist for \(validatedApp.name)")
                }
            } catch {
                DispatchQueue.main.async {
                    // Keep HUD visible to show the error, then hide
                    self.snapshotOperationProgress = 1.0
                    self.snapshotOperationMessage = "Error taking snapshot: \(error.localizedDescription)"
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                        self.isSnapshotOperationInProgress = false
                        self.snapshotOperationProgress = 0.0
                        self.snapshotOperationMessage = ""
                    }
                }
                self.log("Error taking snapshot: \(error)", type: .error)
            }
        }
    }

    // Validates that the snapshot at snapshotDocumentsPath matches the source at sourcePath
    // by comparing recursive file lists, relative paths, and sizes.
    private func validateSnapshot(sourcePath: String, snapshotDocumentsPath: String) -> Bool {
        // Ensure both directories exist
        guard FileManager.default.fileExists(atPath: sourcePath), FileManager.default.fileExists(atPath: snapshotDocumentsPath) else {
            self.log("Snapshot validation failed: One or both directories don't exist", type: .error)
            return false
        }

        do {
            let sourceFiles = try getAllFilesRecursively(at: sourcePath)
            let snapshotFiles = try getAllFilesRecursively(at: snapshotDocumentsPath)

            if sourceFiles.count != snapshotFiles.count {
                self.log("Snapshot validation failed: File count mismatch. Source: \(sourceFiles.count), Snapshot: \(snapshotFiles.count)", type: .error)
                return false
            }

            for (index, sourceFile) in sourceFiles.enumerated() {
                let copiedFile = snapshotFiles[index]

                if sourceFile.relativePath != copiedFile.relativePath {
                    self.log("Snapshot validation failed: File path mismatch at index \(index)", type: .error)
                    return false
                }

                if sourceFile.size != copiedFile.size {
                    self.log("Snapshot validation failed: Size mismatch for \(sourceFile.relativePath). Source: \(sourceFile.size), Snapshot: \(copiedFile.size)", type: .error)
                    return false
                }
            }

            self.log("Snapshot validation successful: All \(sourceFiles.count) files copied correctly")
            return true
        } catch {
            self.log("Snapshot validation failed with error: \(error)", type: .error)
            return false
        }
    }
    
    func restoreSnapshot(_ snapshot: Snapshot, for app: App) {
        guard let validatedApp = getValidatedApp(app) else {
            log("Could not validate paths for \(app.name), cannot restore snapshot", type: .error)
            return
        }
        
        // Start progress tracking
        DispatchQueue.main.async {
            self.isSnapshotOperationInProgress = true
            self.snapshotOperationProgress = 0.0
            self.snapshotOperationMessage = "Preparing to restore snapshot..."
        }
        
        DispatchQueue.global(qos: .userInitiated).async {
            self.performRestoreWithRetry(snapshot: snapshot, app: validatedApp, attempt: 1)
        }
    }
    
    private func performRestoreWithRetry(snapshot: Snapshot, app: App, attempt: Int) {
        do {
            DispatchQueue.main.async {
                self.snapshotOperationProgress = 0.2
                self.snapshotOperationMessage = "Removing current documents..."
            }
            
            // Remove current documents
            try FileManager.default.removeItem(atPath: app.documentsPath)
            
            DispatchQueue.main.async {
                self.snapshotOperationProgress = 0.5
                self.snapshotOperationMessage = "Restoring snapshot documents..."
            }
            
            // Copy the Documents directory from the snapshot to the apps documents path
            let snapshotDocumentsPath = "\(snapshot.path)/Documents"
            try FileManager.default.copyItem(atPath: snapshotDocumentsPath, toPath: app.documentsPath)
            
            DispatchQueue.main.async {
                self.snapshotOperationProgress = 0.8
                self.snapshotOperationMessage = "Waiting for file system to complete..."
            }
            
            // Wait 0.5ds for file system actions to complete
            Thread.sleep(forTimeInterval: 0.5)
            DispatchQueue.main.async {
                self.snapshotOperationProgress = 0.9
                self.snapshotOperationMessage = "Validating restore..."
            }
            
            // Validate the restore by comparing files
            let isValid = self.validateRestore(snapshot: snapshot, app: app)
            
            if isValid {
                DispatchQueue.main.async {
                    self.loadSnapshots(for: app)
                    self.snapshotOperationProgress = 1.0
                    self.snapshotOperationMessage = "Snapshot restored successfully!"
                    self.isSnapshotOperationInProgress = false
                    
                    // Reset progress after a short delay
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        self.snapshotOperationProgress = 0.0
                        self.snapshotOperationMessage = ""
                    }
                }
                self.log("Snapshot restored successfully on attempt \(attempt)")
            } else {
                if attempt < 2 {
                    self.log("Restore validation failed on attempt \(attempt), retrying...")
                    DispatchQueue.main.async {
                        self.snapshotOperationProgress = 0.1
                        self.snapshotOperationMessage = "Validation failed, retrying restore..."
                    }
                    
                    // Wait a bit before retry
                    Thread.sleep(forTimeInterval: 0.3)
                    
                    // Retry the restore
                    self.performRestoreWithRetry(snapshot: snapshot, app: app, attempt: attempt + 1)
                } else {
                    DispatchQueue.main.async {
                        self.isSnapshotOperationInProgress = false
                        self.snapshotOperationMessage = "Snapshot restore failed after 2 attempts. Files may be corrupted or incomplete."
                        
                        // Reset progress after a longer delay for error
                        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                            self.snapshotOperationProgress = 0.0
                            self.snapshotOperationMessage = ""
                        }
                    }
                    self.log("Snapshot restore failed after 2 attempts", type: .error)
                }
            }
        } catch {
            DispatchQueue.main.async {
                self.isSnapshotOperationInProgress = false
                self.snapshotOperationMessage = "Error restoring snapshot: \(error.localizedDescription)"
                
                // Reset progress after a short delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    self.snapshotOperationProgress = 0.0
                    self.snapshotOperationMessage = ""
                }
            }
            self.log("Error restoring snapshot on attempt \(attempt): \(error)", type: .error)
        }
    }
    
    private func validateRestore(snapshot: Snapshot, app: App) -> Bool {
        let snapshotDocumentsPath = "\(snapshot.path)/Documents"
        let restoredDocumentsPath = app.documentsPath
        
        // Check if both directories exist
        guard FileManager.default.fileExists(atPath: snapshotDocumentsPath),
              FileManager.default.fileExists(atPath: restoredDocumentsPath) else {
            self.log("Validation failed: One or both directories don't exist", type: .error)
            return false
        }
        
        do {
            // Get all files from both directories recursively
            let snapshotFiles = try getAllFilesRecursively(at: snapshotDocumentsPath)
            let restoredFiles = try getAllFilesRecursively(at: restoredDocumentsPath)
            
            // Compare file counts
            if snapshotFiles.count != restoredFiles.count {
                self.log("Validation failed: File count mismatch. Snapshot: \(snapshotFiles.count), Restored: \(restoredFiles.count)", type: .error)
                return false
            }
            
            // Compare file sizes and names
            for (index, snapshotFile) in snapshotFiles.enumerated() {
                let restoredFile = restoredFiles[index]
                
                // Compare relative paths
                if snapshotFile.relativePath != restoredFile.relativePath {
                    self.log("Validation failed: File path mismatch at index \(index)", type: .error)
                    return false
                }
                
                // Compare file sizes
                if snapshotFile.size != restoredFile.size {
                    self.log("Validation failed: File size mismatch for \(snapshotFile.relativePath). Snapshot: \(snapshotFile.size), Restored: \(restoredFile.size)", type: .error)
                    return false
                }
            }
            
            self.log("Validation successful: All \(snapshotFiles.count) files restored correctly")
            return true
            
        } catch {
            self.log("Validation failed with error: \(error)", type: .error)
            return false
        }
    }
    
    private struct FileInfo {
        let relativePath: String
        let size: Int64
    }
    
    private func getAllFilesRecursively(at path: String) throws -> [FileInfo] {
        var files: [FileInfo] = []
        let basePath = path
        
        func enumerateFiles(at currentPath: String, relativePath: String = "") throws {
            let contents = try FileManager.default.contentsOfDirectory(atPath: currentPath)
            
            for item in contents {
                let fullPath = "\(currentPath)/\(item)"
                let itemRelativePath = relativePath.isEmpty ? item : "\(relativePath)/\(item)"
                
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDirectory) {
                    if isDirectory.boolValue {
                        // Recursively enumerate subdirectories
                        try enumerateFiles(at: fullPath, relativePath: itemRelativePath)
                    } else {
                        // Add file to our list
                        let attributes = try FileManager.default.attributesOfItem(atPath: fullPath)
                        let size = attributes[.size] as? Int64 ?? 0
                        files.append(FileInfo(relativePath: itemRelativePath, size: size))
                    }
                }
            }
        }
        
        try enumerateFiles(at: basePath)
        return files.sorted { $0.relativePath < $1.relativePath }
    }
    
    func deleteSnapshot(_ snapshot: Snapshot) {
        // For delete operations, we need to validate the snapshot path
        guard FileManager.default.fileExists(atPath: snapshot.path) else {
            log("Snapshot path does not exist: \(snapshot.path)", type: .error)
            
            // Try to refresh and find the updated snapshot
            if let selectedApp = selectedApp {
                loadSnapshots(for: selectedApp)
                
                // Try to find the snapshot again
                if let updatedSnapshot = snapshots.first(where: { $0.id == snapshot.id }) {
                    if FileManager.default.fileExists(atPath: updatedSnapshot.path) {
                        log("Found updated snapshot, retrying delete")
                        deleteSnapshot(updatedSnapshot)
                        return
                    }
                }
            }
            
            log("Could not find valid snapshot to delete", type: .error)
            return
        }
        
        do {
            try FileManager.default.removeItem(atPath: snapshot.path)
            loadSnapshots(for: selectedApp!)
        } catch {
            log("Error deleting snapshot: \(error)", type: .error)
        }
    }
    
    func deleteAllSnapshots() {
        // Validate all apps before proceeding
        var validApps: [App] = []
        
        for app in apps {
            if let validatedApp = getValidatedApp(app) {
                validApps.append(validatedApp)
            } else {
                log("Skipping invalid app: \(app.name)", type: .error)
            }
        }
        
        for app in validApps {
            do {
                let snapshotDirectories = try FileManager.default.contentsOfDirectory(atPath: app.snapshotsPath)
                for snapshotDir in snapshotDirectories {
                    let snapshotPath = "\(app.snapshotsPath)/\(snapshotDir)"
                    try FileManager.default.removeItem(atPath: snapshotPath)
                }
            } catch {
                log("Error deleting snapshots for \(app.name): \(error)", type: .error)
            }
        }
        
        if let selectedApp = selectedApp {
            loadSnapshots(for: selectedApp)
        }
    }
    
    func testProgressBar() {
        // Start progress tracking
        DispatchQueue.main.async {
            self.isSnapshotOperationInProgress = true
            self.snapshotOperationProgress = 0.0
            self.snapshotOperationMessage = "Testing progress bar..."
        }
        
        // Simulate progress over 3 seconds
        DispatchQueue.global(qos: .userInitiated).async {
            for i in 1...30 {
                DispatchQueue.main.async {
                    self.snapshotOperationProgress = Double(i) / 30.0
                    
                    // Update message based on progress
                    if i <= 10 {
                        self.snapshotOperationMessage = "Preparing test operation..."
                    } else if i <= 20 {
                        self.snapshotOperationMessage = "Processing test data..."
                    } else {
                        self.snapshotOperationMessage = "Finalizing test..."
                    }
                }
                
                Thread.sleep(forTimeInterval: 0.1) // 100ms delay between updates
            }
            
            DispatchQueue.main.async {
                self.snapshotOperationProgress = 1.0
                self.snapshotOperationMessage = "Test completed successfully!"
                
                // Reset after 2 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.isSnapshotOperationInProgress = false
                    self.snapshotOperationProgress = 0.0
                    self.snapshotOperationMessage = ""
                }
            }
        }
    }

    // Call this to refresh disk usage for the selected app
    func refreshSelectedAppDiskUsage() {
        if let app = selectedApp {
            loadSnapshots(for: app)
        }
    }
    
    // MARK: - Mock Data Methods
    
    private func getMockSimulators() -> [Simulator] {
        return [
            Simulator(
                id: "mock-iphone-15-pro",
                name: "iPhone 15 Pro",
                iOSVersion: "iOS 17.4",
                deviceType: .iPhone,
                udid: "mock-udid-1",
                dataPath: "/mock/path/1",
                isPinned: true
            ),
            Simulator(
                id: "mock-iphone-15",
                name: "iPhone 15",
                iOSVersion: "iOS 17.4",
                deviceType: .iPhone,
                udid: "mock-udid-2",
                dataPath: "/mock/path/2",
                isPinned: false
            ),
            Simulator(
                id: "mock-ipad-pro",
                name: "iPad Pro (12.9-inch)",
                iOSVersion: "iOS 17.4",
                deviceType: .iPad,
                udid: "mock-udid-3",
                dataPath: "/mock/path/3",
                isPinned: false
            ),
            Simulator(
                id: "mock-iphone-se",
                name: "iPhone SE (3rd generation)",
                iOSVersion: "iOS 17.3",
                deviceType: .iPhone,
                udid: "mock-udid-4",
                dataPath: "/mock/path/4",
                isPinned: false
            )
        ]
    }
    
    private func getMockApps(for simulator: Simulator) -> [App] {
        let appNames = ["PhotoGram", "BikBok", "Smudgify", "FlixStream", "HiLoThere"]
        let bundleIds = ["com.photogram.ios", "com.bikbok.app", "com.smudgify.music", "com.flixstream.tv", "com.hilothere.chat"]
        let documentSizes = [2_500_000_000, 1_800_000_000, 950_000_000, 3_200_000_000, 750_000_000] // in bytes
        
        return zip(zip(appNames, bundleIds), documentSizes).enumerated().map { index, data in
            let ((name, bundleId), size) = data
            return App(
                id: "mock-app-\(index + 1)",
                name: name,
                bundleIdentifier: bundleId,
                iconPath: getMockAppIcon(for: name),
                documentsPath: "/mock/documents/\(name.lowercased().replacingOccurrences(of: " ", with: ""))",
                snapshotsPath: "/mock/snapshots/\(name.lowercased().replacingOccurrences(of: " ", with: ""))",
                documentsSize: Int64(size)
            )
        }
    }
    
    private func getMockSnapshots(for app: App) -> [Snapshot] {
        let calendar = Calendar.current
        let now = Date()
        
        return [
            Snapshot(
                id: "mock-snapshot-1",
                name: "Backup before update",
                date: calendar.date(byAdding: .day, value: -1, to: now) ?? now,
                size: 850_000_000, // 850 MB
                path: "/mock/snapshots/backup-1"
            ),
            Snapshot(
                id: "mock-snapshot-2",
                name: "Weekly backup",
                date: calendar.date(byAdding: .day, value: -7, to: now) ?? now,
                size: 1_200_000_000, // 1.2 GB
                path: "/mock/snapshots/backup-2"
            ),
            Snapshot(
                id: "mock-snapshot-3",
                name: "Monthly backup",
                date: calendar.date(byAdding: .month, value: -1, to: now) ?? now,
                size: 2_100_000_000, // 2.1 GB
                path: "/mock/snapshots/backup-3"
            ),
            Snapshot(
                id: "mock-snapshot-4",
                name: "Before app reinstall",
                date: calendar.date(byAdding: .day, value: -14, to: now) ?? now,
                size: 950_000_000, // 950 MB
                path: "/mock/snapshots/backup-4"
            )
        ]
    }
    
} 