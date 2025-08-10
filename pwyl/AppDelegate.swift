//
//  AppDelegate.swift
//  pwyl
//
//  Created by Eric Weinert on 8/9/25.
//

import AppKit
import SwiftUI

final class DebugState: ObservableObject {
    @Published var text: String = "No data yet"
}

final class DebugConfig: ObservableObject {
    @Published var threshold: Double = 0.17
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    let controller = GazeController()
    var debugWindow: NSWindow?
    let debugState = DebugState()
    let debugConfig = DebugConfig()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // background app, menu bar only
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "eye.slash", accessibilityDescription: "LookPause")
        constructMenu()
        controller.onEnabledChanged = { [weak self] _ in self?.updateMenu() }
        controller.onStateChanged = { [weak self] state in
            DispatchQueue.main.async {
                self?.statusItem.button?.image = NSImage(systemSymbolName: state.menuBarSymbolName, accessibilityDescription: nil)
            }
        }
        controller.onDebug = { [weak self] text in
            DispatchQueue.main.async {
                self?.debugState.text = text
            }
        }
        debugConfig.threshold = controller.earOpenThreshold
        // Proactively trigger Automation prompts for Safari/Chrome
        controller.primeAutomationPermissions()
        controller.start()
    }

    private func constructMenu() {
        let menu = NSMenu()
        let enabledItem = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled(_:)), keyEquivalent: "")
        enabledItem.state = controller.isEnabled ? .on : .off
        menu.addItem(enabledItem)
        menu.addItem(NSMenuItem(title: "Show Debug", action: #selector(showDebug), keyEquivalent: "d"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func updateMenu() {
        if let item = statusItem.menu?.item(at: 0) {
            item.state = controller.isEnabled ? .on : .off
        }
    }

    @objc private func toggleEnabled(_ sender: NSMenuItem) {
        controller.isEnabled.toggle()
        updateMenu()
    }

    @objc private func showDebug() {
        if debugWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 320),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.center()
            window.title = "Gaze Debug"
            window.contentView = NSHostingView(
                rootView: DebugView(
                    state: debugState,
                    config: debugConfig,
                    onThresholdChange: { [weak self] value in
                        self?.controller.earOpenThreshold = value
                    }
                )
            )
            debugWindow = window
        }
        debugWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

extension GazeController.State {
    var menuBarSymbolName: String {
        switch self {
        case .idle: return "eye.slash"
        case .looking: return "eye"
        case .away: return "eye.trianglebadge.exclamationmark"
        }
    }
}
