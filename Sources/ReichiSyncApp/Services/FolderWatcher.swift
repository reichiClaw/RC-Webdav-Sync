import Foundation
import CoreServices

/// Beobachtet den lokalen Synchronisierungsordner mit FSEvents und meldet
/// Änderungen gebündelt nach einer Beruhigungszeit.
final class FolderWatcher: @unchecked Sendable {
    private final class CallbackContext {
        weak var watcher: FolderWatcher?

        init(watcher: FolderWatcher) {
            self.watcher = watcher
        }
    }

    private var stream: FSEventStreamRef?
    private var callbackContext: CallbackContext?
    private let queue = DispatchQueue(label: "de.reichi.sync.fsevents", qos: .utility)
    private let debounce: TimeInterval
    private let ignoredPrefix: String
    private var pending: DispatchWorkItem?
    private let lock = NSLock()
    private let onChange: @Sendable () -> Void
    private let root: URL

    init(root: URL, debounce: TimeInterval = 2.0, onChange: @escaping @Sendable () -> Void) {
        self.root = root
        self.debounce = debounce
        self.onChange = onChange
        self.ignoredPrefix = root.standardizedFileURL.path + "/.reichi-sync"
    }

    deinit {
        stop()
    }

    @discardableResult
    func start() -> Bool {
        guard stream == nil else { return true }
        let holder = CallbackContext(watcher: self)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(holder).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                return UnsafeRawPointer(Unmanaged<CallbackContext>.fromOpaque(info).retain().toOpaque())
            },
            release: { info in
                guard let info else { return }
                Unmanaged<CallbackContext>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            guard let watcher = Unmanaged<CallbackContext>.fromOpaque(info).takeUnretainedValue().watcher else { return }
            guard let paths = Unmanaged<NSArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] else {
                watcher.scheduleNotification()
                return
            }
            let relevant = paths.prefix(count).contains { !$0.hasPrefix(watcher.ignoredPrefix) }
            if relevant { watcher.scheduleNotification() }
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagIgnoreSelf)
        guard let created = FSEventStreamCreate(nil, callback, &context, [root.path] as CFArray, FSEventStreamEventId(bitPattern: -1) /* kFSEventStreamEventIdSinceNow */, 1.0, flags) else {
            return false
        }
        callbackContext = holder
        stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            stream = nil
            callbackContext = nil
            return false
        }
        return true
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        callbackContext = nil
        lock.lock(); pending?.cancel(); pending = nil; lock.unlock()
    }

    private func scheduleNotification() {
        lock.lock()
        pending?.cancel()
        let item = DispatchWorkItem { [onChange] in onChange() }
        pending = item
        lock.unlock()
        queue.asyncAfter(deadline: .now() + debounce, execute: item)
    }
}
