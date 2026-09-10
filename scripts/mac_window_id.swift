// Reports the on-screen window belonging to one process id.
//
// The lookup is by pid rather than by process name because several captures
// can run at once from different worktrees, where every example binary shares
// its name with a sibling. It also keeps a capture from ever naming a window
// that belongs to somebody else's application.
import CoreGraphics
import Foundation

guard CommandLine.arguments.count > 1, let pid = Int(CommandLine.arguments[1]) else {
    FileHandle.standardError.write(Data("usage: mac_window_id <pid>\n".utf8))
    exit(64)
}
guard
    let windows = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
else {
    FileHandle.standardError.write(Data("window list unavailable\n".utf8))
    exit(64)
}

for window in windows {
    guard
        (window[kCGWindowOwnerPID as String] as? Int) == pid,
        let number = window[kCGWindowNumber as String] as? Int,
        let bounds = window[kCGWindowBounds as String] as? [String: Any],
        let width = bounds["Width"] as? Double, let height = bounds["Height"] as? Double,
        width > 1, height > 1
    else { continue }
    print("\(number) \(Int(width)) \(Int(height))")
    exit(0)
}
FileHandle.standardError.write(Data("process \(pid) has no on-screen window\n".utf8))
exit(1)
