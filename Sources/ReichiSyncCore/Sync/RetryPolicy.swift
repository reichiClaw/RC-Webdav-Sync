import Foundation

/// Exponentielles Backoff mit Obergrenze und leichtem Jitter.
public struct RetryPolicy: Sendable {
    public var baseDelay: TimeInterval
    public var maxDelay: TimeInterval
    public private(set) var failureCount = 0

    public init(baseDelay: TimeInterval = 5, maxDelay: TimeInterval = 300) {
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
    }

    public mutating func recordFailure() -> TimeInterval {
        failureCount += 1
        let exponent = min(failureCount - 1, 10)
        let raw = baseDelay * pow(2.0, Double(exponent))
        let capped = min(raw, maxDelay)
        let jitter = capped * Double.random(in: -0.1...0.1)
        return max(1, capped + jitter)
    }

    public mutating func reset() {
        failureCount = 0
    }
}

/// Schutz vor auffällig großen Löschmengen.
public struct DeletionGuard: Sendable {
    public var threshold: Int
    public var fraction: Double

    public init(threshold: Int = 25, fraction: Double = 0.2) {
        self.threshold = max(1, threshold)
        self.fraction = min(1, max(0, fraction))
    }

    /// `true`, wenn die Löschungen vor der Ausführung bestätigt werden müssen.
    public func requiresConfirmation(deletionImpact: Int, baselineCount: Int, localItemCount: Int) -> Bool {
        if deletionImpact == 0 { return false }
        // Lokaler Ordner plötzlich leer, obwohl ein Bestand bekannt war: immer nachfragen.
        if localItemCount == 0 && baselineCount > 0 { return true }
        if baselineCount == 0 { return true }
        // Die beiden Grenzen sind unabhängig: Eine große absolute Anzahl ODER ein
        // großer Anteil des bekannten Bestands muss bestätigt werden.
        return deletionImpact >= threshold || Double(deletionImpact) / Double(baselineCount) > fraction
    }
}
