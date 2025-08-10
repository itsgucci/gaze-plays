//
//  YouTubeController.swift
//  pwyl
//
//  Created by Eric Weinert on 8/9/25.
//

import Foundation
import AppKit
import ApplicationServices

final class YouTubeController {

    enum ControlMode { case safariJS, systemMediaKey }
    var mode: ControlMode = .systemMediaKey

    var onDebug: ((String) -> Void)?

    private func log(_ message: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "[YouTubeController] \(ts) - \(message)"
        print(line)
        onDebug?(line)
    }

    // Throttle to avoid double-toggles (play then immediate pause)
    private var lastMediaKeySentAt: Date = .distantPast
    private let mediaKeyMinInterval: TimeInterval = 1.5

    func playIfYouTubeFrontmost() {
        log("playIfYouTubeFrontmost: attempting")
        switch mode {
        case .safariJS:
            runForSafari(js: "var v=document.querySelector('video'); if(v){ v.play(); 'played' } else { 'no-video' }")
        case .systemMediaKey:
            sendSystemPlayPause()
        }
    }

    func pauseIfYouTubeFrontmost() {
        log("pauseIfYouTubeFrontmost: attempting")
        switch mode {
        case .safariJS:
            runForSafari(js: "var v=document.querySelector('video'); if(v){ v.pause(); 'paused' } else { 'no-video' }")
        case .systemMediaKey:
            sendSystemPlayPause()
        }
    }

    /// Send a harmless Apple Event to trigger Automation permission prompts for Safari.
    func primeAutomationPermissions() {
        guard mode == .safariJS else { return }
        let safariPing = """
        set isRunning to (application id "com.apple.Safari" is running)
        if isRunning then
            tell application id "com.apple.Safari"
                try
                    set _ to (count of windows)
                end try
            end tell
        end if
        return "prime:safari running=" & isRunning
        """
        _ = runAppleScript(safariPing)
    }

    // MARK: - System media key (Accessibility)

    private func sendSystemPlayPause() {
        let now = Date()
        if now.timeIntervalSince(lastMediaKeySentAt) < mediaKeyMinInterval {
            log("system media key: skipped (throttled)")
            return
        }
        lastMediaKeySentAt = now
        // Requires Accessibility to post HID events
        if !AXIsProcessTrusted() {
            log("Accessibility permission missing. Enable pwyl in System Settings → Privacy & Security → Accessibility.")
        }
        // NX_KEYTYPE_PLAY = 16. Post key down/up as systemDefined events.
        let key: Int32 = 16
        func post(_ isDown: Bool) {
            let flags: NSEvent.ModifierFlags = isDown ? NSEvent.ModifierFlags(rawValue: 0xA00) : NSEvent.ModifierFlags(rawValue: 0xB00)
            let eventData = Int((key << 16) | ((isDown ? 0xA : 0xB) << 8))
            if let e = NSEvent.otherEvent(with: .systemDefined,
                                           location: .zero,
                                           modifierFlags: flags,
                                           timestamp: 0,
                                           windowNumber: 0,
                                           context: nil,
                                           subtype: 8,
                                           data1: eventData,
                                           data2: 0) {
                e.cgEvent?.post(tap: .cghidEventTap)
            }
        }
        post(true)
        usleep(30_000)
        post(false)
        log("system media key: play/pause sent")
    }

    // MARK: - AppleScript control (Developer setting required)

    private func runForSafari(js: String) {
        let escaped = js.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        if (application id \"com.apple.Safari\" is running) is false then return \"safari:not-running\"
        tell application id \"com.apple.Safari\" to activate
        delay 0.1
        tell application id \"com.apple.Safari\"
            set summary to \"safari:unknown\"
            if (count of windows) = 0 then return \"safari:no-window\"
            set theURL to \"\"
            set candidateTab to missing value
            try
                set frontTab to current tab of front window
                set frontURL to URL of frontTab
                if frontURL contains \"youtube.com\" or frontURL contains \"youtu.be\" or frontURL contains \"music.youtube.com\" then
                    set candidateTab to frontTab
                    set theURL to frontURL
                end if
            end try
            if candidateTab is missing value then
                repeat with w in windows
                    repeat with t in (tabs of w)
                        try
                            set u to URL of t
                            if u contains \"youtube.com\" or u contains \"youtu.be\" or u contains \"music.youtube.com\" then
                                set candidateTab to t
                                set theURL to u
                                exit repeat
                            end if
                        end try
                    end repeat
                    if candidateTab is not missing value then exit repeat
                end repeat
            end if
            if candidateTab is missing value then
                set summary to \"safari:no-youtube-tab\"
            else
                try
                    set resultJs to do JavaScript \"\(escaped)\" in candidateTab
                    set summary to \"safari:yt exec result=\" & resultJs
                on error errMsg number errNum
                    if errNum is -1723 then
                        set summary to \"safari:error dev-setting-disabled (-1723) url=\" & theURL
                    else
                        set summary to \"safari:error \" & errMsg & \" (\" & errNum & \") url=\" & theURL
                    end if
                end try
            end if
            return summary
        end tell
        """
        _ = runAppleScript(script)
    }

    @discardableResult
    private func runAppleScript(_ source: String) -> Bool {
        let executeOnMain: () -> Void = { [weak self] in
            guard let scpt = NSAppleScript(source: source) else {
                self?.log("AppleScript build failed")
                return
            }
            var err: NSDictionary?
            let desc = scpt.executeAndReturnError(&err)
            if let s = desc.stringValue, s.isEmpty == false {
                self?.log("AS OK: \(s)")
            }
            if let err = err as? [String: Any] {
                let message = (err[NSAppleScript.errorMessage] as? String) ?? String(describing: err)
                let number = (err[NSAppleScript.errorNumber] as? NSNumber)?.intValue
                self?.log("AS ERROR: \(message)\(number != nil ? " [code \(number!)]" : "")")
            }
        }
        DispatchQueue.main.async { executeOnMain() }
        return true
    }
}
