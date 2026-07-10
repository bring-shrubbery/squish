import CoreServices
import Foundation

public final class FileSystemEventMonitor: @unchecked Sendable {
    public typealias Handler = @Sendable ([URL]) -> Void

    private let paths: [URL]
    private let latency: TimeInterval
    private let handler: Handler
    private let queue = DispatchQueue(label: "com.squish.filesystem-events", qos: .userInitiated)
    private var stream: FSEventStreamRef?
    private var pendingPaths = Set<String>()
    private var deliveryWorkItem: DispatchWorkItem?

    public init(paths: [URL], latency: TimeInterval = 0.12, handler: @escaping Handler) {
        self.paths = paths
        self.latency = latency
        self.handler = handler
    }

    deinit {
        stop()
    }

    @discardableResult
    public func start() -> Bool {
        guard !paths.isEmpty else { return false }
        var started = false
        queue.sync {
            guard stream == nil else {
                started = true
                return
            }

            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passUnretained(self).toOpaque(),
                retain: nil,
                release: nil,
                copyDescription: nil
            )
            let watchedPaths = paths.map(\.path) as CFArray
            let flags = FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagWatchRoot
                | kFSEventStreamCreateFlagNoDefer
            )

            guard let created = FSEventStreamCreate(
                kCFAllocatorDefault,
                squishFileSystemEventCallback,
                &context,
                watchedPaths,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                latency,
                flags
            ) else { return }

            stream = created
            FSEventStreamSetDispatchQueue(created, queue)
            started = FSEventStreamStart(created)
            if !started {
                FSEventStreamInvalidate(created)
                FSEventStreamRelease(created)
                stream = nil
            }
        }
        return started
    }

    public func stop() {
        queue.sync {
            deliveryWorkItem?.cancel()
            deliveryWorkItem = nil
            pendingPaths.removeAll()
            guard let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    fileprivate func receive(paths: [String]) {
        pendingPaths.formUnion(paths)
        deliveryWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.pendingPaths.isEmpty else { return }
            let urls = self.pendingPaths.map { URL(fileURLWithPath: $0) }
            self.pendingPaths.removeAll(keepingCapacity: true)
            self.handler(urls)
        }
        deliveryWorkItem = workItem
        queue.asyncAfter(deadline: .now() + latency, execute: workItem)
    }
}

private let squishFileSystemEventCallback: FSEventStreamCallback = {
    _, clientInfo, eventCount, eventPaths, _, _ in
    guard let clientInfo else { return }
    let monitor = Unmanaged<FileSystemEventMonitor>.fromOpaque(clientInfo).takeUnretainedValue()
    let array = unsafeBitCast(eventPaths, to: NSArray.self)
    let paths = (array as? [String]) ?? []
    if eventCount > 0 { monitor.receive(paths: paths) }
}
