import Foundation
import CoreServices

/// Thin wrapper over FSEventStream. Delivers batches of changed file paths on a background queue.
public final class FSEventsWatcher: @unchecked Sendable {
    private let paths: [String]
    private let onChange: @Sendable ([String]) -> Void
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "gitunia.fsevents")

    public init(paths: [String], onChange: @escaping @Sendable ([String]) -> Void) {
        self.paths = paths
        self.onChange = onChange
    }

    deinit { stop() }

    public func start() {
        guard stream == nil, !paths.isEmpty else { return }
        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue()
            // eventPaths is documented as a CFArray of CFString when kFSEventStreamCreateFlagUseCFTypes
            // is not set FSEventStreamCreate actually still hands back a raw `const void **` (char*[]) buffer.
            // Deviation from brief: bind it as a C string array instead of `unsafeBitCast(..., to: NSArray.self)`,
            // which is not valid for the non-CFTypes callback shape and would crash/misbehave under Swift 6.
            let cPaths = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            var paths: [String] = []
            paths.reserveCapacity(count)
            for i in 0..<count {
                paths.append(String(cString: cPaths[i]))
            }
            watcher.onChange(paths)
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(nil, callback, &context, paths as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2, flags) else { return }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
    }

    public func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }
}
