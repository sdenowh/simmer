//
//  SimulatorService.swift
//  Simmer
//
//  Created by Scott Denowh on 7/10/25.
//

import Foundation
import AppKit
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
        snapshotOperationProgress = 1
        snapshotOperationMessage = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            self.isSnapshotOperationInProgress = false
            self.snapshotOperationProgress = 0
            self.snapshotOperationMessage = ""
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
        isSnapshotOperationInProgress = true
        snapshotOperationProgress = 0
        snapshotOperationMessage = "Preparing snapshot..."
        beginCriticalFileOperation()
        handedOff = true

        DispatchQueue.global(qos: .userInitiated).async {
            defer {
                self.endSnapshotOperation()
                DispatchQueue.main.async { self.endCriticalFileOperation() }
            }
            do {
                if !FileManager.default.fileExists(atPath: validatedApp.snapshotsPath) {
                    try FileManager.default.createDirectory(atPath: validatedApp.snapshotsPath, withIntermediateDirectories: true)
                }
                DispatchQueue.main.async {
                    self.snapshotOperationProgress = 0.4
                    self.snapshotOperationMessage = "Copying documents..."
                }
                try captureDocumentsSnapshot(documentsPath: validatedApp.documentsPath, snapshotPath: snapshotPath)
                DispatchQueue.main.async {
                    self.loadSnapshots(for: validatedApp)
                    self.snapshotOperationProgress = 1
                    self.snapshotOperationMessage = "Snapshot created successfully!"
                    self.isSnapshotOperationInProgress = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        self.snapshotOperationProgress = 0
                        self.snapshotOperationMessage = ""
                    }
                }
                self.log("Snapshot created successfully: \(snapshotName)")
            } catch {
                self.blockFurtherSnapshots(for: 4)
                DispatchQueue.main.async {
                    self.snapshotOperationProgress = 1
                    self.snapshotOperationMessage = "Snapshot failed: \(error.localizedDescription). Close the app if it has these files open, then try again."
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                        self.isSnapshotOperationInProgress = false
                        self.snapshotOperationProgress = 0
                        self.snapshotOperationMessage = ""
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
            self.performRestore(snapshotDocumentsPath: snapshotDocumentsPath, app: validatedApp, simulator: simulator, attempt: 1)
        }
    }

    private func performRestore(snapshotDocumentsPath: String, app: App, simulator: Simulator, attempt: Int) {
        DispatchQueue.main.async {
            self.snapshotOperationProgress = 0.4
            self.snapshotOperationMessage = attempt == 1 ? "Restoring snapshot..." : "Validation failed, retrying restore..."
        }
        do {
            try restoreDocumentsReplacingLiveCopy(
                snapshotDocumentsPath: snapshotDocumentsPath,
                documentsPath: app.documentsPath,
                simulatorRoot: simulator.dataPath
            )
            DispatchQueue.main.async {
                self.loadSnapshots(for: app)
                self.snapshotOperationProgress = 1
                self.snapshotOperationMessage = "Snapshot restored successfully!"
                self.isSnapshotOperationInProgress = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    self.snapshotOperationProgress = 0
                    self.snapshotOperationMessage = ""
                }
            }
            self.log("Snapshot restored successfully on attempt \(attempt)")
        } catch SnapshotFileFailure.validationFailed where attempt < 2 {
            self.log("Restore validation failed on attempt \(attempt). Original Documents were kept. Retrying...")
            self.performRestore(snapshotDocumentsPath: snapshotDocumentsPath, app: app, simulator: simulator, attempt: attempt + 1)
        } catch {
            self.blockFurtherSnapshots(for: 4)
            DispatchQueue.main.async {
                self.snapshotOperationProgress = 1
                self.snapshotOperationMessage = error.localizedDescription
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    self.isSnapshotOperationInProgress = false
                    self.snapshotOperationProgress = 0
                    self.snapshotOperationMessage = ""
                }
            }
            self.log("Error restoring snapshot on attempt \(attempt): \(error)", type: .error)
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

struct ListedFile: Equatable {
    let relativePath: String
    let size: Int64
}

enum SnapshotFileFailure: Error, Equatable, LocalizedError {
    case missingSnapshotDocuments
    case unsafeDocumentsPath
    case validationFailed
    case rollbackFailed(backupPath: String)

    var errorDescription: String? {
        switch self {
        case .missingSnapshotDocuments:
            return "The snapshot does not contain a Documents folder"
        case .unsafeDocumentsPath:
            return "Refusing to replace a path that is not this simulator's Documents folder"
        case .validationFailed:
            return "The copied files did not match the snapshot. The original Documents folder was kept."
        case .rollbackFailed(let backupPath):
            return "Restore failed and the previous Documents folder is still at \(backupPath)"
        }
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

func recursiveFileInfos(at path: String) throws -> [ListedFile] {
    var files: [ListedFile] = []
    func enumerate(at currentPath: String, relativePath: String) throws {
        let contents = try FileManager.default.contentsOfDirectory(atPath: currentPath)
        for item in contents {
            let fullPath = (currentPath as NSString).appendingPathComponent(item)
            let itemRelative = relativePath.isEmpty ? item : (relativePath as NSString).appendingPathComponent(item)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDirectory) {
                if isDirectory.boolValue {
                    try enumerate(at: fullPath, relativePath: itemRelative)
                } else {
                    let attributes = try FileManager.default.attributesOfItem(atPath: fullPath)
                    let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
                    files.append(ListedFile(relativePath: itemRelative, size: size))
                }
            }
        }
    }
    try enumerate(at: path, relativePath: "")
    return files.sorted { $0.relativePath < $1.relativePath }
}

func copiedTreeMatches(sourcePath: String, copyPath: String) throws -> Bool {
    let sourceFiles = try recursiveFileInfos(at: sourcePath)
    let copiedFiles = try recursiveFileInfos(at: copyPath)
    guard sourceFiles.count == copiedFiles.count else { return false }
    for pair in zip(sourceFiles, copiedFiles) {
        if pair.0.relativePath != pair.1.relativePath || pair.0.size != pair.1.size {
            return false
        }
    }
    return true
}

func captureDocumentsSnapshot(
    documentsPath: String,
    snapshotPath: String,
    validate: (String, String) throws -> Bool = { try copiedTreeMatches(sourcePath: $0, copyPath: $1) }
) throws {
    let fm = FileManager.default
    try fm.createDirectory(atPath: snapshotPath, withIntermediateDirectories: true)
    let destination = (snapshotPath as NSString).appendingPathComponent("Documents")
    do {
        try fm.copyItem(atPath: documentsPath, toPath: destination)
        let matches = try validate(documentsPath, destination)
        if !matches {
            try? fm.removeItem(atPath: snapshotPath)
            throw SnapshotFileFailure.validationFailed
        }
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
    validate: (String, String) throws -> Bool = { try copiedTreeMatches(sourcePath: $0, copyPath: $1) }
) throws {
    guard isSafeLiveDocumentsPath(documentsPath, simulatorRoot: simulatorRoot) else {
        throw SnapshotFileFailure.unsafeDocumentsPath
    }
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: snapshotDocumentsPath, isDirectory: &isDir), isDir.boolValue else {
        throw SnapshotFileFailure.missingSnapshotDocuments
    }

    let fm = FileManager.default
    let parent = (documentsPath as NSString).deletingLastPathComponent
    let backupPath = (parent as NSString).appendingPathComponent(".simmer-documents-backup-\(UUID().uuidString)")
    let hadDocuments = fm.fileExists(atPath: documentsPath)

    if hadDocuments {
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
        try fm.copyItem(atPath: snapshotDocumentsPath, toPath: documentsPath)
        let matches = try validate(snapshotDocumentsPath, documentsPath)
        if !matches {
            do {
                try rollBack()
            } catch {
                throw SnapshotFileFailure.rollbackFailed(backupPath: backupPath)
            }
            throw SnapshotFileFailure.validationFailed
        }
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
