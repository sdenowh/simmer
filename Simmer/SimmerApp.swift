//
//  SimmerApp.swift
//  Simmer
//
//  Created by Scott Denowh on 7/10/25.
//

import SwiftUI
import AppKit

class PopoverWindowProvider: ObservableObject {
    weak var window: NSWindow?
}

@main
struct SimmerApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

class AppState: ObservableObject {
    @Published var popoverAppearanceCount: Int = 0
}

class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private let appState = AppState()
    private let simulatorService = SimulatorService() // Shared instance
    private var contentView: ContentView?
    private let popoverWindowProvider = PopoverWindowProvider()
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupPopover()
    }
    
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "iphone", accessibilityDescription: "Simmer")
            button.action = #selector(togglePopover)
            button.target = self
        }
    }
    
    private func setupPopover() {
        popover = NSPopover()
        popover?.contentSize = NSSize(width: 300, height: 400)
        popover?.behavior = .transient
        popover?.delegate = self
        let hostingController = NSHostingController(rootView: ContentView(appState: appState, simulatorService: simulatorService).environmentObject(popoverWindowProvider))
        popover?.contentViewController = hostingController
        // Set window reference after popover is shown
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.popoverWindowProvider.window = hostingController.view.window
        }
    }
    
    @objc private func togglePopover() {
        if let button = statusItem?.button {
            if popover?.isShown == true {
                popover?.performClose(nil)
            } else {
                popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                // Set window reference after popover is shown
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    if let window = self.popover?.contentViewController?.view.window {
                        self.popoverWindowProvider.window = window
                    }
                }
            }
        }
    }
    
    // MARK: - NSPopoverDelegate
    
    func popoverDidShow(_ notification: Notification) {
        appState.popoverAppearanceCount += 1
        simulatorService.refreshSelectedAppDiskUsage()
    }
}
