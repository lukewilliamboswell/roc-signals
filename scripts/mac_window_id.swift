// Reports the on-screen window of one process so a capture names a single
// window instead of a region of whoever's desktop is running the review.
import CoreGraphics
import Foundation

let owner = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
guard
    !owner.isEmpty,
    let windows = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
else {
    FileHandle.standardError.write(Data("usage: mac_window_id <process name>\n".utf8))
    exit(64)
}

for window in windows {
    guard
        (window[kCGWindowOwnerName as String] as? String) == owner,
        let number = window[kCGWindowNumber as String] as? Int,
        let bounds = window[kCGWindowBounds as String] as? [String: Any],
        let width = bounds["Width"] as? Double, let height = bounds["Height"] as? Double,
        width > 1, height > 1
    else { continue }
    print("\(number) \(Int(width)) \(Int(height))")
    exit(0)
}
FileHandle.standardError.write(Data("no on-screen window owned by \(owner)\n".utf8))
exit(1)
