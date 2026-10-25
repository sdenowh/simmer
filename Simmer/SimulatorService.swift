//
//  SimulatorService.swift
//  Simmer
//
//  Created by Scott Denowh on 7/10/25.
//

import Foundation
import AppKit
import CryptoKit
import Darwin
import os.log

enum PushSendOutcome {
    case sent
    case rejected(String)
    case failed(String)
}

class SimulatorService: ObservableObject {
    private let logger = Logger(subsystem: "com.simmer.app", category: "SimulatorService")
    
    // MARK: - Mock Data Configuration
    private var useMockData: Bool {
        get {
            #if DEBUG
            return UserDefaults.standard.bool(forKey: "UseMockData")
            #else
            return false
            #endif
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
        #else
        NSLog("[Simmer] \(message)")
        // Stdio MCP framing owns stdout. Release logs stay in the system log.
        if !MCPProcess.stdio {
            print("[Simmer] \(message)")
        }
        #endif
    }
    
    @Published var simulators: [Simulator] = []
    @Published var selectedSimulator: Simulator?
    @Published var apps: [App] = []
    @Published var selectedApp: App?
    @Published var snapshots: [Snapshot] = []
    @Published var totalSnapshotsSize: Int64 = 0
    @Published var isLoadingTotalSnapshotsSize: Bool = false
    @Published var isSnapshotOperationInProgress: Bool = false
    @Published var snapshotOperationFailed: Bool = false
    @Published var snapshotOperationProgress: Double = 0.0
    @Published var snapshotOperationMessage: String = ""
    @Published var pushHistoryChangeTick: Int = 0
    
    private let simulatorPath = "~/Library/Developer/CoreSimulator/Devices"
    private let expandedSimulatorPath = NSString(string: "~/Library/Developer/CoreSimulator/Devices").expandingTildeInPath
    private let pinnedSimulatorsKey = "PinnedSimulators"
    private var snapshotLoadGeneration = 0
    private var snapshotsSizeGeneration = 0
    private let criticalOperationReason = "Simmer snapshot operation"
    private let snapshotLock = NSLock()
    private var snapshotBlockedUntil: Date?
    private var simulatorControlKeys: Set<String> = []
    
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

    func sendPushNotification(payloadJSON: String, name: String?, for app: App, on simulator: Simulator, saveToHistory: Bool = true, completion: ((Bool, String?) -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = self.performPushNotification(payloadJSON: payloadJSON, name: name, for: app, on: simulator, saveToHistory: saveToHistory)
            DispatchQueue.main.async {
                switch outcome {
                case .sent:
                    self.deliverBanner("Push sent to \(app.name) on \(simulator.name)")
                    completion?(true, nil)
                case .rejected(let message):
                    completion?(false, message)
                case .failed(let message):
                    self.log("Push failed: \(message)", type: .error)
                    self.deliverBanner("Push failed: \(message)")
                    completion?(false, message)
                }
            }
        }
    }

    func performPushNotification(payloadJSON: String, name: String?, for app: App, on simulator: Simulator, saveToHistory: Bool) -> PushSendOutcome {
        guard let data = payloadJSON.data(using: .utf8) else {
            return .rejected("Invalid UTF-8 payload")
        }
        do {
            _ = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            return .rejected("Payload is not valid JSON: \(error.localizedDescription)")
        }

        guard simulatorIsBooted(at: simulator.dataPath) else {
            return .rejected("\(simulator.name) is not booted. Boot it in Simulator and try again.")
        }

        let tempDir = NSTemporaryDirectory()
        let filePath = (tempDir as NSString).appendingPathComponent("simmer-\(UUID().uuidString).apns")
        do {
            try payloadJSON.write(toFile: filePath, atomically: true, encoding: .utf8)
        } catch {
            return .rejected("Failed to write temp file: \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(atPath: filePath) }

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
            log("Failed to run simctl push: \(error)", type: .error)
            return .failed("Failed to run simctl push: \(error.localizedDescription)")
        }

        process.waitUntilExit()

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errOutput = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            let message = errOutput.isEmpty ? output : errOutput
            return .failed(message.isEmpty ? "simctl push failed" : message)
        }

        log("Push sent successfully: \(output)")
        if saveToHistory {
            var existing = getPushHistory(for: app, on: simulator)
            let fallbackName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let finalName = (fallbackName?.isEmpty == false ? fallbackName! : (extractAlertTitle(from: payloadJSON) ?? ""))
            let item = SentNotification(id: UUID().uuidString, name: finalName, createdAt: Date(), payloadJSON: payloadJSON)
            existing.append(item)
            savePushHistory(existing, for: app, on: simulator)
        }
        return .sent
    }

    func repeatLastPush(for app: App, on simulator: Simulator, completion: ((Bool, String?) -> Void)? = nil) {
        let history = getPushHistory(for: app, on: simulator)
        guard let last = history.first else {
            completion?(false, "No previous notification to repeat")
            return
        }
        sendPushNotification(payloadJSON: last.payloadJSON, name: last.name.isEmpty ? nil : last.name, for: app, on: simulator, saveToHistory: false, completion: completion)
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
            if first.isPinned != second.isPinned {
                return first.isPinned
            }
            switch (first.lastBootedAt, second.lastBootedAt) {
            case let (lhs?, rhs?) where lhs != rhs:
                return lhs > rhs
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return first.name.localizedCaseInsensitiveCompare(second.name) == .orderedAscending
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
        // Mock simulators use fake ids. Persisting them would erase real pins.
        guard !useMockData else { return }
        let pinnedIds = simulators.filter { $0.isPinned }.map { $0.id }
        UserDefaults.standard.set(pinnedIds, forKey: pinnedSimulatorsKey)
    }
    
    func loadApps(for simulator: Simulator) {
        let previousSimulatorId = selectedSimulator?.id
        let previousBundleId = selectedApp?.bundleIdentifier
        if useMockData {
            apps = getMockApps(for: simulator)
        } else {
            apps = getApps(for: simulator)
        }
        selectedSimulator = simulator
        if previousSimulatorId != nil && previousSimulatorId != simulator.id {
            selectedApp = nil
            snapshots = []
            clearSnapshotSize()
        } else if let previousBundleId,
                  let updated = apps.first(where: { $0.bundleIdentifier == previousBundleId }) {
            selectedApp = updated
        } else if previousBundleId != nil {
            selectedApp = nil
            snapshots = []
            clearSnapshotSize()
        }
    }
    
    func loadSnapshots(for app: App) {
        snapshotLoadGeneration += 1
        if useMockData {
            snapshotsSizeGeneration += 1
            snapshots = getMockSnapshots(for: app)
            totalSnapshotsSize = snapshots.reduce(0) { $0 + $1.size }
            isLoadingTotalSnapshotsSize = false
        } else {
            let generation = snapshotLoadGeneration
            snapshots = getSnapshots(for: app, generation: generation)
            if snapshots.isEmpty {
                clearSnapshotSize()
            } else {
                calculateTotalSnapshotsSize(at: app.snapshotsPath)
            }
            
            // Always refresh documents size for the expanded app to keep sizes accurate
            if let appIndex = apps.firstIndex(where: { $0.id == app.id }) {
                if !apps[appIndex].documentsPath.isEmpty {
                    let measuredPath = apps[appIndex].documentsPath
                    let measuredId = apps[appIndex].id
                    apps[appIndex].startLoadingDocumentsSize()
                    calculateDocumentsSize(for: apps[appIndex]) { calculatedSize in
                        DispatchQueue.main.async {
                            self.applyDocumentsSize(calculatedSize, appId: measuredId, documentsPath: measuredPath)
                        }
                    }
                }
            }
        }
        selectedApp = app
    }

    private func clearSnapshotSize() {
        snapshotsSizeGeneration += 1
        totalSnapshotsSize = 0
        isLoadingTotalSnapshotsSize = false
    }

    private func applyDocumentsSize(_ calculatedSize: Int64, appId: String, documentsPath: String) {
        guard let appIndex = apps.firstIndex(where: { $0.id == appId }) else { return }
        guard apps[appIndex].documentsPath == documentsPath else { return }
        apps[appIndex].finishLoadingDocumentsSize(calculatedSize)
    }
    
    func getAvailableSimulators() -> [Simulator] {
        var simulators: [Simulator] = []
        
        do {
            let deviceDirectories = try FileManager.default.contentsOfDirectory(atPath: expandedSimulatorPath)
            
            for deviceDir in deviceDirectories {
                let devicePath = "\(expandedSimulatorPath)/\(deviceDir)"
                let devicePlistPath = "\(devicePath)/device.plist"
                
                if let deviceData = NSDictionary(contentsOfFile: devicePlistPath) {
                    if deviceRecordIsDeleted(deviceData) {
                        continue
                    }
                    let name = deviceData["name"] as? String ?? "Unknown"
                    let runtime = deviceData["runtime"] as? String ?? "Unknown"
                    let deviceType = deviceData["deviceType"] as? String ?? "iPhone"
                    let lastBootedAt = deviceData["lastBootedAt"] as? Date
                    
                    let simulator = Simulator(
                        id: deviceDir,
                        name: name,
                        iOSVersion: runtime.replacingOccurrences(of: "com.apple.CoreSimulator.SimRuntime.", with: ""),
                        deviceType: Simulator.DeviceType.resolve(deviceType),
                        udid: deviceDir,
                        dataPath: devicePath,
                        lastBootedAt: lastBootedAt
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
    
    func getApps(for simulator: Simulator) -> [App] {
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
                                    let measuredPath = documentsPath
                                    let measuredId = bundleDir
                                    calculateDocumentsSize(for: app) { calculatedSize in
                                        DispatchQueue.main.async {
                                            self.applyDocumentsSize(calculatedSize, appId: measuredId, documentsPath: measuredPath)
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
                                
                                log("No loose icon file for \(bundleIdentifier); using the app bundle icon")
                                return appBundlePath
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
    
    private func getSnapshots(for app: App, generation: Int) -> [Snapshot] {
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
                // Load optional display name from metadata.json if present
                let metadataPath = "\(snapshotPath)/metadata.json"
                if FileManager.default.fileExists(atPath: metadataPath) {
                    do {
                        let data = try Data(contentsOf: URL(fileURLWithPath: metadataPath))
                        if let decoded = try? JSONDecoder().decode(SnapshotMetadata.self, from: data) {
                            snapshot.displayName = decoded.displayName
                        }
                    } catch {
                        log("Failed to read snapshot metadata at \(metadataPath): \(error)", type: .error)
                    }
                }
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
                    guard generation == self.snapshotLoadGeneration else { return }
                    if let snapshotIndex = self.snapshots.firstIndex(where: { $0.id == snapshot.id }) {
                        self.snapshots[snapshotIndex].finishLoadingSize(calculatedSize)
                    }
                }
            }
        }
        
        return sortedSnapshots
    }

    // MARK: - Snapshot Metadata (Rename)
    func renameSnapshotDisplayName(_ snapshot: Snapshot, to newName: String?) {
        // Must have selected app context to ensure paths remain valid/fresh
        guard let selected = selectedApp, let app = liveApp(selected) else { return }
        // Find current snapshot (by id) to get latest path
        loadSnapshots(for: app)
        guard let currentIndex = snapshots.firstIndex(where: { $0.id == snapshot.id }) else { return }
        let current = snapshots[currentIndex]
        let metadataPath = "\(current.path)/metadata.json"

        let trimmed = newName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            // Clear display name by removing metadata file if exists
            if FileManager.default.fileExists(atPath: metadataPath) {
                do { try FileManager.default.removeItem(atPath: metadataPath) } catch {
                    log("Failed to remove metadata.json: \(error)", type: .error)
                }
            }
            DispatchQueue.main.async {
                if let idx = self.snapshots.firstIndex(where: { $0.id == snapshot.id }) {
                    self.snapshots[idx].displayName = nil
                }
            }
            return
        }

        // Persist new display name
        let metadata = SnapshotMetadata(displayName: trimmed)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            let data = try encoder.encode(metadata)
            try data.write(to: URL(fileURLWithPath: metadataPath), options: [.atomic])
            DispatchQueue.main.async {
                if let idx = self.snapshots.firstIndex(where: { $0.id == snapshot.id }) {
                    self.snapshots[idx].displayName = trimmed
                }
            }
        } catch {
            log("Failed to write metadata.json: \(error)", type: .error)
        }
    }
    
    private func calculateSnapshotSize(for snapshot: Snapshot, completion: @escaping (Int64) -> Void) {
        let path = snapshot.path
        DispatchQueue.global(qos: .userInitiated).async {
            completion(directoryByteSize(at: path))
        }
    }
    
    private func calculateDocumentsSize(for app: App, completion: @escaping (Int64) -> Void) {
        let path = app.documentsPath
        DispatchQueue.global(qos: .userInitiated).async {
            completion(directoryByteSize(at: path))
        }
    }
    
    func getDirectorySize(for path: String) -> DirectorySize {
        DirectorySize(size: directoryByteSize(at: path))
    }
    
    func calculateTotalSnapshotsSize(at snapshotsPath: String) {
        snapshotsSizeGeneration += 1
        let generation = snapshotsSizeGeneration
        guard !snapshotsPath.isEmpty else {
            totalSnapshotsSize = 0
            isLoadingTotalSnapshotsSize = false
            return
        }
        isLoadingTotalSnapshotsSize = true
        DispatchQueue.global(qos: .userInitiated).async {
            let totalSize = directoryByteSize(at: snapshotsPath)
            DispatchQueue.main.async {
                guard generation == self.snapshotsSizeGeneration else { return }
                self.totalSnapshotsSize = totalSize
                self.isLoadingTotalSnapshotsSize = false
            }
        }
    }
    
    func getAllSnapshotsSize() -> DirectorySize {
        return DirectorySize(size: totalSnapshotsSize)
    }
    
    // MARK: - Live container lookup

    /// True when `documentsPath` still sits in the data container CoreSimulator
    /// currently assigns to this bundle id. A reinstall mints a new UUID, and
    /// the old path must not be recreated.
    func isLiveDataContainer(_ app: App) -> Bool {
        guard !app.documentsPath.isEmpty, !app.bundleIdentifier.isEmpty else { return false }
        let container = (app.documentsPath as NSString).deletingLastPathComponent
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: container, isDirectory: &isDir), isDir.boolValue else {
            return false
        }
        let metadataPath = (container as NSString).appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist")
        guard let metadata = NSDictionary(contentsOfFile: metadataPath),
              let identifier = metadata["MCMMetadataIdentifier"] as? String else {
            return false
        }
        return identifier == app.bundleIdentifier
    }

    /// Returns the app record whose data container matches the bundle id now.
    /// Does not require a Snapshots directory; that folder is created on first capture.
    private func liveApp(_ app: App) -> App? {
        if isLiveDataContainer(app) {
            return app
        }
        guard let simulator = selectedSimulator else { return nil }
        loadApps(for: simulator)
        guard let updated = apps.first(where: { $0.bundleIdentifier == app.bundleIdentifier }),
              isLiveDataContainer(updated) else {
            return nil
        }
        return updated
    }

    func tryBeginSnapshotOperation() -> Bool {
        guard snapshotLock.`try`() else { return false }
        if let snapshotBlockedUntil, snapshotBlockedUntil > Date() {
            snapshotLock.unlock()
            return false
        }
        snapshotBlockedUntil = nil
        return true
    }

    func endSnapshotOperation() {
        snapshotLock.unlock()
    }

    func blockFurtherSnapshots(for interval: TimeInterval) {
        snapshotBlockedUntil = Date().addingTimeInterval(interval)
    }

    func deliverBanner(_ text: String) {
        let post = {
            let notification = NSUserNotification()
            notification.title = "Simmer"
            notification.informativeText = text
            NSUserNotificationCenter.default.deliver(notification)
        }
        if Thread.isMainThread {
            post()
        } else {
            DispatchQueue.main.async(execute: post)
        }
    }

    private func beginCriticalFileOperation() {
        ProcessInfo.processInfo.disableSuddenTermination()
        ProcessInfo.processInfo.disableAutomaticTermination(criticalOperationReason)
    }

    private func endCriticalFileOperation() {
        ProcessInfo.processInfo.enableAutomaticTermination(criticalOperationReason)
        ProcessInfo.processInfo.enableSuddenTermination()
    }

    // MARK: - Boot and launch

    /// Boots the simulator if it is shut down, then brings Simulator to the front on that device.
    func openInSimulator(_ simulator: Simulator) {
        startSimulatorControl(simulator, bundleIdentifier: nil)
    }

    /// Launches the app. Boots the simulator and opens Simulator first when the device is shut down.
    func launch(_ app: App, on simulator: Simulator) {
        startSimulatorControl(simulator, bundleIdentifier: app.bundleIdentifier)
    }

    private func startSimulatorControl(_ simulator: Simulator, bundleIdentifier: String?) {
        if isSnapshotOperationInProgress {
            deliverBanner("Wait for the snapshot to finish, then try again.")
            return
        }
        if useMockData {
            deliverBanner("Turn off mock data to open a simulator.")
            return
        }
        let key = simulatorControlKey(udid: simulator.udid, bundleIdentifier: bundleIdentifier)
        guard simulatorControlKeys.insert(key).inserted else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = self.performSimulatorControl(name: simulator.name, udid: simulator.udid, bundleIdentifier: bundleIdentifier)
            DispatchQueue.main.async {
                self.simulatorControlKeys.remove(key)
                switch result {
                case .opened:
                    self.loadSimulators()
                case .failed(let message):
                    self.log(message, type: .error)
                    self.deliverBanner(message)
                }
            }
        }
    }

    private func performSimulatorControl(name: String, udid: String, bundleIdentifier: String?) -> SimulatorControlResult {
        guard let plan = simulatorControlPlan(udid: udid, bundleIdentifier: bundleIdentifier) else {
            return .failed("That simulator can't be opened from Simmer.")
        }

        switch runXcrun(plan.bootStatusArguments, timeout: simulatorBootTimeout) {
        case .failure(.timedOut):
            return .failed("Timed out waiting for \(name) to boot.")
        case .failure(.launchFailed(let message)):
            return .failed("Couldn't run simctl: \(message)")
        case .success(let result) where result.status != 0:
            return .failed(simctlFailureSummary(result.output, fallback: "Couldn't boot \(name)."))
        case .success:
            break
        }

        if let message = focusSimulatorApp(arguments: plan.focusArguments) {
            return .failed(message)
        }

        guard let launchArguments = plan.launchArguments else { return .opened }
        switch runXcrun(launchArguments, timeout: simulatorLaunchTimeout) {
        case .failure(.timedOut):
            return .failed("Timed out launching the app on \(name).")
        case .failure(.launchFailed(let message)):
            return .failed("Couldn't run simctl: \(message)")
        case .success(let result) where result.status != 0:
            return .failed(simctlFailureSummary(result.output, fallback: "Couldn't launch the app on \(name)."))
        case .success:
            return .opened
        }
    }

    /// Asks Simulator.app to show this device. Arguments are ignored when Simulator
    /// is already running, but a boot still makes that app open a window for the device.
    private func focusSimulatorApp(arguments: [String]) -> String? {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: simulatorAppBundleIdentifier) else {
            return "Couldn't find Simulator.app."
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = arguments
        configuration.activates = true
        let semaphore = DispatchSemaphore(value: 0)
        var failure: String?
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
            if let error {
                failure = error.localizedDescription
            }
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + 20) == .timedOut {
            return "Timed out opening Simulator."
        }
        return failure
    }

    func terminateRunningApp(_ app: App, on simulator: Simulator) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "terminate", simulator.udid, app.bundleIdentifier]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            log("Could not terminate \(app.bundleIdentifier): \(error)")
        }
    }

    private func reportSnapshotFailure(_ message: String) {
        blockFurtherSnapshots(for: 4)
        isSnapshotOperationInProgress = true
        snapshotOperationFailed = true
        snapshotOperationProgress = 0
        snapshotOperationMessage = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            self.clearSnapshotOperationStatus()
        }
    }

    /// Clears the progress UI without releasing the snapshot lock.
    private func clearSnapshotOperationStatus() {
        isSnapshotOperationInProgress = false
        snapshotOperationFailed = false
        snapshotOperationProgress = 0
        snapshotOperationMessage = ""
    }

    /// Clears the progress UI and releases the operation claimed by `tryBeginSnapshotOperation`.
    /// Call only after the background work has kept that claim.
    private func endVisibleSnapshotOperation() {
        clearSnapshotOperationStatus()
        endSnapshotOperation()
    }

    func noteSnapshotProgress(message: String, fraction: Double) {
        DispatchQueue.main.async {
            guard self.isSnapshotOperationInProgress, !self.snapshotOperationFailed else { return }
            self.snapshotOperationMessage = message
            self.snapshotOperationProgress = min(max(fraction, 0), 1)
        }
    }
    
    // MARK: - Updated Functions with Path Validation
    
    /// Opens the live Documents directory. Returns an error message when the
    /// current container cannot be resolved. Never recreates a stale UUID.
    func openDocumentsFolder(for app: App) -> String? {
        guard let current = liveApp(app) else {
            let message = "Couldn't find the current Documents folder for \(app.name). Reopen this simulator and try again."
            log(message, type: .error)
            return message
        }

        let documentsPath = current.documentsPath
        let parent = (documentsPath as NSString).deletingLastPathComponent
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent, isDirectory: &isDirectory), isDirectory.boolValue else {
            let message = "Couldn't find the app container for \(app.name)."
            log(message, type: .error)
            return message
        }

        if !FileManager.default.fileExists(atPath: documentsPath, isDirectory: &isDirectory) || !isDirectory.boolValue {
            do {
                try FileManager.default.createDirectory(atPath: documentsPath, withIntermediateDirectories: false)
                log("Created Documents directory for \(current.name) at \(documentsPath)")
            } catch {
                let message = "Couldn't create the Documents folder for \(current.name)."
                log("\(message) \(error)", type: .error)
                return message
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
                log("Revealing first file in Documents for \(current.name): \(fileURL.path)")
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                return nil
            }
        } catch {
            log("Failed to enumerate Documents at \(documentsPath): \(error)", type: .error)
        }

        let url = URL(fileURLWithPath: documentsPath, isDirectory: true)
        log("Opening documents folder for \(current.name) at \(documentsPath)")
        NSWorkspace.shared.open(url)
        return nil
    }
    
    func takeSnapshot(for app: App) {
        guard tryBeginSnapshotOperation() else { return }
        var handedOff = false
        defer { if !handedOff { endSnapshotOperation() } }
        isSnapshotOperationInProgress = true
        snapshotOperationFailed = false
        snapshotOperationProgress = 0
        snapshotOperationMessage = "Preparing snapshot..."
        guard let validatedApp = liveApp(app) else {
            log("Documents container invalid for \(app.name), cannot take snapshot", type: .error)
            reportSnapshotFailure("Couldn't find this app's container, so no snapshot was taken.")
            return
        }
        guard !validatedApp.snapshotsPath.isEmpty else {
            reportSnapshotFailure("Couldn't find a place to store snapshots for \(validatedApp.name).")
            return
        }
        guard FileManager.default.fileExists(atPath: validatedApp.documentsPath) else {
            reportSnapshotFailure("Documents directory does not exist")
            return
        }

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let snapshotName = "snapshot_\(timestamp)"
        let snapshotPath = (validatedApp.snapshotsPath as NSString).appendingPathComponent(snapshotName)

        log("Taking snapshot for \(validatedApp.name) at \(snapshotPath)")
        beginCriticalFileOperation()
        handedOff = true

        DispatchQueue.global(qos: .userInitiated).async {
            defer {
                DispatchQueue.main.async { self.endCriticalFileOperation() }
            }
            do {
                if !FileManager.default.fileExists(atPath: validatedApp.snapshotsPath) {
                    try FileManager.default.createDirectory(atPath: validatedApp.snapshotsPath, withIntermediateDirectories: true)
                }
                try captureDocumentsSnapshot(
                    documentsPath: validatedApp.documentsPath,
                    snapshotPath: snapshotPath,
                    onProgress: { message, fraction in
                        self.noteSnapshotProgress(message: message, fraction: fraction)
                    },
                    onRetry: { attempt, error in
                        DispatchQueue.main.async {
                            self.snapshotOperationFailed = false
                            self.snapshotOperationProgress = 0
                            self.snapshotOperationMessage = "Temporary problem (\(error.localizedDescription)). Retrying snapshot..."
                        }
                        self.log("Snapshot attempt \(attempt) failed: \(error). Retrying.")
                    }
                )
                DispatchQueue.main.async {
                    self.loadSnapshots(for: validatedApp)
                    self.snapshotOperationFailed = false
                    self.snapshotOperationProgress = 1
                    self.snapshotOperationMessage = "Snapshot created successfully!"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        self.endVisibleSnapshotOperation()
                    }
                }
                self.log("Snapshot created successfully: \(snapshotName)")
            } catch {
                self.blockFurtherSnapshots(for: 4)
                DispatchQueue.main.async {
                    self.snapshotOperationFailed = true
                    self.snapshotOperationProgress = 0
                    self.snapshotOperationMessage = "Snapshot failed: \(error.localizedDescription) No snapshot was saved."
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                        self.endVisibleSnapshotOperation()
                    }
                }
                self.log("Error taking snapshot: \(error)", type: .error)
            }
        }
    }

    func restoreSnapshot(_ snapshot: Snapshot, for app: App) {
        guard tryBeginSnapshotOperation() else { return }
        var handedOff = false
        defer { if !handedOff { endSnapshotOperation() } }
        guard let validatedApp = liveApp(app) else {
            reportSnapshotFailure("Couldn't find this app's container, so nothing was changed.")
            return
        }
        guard let simulator = selectedSimulator else { return }
        guard isSafeSnapshotPath(snapshot.path, for: validatedApp) else {
            reportSnapshotFailure("This snapshot is not in the current app container, so nothing was changed.")
            return
        }
        let snapshotDocumentsPath = (snapshot.path as NSString).appendingPathComponent("Documents")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: snapshotDocumentsPath, isDirectory: &isDir), isDir.boolValue else {
            reportSnapshotFailure("This snapshot has no Documents folder, so nothing was changed.")
            return
        }

        isSnapshotOperationInProgress = true
        snapshotOperationFailed = false
        snapshotOperationProgress = 0
        snapshotOperationMessage = "Preparing to restore snapshot..."
        beginCriticalFileOperation()
        handedOff = true

        DispatchQueue.global(qos: .userInitiated).async {
            defer {
                self.endSnapshotOperation()
                DispatchQueue.main.async { self.endCriticalFileOperation() }
            }
            self.terminateRunningApp(validatedApp, on: simulator)
            self.performRestore(snapshotDocumentsPath: snapshotDocumentsPath, app: validatedApp, simulator: simulator)
        }
    }

    private func performRestore(snapshotDocumentsPath: String, app: App, simulator: Simulator) {
        do {
            try restoreDocumentsReplacingLiveCopy(
                snapshotDocumentsPath: snapshotDocumentsPath,
                documentsPath: app.documentsPath,
                simulatorRoot: simulator.dataPath,
                onProgress: { message, fraction in
                    self.noteSnapshotProgress(message: message, fraction: fraction)
                },
                onRetry: { attempt, error in
                    DispatchQueue.main.async {
                        self.snapshotOperationFailed = false
                        self.snapshotOperationProgress = 0
                        self.snapshotOperationMessage = "Temporary problem (\(error.localizedDescription)). Retrying restore..."
                    }
                    self.log("Restore attempt \(attempt) failed: \(error). Retrying.")
                }
            )
            DispatchQueue.main.async {
                self.loadSnapshots(for: app)
                self.snapshotOperationFailed = false
                self.snapshotOperationProgress = 1
                self.snapshotOperationMessage = "Snapshot restored successfully!"
                self.isSnapshotOperationInProgress = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    self.snapshotOperationProgress = 0
                    self.snapshotOperationMessage = ""
                }
            }
            self.log("Snapshot restored successfully")
        } catch {
            self.blockFurtherSnapshots(for: 4)
            DispatchQueue.main.async {
                self.snapshotOperationFailed = true
                self.snapshotOperationProgress = 0
                self.snapshotOperationMessage = restoreFailureMessage(error)
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    self.clearSnapshotOperationStatus()
                }
            }
            self.log("Error restoring snapshot: \(error)", type: .error)
        }
    }

    // MARK: - Path Safety
    
    private func normalizedPath(_ path: String) -> String {
        standardizedPath(path)
    }
    
    private func isPath(_ candidate: String, underDirectory base: String) -> Bool {
        pathIsInside(candidate, directory: base)
    }
    
    private func isSafeSnapshotPath(_ snapshotPath: String, for app: App) -> Bool {
        isDeletableSnapshotDirectory(
            snapshotPath,
            snapshotsRoot: app.snapshotsPath,
            documentsPath: app.documentsPath,
            simulatorRoot: selectedSimulator?.dataPath
        )
    }
    
    func deleteSnapshot(_ snapshot: Snapshot) {
        guard tryBeginSnapshotOperation() else { return }
        defer { endSnapshotOperation() }
        if useMockData {
            snapshots.removeAll { $0.id == snapshot.id }
            totalSnapshotsSize = snapshots.reduce(0) { $0 + $1.size }
            return
        }
        guard let selected = selectedApp else {
            log("No selected app; refusing to delete snapshot", type: .error)
            return
        }
        guard let app = liveApp(selected) else {
            log("Refusing to delete snapshot; app container is not current", type: .error)
            return
        }
        
        // Resolve latest path for this snapshot by ID to avoid stale paths
        loadSnapshots(for: app)
        guard let current = snapshots.first(where: { $0.id == snapshot.id }) else {
            log("Snapshot not found by id: \(snapshot.id)", type: .error)
            return
        }
        
        let targetPath = current.path
        
        // Existence check
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: targetPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            log("Snapshot path missing or not a directory: \(targetPath)", type: .error)
            return
        }
        
        // Dual safety checks: semantic and structural
        guard isSafeSnapshotPath(targetPath, for: app) else {
            log("Refusing to delete unsafe path: \(targetPath)", type: .error)
            return
        }
        
        // Extra sanity check with independent logic: ensure not simulator root or app Documents
        let normTarget = normalizedPath(targetPath)
        let normDocs = normalizedPath(app.documentsPath)
        let normSnapshots = normalizedPath(app.snapshotsPath)
        if normTarget == normDocs || normTarget == normSnapshots || isPath(normTarget, underDirectory: normDocs) {
            log("Sanity check failed; target is Documents or Snapshots root: \(normTarget)", type: .error)
            return
        }
        if let sim = selectedSimulator {
            let normSim = normalizedPath(sim.dataPath)
            if normTarget == normSim {
                log("Sanity check failed; target is simulator root: \(normTarget)", type: .error)
                return
            }
            // Also insist target lives under the simulator data path
            if !isPath(normTarget, underDirectory: normSim) {
                log("Sanity check failed; target not under simulator path: \(normTarget)", type: .error)
                return
            }
        }
        
        do {
            try FileManager.default.removeItem(atPath: targetPath)
            loadSnapshots(for: app)
        } catch {
            log("Error deleting snapshot at \(targetPath): \(error)", type: .error)
        }
    }
    
    func deleteAllSnapshots(for app: App) {
        guard tryBeginSnapshotOperation() else { return }
        var handedOff = false
        defer { if !handedOff { endSnapshotOperation() } }
        if useMockData {
            snapshots = []
            totalSnapshotsSize = 0
            isLoadingTotalSnapshotsSize = false
            return
        }
        guard let current = liveApp(app) else {
            log("Skipping delete-all; app container is not current", type: .error)
            return
        }
        let snapshotsPath = current.snapshotsPath
        let documentsPath = current.documentsPath
        let simulatorRoot = selectedSimulator?.dataPath
        guard !snapshotsPath.isEmpty else { return }

        isSnapshotOperationInProgress = true
        snapshotOperationFailed = false
        snapshotOperationProgress = 0.3
        snapshotOperationMessage = "Deleting snapshots for \(current.name)..."
        beginCriticalFileOperation()
        handedOff = true

        DispatchQueue.global(qos: .userInitiated).async {
            defer {
                self.endSnapshotOperation()
                DispatchQueue.main.async {
                    self.endCriticalFileOperation()
                    self.isSnapshotOperationInProgress = false
                    self.snapshotOperationProgress = 0
                    self.snapshotOperationMessage = ""
                    self.loadSnapshots(for: current)
                }
            }
            do {
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: snapshotsPath, isDirectory: &isDir), isDir.boolValue else { return }
                let children = try FileManager.default.contentsOfDirectory(atPath: snapshotsPath)
                for name in children {
                    if name.hasPrefix(".") { continue }
                    let snapshotPath = (snapshotsPath as NSString).appendingPathComponent(name)
                    var itemIsDir: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: snapshotPath, isDirectory: &itemIsDir), itemIsDir.boolValue else { continue }
                    guard isDeletableSnapshotDirectory(snapshotPath, snapshotsRoot: snapshotsPath, documentsPath: documentsPath, simulatorRoot: simulatorRoot) else {
                        self.log("Skipping unsafe snapshot path: \(snapshotPath)", type: .error)
                        continue
                    }
                    try FileManager.default.removeItem(atPath: snapshotPath)
                }
            } catch {
                self.log("Error deleting snapshots for \(current.name): \(error)", type: .error)
            }
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

// MARK: - Snapshot file operations
// Pure helpers so capture/restore can be tested without launching the app.

let snapshotTransientRetryLimit = 3
let snapshotTransientRetryDelay: TimeInterval = 1
private let snapshotTreeDepthLimit = 64

struct ListedFile: Equatable {
    enum Kind: Equatable {
        case directory
        case file(size: Int64, modified: TimeInterval, contentHash: Data?)
        case symlink(target: String)
        case other
    }

    let relativePath: String
    let kind: Kind
}

enum SnapshotFileFailure: Error, Equatable, LocalizedError {
    case missingSnapshotDocuments
    case unsafeDocumentsPath
    case validationFailed
    case changedDuringCopy
    case unreadableItem(String)
    case rollbackFailed(backupPath: String)

    var errorDescription: String? {
        switch self {
        case .missingSnapshotDocuments:
            return "The snapshot does not contain a Documents folder."
        case .unsafeDocumentsPath:
            return "Refusing to replace a path that is not this simulator's Documents folder."
        case .validationFailed:
            return "The copied files did not match."
        case .changedDuringCopy:
            return "Documents changed while they were being copied."
        case .unreadableItem(let relativePath):
            return "Couldn't read \(relativePath)."
        case .rollbackFailed(let backupPath):
            return "Restore failed and the previous Documents folder is still at \(backupPath)."
        }
    }
}

struct SnapshotAttemptsExhausted: Error, LocalizedError {
    let attempts: Int
    let underlying: Error

    var errorDescription: String? {
        let detail = (underlying as? LocalizedError)?.errorDescription ?? underlying.localizedDescription
        return "Still failing after \(attempts) attempts. \(detail)"
    }
}

func standardizedPath(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.path
}

func pathIsInside(_ candidate: String, directory base: String) -> Bool {
    let candidateNorm = standardizedPath(candidate)
    let baseNorm = standardizedPath(base)
    if candidateNorm == baseNorm { return true }
    let prefix = baseNorm.hasSuffix("/") ? baseNorm : baseNorm + "/"
    return candidateNorm.hasPrefix(prefix)
}

func directoryByteSize(at path: String) -> Int64 {
    guard !path.isEmpty else { return 0 }
    guard let enumerator = FileManager.default.enumerator(atPath: path) else { return 0 }
    var total: Int64 = 0
    while let file = enumerator.nextObject() as? String {
        let filePath = (path as NSString).appendingPathComponent(file)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: filePath),
              let size = (attributes[.size] as? NSNumber)?.int64Value else { continue }
        total += size
    }
    return total
}

func deviceRecordIsDeleted(_ deviceData: NSDictionary) -> Bool {
    if let deleted = deviceData["isDeleted"] as? Bool { return deleted }
    if let deleted = deviceData["isDeleted"] as? NSNumber { return deleted.boolValue }
    return false
}

let simulatorAppBundleIdentifier = "com.apple.iphonesimulator"
let simulatorBootTimeout: TimeInterval = 180
let simulatorLaunchTimeout: TimeInterval = 45

enum SimulatorControlResult {
    case opened
    case failed(String)
}

struct SimulatorControlPlan: Equatable {
    var bootStatusArguments: [String]
    var focusArguments: [String]
    var launchArguments: [String]?
}

func simulatorControlKey(udid: String, bundleIdentifier: String?) -> String {
    if let bundleIdentifier, !bundleIdentifier.isEmpty {
        return "\(udid):\(bundleIdentifier)"
    }
    return udid
}

func isSimulatorUDID(_ value: String) -> Bool {
    UUID(uuidString: value) != nil
}

func isLaunchableBundleIdentifier(_ value: String) -> Bool {
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-")
    guard !value.isEmpty, value.count <= 255 else { return false }
    guard value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
    return !value.hasPrefix(".") && !value.hasPrefix("-") && !value.hasSuffix(".")
}

/// `bootstatus -b` boots a shut-down device and returns immediately when it is already booted.
func simulatorControlPlan(udid: String, bundleIdentifier: String?) -> SimulatorControlPlan? {
    guard isSimulatorUDID(udid) else { return nil }
    if let bundleIdentifier {
        guard isLaunchableBundleIdentifier(bundleIdentifier) else { return nil }
    }
    return SimulatorControlPlan(
        bootStatusArguments: ["simctl", "bootstatus", udid, "-b"],
        focusArguments: ["-CurrentDeviceUDID", udid],
        launchArguments: bundleIdentifier.map { ["simctl", "launch", udid, $0] }
    )
}

func simctlFailureSummary(_ output: String, fallback: String) -> String {
    let line = output
        .split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .last { !$0.isEmpty }
    guard let line, !line.isEmpty else { return fallback }
    if line.count <= 180 { return String(line) }
    return String(line.prefix(177)) + "..."
}

enum SimctlRunError: Error {
    case timedOut
    case launchFailed(String)
}

struct SimctlRunResult {
    var status: Int32
    var output: String
}

func runXcrun(_ arguments: [String], timeout: TimeInterval) -> Result<SimctlRunResult, SimctlRunError> {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = arguments
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    let lock = NSLock()
    var collected = Data()
    let group = DispatchGroup()
    for pipe in [stdout, stderr] {
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            lock.lock()
            collected.append(data)
            lock.unlock()
            group.leave()
        }
    }

    do {
        try process.run()
    } catch {
        process.terminate()
        _ = group.wait(timeout: .now() + 2)
        return .failure(.launchFailed(error.localizedDescription))
    }

    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning && Date() < deadline {
        Thread.sleep(forTimeInterval: 0.2)
    }
    if process.isRunning {
        process.terminate()
        process.waitUntilExit()
        _ = group.wait(timeout: .now() + 2)
        return .failure(.timedOut)
    }
    process.waitUntilExit()
    _ = group.wait(timeout: .now() + 2)
    lock.lock()
    let output = String(data: collected, encoding: .utf8) ?? ""
    lock.unlock()
    return .success(SimctlRunResult(status: process.terminationStatus, output: output))
}

func simulatorIsBooted(at dataPath: String) -> Bool {
    let plistPath = (dataPath as NSString).appendingPathComponent("device.plist")
    guard let deviceData = NSDictionary(contentsOfFile: plistPath) else { return false }
    if let state = deviceData["state"] as? Int { return state == 3 }
    if let state = deviceData["state"] as? NSNumber { return state.intValue == 3 }
    return false
}

func isSafeLiveDocumentsPath(_ documentsPath: String, simulatorRoot: String) -> Bool {
    guard !documentsPath.isEmpty, !simulatorRoot.isEmpty else { return false }
    let norm = standardizedPath(documentsPath)
    guard (norm as NSString).lastPathComponent == "Documents" else { return false }
    guard pathIsInside(norm, directory: simulatorRoot) else { return false }
    let parent = standardizedPath((norm as NSString).deletingLastPathComponent)
    return parent != standardizedPath(simulatorRoot)
}

func isDeletableSnapshotDirectory(_ snapshotPath: String, snapshotsRoot: String, documentsPath: String, simulatorRoot: String?) -> Bool {
    guard !snapshotsRoot.isEmpty, !documentsPath.isEmpty, !snapshotPath.isEmpty else { return false }
    let normTarget = standardizedPath(snapshotPath)
    let normDocs = standardizedPath(documentsPath)
    let normSnapshots = standardizedPath(snapshotsRoot)
    guard pathIsInside(normTarget, directory: normSnapshots) else { return false }
    if normTarget == normSnapshots || normTarget == normDocs { return false }
    if pathIsInside(normTarget, directory: normDocs) { return false }
    if let simulatorRoot, !simulatorRoot.isEmpty {
        let normSim = standardizedPath(simulatorRoot)
        if normTarget == normSim || !pathIsInside(normTarget, directory: normSim) { return false }
    }
    let documentsInside = (normTarget as NSString).appendingPathComponent("Documents")
    var isDir: ObjCBool = false
    if FileManager.default.fileExists(atPath: documentsInside, isDirectory: &isDir), isDir.boolValue {
        return true
    }
    let parent = standardizedPath((normTarget as NSString).deletingLastPathComponent)
    return parent == normSnapshots
}

func isTransientSnapshotError(_ error: Error) -> Bool {
    if error is SnapshotAttemptsExhausted { return false }
    if let failure = error as? SnapshotFileFailure {
        switch failure {
        case .validationFailed, .changedDuringCopy, .unreadableItem:
            return true
        case .missingSnapshotDocuments, .unsafeDocumentsPath, .rollbackFailed:
            return false
        }
    }
    let nsError = error as NSError
    if nsError.domain == NSPOSIXErrorDomain {
        let transient: Set<Int32> = [EINTR, EAGAIN, EBUSY, ETXTBSY, EDEADLK, ENOLCK, ETIMEDOUT, EIO, ENOENT]
        if transient.contains(Int32(nsError.code)) { return true }
    }
    if nsError.domain == NSCocoaErrorDomain {
        // Unknown, missing, permission, and "file exists" errors are often a file the app still has open.
        let transient: Set<Int> = [4, 256, 257, 260, 512, 513, 516]
        if transient.contains(nsError.code) { return true }
    }
    if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
        return isTransientSnapshotError(underlying)
    }
    return false
}

func restoreFailureMessage(_ error: Error) -> String {
    if let failure = error as? SnapshotFileFailure, case .rollbackFailed = failure {
        return failure.localizedDescription
    }
    return "\(error.localizedDescription) The original Documents folder was kept."
}

func retryingTransientSnapshot<T>(
    maxAttempts: Int = snapshotTransientRetryLimit,
    retryDelay: TimeInterval = snapshotTransientRetryDelay,
    sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
    onRetry: ((Int, Error) -> Void)? = nil,
    _ operation: () throws -> T
) throws -> T {
    let attempts = max(1, maxAttempts)
    var lastError: Error?
    for attempt in 1...attempts {
        do {
            return try operation()
        } catch {
            lastError = error
            if attempt == attempts || !isTransientSnapshotError(error) {
                if attempt > 1 {
                    throw SnapshotAttemptsExhausted(attempts: attempt, underlying: error)
                }
                throw error
            }
            onRetry?(attempt, error)
            if retryDelay > 0 {
                sleep(retryDelay)
            }
        }
    }
    throw lastError ?? SnapshotFileFailure.validationFailed
}

private func hashFileContents(at path: String, onBytesRead: ((Int64) -> Void)? = nil) throws -> Data {
    let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
    defer { try? handle.close() }
    var hasher = SHA256()
    while true {
        let chunk = try handle.read(upToCount: 1024 * 1024)
        guard let chunk, !chunk.isEmpty else { break }
        hasher.update(data: chunk)
        onBytesRead?(Int64(chunk.count))
    }
    return Data(hasher.finalize())
}

/// Lists every entry under `path`. A name that cannot be inspected throws.
/// Skipping it would let a partial copy look identical to the source.
func fileTreeEntries(
    at path: String,
    hashContents: Bool,
    onBytesRead: ((Int64) -> Void)? = nil,
    onEntry: ((ListedFile) -> Void)? = nil
) throws -> [ListedFile] {
    var files: [ListedFile] = []
    func enumerate(at currentPath: String, relativePath: String, depth: Int) throws {
        if depth > snapshotTreeDepthLimit {
            throw SnapshotFileFailure.unreadableItem(relativePath.isEmpty ? path : relativePath)
        }
        let contents = try FileManager.default.contentsOfDirectory(atPath: currentPath)
        for item in contents {
            let fullPath = (currentPath as NSString).appendingPathComponent(item)
            let itemRelative = relativePath.isEmpty ? item : (relativePath as NSString).appendingPathComponent(item)
            let attributes: [FileAttributeKey: Any]
            do {
                attributes = try FileManager.default.attributesOfItem(atPath: fullPath)
            } catch {
                throw SnapshotFileFailure.unreadableItem(itemRelative)
            }
            let type = attributes[.type] as? FileAttributeType
            if type == .typeSymbolicLink {
                let target: String
                do {
                    target = try FileManager.default.destinationOfSymbolicLink(atPath: fullPath)
                } catch {
                    throw SnapshotFileFailure.unreadableItem(itemRelative)
                }
                let listed = ListedFile(relativePath: itemRelative, kind: .symlink(target: target))
                files.append(listed)
                onEntry?(listed)
            } else if type == .typeDirectory {
                let listed = ListedFile(relativePath: itemRelative, kind: .directory)
                files.append(listed)
                onEntry?(listed)
                try enumerate(at: fullPath, relativePath: itemRelative, depth: depth + 1)
            } else if type == .typeRegular {
                let hash: Data?
                if hashContents {
                    do {
                        hash = try hashFileContents(at: fullPath, onBytesRead: onBytesRead)
                    } catch {
                        throw SnapshotFileFailure.unreadableItem(itemRelative)
                    }
                } else {
                    hash = nil
                }
                let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
                let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                let listed = ListedFile(
                    relativePath: itemRelative,
                    kind: .file(size: size, modified: modified, contentHash: hash)
                )
                files.append(listed)
                onEntry?(listed)
            } else {
                let listed = ListedFile(relativePath: itemRelative, kind: .other)
                files.append(listed)
                onEntry?(listed)
            }
        }
    }
    try enumerate(at: path, relativePath: "", depth: 0)
    return files.sorted { $0.relativePath < $1.relativePath }
}

private func ignoringTimestamps(_ files: [ListedFile]) -> [ListedFile] {
    files.map { file in
        guard case .file(let size, _, let contentHash) = file.kind else { return file }
        return ListedFile(
            relativePath: file.relativePath,
            kind: .file(size: size, modified: 0, contentHash: contentHash)
        )
    }
}

func copiedTreeMatches(
    sourcePath: String,
    copyPath: String,
    sourceBytes: ((Int64) -> Void)? = nil,
    sourceEntry: ((ListedFile) -> Void)? = nil,
    copyBytes: ((Int64) -> Void)? = nil,
    copyEntry: ((ListedFile) -> Void)? = nil,
    beforeCopyWalk: (() -> Void)? = nil
) throws -> Bool {
    let sourceFiles = try fileTreeEntries(at: sourcePath, hashContents: true, onBytesRead: sourceBytes, onEntry: sourceEntry)
    beforeCopyWalk?()
    let copiedFiles = try fileTreeEntries(at: copyPath, hashContents: true, onBytesRead: copyBytes, onEntry: copyEntry)
    return ignoringTimestamps(sourceFiles) == ignoringTimestamps(copiedFiles)
}

func captureDocumentsSnapshot(
    documentsPath: String,
    snapshotPath: String,
    maxAttempts: Int = snapshotTransientRetryLimit,
    retryDelay: TimeInterval = snapshotTransientRetryDelay,
    sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
    afterCopy: (() -> Void)? = nil,
    onProgress: ((String, Double) -> Void)? = nil,
    onRetry: ((Int, Error) -> Void)? = nil,
    validate: ((String, String) throws -> Bool)? = nil
) throws {
    try retryingTransientSnapshot(maxAttempts: maxAttempts, retryDelay: retryDelay, sleep: sleep, onRetry: onRetry) {
        try captureDocumentsSnapshotOnce(
            documentsPath: documentsPath,
            snapshotPath: snapshotPath,
            afterCopy: afterCopy,
            onProgress: onProgress,
            validate: validate
        )
    }
}

private func captureDocumentsSnapshotOnce(
    documentsPath: String,
    snapshotPath: String,
    afterCopy: (() -> Void)?,
    onProgress: ((String, Double) -> Void)?,
    validate: ((String, String) throws -> Bool)?
) throws {
    let fm = FileManager.default
    try fm.createDirectory(atPath: snapshotPath, withIntermediateDirectories: true)
    let destination = (snapshotPath as NSString).appendingPathComponent("Documents")
    let progress = SnapshotTransferProgress(operation: .capture, report: onProgress)
    do {
        let before = try fileTreeEntries(at: documentsPath, hashContents: false, onEntry: { entry in
            progress.noteInventoryEntry(byteSize: listedByteSize(entry))
        })
        progress.finishInventory()
        let sizes = Dictionary(uniqueKeysWithValues: before.map { ($0.relativePath, listedByteSize($0)) })
        try copyTreePreservingMetadata(from: documentsPath, to: destination, sizes: sizes, progress: progress)
        progress.finishCopy()
        afterCopy?()
        let after = try fileTreeEntries(at: documentsPath, hashContents: false, onEntry: { _ in
            progress.noteStabilityEntry()
        })
        progress.finishStability()
        guard before == after else {
            throw SnapshotFileFailure.changedDuringCopy
        }
        var destinationIsDirectory: ObjCBool = false
        guard fm.fileExists(atPath: destination, isDirectory: &destinationIsDirectory), destinationIsDirectory.boolValue else {
            throw SnapshotFileFailure.validationFailed
        }
        let matches = try snapshotCopyMatches(sourcePath: documentsPath, copyPath: destination, progress: progress, validate: validate)
        guard matches else {
            throw SnapshotFileFailure.validationFailed
        }
        progress.finish()
    } catch {
        if fm.fileExists(atPath: snapshotPath) {
            try? fm.removeItem(atPath: snapshotPath)
        }
        throw error
    }
}

func restoreDocumentsReplacingLiveCopy(
    snapshotDocumentsPath: String,
    documentsPath: String,
    simulatorRoot: String,
    maxAttempts: Int = snapshotTransientRetryLimit,
    retryDelay: TimeInterval = snapshotTransientRetryDelay,
    sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
    onProgress: ((String, Double) -> Void)? = nil,
    onRetry: ((Int, Error) -> Void)? = nil,
    validate: ((String, String) throws -> Bool)? = nil
) throws {
    try retryingTransientSnapshot(maxAttempts: maxAttempts, retryDelay: retryDelay, sleep: sleep, onRetry: onRetry) {
        try restoreDocumentsReplacingLiveCopyOnce(
            snapshotDocumentsPath: snapshotDocumentsPath,
            documentsPath: documentsPath,
            simulatorRoot: simulatorRoot,
            onProgress: onProgress,
            validate: validate
        )
    }
}

private func restoreDocumentsReplacingLiveCopyOnce(
    snapshotDocumentsPath: String,
    documentsPath: String,
    simulatorRoot: String,
    onProgress: ((String, Double) -> Void)?,
    validate: ((String, String) throws -> Bool)?
) throws {
    guard isSafeLiveDocumentsPath(documentsPath, simulatorRoot: simulatorRoot) else {
        throw SnapshotFileFailure.unsafeDocumentsPath
    }
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: snapshotDocumentsPath, isDirectory: &isDir), isDir.boolValue else {
        throw SnapshotFileFailure.missingSnapshotDocuments
    }

    let fm = FileManager.default
    let progress = SnapshotTransferProgress(operation: .restore, report: onProgress)
    var sizes: [String: Int64] = [:]
    _ = try fileTreeEntries(at: snapshotDocumentsPath, hashContents: false, onEntry: { entry in
        let size = listedByteSize(entry)
        sizes[entry.relativePath] = size
        progress.noteInventoryEntry(byteSize: size)
    })
    progress.finishInventory()

    let parent = (documentsPath as NSString).deletingLastPathComponent
    let backupPath = (parent as NSString).appendingPathComponent(".simmer-documents-backup-\(UUID().uuidString)")
    let hadDocuments = fm.fileExists(atPath: documentsPath)

    if hadDocuments {
        progress.noteReplacingDocuments()
        try fm.moveItem(atPath: documentsPath, toPath: backupPath)
    }

    func rollBack() throws {
        if fm.fileExists(atPath: documentsPath) {
            try fm.removeItem(atPath: documentsPath)
        }
        if hadDocuments {
            try fm.moveItem(atPath: backupPath, toPath: documentsPath)
        }
    }

    do {
        try copyTreePreservingMetadata(from: snapshotDocumentsPath, to: documentsPath, sizes: sizes, progress: progress)
        progress.finishCopy()
        let matches = try snapshotCopyMatches(
            sourcePath: snapshotDocumentsPath,
            copyPath: documentsPath,
            progress: progress,
            validate: validate
        )
        guard matches else {
            do {
                try rollBack()
            } catch {
                throw SnapshotFileFailure.rollbackFailed(backupPath: backupPath)
            }
            throw SnapshotFileFailure.validationFailed
        }
        progress.finish()
        if hadDocuments {
            try? fm.removeItem(atPath: backupPath)
        }
    } catch let failure as SnapshotFileFailure {
        throw failure
    } catch {
        do {
            try rollBack()
        } catch {
            throw SnapshotFileFailure.rollbackFailed(backupPath: backupPath)
        }
        throw error
    }
}

private func listedByteSize(_ entry: ListedFile) -> Int64 {
    if case .file(let size, _, _) = entry.kind { return size }
    return 0
}

private func snapshotCopyMatches(
    sourcePath: String,
    copyPath: String,
    progress: SnapshotTransferProgress,
    validate: ((String, String) throws -> Bool)?
) throws -> Bool {
    if let validate {
        return try validate(sourcePath, copyPath)
    }
    progress.beginVerifyingOriginal()
    return try copiedTreeMatches(
        sourcePath: sourcePath,
        copyPath: copyPath,
        sourceBytes: { progress.noteVerifiedBytes($0) },
        sourceEntry: { _ in progress.noteVerifiedEntry() },
        copyBytes: { progress.noteVerifiedBytes($0) },
        copyEntry: { _ in progress.noteVerifiedEntry() },
        beforeCopyWalk: { progress.beginVerifyingCopy() }
    )
}

/// Tracks snapshot copy and verification as one 0...1 fraction.
///
/// A same-volume copy is often an APFS clone and finishes immediately. The long
/// part is reading every byte back to prove the copy matches, so that read is
/// most of the bar. A real byte-for-byte copy still moves the bar while it writes,
/// including through a single multi-gigabyte file.
final class SnapshotTransferProgress {
    enum Operation {
        case capture
        case restore
    }

    private let operation: Operation
    private let report: ((String, Double) -> Void)?
    private let entryCredit: Int64 = 64 * 1024
    private let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()
    private let countFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    private enum Phase {
        case counting
        case copying
        case checking
        case verifying
    }

    private var phase: Phase = .counting
    private var messageOverride: String?
    private var inventoryClosed = false
    private var inventoryEntries = 0
    private var inventoryBytes: Int64 = 0
    private var totalEntries = 0
    private var totalBytes: Int64 = 0

    private var committedBytes: Int64 = 0
    private var committedEntries = 0
    private var inFlightBytes: Int64 = 0

    private var stabilityDone = 0
    private var verifyBytes: Int64 = 0
    private var verifyEntries = 0
    private var verifyTreeBytes: Int64 = 0
    private var verifyTreeEntries = 0
    private var verificationPass = 1

    private var completedFractionOverride: Double?
    private var highWater: Double = 0
    private var lastReport = Date.distantPast

    init(operation: Operation, report: ((String, Double) -> Void)?) {
        self.operation = operation
        self.report = report
    }

    var fraction: Double {
        if let completedFractionOverride { return completedFractionOverride }
        let total = totalWork
        guard inventoryClosed, total > 0 else { return highWater }
        let raw = min(1, Double(min(total, completedWork)) / Double(total))
        if raw > highWater { highWater = raw }
        return highWater
    }

    func noteInventoryEntry(byteSize: Int64) {
        inventoryEntries += 1
        inventoryBytes += max(0, byteSize)
        publish(force: inventoryEntries == 1)
    }

    func finishInventory() {
        totalEntries = inventoryEntries
        totalBytes = inventoryBytes
        inventoryClosed = true
        phase = .copying
        publish(force: true)
    }

    func noteReplacingDocuments() {
        messageOverride = "Replacing documents..."
        publish(force: true)
    }

    func noteCopyProgress(copiedBytes: Int64, fileSize: Int64) {
        messageOverride = nil
        guard fileSize > 0 else { return }
        let copied = max(copiedBytes, 0)
        if copied < inFlightBytes { inFlightBytes = 0 }
        let limited = min(copied, fileSize)
        if limited > inFlightBytes { inFlightBytes = limited }
        publish()
    }

    func noteCopyFinished(fileSize: Int64) {
        messageOverride = nil
        committedBytes += max(fileSize, 0)
        committedEntries += 1
        inFlightBytes = 0
        publish()
    }

    func finishCopy() {
        messageOverride = nil
        committedBytes = max(committedBytes, totalBytes)
        committedEntries = max(committedEntries, totalEntries)
        inFlightBytes = 0
        publish(force: true)
    }

    func noteStabilityEntry() {
        guard operation == .capture else { return }
        phase = .checking
        stabilityDone += 1
        publish()
    }

    func finishStability() {
        guard operation == .capture else { return }
        phase = .checking
        if stabilityDone < totalEntries { stabilityDone = totalEntries }
        publish(force: true)
    }

    func beginVerifyingOriginal() {
        messageOverride = nil
        phase = .verifying
        verificationPass = 1
        verifyTreeBytes = 0
        verifyTreeEntries = 0
        publish(force: true)
    }

    func beginVerifyingCopy() {
        messageOverride = nil
        phase = .verifying
        verificationPass = 2
        verifyTreeBytes = 0
        verifyTreeEntries = 0
        publish(force: true)
    }

    func noteVerifiedBytes(_ count: Int64) {
        let bytes = max(0, count)
        verifyBytes += bytes
        verifyTreeBytes += bytes
        publish()
    }

    func noteVerifiedEntry() {
        verifyEntries += 1
        verifyTreeEntries += 1
        publish()
    }

    func finish() {
        completedFractionOverride = 1
        publish(force: true)
    }

    private var copyBudget: Int64 { totalBytes + Int64(totalEntries) * entryCredit }
    private var stabilityBudget: Int64 {
        operation == .capture ? Int64(totalEntries) * entryCredit : 0
    }
    private var verifyBudget: Int64 { (totalBytes + Int64(totalEntries) * entryCredit) * 2 }
    private var totalWork: Int64 { copyBudget + stabilityBudget + verifyBudget }

    private var completedWork: Int64 {
        let copyBytes = min(totalBytes, committedBytes + inFlightBytes)
        let copy = min(copyBudget, copyBytes + Int64(committedEntries) * entryCredit)
        let stability = min(stabilityBudget, Int64(stabilityDone) * entryCredit)
        let verify = min(verifyBudget, verifyBytes + Int64(verifyEntries) * entryCredit)
        return copy + stability + verify
    }

    private var message: String {
        if let messageOverride { return messageOverride }
        switch phase {
        case .counting:
            return "Counting files... \(formatCount(inventoryEntries))"
        case .copying:
            let action = operation == .capture ? "Copying documents" : "Restoring documents"
            return detail(action: action, bytesDone: min(totalBytes, committedBytes + inFlightBytes), itemsDone: committedEntries)
        case .checking:
            if totalEntries == 0 { return "Checking files haven't changed..." }
            return "Checking files haven't changed... \(formatCount(min(stabilityDone, totalEntries))) of \(formatCount(totalEntries))"
        case .verifying:
            return detail(action: verificationTitle, bytesDone: min(totalBytes, verifyTreeBytes), itemsDone: verifyTreeEntries)
        }
    }

    private var verificationTitle: String {
        switch (operation, verificationPass) {
        case (.capture, 2):
            return "Verifying snapshot"
        case (.capture, _):
            return "Verifying original"
        case (.restore, 2):
            return "Verifying restored documents"
        case (.restore, _):
            return "Verifying snapshot"
        }
    }

    private func detail(action: String, bytesDone: Int64, itemsDone: Int) -> String {
        if totalBytes >= 1_000_000 {
            let bytes = "\(formatBytes(bytesDone)) of \(formatBytes(totalBytes))"
            if totalEntries >= 100 {
                return "\(action)... \(bytes) · \(formatCount(min(itemsDone, totalEntries))) of \(formatCount(totalEntries))"
            }
            return "\(action)... \(bytes)"
        }
        if totalEntries > 0 {
            return "\(action)... \(formatCount(min(itemsDone, totalEntries))) of \(formatCount(totalEntries))"
        }
        return "\(action)..."
    }

    private func publish(force: Bool = false) {
        let fraction = self.fraction
        guard let report else { return }
        let now = Date()
        if !force && now.timeIntervalSince(lastReport) < 0.1 { return }
        lastReport = now
        report(message, fraction)
    }

    private func formatBytes(_ bytes: Int64) -> String {
        if bytes <= 0 { return "0 KB" }
        return byteFormatter.string(fromByteCount: bytes)
    }

    private func formatCount(_ value: Int) -> String {
        countFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

private final class SnapshotCopyContext {
    let sourceRoot: String
    let sizes: [String: Int64]
    var errnoCode: Int32 = 0
    var currentRelativePath: String?
    var finished: Set<String> = []
    let onProgress: (Int64, Int64) -> Void
    let onFinished: (Int64) -> Void

    init(sourceRoot: String, sizes: [String: Int64], onProgress: @escaping (Int64, Int64) -> Void, onFinished: @escaping (Int64) -> Void) {
        self.sourceRoot = sourceRoot
        self.sizes = sizes
        self.onProgress = onProgress
        self.onFinished = onFinished
    }

    func relativePath(of fullPath: String) -> String? {
        if fullPath == sourceRoot { return nil }
        let prefix = sourceRoot + "/"
        guard fullPath.hasPrefix(prefix) else { return nil }
        return String(fullPath.dropFirst(prefix.count))
    }
}

private let snapshotCopyStatusCallback: copyfile_callback_t = { what, stage, state, src, dst, ctx in
    guard let ctx else { return Int32(COPYFILE_CONTINUE) }
    let context = Unmanaged<SnapshotCopyContext>.fromOpaque(ctx).takeUnretainedValue()
    if stage == Int32(COPYFILE_ERR) {
        if context.errnoCode == 0 { context.errnoCode = errno }
        return Int32(COPYFILE_QUIT)
    }
    let fullPath = src.map { String(cString: $0) }
    let isEntry = what == Int32(COPYFILE_RECURSE_FILE) || what == Int32(COPYFILE_RECURSE_DIR)
    if stage == Int32(COPYFILE_START), isEntry {
        context.currentRelativePath = fullPath.flatMap { context.relativePath(of: $0) }
    }
    if what == Int32(COPYFILE_COPY_DATA), stage == Int32(COPYFILE_PROGRESS), let relative = context.currentRelativePath {
        var copied: off_t = 0
        if let state {
            copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied)
        }
        let size = context.sizes[relative] ?? Int64(copied)
        context.onProgress(Int64(copied), size)
    }
    if stage == Int32(COPYFILE_FINISH), isEntry {
        if let fullPath, let relative = context.relativePath(of: fullPath), context.finished.insert(relative).inserted {
            context.onFinished(context.sizes[relative] ?? 0)
        }
        context.currentRelativePath = nil
    }
    return Int32(COPYFILE_CONTINUE)
}

private func copyTreePreservingMetadata(
    from source: String,
    to destination: String,
    sizes: [String: Int64],
    progress: SnapshotTransferProgress
) throws {
    let context = SnapshotCopyContext(
        sourceRoot: source,
        sizes: sizes,
        onProgress: { copied, fileSize in
            progress.noteCopyProgress(copiedBytes: copied, fileSize: fileSize)
        },
        onFinished: { fileSize in
            progress.noteCopyFinished(fileSize: fileSize)
        }
    )
    guard let state = copyfile_state_alloc() else {
        throw snapshotPOSIXError(ENOMEM)
    }
    defer { copyfile_state_free(state) }
    let callback: copyfile_callback_t = snapshotCopyStatusCallback
    let status = copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(callback, to: UnsafeRawPointer.self))
    let contextStatus = copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), Unmanaged.passUnretained(context).toOpaque())
    guard status == 0, contextStatus == 0 else {
        throw snapshotPOSIXError(errno == 0 ? EINVAL : errno)
    }
    let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_NOFOLLOW | COPYFILE_CLONE | COPYFILE_EXCL)
    if copyfile(source, destination, state, flags) < 0 {
        let code = context.errnoCode != 0 ? context.errnoCode : errno
        throw snapshotPOSIXError(code == 0 ? EIO : code)
    }
}

private func snapshotPOSIXError(_ code: Int32) -> NSError {
    NSError(
        domain: NSPOSIXErrorDomain,
        code: Int(code),
        userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(code))]
    )
}
