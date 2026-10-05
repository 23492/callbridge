import Cocoa
import SwiftUI
import Foundation
import CryptoKit
import AVFoundation
import Security

// MARK: - Version & Update Config

let appVersion = "2.1.0-beta.1"
/// Release channel this binary was built for ("stable" or "beta"); set by build-release.sh.
let appBuildChannel = "beta"
let updatePublicKey = "ylneUBx4bMQxiX9rsDkKtya1InBHUzlbfsEOwpvFA2E="

// MARK: - App Entry Point

debugLog("=== CallBridge starting ===")
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
