import AppKit

@main
struct SpotifySwitcherApp {
    static func main() {
        print("🔥 Entered Main.swift")
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
