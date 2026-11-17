import CoreServices
import Foundation

@MainActor
final class UsageLogWatcher {
    private var stream: FSEventStreamRef?
    private var watched: [String] = []
    private var rootChanged = false
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    func updateRoots() {
        let roots = Provider.allCases.flatMap { LocalUsageReader.roots(for: $0) }
            .map(\.path)
            .filter { FileManager.default.fileExists(atPath: $0) }
        guard rootChanged || roots != watched || (!roots.isEmpty && stream == nil) else { return }

        stop()
        guard !roots.isEmpty else { return }
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot
        )
        guard let stream = FSEventStreamCreate(
            nil, { _, info, count, paths, flags, _ in
                guard let info else { return }
                let names = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
                let changedRoot = (0..<count).contains {
                    flags[$0] & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0
                }
                let needsRescan = (0..<count).contains {
                    flags[$0] & FSEventStreamEventFlags(
                        kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged
                    ) != 0
                }
                let changedDirectory = (0..<count).contains {
                    let flag = flags[$0]
                    return flag & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0 &&
                        flag & FSEventStreamEventFlags(
                            kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved |
                            kFSEventStreamEventFlagItemRenamed
                        ) != 0
                }
                guard needsRescan || changedDirectory || names.contains(where: { $0.hasSuffix(".jsonl") }) else { return }
                MainActor.assumeIsolated {
                    let watcher = Unmanaged<UsageLogWatcher>.fromOpaque(info).takeUnretainedValue()
                    watcher.rootChanged = watcher.rootChanged || changedRoot
                    watcher.onChange()
                }
            }, &context, roots as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1, flags
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        if FSEventStreamStart(stream) {
            watched = roots
            self.stream = stream
        } else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        watched = []
        rootChanged = false
    }
}
