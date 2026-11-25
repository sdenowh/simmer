//
//  UserDefaultsSnapshot.swift
//  Simmer
//
//  The app's NSUserDefaults live in its data container at
//  Library/Preferences/<domain>.plist. UserDefaults.standard uses the bundle
//  identifier. UserDefaults(suiteName:) in that same container is another plist.
//  App-group suites live in a different container and are not part of this copy.
//
//  While the simulator is booted, cfprefsd can hold newer values than the file.
//  simctl spawn defaults export/import talks to that cache. A shut-down simulator
//  has no cache, so the plist files are the settings.

import Foundation

let snapshotUserDefaultsDirectoryName = "UserDefaults"
private let preferenceCommandTimeout: TimeInterval = 20

enum UserDefaultsCaptureSource: Equatable {
    case files
    case simulator
}

enum LivePreferenceRead: Equatable {
    case value(Data)
    case missing
    case unavailable
}

enum UserDefaultsSnapshotFailure: Error, Equatable, LocalizedError {
    case unsafePreferencesPath
    case unreadablePreferences(String)
    case simulatorPreferencesUnavailable(String)
    case settingsRollbackFailed
    case documentsRestoreFailedAfterSettings(String)

    var errorDescription: String? {
        switch self {
        case .unsafePreferencesPath:
            return "Refusing to change a path that is not this app's settings."
        case .unreadablePreferences(let name):
            return "Couldn't read settings (\(name))."
        case .simulatorPreferencesUnavailable(let detail):
            return detail
        case .settingsRollbackFailed:
            return "Settings restore failed and the previous settings could not be put back."
        case .documentsRestoreFailedAfterSettings(let detail):
            return "Settings were restored, but Documents could not be replaced. \(detail)"
        }
    }
}

struct PreferenceFile: Equatable {
    var domain: String
    var data: Data
}

private enum SavedPreference: Equatable {
    case absent
    case data(Data)
}

func userDefaultsSnapshotIsPresent(at snapshotPath: String) -> Bool {
    var isDirectory: ObjCBool = false
    let directory = (snapshotPath as NSString).appendingPathComponent(snapshotUserDefaultsDirectoryName)
    return FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory) && isDirectory.boolValue
}

func appDataContainerPath(documentsPath: String) -> String {
    standardizedPath((documentsPath as NSString).deletingLastPathComponent)
}

func captureAppSnapshot(
    documentsPath: String,
    bundleIdentifier: String,
    snapshotPath: String,
    bootedUDID: String?,
    onProgress: ((String, Double) -> Void)? = nil,
    onRetry: ((Int, Error) -> Void)? = nil,
    onWarning: ((String) -> Void)? = nil
) throws {
    try captureDocumentsSnapshot(
        documentsPath: documentsPath,
        snapshotPath: snapshotPath,
        onProgress: onProgress,
        onRetry: onRetry
    )
    onProgress?("Saving settings...", 1)
    let reader = livePreferenceReader(bootedUDID: bootedUDID)
    do {
        let source = try captureUserDefaultsSnapshot(
            containerPath: appDataContainerPath(documentsPath: documentsPath),
            bundleIdentifier: bundleIdentifier,
            snapshotPath: snapshotPath,
            readLiveDomain: reader
        )
        if reader != nil && source == .files {
            onWarning?("Couldn't read live settings from the simulator. Saved the settings file on disk.")
        }
    } catch {
        if FileManager.default.fileExists(atPath: snapshotPath) {
            try? FileManager.default.removeItem(atPath: snapshotPath)
        }
        throw error
    }
}

func restoreAppSnapshot(
    snapshotPath: String,
    documentsPath: String,
    bundleIdentifier: String,
    simulatorRoot: String,
    bootedUDID: String?,
    onProgress: ((String, Double) -> Void)? = nil,
    onRetry: ((Int, Error) -> Void)? = nil
) throws {
    var isDirectory: ObjCBool = false
    let snapshotDocuments = (snapshotPath as NSString).appendingPathComponent("Documents")
    guard FileManager.default.fileExists(atPath: snapshotDocuments, isDirectory: &isDirectory), isDirectory.boolValue else {
        throw SnapshotFileFailure.missingSnapshotDocuments
    }

    let includesSettings = userDefaultsSnapshotIsPresent(at: snapshotPath)
    if includesSettings {
        onProgress?("Restoring settings...", 0)
    }
    let container = appDataContainerPath(documentsPath: documentsPath)
    if let bootedUDID, let reader = livePreferenceReader(bootedUDID: bootedUDID) {
        try restoreUserDefaultsSnapshot(
            snapshotPath: snapshotPath,
            containerPath: container,
            simulatorRoot: simulatorRoot,
            bundleIdentifier: bundleIdentifier,
            readLiveDomain: reader,
            replaceLiveDomain: { domain, data in
                try simctlReplacePreference(udid: bootedUDID, domain: domain, data: data)
            }
        )
    } else {
        try restoreUserDefaultsSnapshot(
            snapshotPath: snapshotPath,
            containerPath: container,
            simulatorRoot: simulatorRoot,
            bundleIdentifier: bundleIdentifier
        )
    }

    do {
        try restoreDocumentsReplacingLiveCopy(
            snapshotDocumentsPath: snapshotDocuments,
            documentsPath: documentsPath,
            simulatorRoot: simulatorRoot,
            onProgress: onProgress,
            onRetry: onRetry
        )
    } catch {
        if includesSettings {
            throw UserDefaultsSnapshotFailure.documentsRestoreFailedAfterSettings(restoreFailureMessage(error))
        }
        throw error
    }
}

func captureUserDefaultsSnapshot(
    containerPath: String,
    bundleIdentifier: String,
    snapshotPath: String,
    readLiveDomain: ((String) -> LivePreferenceRead)? = nil
) throws -> UserDefaultsCaptureSource {
    let disk = try readPreferenceFiles(containerPath: standardizedPath(containerPath))
    let files: [PreferenceFile]
    let source: UserDefaultsCaptureSource
    if let readLiveDomain {
        var exported: [PreferenceFile] = []
        var fellBack = false
        for domain in preferenceDomainNames(onDisk: disk, bundleIdentifier: bundleIdentifier).sorted() {
            switch readLiveDomain(domain) {
            case .value(let data):
                guard let stored = validatedPreferencePlist(data) else {
                    throw UserDefaultsSnapshotFailure.unreadablePreferences(domain)
                }
                exported.append(PreferenceFile(domain: domain, data: stored))
            case .missing:
                break
            case .unavailable:
                fellBack = true
            }
        }
        if fellBack {
            files = disk
            source = .files
        } else {
            files = exported
            source = .simulator
        }
    } else {
        files = disk
        source = .files
    }
    try writePreferenceSnapshot(files, to: snapshotPath)
    return source
}

func restoreUserDefaultsSnapshot(
    snapshotPath: String,
    containerPath: String,
    simulatorRoot: String,
    bundleIdentifier: String,
    readLiveDomain: ((String) -> LivePreferenceRead)? = nil,
    replaceLiveDomain: ((String, Data?) throws -> Void)? = nil
) throws {
    guard let snapshotFiles = try readPreferenceSnapshot(at: snapshotPath) else { return }
    let container = standardizedPath(containerPath)
    guard isSafeLiveDocumentsPath(
        (container as NSString).appendingPathComponent("Documents"),
        simulatorRoot: simulatorRoot
    ) else {
        throw UserDefaultsSnapshotFailure.unsafePreferencesPath
    }

    if let readLiveDomain, let replaceLiveDomain {
        let disk = try readPreferenceFiles(containerPath: container)
        let domains = preferenceDomainNames(onDisk: disk, bundleIdentifier: bundleIdentifier)
            .union(snapshotFiles.map(\.domain))
        var backup: [String: SavedPreference] = [:]
        for domain in domains.sorted() {
            switch readLiveDomain(domain) {
            case .value(let data):
                guard let stored = validatedPreferencePlist(data) else {
                    throw UserDefaultsSnapshotFailure.unreadablePreferences(domain)
                }
                backup[domain] = .data(stored)
            case .missing:
                backup[domain] = .absent
            case .unavailable:
                try replaceLivePreferenceFiles(snapshotFiles, containerPath: container, simulatorRoot: simulatorRoot)
                return
            }
        }
        let desired = Dictionary(uniqueKeysWithValues: snapshotFiles.map { ($0.domain, $0.data) })
        var applied: [String] = []
        do {
            for domain in domains.sorted() {
                try replaceLiveDomain(domain, desired[domain])
                applied.append(domain)
            }
        } catch {
            for domain in applied.reversed() {
                do {
                    let previous = backup[domain] ?? .absent
                    switch previous {
                    case .absent:
                        try replaceLiveDomain(domain, nil)
                    case .data(let data):
                        try replaceLiveDomain(domain, data)
                    }
                } catch {
                    throw UserDefaultsSnapshotFailure.settingsRollbackFailed
                }
            }
            throw error
        }
        return
    }

    try replaceLivePreferenceFiles(snapshotFiles, containerPath: container, simulatorRoot: simulatorRoot)
}

func simctlExportPreference(udid: String, domain: String) -> LivePreferenceRead {
    guard isSimulatorUDID(udid), isLaunchableBundleIdentifier(domain) else { return .unavailable }
    switch runXcrun(["simctl", "spawn", udid, "defaults", "export", domain, "-"], timeout: preferenceCommandTimeout) {
    case .failure:
        return .unavailable
    case .success(let result):
        if result.status == 0 {
            guard validatedPreferencePlist(result.stdout) != nil else { return .unavailable }
            return .value(result.stdout)
        }
        if preferenceDomainIsMissing(result.output) { return .missing }
        return .unavailable
    }
}

func simctlReplacePreference(udid: String, domain: String, data: Data?) throws {
    guard isSimulatorUDID(udid), isLaunchableBundleIdentifier(domain) else {
        throw UserDefaultsSnapshotFailure.unsafePreferencesPath
    }
    switch runXcrun(["simctl", "spawn", udid, "defaults", "delete", domain], timeout: preferenceCommandTimeout) {
    case .failure(let error):
        throw UserDefaultsSnapshotFailure.simulatorPreferencesUnavailable(preferenceCommandFailure(error))
    case .success(let result) where result.status != 0 && !preferenceDomainIsMissing(result.output):
        throw UserDefaultsSnapshotFailure.simulatorPreferencesUnavailable(
            simctlFailureSummary(result.output, fallback: "Couldn't update settings for \(domain).")
        )
    case .success:
        break
    }
    guard let data else { return }
    guard validatedPreferencePlist(data) != nil else {
        throw UserDefaultsSnapshotFailure.unreadablePreferences(domain)
    }

    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("simmer-defaults-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let plist = directory.appendingPathComponent("\(domain).plist")
    try data.write(to: plist, options: .atomic)

    switch runXcrun(["simctl", "spawn", udid, "defaults", "import", domain, plist.path], timeout: preferenceCommandTimeout) {
    case .failure(let error):
        throw UserDefaultsSnapshotFailure.simulatorPreferencesUnavailable(preferenceCommandFailure(error))
    case .success(let result) where result.status != 0:
        throw UserDefaultsSnapshotFailure.simulatorPreferencesUnavailable(
            simctlFailureSummary(result.output, fallback: "Couldn't update settings for \(domain).")
        )
    case .success:
        return
    }
}

func validatedPreferencePlist(_ data: Data) -> Data? {
    let payload: Data
    if data.starts(with: Data("bplist".utf8)) {
        payload = data
    } else {
        var bytes = data
        while let first = bytes.first, first == 0x09 || first == 0x0A || first == 0x0D || first == 0x20 {
            bytes.removeFirst()
        }
        payload = bytes
    }
    guard !payload.isEmpty else { return nil }
    var format = PropertyListSerialization.PropertyListFormat.xml
    guard (try? PropertyListSerialization.propertyList(from: payload, options: [], format: &format)) is NSDictionary else {
        return nil
    }
    return payload
}

private func livePreferenceReader(bootedUDID: String?) -> ((String) -> LivePreferenceRead)? {
    guard let bootedUDID, isSimulatorUDID(bootedUDID) else { return nil }
    return { domain in simctlExportPreference(udid: bootedUDID, domain: domain) }
}

private func preferenceDomainNames(onDisk files: [PreferenceFile], bundleIdentifier: String) -> Set<String> {
    var names = Set(files.map(\.domain))
    if isLaunchableBundleIdentifier(bundleIdentifier) {
        names.insert(bundleIdentifier)
    }
    return names
}

private func preferenceDomainIsMissing(_ output: String) -> Bool {
    let text = output.lowercased()
    return text.contains("does not exist") || text.contains("not found")
}

private func preferenceCommandFailure(_ error: SimctlRunError) -> String {
    switch error {
    case .timedOut:
        return "Timed out while updating the app's settings."
    case .launchFailed(let message):
        return "Couldn't run simctl: \(message)"
    }
}

private func writePreferenceSnapshot(_ files: [PreferenceFile], to snapshotPath: String) throws {
    let directory = (snapshotPath as NSString).appendingPathComponent(snapshotUserDefaultsDirectoryName)
    let fm = FileManager.default
    if fm.fileExists(atPath: directory) {
        try fm.removeItem(atPath: directory)
    }
    try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
    for file in files {
        guard let path = preferenceFilePath(directory: directory, domain: file.domain, root: snapshotPath),
              validatedPreferencePlist(file.data) != nil else {
            throw UserDefaultsSnapshotFailure.unsafePreferencesPath
        }
        try file.data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

private func readPreferenceSnapshot(at snapshotPath: String) throws -> [PreferenceFile]? {
    let directory = (snapshotPath as NSString).appendingPathComponent(snapshotUserDefaultsDirectoryName)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory) else { return nil }
    guard isDirectory.boolValue else {
        throw UserDefaultsSnapshotFailure.unreadablePreferences(snapshotUserDefaultsDirectoryName)
    }
    return try readPreferenceFiles(in: directory, rootedAt: standardizedPath(snapshotPath))
}

private func readPreferenceFiles(containerPath: String) throws -> [PreferenceFile] {
    guard let directory = try existingPreferencesDirectory(containerPath: containerPath) else { return [] }
    return try readPreferenceFiles(in: directory, rootedAt: containerPath)
}

private func readPreferenceFiles(in directory: String, rootedAt root: String) throws -> [PreferenceFile] {
    let names: [String]
    do {
        names = try FileManager.default.contentsOfDirectory(atPath: directory)
    } catch {
        throw UserDefaultsSnapshotFailure.unreadablePreferences("Library/Preferences")
    }
    var files: [PreferenceFile] = []
    for name in names.sorted() {
        guard name.hasSuffix(".plist") else { continue }
        let domain = String(name.dropLast(".plist".count))
        guard let path = preferenceFilePath(directory: directory, domain: domain, root: root) else { continue }
        if pathIsSymbolicLink(path) {
            throw UserDefaultsSnapshotFailure.unsafePreferencesPath
        }
        try assertPathStaysInContainer(path, container: root)
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw UserDefaultsSnapshotFailure.unreadablePreferences(domain)
        }
        guard let stored = validatedPreferencePlist(data) else { continue }
        files.append(PreferenceFile(domain: domain, data: stored))
    }
    return files
}

private func replaceLivePreferenceFiles(
    _ files: [PreferenceFile],
    containerPath: String,
    simulatorRoot: String
) throws {
    for file in files {
        guard isLaunchableBundleIdentifier(file.domain), validatedPreferencePlist(file.data) != nil else {
            throw UserDefaultsSnapshotFailure.unsafePreferencesPath
        }
    }
    let preferences = try ensurePreferencesDirectory(containerPath: containerPath, simulatorRoot: simulatorRoot)
    let existing = try readPreferenceFiles(in: preferences, rootedAt: containerPath)
    let backup = Dictionary(uniqueKeysWithValues: existing.map { ($0.domain, $0.data) })

    func apply(_ contents: [String: Data]) throws {
        let current = try readPreferenceFiles(in: preferences, rootedAt: containerPath)
        for file in current where contents[file.domain] == nil {
            guard let path = preferenceFilePath(directory: preferences, domain: file.domain, root: containerPath) else {
                throw UserDefaultsSnapshotFailure.unsafePreferencesPath
            }
            if pathIsSymbolicLink(path) {
                throw UserDefaultsSnapshotFailure.unsafePreferencesPath
            }
            try FileManager.default.removeItem(atPath: path)
        }
        for (domain, data) in contents {
            guard let path = preferenceFilePath(directory: preferences, domain: domain, root: containerPath) else {
                throw UserDefaultsSnapshotFailure.unsafePreferencesPath
            }
            if FileManager.default.fileExists(atPath: path) {
                if pathIsSymbolicLink(path) {
                    throw UserDefaultsSnapshotFailure.unsafePreferencesPath
                }
                try assertPathStaysInContainer(path, container: containerPath)
            }
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    do {
        try apply(Dictionary(uniqueKeysWithValues: files.map { ($0.domain, $0.data) }))
    } catch {
        do {
            try apply(backup)
        } catch {
            throw UserDefaultsSnapshotFailure.settingsRollbackFailed
        }
        throw error
    }
}

private func existingPreferencesDirectory(containerPath: String) throws -> String? {
    let container = standardizedPath(containerPath)
    let library = (container as NSString).appendingPathComponent("Library")
    let preferences = (library as NSString).appendingPathComponent("Preferences")
    let fm = FileManager.default
    if fm.fileExists(atPath: library) || pathIsSymbolicLink(library) {
        try assertPathStaysInContainer(library, container: container)
    }
    guard fm.fileExists(atPath: preferences) || pathIsSymbolicLink(preferences) else { return nil }
    try assertPathStaysInContainer(preferences, container: container)
    var isDirectory: ObjCBool = false
    guard fm.fileExists(atPath: preferences, isDirectory: &isDirectory), isDirectory.boolValue else {
        throw UserDefaultsSnapshotFailure.unreadablePreferences("Library/Preferences")
    }
    return preferences
}

private func ensurePreferencesDirectory(containerPath: String, simulatorRoot: String) throws -> String {
    let container = standardizedPath(containerPath)
    guard isSafeLiveDocumentsPath(
        (container as NSString).appendingPathComponent("Documents"),
        simulatorRoot: simulatorRoot
    ) else {
        throw UserDefaultsSnapshotFailure.unsafePreferencesPath
    }
    if let existing = try existingPreferencesDirectory(containerPath: container) {
        return existing
    }
    let preferences = (container as NSString).appendingPathComponent("Library/Preferences")
    try FileManager.default.createDirectory(atPath: preferences, withIntermediateDirectories: true)
    try assertPathStaysInContainer(preferences, container: container)
    return preferences
}

private func preferenceFilePath(directory: String, domain: String, root: String) -> String? {
    guard isLaunchableBundleIdentifier(domain) else { return nil }
    let path = (directory as NSString).appendingPathComponent(domain + ".plist")
    guard pathIsInside(path, directory: standardizedPath(root)) else { return nil }
    guard (path as NSString).lastPathComponent == domain + ".plist" else { return nil }
    return path
}

private func assertPathStaysInContainer(_ path: String, container: String) throws {
    if pathIsSymbolicLink(path) || !pathIsInside(resolvedFilesystemPath(path), directory: standardizedPath(container)) {
        throw UserDefaultsSnapshotFailure.unsafePreferencesPath
    }
}

private func pathIsSymbolicLink(_ path: String) -> Bool {
    var info = stat()
    guard lstat(path, &info) == 0 else { return false }
    return (info.st_mode & S_IFMT) == S_IFLNK
}

private func resolvedFilesystemPath(_ path: String) -> String {
    URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
}
