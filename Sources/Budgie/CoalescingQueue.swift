import Foundation

/// Collects producer work into batches while guaranteeing that at most one
/// consumer drain is scheduled. A fixed capacity prevents a slow consumer from
/// retaining an unbounded number of audio buffers.
final class CoalescingQueue<Element>: @unchecked Sendable {
    enum EnqueueResult: Equatable {
        case scheduleDrain
        case queued
        case rejected
    }

    struct Batch {
        let elements: [Element]
        let didOverflow: Bool
    }

    private let capacity: Int
    private let lock = NSLock()
    private var elements: [Element] = []
    private var drainScheduled = false
    private var didOverflow = false

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        elements.reserveCapacity(capacity)
    }

    func enqueue(_ element: Element) -> EnqueueResult {
        lock.lock()
        defer { lock.unlock() }

        guard elements.count < capacity else {
            didOverflow = true
            return .rejected
        }

        elements.append(element)
        guard !drainScheduled else { return .queued }
        drainScheduled = true
        return .scheduleDrain
    }

    func takeBatch() -> Batch {
        lock.lock()
        defer { lock.unlock() }

        let batch = Batch(elements: elements, didOverflow: didOverflow)
        elements.removeAll(keepingCapacity: true)
        didOverflow = false
        if batch.elements.isEmpty {
            drainScheduled = false
        }
        return batch
    }

    func reset() {
        lock.lock()
        elements.removeAll(keepingCapacity: true)
        didOverflow = false
        drainScheduled = false
        lock.unlock()
    }
}
