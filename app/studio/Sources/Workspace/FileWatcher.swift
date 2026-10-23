import Foundation
import CoreServices

/// Recursive file-system watcher (FSEvents). Calls back on the main queue with
/// the set of changed paths, coalesced over `latency` seconds.
final class FileWatcher {
    private var stream: FSEventStreamRef?
    private let callback: (Set<String>) -> Void

    init?(path: String, latency: TimeInterval = 0.25, callback: @escaping (Set<String>) -> Void) {
        self.callback = callback
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                           | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
        let cb: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let me = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let arr = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as NSArray
            var set = Set<String>()
            for i in 0..<count { if let p = arr[i] as? String { set.insert(p) } }
            me.callback(set)
        }
        guard let s = FSEventStreamCreate(nil, cb, &ctx, [path] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else {
            return nil
        }
        stream = s
        FSEventStreamSetDispatchQueue(s, DispatchQueue.main)
        FSEventStreamStart(s)
    }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    deinit { stop() }
}
