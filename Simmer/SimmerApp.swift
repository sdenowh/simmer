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
        setupKeyboardShortcuts()
        // Show the popover automatically on launch, after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.togglePopover()
        }
    }
    
    private func setupKeyboardShortcuts() {
        // Add keyboard shortcut to toggle mock data (⌘+M)
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.modifierFlags.contains(.command) && event.characters == "m" {
                self.toggleMockData()
                return nil
            }
            return event
        }
    }
    
    private func toggleMockData() {
        // Toggle mock data state
        let currentState = UserDefaults.standard.bool(forKey: "UseMockData")
        let newState = !currentState
        UserDefaults.standard.set(newState, forKey: "UseMockData")
        
        // Enable/disable mock data in the service
        simulatorService.enableMockData(newState)
        
        // Show a notification
        let notification = NSUserNotification()
        notification.title = "Simmer"
        notification.informativeText = newState ? "Mock data enabled (⌘+M to disable)" : "Mock data disabled (⌘+M to enable)"
        notification.soundName = NSUserNotificationDefaultSoundName
        NSUserNotificationCenter.default.deliver(notification)
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
        popover?.contentSize = NSSize(width: 300, height: 450)
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
        
        // Refresh disk usage for expanded apps
        simulatorService.refreshSelectedAppDiskUsage()
        
        // Refresh documents size for all apps in the current simulator
        if let selectedSimulator = simulatorService.selectedSimulator {
            print("Refreshing documents size for all apps in simulator: \(selectedSimulator.name)")
            
            // Force a complete refresh of the apps list which will recalculate all document sizes
            simulatorService.objectWillChange.send()
            simulatorService.loadApps(for: selectedSimulator)
        }
    }
}
