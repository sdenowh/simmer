//
//  AboutWindowController.swift
//  Simmer
//
//  Created by Cursor AI.
//

import AppKit
import SwiftUI

final class AboutWindowController: NSWindowController {
    static let shared = AboutWindowController()

    private init() {
        let hosting = NSHostingView(rootView: AboutView())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "About Simmer"
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showAbout() {
        guard let window = self.window else { return }
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        self.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }
}


