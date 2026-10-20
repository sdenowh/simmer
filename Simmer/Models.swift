//
//  Models.swift
//  Simmer
//
//  Created by Scott Denowh on 7/10/25.
//

import Foundation
import SwiftUI

struct Simulator: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let iOSVersion: String
    let deviceType: DeviceType
    let udid: String
    let dataPath: String
    var isPinned: Bool = false
    var lastBootedAt: Date? = nil

    var formattedVersion: String {
        Self.formatRuntime(iOSVersion)
    }

    /// Turns a CoreSimulator runtime id into a display string.
    /// `tvOS-26-5` stays tvOS; only an iOS runtime is labeled iOS.
    static func formatRuntime(_ raw: String) -> String {
        var value = raw.replacingOccurrences(of: "com.apple.CoreSimulator.SimRuntime.", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let platforms = ["watchOS", "visionOS", "tvOS", "xrOS", "iOS"]
        var platform = "iOS"
        for candidate in platforms where value.hasPrefix(candidate) {
            platform = candidate == "xrOS" ? "visionOS" : candidate
            value = String(value.dropFirst(candidate.count))
            break
        }
        let version = value
            .trimmingCharacters(in: CharacterSet(charactersIn: "- "))
            .replacingOccurrences(of: "-", with: ".")
        if version.isEmpty { return platform }
        return "\(platform) \(version)"
    }
    
    enum DeviceType: String, CaseIterable, Codable {
        case iPhone = "iPhone"
        case iPad = "iPad"
        case appleTV = "Apple TV"
        case appleWatch = "Apple Watch"

        /// Device type identifiers use hyphens (`Apple-TV-4K`), not the compact `AppleTV` token.
        static func resolve(_ deviceTypeString: String) -> DeviceType {
            let normalized = deviceTypeString.replacingOccurrences(of: "-", with: "")
            if normalized.contains("iPhone") { return .iPhone }
            if normalized.contains("iPad") { return .iPad }
            if normalized.contains("AppleTV") { return .appleTV }
            if normalized.contains("Watch") { return .appleWatch }
            return .iPhone
        }
        
        var icon: String {
            switch self {
            case .iPhone:
                return "iphone"
            case .iPad:
                return "ipad"
            case .appleTV:
                return "tv"
            case .appleWatch:
                return "applewatch"
            }
        }
    }
}

struct App: Identifiable, Hashable {
    let id: String
    let name: String
    let bundleIdentifier: String
    let iconPath: String?
    let documentsPath: String
    let snapshotsPath: String
    var documentsSize: Int64 = 0
    var isLoadingDocumentsSize: Bool = false
    
    mutating func startLoadingDocumentsSize() {
        isLoadingDocumentsSize = true
    }
    
    mutating func finishLoadingDocumentsSize(_ calculatedSize: Int64) {
        documentsSize = calculatedSize
        isLoadingDocumentsSize = false
    }
}

struct Snapshot: Identifiable, Hashable {
    let id: String
    let name: String
    let date: Date
    var size: Int64
    let path: String
    var isLoadingSize: Bool = false
    var displayName: String?
    
    mutating func startLoadingSize() {
        isLoadingSize = true
    }
    
    mutating func finishLoadingSize(_ calculatedSize: Int64) {
        size = calculatedSize
        isLoadingSize = false
    }
}

struct SnapshotMetadata: Codable {
    var displayName: String?
}

struct DirectorySize {
    let size: Int64
    let formattedSize: String
    
    init(size: Int64) {
        self.size = size
        self.formattedSize = Self.formatBytes(size)
    }
    
    private static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
} 

// Represents a push notification payload previously sent to a specific
// simulator/app combination. Stored in UserDefaults per (udid,bundleId).
struct SentNotification: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let createdAt: Date
    let payloadJSON: String
}