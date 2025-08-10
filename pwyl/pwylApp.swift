//
//  pwylApp.swift
//  pwyl
//
//  Created by Eric Weinert on 8/9/25.
//

import SwiftUI

@main
struct pwylApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        Settings { EmptyView() } // no visible windows
    }
}
