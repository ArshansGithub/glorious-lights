import AppKit

// Menu-bar-only agent: no dock icon, no main window, no menu bar of its own.
// Set before the app finishes launching so no dock tile ever appears.
let application = NSApplication.shared
application.setActivationPolicy(.accessory)

let delegate = AppDelegate()
application.delegate = delegate
application.run()
