//
//  AboutView.swift
//  Simmer
//
//  Created by Cursor AI.
//

import SwiftUI
import AppKit

struct AboutView: View {
    private var appName: String {
        (Bundle.main.infoDictionary?["CFBundleName"] as? String) ?? "Simmer"
    }

    private var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""
    }

    private var build: String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? ""
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .cornerRadius(20)

            Text(appName)
                .font(.title2)
                .bold()

            Text("Version \(version) (\(build))")
                .foregroundStyle(.secondary)

            Divider()

            VStack(spacing: 8) {
                Text("Simmer is an open-source menubar app for iOS Simulator management.")
                    .font(.system(size: 12))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                Link("GitHub Repository",
                     destination: URL(string: "https://github.com/sdenowh/simmer")!)
                    .font(.system(size: 12, weight: .medium))
            }

            Spacer()
        }
        .padding(20)
        .frame(minWidth: 420, minHeight: 260)
    }
}


