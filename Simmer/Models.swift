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
    
    var formattedVersion: String {
        // Remove any leading 'iOS-' or 'iOS' and replace dashes with dots
        let cleaned = iOSVersion.replacingOccurrences(of: "iOS-", with: "")
                                 .replacingOccurrences(of: "iOS", with: "")
                                 .replacingOccurrences(of: "-", with: ".")
                                 .trimmingCharacters(in: .whitespacesAndNewlines)
        return "iOS " + cleaned
    }
    
    enum DeviceType: String, CaseIterable, Codable {
        case iPhone = "iPhone"
        case iPad = "iPad"
        case appleTV = "Apple TV"
        case appleWatch = "Apple Watch"
        
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
}

struct Snapshot: Identifiable, Hashable {
    let id: String
    let name: String
    let date: Date
    let size: Int64
    let path: String
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