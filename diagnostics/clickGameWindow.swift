import AppKit
import ApplicationServices

// Single game-window click. Run only after explicit authorization for CGEvent.
func fail(_ text: String) -> Never { fputs(text + "\n", stderr); exit(1) }
let a = CommandLine.arguments
guard a.count == 5, let pid = Int32(a[1]), let wid = UInt32(a[2]),
      let x = Double(a[3]), let y = Double(a[4]), x.isFinite, y.isFinite
else { fail("Expected PID, window ID, window-relative x and y") }
guard AXIsProcessTrusted() else { fail("Accessibility unavailable; no prompt requested") }
let check = Process(), pipe = Pipe()
check.executableURL = URL(fileURLWithPath: "/bin/ps")
check.arguments = ["-p", String(pid), "-o", "command="]
check.standardOutput = pipe; try check.run(); check.waitUntilExit()
let command = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
guard check.terminationStatus == 0, command.hasPrefix("C:\\Games\\IdentityV\\dwrg.exe "),
      let app = NSRunningApplication(processIdentifier: pid)
else { fail("Exact Identity V process no longer present") }
func bounds() -> CGRect {
    guard let all = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
          let w = all.first(where: {
              ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == wid &&
              ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid &&
              ($0[kCGWindowName as String] as? String) == "第五人格" &&
              ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
          }), let raw = w[kCGWindowBounds as String] as? [String: Any],
          let b = CGRect(dictionaryRepresentation: raw as CFDictionary),
          x >= 0, y >= 0, x < b.width, y < b.height
    else { fail("Window identity or coordinates no longer valid") }
    return b
}
_ = bounds()
guard app.activate(options: [.activateAllWindows]) else { fail("Activation failed") }
let accessibilityApp = AXUIElementCreateApplication(pid)
_ = AXUIElementSetAttributeValue(accessibilityApp, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
var windowValue: CFTypeRef?
if AXUIElementCopyAttributeValue(accessibilityApp, kAXWindowsAttribute as CFString, &windowValue) == .success,
   let windows = windowValue as? [AXUIElement] {
    for window in windows { _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString) }
}
let limit = Date().addingTimeInterval(1)
while NSWorkspace.shared.frontmostApplication?.processIdentifier != pid && Date() < limit {
    RunLoop.current.run(until: Date().addingTimeInterval(0.02))
}
guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { fail("Game is not foreground") }
let b = bounds(), point = CGPoint(x: b.minX + x, y: b.minY + y)
guard let source = CGEventSource(stateID: .combinedSessionState),
      let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left),
      let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
      let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
else { fail("Event creation failed") }
move.post(tap: .cghidEventTap); down.post(tap: .cghidEventTap)
usleep(50_000); up.post(tap: .cghidEventTap)
print("event_posted; verify screenshot before another action")
