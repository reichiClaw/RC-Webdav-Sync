import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Beendet URLSession außerhalb des Threads, auf dem ihr letzter Besitzer
/// freigegeben wird. swift-corelibs-foundation kann einen Client nach dem
/// letzten Callback auf einer internen Delegate-Queue zerstören; ein direktes
/// `invalidateAndCancel()` aus `deinit` würde dann synchron auf dieselbe Queue
/// warten und in libdispatch absichtlich abbrechen.
enum URLSessionLifecycle {
    static func invalidate(_ session: URLSession) {
        #if os(Linux)
        DispatchQueue.global(qos: .utility).async {
            session.invalidateAndCancel()
        }
        #else
        session.invalidateAndCancel()
        #endif
    }
}
