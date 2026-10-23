import AppKit
import SwiftUI

/// Entry point. `--snapshot` renders the window offscreen and exits without
/// ever showing a window; otherwise the normal SwiftUI app runs.
@main
enum Launcher {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--snapshot") || args.contains("--bench") || args.contains("--selftest") {
            SnapshotRunner.run(args)
            return
        }
        VantaStudioApp.main()
    }
}
