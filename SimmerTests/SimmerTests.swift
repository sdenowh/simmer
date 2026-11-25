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

struct SimulatorControlPlanTests {
    private let udid = "FD25CCC7-C964-41C4-A1B9-0B0915B71167"

    @Test func openPlanBootsThenFocusesThatDevice() {
        let plan = simulatorControlPlan(udid: udid, bundleIdentifier: nil)
        #expect(plan?.bootStatusArguments == ["simctl", "bootstatus", udid, "-b"])
        #expect(plan?.focusArguments == ["-CurrentDeviceUDID", udid])
        #expect(plan?.launchArguments == nil)
    }

    @Test func launchPlanIncludesTheBundleIdentifier() {
        let plan = simulatorControlPlan(udid: udid, bundleIdentifier: "com.apple.Preferences")
        #expect(plan?.launchArguments == ["simctl", "launch", udid, "com.apple.Preferences"])
        #expect(simulatorControlKey(udid: udid, bundleIdentifier: "com.apple.Preferences") == "\(udid):com.apple.Preferences")
        #expect(simulatorControlKey(udid: udid, bundleIdentifier: nil) == udid)
    }

    @Test func rejectsIdentifiersThatCouldChangeTheCommand() {
        #expect(simulatorControlPlan(udid: "mock-udid-1", bundleIdentifier: nil) == nil)
        #expect(simulatorControlPlan(udid: udid, bundleIdentifier: "com.apple.App; rm") == nil)
        #expect(simulatorControlPlan(udid: udid, bundleIdentifier: "-CurrentDeviceUDID") == nil)
        #expect(isLaunchableBundleIdentifier("com.example.My-App") == true)
    }

    @Test func failureSummaryUsesTheLastLine() {
        let output = """
        An error was encountered processing the command (domain=com.apple.CoreSimulator.SimError, code=405):
        Unable to boot device in current state: Booted
        """
        #expect(simctlFailureSummary(output, fallback: "Couldn't boot.") == "Unable to boot device in current state: Booted")
        #expect(simctlFailureSummary("  \n", fallback: "Couldn't boot.") == "Couldn't boot.")
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

    @Test func bytePastTheFirstHashChunkChangesTheResult() throws {
        let fixture = try makeContainer()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var bytes = Data(repeating: 0x11, count: snapshotHashChunkBytes + 64)
        bytes[snapshotHashChunkBytes + 3] = 0x22
        try bytes.write(to: fixture.documents.appendingPathComponent("blob.bin"))
        let copy = fixture.container.appendingPathComponent("copy", isDirectory: true)
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        try bytes.write(to: copy.appendingPathComponent("blob.bin"))

        #expect(try copiedTreeMatches(sourcePath: fixture.documents.path, copyPath: copy.path))

        bytes[snapshotHashChunkBytes + 3] = 0x33
        try bytes.write(to: copy.appendingPathComponent("blob.bin"))
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

    @Test func progressAdvancesWhileBytesAreCopiedAndVerified() {
        let progress = SnapshotTransferProgress(operation: .capture, report: nil)
        progress.noteInventoryEntry(byteSize: 5_000_000)
        progress.finishInventory()
        let afterInventory = progress.fraction

        progress.noteCopyProgress(copiedBytes: 1_000_000, fileSize: 5_000_000)
        let earlyCopy = progress.fraction
        progress.noteCopyProgress(copiedBytes: 4_000_000, fileSize: 5_000_000)
        let lateCopy = progress.fraction
        #expect(earlyCopy > afterInventory)
        #expect(lateCopy > earlyCopy)

        progress.noteCopyFinished(fileSize: 5_000_000)
        progress.finishCopy()
        let afterCopy = progress.fraction
        #expect(afterCopy > lateCopy)

        progress.noteStabilityEntry()
        progress.finishStability()
        progress.beginVerifyingOriginal()
        let beforeVerify = progress.fraction
        progress.noteVerifiedBytes(2_000_000)
        let midVerify = progress.fraction
        #expect(midVerify > beforeVerify)
        #expect(midVerify < 0.95)

        progress.noteVerifiedBytes(3_000_000)
        progress.noteVerifiedEntry()
        let afterOriginal = progress.fraction
        progress.beginVerifyingCopy()
        #expect(progress.fraction >= afterOriginal)
        progress.noteVerifiedBytes(5_000_000)
        progress.noteVerifiedEntry()
        progress.finish()
        #expect(progress.fraction == 1)
    }

    @Test func progressAdvancesAcrossManyFiles() {
        let progress = SnapshotTransferProgress(operation: .capture, report: nil)
        for _ in 0..<40 {
            progress.noteInventoryEntry(byteSize: 32)
        }
        progress.finishInventory()
        let beforeCopy = progress.fraction
        var last = beforeCopy
        for _ in 0..<40 {
            progress.noteCopyFinished(fileSize: 32)
            #expect(progress.fraction >= last)
            last = progress.fraction
        }
        #expect(progress.fraction > beforeCopy)
        #expect(progress.fraction > 0.1)
    }

    @Test func capturePublishesMovingProgress() throws {
        let fixture = try makeContainer()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try Data(repeating: 0xAB, count: 256 * 1024).write(to: fixture.documents.appendingPathComponent("blob.bin"))
        try FileManager.default.createDirectory(at: fixture.documents.appendingPathComponent("Notes", isDirectory: true), withIntermediateDirectories: true)
        try "page".write(to: fixture.documents.appendingPathComponent("Notes/page.txt"), atomically: true, encoding: .utf8)
        let snapshot = fixture.container.appendingPathComponent("Snapshots/progress", isDirectory: true)

        var samples: [ProgressSample] = []
        try captureDocumentsSnapshot(
            documentsPath: fixture.documents.path,
            snapshotPath: snapshot.path,
            onProgress: { samples.append(ProgressSample(message: $0, fraction: $1)) }
        )
        #expect(samples.contains { $0.message.contains("Counting files") })
        #expect(samples.contains { $0.message.contains("Copying documents") })
        #expect(samples.contains { $0.message.contains("Verifying original") })
        #expect(samples.contains { $0.message.contains("Verifying snapshot") })
        expectMoving(samples)
        let copied = try String(contentsOf: snapshot.appendingPathComponent("Documents/Notes/page.txt"), encoding: .utf8)
        #expect(copied == "page")
    }

    @Test func restorePublishesMovingProgress() throws {
        let fixture = try makeContainer()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try "keep".write(to: fixture.documents.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        let snapshotDocuments = try makeSnapshotDocuments(in: fixture, named: "snap", contents: "restored")
        try FileManager.default.createDirectory(at: snapshotDocuments.appendingPathComponent("Notes", isDirectory: true), withIntermediateDirectories: true)
        try "page".write(to: snapshotDocuments.appendingPathComponent("Notes/page.txt"), atomically: true, encoding: .utf8)

        var samples: [ProgressSample] = []
        try restoreDocumentsReplacingLiveCopy(
            snapshotDocumentsPath: snapshotDocuments.path,
            documentsPath: fixture.documents.path,
            simulatorRoot: fixture.root.path,
            onProgress: { samples.append(ProgressSample(message: $0, fraction: $1)) }
        )
        #expect(samples.contains { $0.message.contains("Restoring documents") })
        #expect(samples.contains { $0.message.contains("Verifying snapshot") })
        #expect(samples.contains { $0.message.contains("Verifying restored documents") })
        expectMoving(samples)
        let text = try String(contentsOf: fixture.documents.appendingPathComponent("Notes/page.txt"), encoding: .utf8)
        #expect(text == "page")
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
        var isDirectory: ObjCBool = false
        let settings = snapshots.appendingPathComponent("\(name)/UserDefaults").path
        #expect(FileManager.default.fileExists(atPath: settings, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }
}

struct UserDefaultsSnapshotTests {
    @Test func captureCopiesSettingsAndSkipsHiddenDomains() throws {
        let fixture = try makeContainer()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try writeAppPreferences([
            "com.example.app": try preferencePlist(["theme": "dark"]),
            "com.example.suite": try preferencePlist(["cached": "yes"]),
            ".GlobalPreferences": try preferencePlist(["hidden": "no"])
        ], container: fixture.container)
        let snapshot = fixture.container.appendingPathComponent("Snapshots/settings", isDirectory: true)

        let source = try captureUserDefaultsSnapshot(
            containerPath: fixture.container.path,
            bundleIdentifier: "com.example.app",
            snapshotPath: snapshot.path
        )

        #expect(source == .files)
        #expect(try preferenceDictionary(in: snapshot, domain: "com.example.app")["theme"] == "dark")
        #expect(try preferenceDictionary(in: snapshot, domain: "com.example.suite")["cached"] == "yes")
        #expect(FileManager.default.fileExists(atPath: snapshot.appendingPathComponent("UserDefaults/.GlobalPreferences.plist").path) == false)
    }

    @Test func captureWithNoSettingsStillRecordsThatSettingsWereIncluded() throws {
        let fixture = try makeContainer()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let snapshot = fixture.container.appendingPathComponent("Snapshots/empty", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)

        _ = try captureUserDefaultsSnapshot(
            containerPath: fixture.container.path,
            bundleIdentifier: "com.example.app",
            snapshotPath: snapshot.path
        )
        try writeAppPreferences([
            "com.example.app": try preferencePlist(["theme": "later"])
        ], container: fixture.container)

        try restoreUserDefaultsSnapshot(
            snapshotPath: snapshot.path,
            containerPath: fixture.container.path,
            simulatorRoot: fixture.root.path,
            bundleIdentifier: "com.example.app"
        )

        let plist = fixture.container.appendingPathComponent("Library/Preferences/com.example.app.plist")
        #expect(FileManager.default.fileExists(atPath: plist.path) == false)
    }

    @Test func bootedReaderReplacesStaleFiles() throws {
        let fixture = try makeContainer()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try writeAppPreferences([
            "com.example.app": try preferencePlist(["theme": "light"]),
            "com.example.suite": try preferencePlist(["cached": "stale"])
        ], container: fixture.container)
        let snapshot = fixture.container.appendingPathComponent("Snapshots/live", isDirectory: true)
        let live = try preferencePlist(["theme": "dark"])

        let source = try captureUserDefaultsSnapshot(
            containerPath: fixture.container.path,
            bundleIdentifier: "com.example.app",
            snapshotPath: snapshot.path,
            readLiveDomain: { domain in
                if domain == "com.example.app" { return .value(live) }
                return .missing
            }
        )

        #expect(source == .simulator)
        #expect(try preferenceDictionary(in: snapshot, domain: "com.example.app")["theme"] == "dark")
        #expect(FileManager.default.fileExists(atPath: snapshot.appendingPathComponent("UserDefaults/com.example.suite.plist").path) == false)
    }

    @Test func unavailableLiveSettingsFallBackToThePlist() throws {
        let fixture = try makeContainer()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try writeAppPreferences([
            "com.example.app": try preferencePlist(["theme": "disk"])
        ], container: fixture.container)
        let snapshot = fixture.container.appendingPathComponent("Snapshots/fallback", isDirectory: true)

        let source = try captureUserDefaultsSnapshot(
            containerPath: fixture.container.path,
            bundleIdentifier: "com.example.app",
            snapshotPath: snapshot.path,
            readLiveDomain: { _ in .unavailable }
        )

        #expect(source == .files)
        #expect(try preferenceDictionary(in: snapshot, domain: "com.example.app")["theme"] == "disk")
    }

    @Test func symlinkPreferenceIsNotCopied() throws {
        let fixture = try makeContainer()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let outside = fixture.root.appendingPathComponent("outside.plist")
        try preferencePlist(["secret": "no"]).write(to: outside, options: .atomic)
        let preferences = fixture.container.appendingPathComponent("Library/Preferences", isDirectory: true)
        try FileManager.default.createDirectory(at: preferences, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: preferences.appendingPathComponent("com.example.app.plist"),
            withDestinationURL: outside
        )
        try "keep".write(to: fixture.documents.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        let snapshot = fixture.container.appendingPathComponent("Snapshots/link", isDirectory: true)

        #expect(throws: UserDefaultsSnapshotFailure.unsafePreferencesPath) {
            try captureAppSnapshot(
                documentsPath: fixture.documents.path,
                bundleIdentifier: "com.example.app",
                snapshotPath: snapshot.path,
                bootedUDID: nil
            )
        }
        #expect(FileManager.default.fileExists(atPath: snapshot.path) == false)
        #expect(try preferenceDictionary(at: outside)["secret"] == "no")
    }

    @Test func restoreReplacesSettingsAndDocuments() throws {
        let fixture = try makeContainer()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try "before".write(to: fixture.documents.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        try writeAppPreferences([
            "com.example.app": try preferencePlist(["theme": "before"])
        ], container: fixture.container)
        let snapshot = fixture.container.appendingPathComponent("Snapshots/full", isDirectory: true)
        try captureAppSnapshot(
            documentsPath: fixture.documents.path,
            bundleIdentifier: "com.example.app",
            snapshotPath: snapshot.path,
            bootedUDID: nil
        )

        try "after".write(to: fixture.documents.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        try writeAppPreferences([
            "com.example.app": try preferencePlist(["theme": "after"]),
            "com.example.suite": try preferencePlist(["cached": "extra"])
        ], container: fixture.container)

        try restoreAppSnapshot(
            snapshotPath: snapshot.path,
            documentsPath: fixture.documents.path,
            bundleIdentifier: "com.example.app",
            simulatorRoot: fixture.root.path,
            bootedUDID: nil
        )

        let text = try String(contentsOf: fixture.documents.appendingPathComponent("note.txt"), encoding: .utf8)
        #expect(text == "before")
        #expect(try preferenceDictionary(in: fixture.container, domain: "com.example.app")["theme"] == "before")
        let extra = fixture.container.appendingPathComponent("Library/Preferences/com.example.suite.plist")
        #expect(FileManager.default.fileExists(atPath: extra.path) == false)
        #expect(try preferenceDictionary(in: snapshot, domain: "com.example.app")["theme"] == "before")
    }

    @Test func olderSnapshotRestoresDocumentsWithoutChangingSettings() throws {
        let fixture = try makeContainer()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try "keep".write(to: fixture.documents.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        try writeAppPreferences([
            "com.example.app": try preferencePlist(["theme": "stay"])
        ], container: fixture.container)
        let snapshotDocuments = try makeSnapshotDocuments(in: fixture, named: "legacy", contents: "restored")

        try restoreAppSnapshot(
            snapshotPath: snapshotDocuments.deletingLastPathComponent().path,
            documentsPath: fixture.documents.path,
            bundleIdentifier: "com.example.app",
            simulatorRoot: fixture.root.path,
            bootedUDID: nil
        )

        let text = try String(contentsOf: fixture.documents.appendingPathComponent("note.txt"), encoding: .utf8)
        #expect(text == "restored")
        #expect(try preferenceDictionary(in: fixture.container, domain: "com.example.app")["theme"] == "stay")
    }

    @Test func unsafeContainerLeavesDocumentsAndSettingsAlone() throws {
        let fixture = try makeContainer()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try "keep".write(to: fixture.documents.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        try writeAppPreferences([
            "com.example.app": try preferencePlist(["theme": "keep"])
        ], container: fixture.container)
        let snapshot = fixture.container.appendingPathComponent("Snapshots/safe", isDirectory: true)
        try captureAppSnapshot(
            documentsPath: fixture.documents.path,
            bundleIdentifier: "com.example.app",
            snapshotPath: snapshot.path,
            bootedUDID: nil
        )
        try "changed".write(to: fixture.documents.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        let elsewhere = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: elsewhere) }

        #expect(throws: UserDefaultsSnapshotFailure.unsafePreferencesPath) {
            try restoreAppSnapshot(
                snapshotPath: snapshot.path,
                documentsPath: fixture.documents.path,
                bundleIdentifier: "com.example.app",
                simulatorRoot: elsewhere.path,
                bootedUDID: nil
            )
        }
        let text = try String(contentsOf: fixture.documents.appendingPathComponent("note.txt"), encoding: .utf8)
        #expect(text == "changed")
        #expect(try preferenceDictionary(in: fixture.container, domain: "com.example.app")["theme"] == "keep")
        #expect(restoreFailureMessage(UserDefaultsSnapshotFailure.unsafePreferencesPath).contains("Documents were left unchanged"))
    }

    @Test func failedSettingsReplaceRollsBack() throws {
        let fixture = try makeContainer()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let original = try preferencePlist(["theme": "old"])
        let replacement = try preferencePlist(["theme": "new"])
        let suite = try preferencePlist(["cached": "extra"])
        try writeAppPreferences([
            "com.example.app": original,
            "com.example.suite": suite
        ], container: fixture.container)
        let snapshot = fixture.container.appendingPathComponent("Snapshots/rollback/UserDefaults", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try replacement.write(to: snapshot.appendingPathComponent("com.example.app.plist"), options: .atomic)

        var store = ["com.example.app": original, "com.example.suite": suite]
        #expect(throws: UserDefaultsSnapshotFailure.simulatorPreferencesUnavailable("nope")) {
            try restoreUserDefaultsSnapshot(
                snapshotPath: snapshot.deletingLastPathComponent().path,
                containerPath: fixture.container.path,
                simulatorRoot: fixture.root.path,
                bundleIdentifier: "com.example.app",
                readLiveDomain: { domain in
                    guard let data = store[domain] else { return .missing }
                    return .value(data)
                },
                replaceLiveDomain: { domain, data in
                    if domain == "com.example.suite" {
                        throw UserDefaultsSnapshotFailure.simulatorPreferencesUnavailable("nope")
                    }
                    if let data {
                        store[domain] = data
                    } else {
                        store.removeValue(forKey: domain)
                    }
                }
            )
        }
        #expect(store["com.example.app"] == original)
        #expect(store["com.example.suite"] == suite)
    }

    @Test func invalidSimulatorIdentifierDoesNotSpawn() {
        #expect(simctlExportPreference(udid: "not-a-udid", domain: "com.example.app") == .unavailable)
        #expect(simctlExportPreference(udid: "FD25CCC7-C964-41C4-A1B9-0B0915B71167", domain: "../com.example") == .unavailable)
    }
}

private struct ProgressSample {
    var message: String
    var fraction: Double
}

private func expectMoving(_ samples: [ProgressSample]) {
    #expect(samples.count >= 4)
    for pair in zip(samples, samples.dropFirst()) {
        #expect(pair.1.fraction + 0.000_001 >= pair.0.fraction)
    }
    #expect(samples.contains { $0.fraction > 0.2 && $0.fraction < 0.9 })
    #expect((samples.last?.fraction ?? 0) > 0.95)
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

private func preferencePlist(_ values: [String: String]) throws -> Data {
    try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
}

private func preferenceDictionary(at url: URL) throws -> [String: String] {
    let data = try Data(contentsOf: url)
    let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    return object as? [String: String] ?? [:]
}

private func preferenceDictionary(in root: URL, domain: String) throws -> [String: String] {
    let candidates = [
        root.appendingPathComponent("UserDefaults/\(domain).plist"),
        root.appendingPathComponent("Library/Preferences/\(domain).plist")
    ]
    guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
        return [:]
    }
    return try preferenceDictionary(at: url)
}

private func writeAppPreferences(_ files: [String: Data], container: URL) throws {
    let directory = container.appendingPathComponent("Library/Preferences", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for (domain, data) in files {
        try data.write(to: directory.appendingPathComponent("\(domain).plist"), options: .atomic)
    }
}

private func makeSnapshotDocuments(in fixture: ContainerFixture, named name: String, contents: String) throws -> URL {
    let documents = fixture.container.appendingPathComponent("Snapshots/\(name)/Documents", isDirectory: true)
    try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
    try contents.write(to: documents.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
    return documents
}
