import AppKit
import Darwin

// Signal handlers to restore native Cmd+Tab on crash/quit
// SIGTERM: quit/force-quit from Activity Monitor
// SIGTRAP: crash in swift code
// SIGKILL cannot be intercepted
[SIGTERM, SIGINT, SIGTRAP].forEach { sig in
    signal(sig) { _ in
        emergencyExit()
    }
}

// Intercept uncaught Objective-C exceptions
NSSetUncaughtExceptionHandler { _ in
    emergencyExit()
}

private func emergencyExit() {
    setNativeCommandTabEnabled(true)
    exit(0)
}

// Diagnostic mode: print the computed app list with a per-app verdict and exit,
// without registering hotkeys or touching the native Cmd+Tab.
if CommandLine.arguments.contains("--list-apps") {
    AppListProvider.printAppListDiagnostic()
    exit(0)
}

// Create and run the application
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
