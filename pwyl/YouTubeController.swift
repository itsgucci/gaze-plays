//
//  YouTubeController.swift
//  pwyl
//
//  Created by Eric Weinert on 8/9/25.
//

import Foundation
import AppKit

final class YouTubeController {

    func playIfYouTubeFrontmost() {
        runForSafari(js: "var v=document.querySelector('video'); if(v){ v.play(); }")
        runForChrome(js: "var v=document.querySelector('video'); if(v){ v.play(); }")
    }

    func pauseIfYouTubeFrontmost() {
        runForSafari(js: "var v=document.querySelector('video'); if(v){ v.pause(); }")
        runForChrome(js: "var v=document.querySelector('video'); if(v){ v.pause(); }")
    }

    private func runForSafari(js: String) {
        let escaped = js.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Safari"
            if (count of windows) > 0 then
                set t to current tab of front window
                try
                    set theURL to URL of t
                    if theURL contains "youtube.com" then
                        do JavaScript "\(escaped)" in t
                    end if
                end try
            end if
        end tell
        """
        _ = runAppleScript(script)
    }

    private func runForChrome(js: String) {
        let escaped = js.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Google Chrome"
            if (count of windows) > 0 then
                set t to active tab of front window
                try
                    set theURL to URL of t
                    if theURL contains "youtube.com" then
                        execute javascript "\(escaped)" in t
                    end if
                end try
            end if
        end tell
        """
        _ = runAppleScript(script)
    }

    @discardableResult
    private func runAppleScript(_ source: String) -> Bool {
        let execute: () -> Bool = {
            guard let scpt = NSAppleScript(source: source) else { return false }
            var err: NSDictionary?
            scpt.executeAndReturnError(&err)
            return err == nil
        }
        if Thread.isMainThread { return execute() }
        var result = false
        DispatchQueue.main.sync { result = execute() }
        return result
    }
}
