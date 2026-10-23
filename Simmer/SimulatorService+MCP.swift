//
//  SimulatorService+MCP.swift
//  Simmer
//

import Foundation

extension SimulatorService: MCPBackend {
    func mcpListSimulators() throws -> [[String: Any]] {
        getAvailableSimulators().map { simulator in
            [
                "udid": simulator.udid,
                "name": simulator.name,
                "runtime": simulator.formattedVersion,
                "device": simulator.deviceType.rawValue,
                "booted": simulatorIsBooted(at: simulator.dataPath)
            ]
        }
    }

    func mcpListApps(simulator: String) throws -> [[String: Any]] {
        let device = try requireSimulator(simulator)
        return getApps(for: device).map { app in
            [
                "bundleId": app.bundleIdentifier,
                "name": app.name,
                "ready": isLiveDataContainer(app)
            ]
        }
    }

    func mcpListSnapshots(simulator: String, bundleId: String) throws -> [[String: Any]] {
        let device = try requireSimulator(simulator)
        let app = try requireApp(bundleId, on: device, needsDocuments: true)
        return snapshotRecords(for: app).map { record in
            [
                "id": record.id,
                "name": record.displayName ?? record.id,
                "createdAt": MCPJSON.timestamp.string(from: record.date),
                "bytes": NSNumber(value: record.size)
            ]
        }
    }

    func mcpCreateSnapshot(simulator: String, bundleId: String, displayName: String?) throws -> [String: Any] {
        let device = try requireSimulator(simulator)
        let app = try requireApp(bundleId, on: device, needsDocuments: true)
        guard FileManager.default.fileExists(atPath: app.documentsPath) else {
            throw MCPBackendError(message: "Documents directory does not exist for \(app.name).")
        }
        guard !app.snapshotsPath.isEmpty else {
            throw MCPBackendError(message: "Couldn't find a place to store snapshots for \(app.name).")
        }
        guard tryBeginSnapshotOperation() else {
            throw MCPBackendError(message: "A snapshot operation is already in progress.")
        }
        defer { endSnapshotOperation() }

        showSnapshotProgress("Preparing snapshot...", progress: 0)
        let stamp = ISO8601DateFormatter().string(from: Date())
        var snapshotId = "snapshot_\(stamp)"
        var snapshotPath = (app.snapshotsPath as NSString).appendingPathComponent(snapshotId)
        if FileManager.default.fileExists(atPath: snapshotPath) {
            snapshotId += "-" + String(UUID().uuidString.prefix(4))
            snapshotPath = (app.snapshotsPath as NSString).appendingPathComponent(snapshotId)
        }

        let trimmedName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        do {
            if !FileManager.default.fileExists(atPath: app.snapshotsPath) {
                try FileManager.default.createDirectory(atPath: app.snapshotsPath, withIntermediateDirectories: true)
            }
            try captureDocumentsSnapshot(
                documentsPath: app.documentsPath,
                snapshotPath: snapshotPath,
                onProgress: { message, fraction in
                    self.noteSnapshotProgress(message: message, fraction: fraction)
                },
                onRetry: { _, error in
                    self.showSnapshotProgress("Temporary problem (\(error.localizedDescription)). Retrying snapshot...", progress: 0)
                }
            )
            if !trimmedName.isEmpty {
                let metadata = SnapshotMetadata(displayName: trimmedName)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
                let data = try encoder.encode(metadata)
                try data.write(to: URL(fileURLWithPath: (snapshotPath as NSString).appendingPathComponent("metadata.json")), options: [.atomic])
            }
        } catch {
            try? FileManager.default.removeItem(atPath: snapshotPath)
            blockFurtherSnapshots(for: 4)
            let message = "Snapshot failed: \(error.localizedDescription) No snapshot was saved."
            showSnapshotProgress(message, progress: 0, dismissAfter: 4, failed: true)
            throw MCPBackendError(message: message)
        }

        showSnapshotProgress("Snapshot created successfully!", progress: 1, dismissAfter: 1)
        refreshSnapshotsIfVisible(bundleId: app.bundleIdentifier, udid: device.udid)
        return [
            "id": snapshotId,
            "name": trimmedName.isEmpty ? snapshotId : trimmedName,
            "udid": device.udid,
            "simulator": device.name,
            "bundleId": app.bundleIdentifier,
            "app": app.name
        ]
    }

    func mcpRestoreSnapshot(simulator: String, bundleId: String, snapshot: String) throws -> [String: Any] {
        let device = try requireSimulator(simulator)
        let app = try requireApp(bundleId, on: device, needsDocuments: true)
        let records = snapshotRecords(for: app)
        let items = records.map { record in
            MCPMatchItem(id: record.id, names: [record.id, record.displayName].compactMap { $0 })
        }
        let snapshotId: String
        switch mcpMatch(query: snapshot, items: items) {
        case .match(let id):
            snapshotId = id
        case .none:
            throw MCPBackendError(message: "No snapshot matches \"\(snapshot)\" for \(app.name).")
        case .ambiguous(let ids):
            throw MCPBackendError(message: "More than one snapshot matches \"\(snapshot)\": \(ids.joined(separator: ", ")). Pass a snapshot id.")
        }
        guard let record = records.first(where: { $0.id == snapshotId }) else {
            throw MCPBackendError(message: "No snapshot matches \"\(snapshot)\" for \(app.name).")
        }
        let snapshotDocuments = (record.path as NSString).appendingPathComponent("Documents")
        guard tryBeginSnapshotOperation() else {
            throw MCPBackendError(message: "A snapshot operation is already in progress.")
        }
        defer { endSnapshotOperation() }

        showSnapshotProgress("Preparing to restore snapshot...", progress: 0)
        terminateRunningApp(app, on: device)
        do {
            try restoreDocumentsReplacingLiveCopy(
                snapshotDocumentsPath: snapshotDocuments,
                documentsPath: app.documentsPath,
                simulatorRoot: device.dataPath,
                onProgress: { message, fraction in
                    self.noteSnapshotProgress(message: message, fraction: fraction)
                },
                onRetry: { _, error in
                    self.showSnapshotProgress("Temporary problem (\(error.localizedDescription)). Retrying restore...", progress: 0)
                }
            )
        } catch {
            blockFurtherSnapshots(for: 4)
            let message = restoreFailureMessage(error)
            showSnapshotProgress(message, progress: 0, dismissAfter: 4, failed: true)
            throw MCPBackendError(message: message)
        }

        showSnapshotProgress("Snapshot restored successfully!", progress: 1, dismissAfter: 1)
        refreshSnapshotsIfVisible(bundleId: app.bundleIdentifier, udid: device.udid)
        return [
            "id": record.id,
            "name": record.displayName ?? record.id,
            "udid": device.udid,
            "simulator": device.name,
            "bundleId": app.bundleIdentifier,
            "app": app.name
        ]
    }

    func mcpSendPush(simulator: String, bundleId: String, payloadJSON: String, name: String?) throws -> [String: Any] {
        let device = try requireSimulator(simulator)
        let app = try requireApp(bundleId, on: device, needsDocuments: false)
        switch performPushNotification(payloadJSON: payloadJSON, name: name, for: app, on: device, saveToHistory: true) {
        case .sent:
            deliverBanner("Push sent to \(app.name) on \(device.name)")
            return [
                "sent": true,
                "udid": device.udid,
                "simulator": device.name,
                "bundleId": app.bundleIdentifier,
                "app": app.name
            ]
        case .rejected(let message), .failed(let message):
            throw MCPBackendError(message: message)
        }
    }

    private func requireSimulator(_ query: String) throws -> Simulator {
        let simulators = getAvailableSimulators()
        let items = simulators.map { MCPMatchItem(id: $0.udid, names: [$0.name]) }
        switch mcpMatch(query: query, items: items) {
        case .match(let udid):
            guard let simulator = simulators.first(where: { $0.udid == udid }) else {
                throw MCPBackendError(message: "No simulator matches \"\(query)\".")
            }
            return simulator
        case .none:
            throw MCPBackendError(message: "No simulator matches \"\(query)\". List simulators to see UDIDs.")
        case .ambiguous(let ids):
            throw MCPBackendError(message: "More than one simulator matches \"\(query)\": \(ids.joined(separator: ", ")). Pass a UDID.")
        }
    }

    private func requireApp(_ query: String, on simulator: Simulator, needsDocuments: Bool) throws -> App {
        let apps = getApps(for: simulator)
        let items = apps.map { MCPMatchItem(id: $0.bundleIdentifier, names: [$0.name, $0.bundleIdentifier]) }
        let bundleId: String
        switch mcpMatch(query: query, items: items) {
        case .match(let id):
            bundleId = id
        case .none:
            throw MCPBackendError(message: "No app matches \"\(query)\" on \(simulator.name).")
        case .ambiguous(let ids):
            throw MCPBackendError(message: "More than one app matches \"\(query)\" on \(simulator.name): \(ids.joined(separator: ", ")). Pass a bundle id.")
        }
        guard let app = apps.first(where: { $0.bundleIdentifier == bundleId }) else {
            throw MCPBackendError(message: "No app matches \"\(query)\" on \(simulator.name).")
        }
        if needsDocuments && !isLiveDataContainer(app) {
            throw MCPBackendError(message: "Couldn't find the current Documents container for \(app.name). Reopen the simulator and try again.")
        }
        return app
    }

    private func snapshotRecords(for app: App) -> [MCPSnapshotRecord] {
        guard !app.snapshotsPath.isEmpty, FileManager.default.fileExists(atPath: app.snapshotsPath) else { return [] }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: app.snapshotsPath) else { return [] }
        var records: [MCPSnapshotRecord] = []
        for name in names where !name.hasPrefix(".") {
            let path = (app.snapshotsPath as NSString).appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            guard isDeletableSnapshotDirectory(path, snapshotsRoot: app.snapshotsPath, documentsPath: app.documentsPath, simulatorRoot: nil) else { continue }
            let documents = (path as NSString).appendingPathComponent("Documents")
            var documentsDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: documents, isDirectory: &documentsDirectory), documentsDirectory.boolValue else { continue }

            var displayName: String?
            let metadataPath = (path as NSString).appendingPathComponent("metadata.json")
            if let data = try? Data(contentsOf: URL(fileURLWithPath: metadataPath)),
               let decoded = try? JSONDecoder().decode(SnapshotMetadata.self, from: data) {
                displayName = decoded.displayName
            }
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            let date = attributes?[.creationDate] as? Date ?? Date()
            records.append(MCPSnapshotRecord(id: name, displayName: displayName, date: date, path: path, size: directoryByteSize(at: path)))
        }
        return records.sorted { $0.date > $1.date }
    }

    private func showSnapshotProgress(_ message: String, progress: Double, dismissAfter: TimeInterval? = nil, failed: Bool = false) {
        DispatchQueue.main.async {
            self.isSnapshotOperationInProgress = true
            self.snapshotOperationFailed = failed
            self.snapshotOperationProgress = progress
            self.snapshotOperationMessage = message
            guard let dismissAfter else { return }
            if dismissAfter <= 1.5 && !failed {
                self.isSnapshotOperationInProgress = false
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + dismissAfter) {
                self.isSnapshotOperationInProgress = false
                self.snapshotOperationFailed = false
                self.snapshotOperationProgress = 0
                self.snapshotOperationMessage = ""
            }
        }
    }

    private func refreshSnapshotsIfVisible(bundleId: String, udid: String) {
        DispatchQueue.main.async {
            guard self.selectedSimulator?.udid == udid,
                  self.selectedApp?.bundleIdentifier == bundleId,
                  let simulator = self.selectedSimulator else { return }
            self.loadApps(for: simulator)
            if let app = self.apps.first(where: { $0.bundleIdentifier == bundleId }) {
                self.loadSnapshots(for: app)
            }
        }
    }
}

private struct MCPSnapshotRecord {
    var id: String
    var displayName: String?
    var date: Date
    var path: String
    var size: Int64
}

private enum MCPJSON {
    static let timestamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
