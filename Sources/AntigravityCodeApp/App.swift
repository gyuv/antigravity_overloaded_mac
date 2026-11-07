import SwiftUI
import AppKit
import AntigravityCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare SwiftPM executable (outside an .app bundle).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct AntigravityCodeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = SessionViewModel()

    var body: some Scene {
        WindowGroup("Antigravity Code") {
            MainView()
                .environmentObject(model)
                .frame(minWidth: 1000, minHeight: 640)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Folder…") { model.chooseFolder() }.keyboardShortcut("o")
                Button("New Conversation") { model.newConversation() }.keyboardShortcut("n")
            }
            CommandMenu("Agent") {
                Button("Stop") { model.stop() }.keyboardShortcut(".", modifiers: .command)
                Divider()
                Button("Install ‘agcode’ Command Line Tool…") { CLIInstaller.install() }
            }
        }
        Settings {
            SettingsView().environmentObject(model)
        }
    }
}

enum CLIInstaller {
    /// Symlinks Contents/Helpers/agcode into /usr/local/bin (asks for admin rights via AppleScript).
    static func install() {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/agcode").path
        guard FileManager.default.isExecutableFile(atPath: helper) else {
            alert("The agcode helper was not found in the app bundle.\nBuild with `make app` to bundle it.")
            return
        }
        let shell = "mkdir -p /usr/local/bin && ln -sf '\(helper)' /usr/local/bin/agcode"
        let script = "do shell script \"\(shell)\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let e = error { alert("Install failed: \(e[NSAppleScript.errorMessage] ?? e)") }
        else { alert("Installed. Run `agcode` in Terminal or iTerm2.") }
    }
    static func alert(_ text: String) {
        let a = NSAlert(); a.messageText = "agcode"; a.informativeText = text; a.runModal()
    }
}
