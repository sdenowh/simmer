//
//  SimmerTests.swift
//  SimmerTests
//

import Foundation
import Testing
@testable import Simmer

struct RuntimeLabelTests {
    @Test func keepsTheRuntimePlatform() {
        #expect(Simulator.formatRuntime("iOS-26-5") == "iOS 26.5")
        #expect(Simulator.formatRuntime("com.apple.CoreSimulator.SimRuntime.tvOS-26-5") == "tvOS 26.5")
        #expect(Simulator.formatRuntime("watchOS-11-0") == "watchOS 11.0")
        #expect(Simulator.formatRuntime("iOS 17.4") == "iOS 17.4")
        #expect(Simulator.formatRuntime("xrOS-2-0") == "visionOS 2.0")
    }

    @Test func appleTVIdentifierIsNotAniPhone() {
        #expect(Simulator.DeviceType.resolve("com.apple.CoreSimulator.SimDeviceType.Apple-TV-4K-3rd-generation-4K") == .appleTV)
        #expect(Simulator.DeviceType.resolve("com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro") == .iPhone)
        #expect(Simulator.DeviceType.resolve("com.apple.CoreSimulator.SimDeviceType.iPad-10th-generation") == .iPad)
        #expect(Simulator.DeviceType.resolve("com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Series-10") == .appleWatch)
    }
}

struct DevicePlistTests {
    @Test func deletedFlagAndBootState() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let booted: [String: Any] = ["state": 3, "isDeleted": false]
        let shutdown: [String: Any] = ["state": 1, "isDeleted": true]
        NSDictionary(dictionary: booted).write(toFile: root.appendingPathComponent("device.plist").path, atomically: true)

        #expect(simulatorIsBooted(at: root.path))
        let bootedPlist = NSDictionary(dictionary: booted)
        #expect(deviceRecordIsDeleted(bootedPlist) == false)
        #expect(deviceRecordIsDeleted(NSDictionary(dictionary: shutdown)))

        NSDictionary(dictionary: shutdown).write(toFile: root.appendingPathComponent("device.plist").path, atomically: true)
        #expect(simulatorIsBooted(at: root.path) == false)
    }
}

struct SnapshotSafetyTests {
    @Test func pathPrefixDoesNotMatchASibling() {
        #expect(pathIsInside("/tmp/a/b", directory: "/tmp/a"))
        #expect(pathIsInside("/tmp/a/b/../c", directory: "/tmp/a/c"))
        #expect(pathIsInside("/tmp/ab", directory: "/tmp/a") == false)
    }

    @Test func documentsPathMustLiveUnderTheSimulator() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let documents = root.appendingPathComponent("container/Documents", isDirectory: true)
        #expect(isSafeLiveDocumentsPath(documents.path, simulatorRoot: root.path))
        #expect(isSafeLiveDocumentsPath(root.appendingPathComponent("Documents").path, simulatorRoot: root.path) == false)
        #expect(isSafeLiveDocumentsPath("/tmp/elsewhere/Documents", simulatorRoot: root.path) == false)
    }

    @Test func onlyAChildOfSnapshotsCanBeDeleted() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let container = root.appendingPathComponent("container", isDirectory: true)
        let documents = container.appendingPathComponent("Documents", isDirectory: true)
        let snapshots = container.appendingPathComponent("Snapshots", isDirectory: true)
        let snapshot = snapshots.appendingPathComponent("snap", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshot.appendingPathComponent("Documents", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)

        #expect(isDeletableSnapshotDirectory(snapshot.path, snapshotsRoot: snapshots.path, documentsPath: documents.path, simulatorRoot: root.path))
        #expect(isDeletableSnapshotDirectory(snapshots.path, snapshotsRoot: snapshots.path, documentsPath: documents.path, simulatorRoot: root.path) == false)
        #expect(isDeletableSnapshotDirectory(documents.path, snapshotsRoot: snapshots.path, documentsPath: documents.path, simulatorRoot: root.path) == false)
        let outside = root.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        #expect(isDeletableSnapshotDirectory(outside.path, snapshotsRoot: snapshots.path, documentsPath: documents.path, simulatorRoot: root.path) == false)
    }
}

struct SnapshotFileOperationTests {
    @Test func missingSnapshotLeavesDocumentsAlone() throws {
        let fixture = try makeContainer()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try "keep".write(to: fixture.documents.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)

        #expect(throws: SnapshotFileFailure.missingSnapshotDocuments) {
            try restoreDocumentsReplacingLiveCopy(
                snapshotDocumentsPath: fixture.root.appendingPathComponent("missing/Documents").path,
                documentsPath: fixture.documents.path,
                simulatorRoot: fixture.root.path
            )
        }
        let text = try String(contentsOf: fixture.documents.appendingPathComponent("note.txt"), encoding: .utf8)
        #expect(text == "keep")
    }

    @Test func failedValidationRollsDocumentsBack() throws {
        let fixture = try makeContainer()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try "keep".write(to: fixture.documents.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        let snapshotDocuments = try makeSnapshotDocuments(in: fixture, named: "snap", contents: "new")

        #expect(throws: SnapshotFileFailure.validationFailed) {
            try restoreDocumentsReplacingLiveCopy(
                snapshotDocumentsPath: snapshotDocuments.path,
                documentsPath: fixture.documents.path,
                simulatorRoot: fixture.root.path,
                maxAttempts: 1,
                validate: { _, _ in false }
            )
        }
        let text = try String(contentsOf: fixture.documents.appendingPathComponent("note.txt"), encoding: .utf8)
        #expect(text == "keep")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: fixture.container.path)
        #expect(leftovers.contains { $0.hasPrefix(".simmer-documents-backup-") } == false)
    }

    @Test func successfulRestoreReplacesDocumentsAndKeepsTheSnapshot() throws {
        let fixture = try makeContainer()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try "keep".write(to: fixture.documents.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        let snapshotDocuments = try makeSnapshotDocuments(in: fixture, named: "snap", contents: "restored")

        try restoreDocumentsReplacingLiveCopy(
            snapshotDocumentsPath: snapshotDocuments.path,
            documentsPath: fixture.documents.path,
            simulatorRoot: fixture.root.path
        )
        let text = try String(contentsOf: fixture.documents.appendingPathComponent("note.txt"), encoding: .utf8)
        #expect(text == "restored")
        let snapshotText = try String(contentsOf: snapshotDocuments.appendingPathComponent("note.txt"), encoding: .utf8)
        #expect(snapshotText == "restored")
    }

    @Test func failedCaptureRemovesThePartialSnapshot() throws {
        let fixture = try makeContainer()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try "keep".write(to: fixture.documents.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        let snapshot = fixture.container.appendingPathComponent("Snapshots/partial", isDirectory: true)

        #expect(throws: SnapshotFileFailure.validationFailed) {
            try captureDocumentsSnapshot(
                documentsPath: fixture.documents.path,
                snapshotPath: snapshot.path,
                maxAttempts: 1,
                validate: { _, _ in false }
            )
        }
        #expect(FileManager.default.fileExists(atPath: snapshot.path) == false)
        let text = try String(contentsOf: fixture.documents.appendingPathComponent("note.txt"), encoding: .utf8)
        #expect(text == "keep")
    }

    @Test func captureCopiesDocumentsIntoTheSnapshot() throws {
        let fixture = try makeContainer()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try "keep".write(to: fixture.documents.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        let snapshot = fixture.container.appendingPathComponent("Snapshots/ok", isDirectory: true)

        try FileManager.default.createDirectory(at: fixture.documents.appendingPathComponent("Empty", isDirectory: true), withIntermediateDirectories: true)
        try captureDocumentsSnapshot(documentsPath: fixture.documents.path, snapshotPath: snapshot.path)
        let copied = try String(contentsOf: snapshot.appendingPathComponent("Documents/note.txt"), encoding: .utf8)
        #expect(copied == "keep")
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: snapshot.appendingPathComponent("Documents/Empty").path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }

    @Test func sameSizeWithDifferentBytesIsNotAMatch() throws {
        let fixture = try makeContainer()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try "ab".write(to: fixture.documents.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        let copy = fixture.container.appendingPathComponent("copy", isDirectory: true)
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        try "cd".write(to: copy.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)

        #expect(try copiedTreeMatches(sourcePath: fixture.documents.path, copyPath: copy.path) == false)
    }

    @Test func missingFileIsNotAMatch() throws {
        let fixture = try makeContainer()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try "keep".write(to: fixture.documents.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: fixture.documents.appendingPathComponent("Empty", isDirectory: true), withIntermediateDirectories: true)
        let copy = fixture.container.appendingPathComponent("copy", isDirectory: true)
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        try "keep".write(to: copy.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)

        #expect(try copiedTreeMatches(sourcePath: fixture.documents.path, copyPath: copy.path) == false)
    }

    @Test func brokenSymlinkIsCopiedAsItself() throws {
        let fixture = try makeContainer()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let missing = fixture.root.appendingPathComponent("missing-\(UUID().uuidString)").path
        try FileManager.default.createSymbolicLink(
            atPath: fixture.documents.appendingPathComponent("broken").path,
            withDestinationPath: missing
        )
        let entries = try fileTreeEntries(at: fixture.documents.path, hashContents: true)
        #expect(entries.count == 1)
        guard case .symlink(let target) = entries.first?.kind else {
            Issue.record("Broken symlink was omitted from the snapshot tree")
            return
        }
        #expect(target == missing)

        let snapshot = fixture.container.appendingPathComponent("Snapshots/link", isDirectory: true)
        try captureDocumentsSnapshot(
            documentsPath: fixture.documents.path,
            snapshotPath: snapshot.path,
            maxAttempts: 1
        )
        let copied = try FileManager.default.destinationOfSymbolicLink(
            atPath: snapshot.appendingPathComponent("Documents/broken").path
        )
        #expect(copied == missing)
    }

    @Test func captureRetriesUntilTheCopyMatches() throws {
        let fixture = try makeContainer()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try "keep".write(to: fixture.documents.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        let snapshot = fixture.container.appendingPathComponent("Snapshots/retry", isDirectory: true)
        var attempts = 0

        try captureDocumentsSnapshot(
            documentsPath: fixture.documents.path,
            snapshotPath: snapshot.path,
            maxAttempts: 3,
            retryDelay: 0,
            validate: { source, copy in
                attempts += 1
                if attempts == 1 { return false }
                return try copiedTreeMatches(sourcePath: source, copyPath: copy)
            }
        )

        #expect(attempts == 2)
        let copied = try String(contentsOf: snapshot.appendingPathComponent("Documents/note.txt"), encoding: .utf8)
        #expect(copied == "keep")
    }

    @Test func captureThatKeepsChangingFailsAndRemovesTheSnapshot() throws {
        let fixture = try makeContainer()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let note = fixture.documents.appendingPathComponent("note.txt")
        try "keep".write(to: note, atomically: true, encoding: .utf8)
        let snapshot = fixture.container.appendingPathComponent("Snapshots/unstable", isDirectory: true)

        do {
            try captureDocumentsSnapshot(
                documentsPath: fixture.documents.path,
                snapshotPath: snapshot.path,
                maxAttempts: 2,
                retryDelay: 0,
                afterCopy: {
                    let text = (try? String(contentsOf: note, encoding: .utf8)) ?? ""
                    try! (text + "x").write(to: note, atomically: true, encoding: .utf8)
                }
            )
            Issue.record("A snapshot that changed during the copy was reported as a success")
        } catch let error as SnapshotAttemptsExhausted {
            #expect(error.attempts == 2)
            #expect(error.underlying as? SnapshotFileFailure == .changedDuringCopy)
        }
        #expect(FileManager.default.fileExists(atPath: snapshot.path) == false)
    }

    @Test func unreadableDirectoryFailsAndRemovesTheSnapshot() throws {
        let fixture = try makeContainer()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let secret = fixture.documents.appendingPathComponent("Secret", isDirectory: true)
        try FileManager.default.createDirectory(at: secret, withIntermediateDirectories: true)
        try "hidden".write(to: secret.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: secret.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: secret.path) }
        let snapshot = fixture.container.appendingPathComponent("Snapshots/unreadable", isDirectory: true)

        do {
            try captureDocumentsSnapshot(
                documentsPath: fixture.documents.path,
                snapshotPath: snapshot.path,
                maxAttempts: 1
            )
            Issue.record("An unreadable Documents tree was reported as a successful snapshot")
        } catch {
            #expect(FileManager.default.fileExists(atPath: snapshot.path) == false)
        }
    }

    @Test func restoreRetriesAfterATransientMismatch() throws {
        let fixture = try makeContainer()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try "keep".write(to: fixture.documents.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        let snapshotDocuments = try makeSnapshotDocuments(in: fixture, named: "snap", contents: "restored")
        var attempts = 0

        try restoreDocumentsReplacingLiveCopy(
            snapshotDocumentsPath: snapshotDocuments.path,
            documentsPath: fixture.documents.path,
            simulatorRoot: fixture.root.path,
            maxAttempts: 2,
            retryDelay: 0,
            validate: { source, copy in
                attempts += 1
                if attempts == 1 { return false }
                return try copiedTreeMatches(sourcePath: source, copyPath: copy)
            }
        )

        #expect(attempts == 2)
        let text = try String(contentsOf: fixture.documents.appendingPathComponent("note.txt"), encoding: .utf8)
        #expect(text == "restored")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: fixture.container.path)
        #expect(leftovers.contains { $0.hasPrefix(".simmer-documents-backup-") } == false)
    }

    @Test func repeatedSnapshotClicksWhileOneIsRunningCreateOnlyOne() throws {
        let fixture = try makeContainer()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let metadata: [String: Any] = ["MCMMetadataIdentifier": "com.example.app"]
        let metadataPath = fixture.container.appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist")
        #expect(NSDictionary(dictionary: metadata).write(to: metadataPath, atomically: true))
        try "keep".write(to: fixture.documents.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)

        let snapshots = fixture.container.appendingPathComponent("Snapshots", isDirectory: true)
        let app = App(
            id: "com.example.app",
            name: "Example",
            bundleIdentifier: "com.example.app",
            iconPath: nil,
            documentsPath: fixture.documents.path,
            snapshotsPath: snapshots.path
        )
        let service = SimulatorService()
        service.takeSnapshot(for: app)
        #expect(service.isSnapshotOperationInProgress)
        service.takeSnapshot(for: app)
        service.takeSnapshot(for: app)

        waitUntil(timeout: 5) { !service.isSnapshotOperationInProgress }
        #expect(service.isSnapshotOperationInProgress == false)
        let names = try FileManager.default.contentsOfDirectory(atPath: snapshots.path).filter { !$0.hasPrefix(".") }
        #expect(names.count == 1)
        guard let name = names.first else { return }
        let copied = try String(contentsOf: snapshots.appendingPathComponent("\(name)/Documents/note.txt"), encoding: .utf8)
        #expect(copied == "keep")
    }
}

private struct ContainerFixture {
    let root: URL
    let container: URL
    let documents: URL
}

private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        let done = Thread.isMainThread ? condition() : DispatchQueue.main.sync(execute: condition)
        if done { return }
        if Thread.isMainThread {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        } else {
            Thread.sleep(forTimeInterval: 0.05)
        }
    }
}

private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("simmer-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeContainer() throws -> ContainerFixture {
    let root = try makeTempDirectory()
    let container = root.appendingPathComponent("container", isDirectory: true)
    let documents = container.appendingPathComponent("Documents", isDirectory: true)
    try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
    return ContainerFixture(root: root, container: container, documents: documents)
}

private func makeSnapshotDocuments(in fixture: ContainerFixture, named name: String, contents: String) throws -> URL {
    let documents = fixture.container.appendingPathComponent("Snapshots/\(name)/Documents", isDirectory: true)
    try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
    try contents.write(to: documents.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
    return documents
}
