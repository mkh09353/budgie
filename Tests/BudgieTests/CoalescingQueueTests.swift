import XCTest
@testable import Budgie

final class CoalescingQueueTests: XCTestCase {
    func testCoalescesPendingElementsIntoOneScheduledDrain() {
        let queue = CoalescingQueue<Int>(capacity: 4)

        XCTAssertEqual(queue.enqueue(1), .scheduleDrain)
        XCTAssertEqual(queue.enqueue(2), .queued)
        XCTAssertEqual(queue.enqueue(3), .queued)

        let firstBatch = queue.takeBatch()
        XCTAssertEqual(firstBatch.elements, [1, 2, 3])
        XCTAssertFalse(firstBatch.didOverflow)
        XCTAssertTrue(queue.takeBatch().elements.isEmpty)

        XCTAssertEqual(queue.enqueue(4), .scheduleDrain)
    }

    func testKeepsNewestWorkPastCapacityAndReportsOverflowToDrain() {
        let queue = CoalescingQueue<Int>(capacity: 2)

        XCTAssertEqual(queue.enqueue(1), .scheduleDrain)
        XCTAssertEqual(queue.enqueue(2), .queued)
        XCTAssertEqual(queue.enqueue(3), .replacedOldest)

        let batch = queue.takeBatch()
        XCTAssertEqual(batch.elements, [2, 3])
        XCTAssertTrue(batch.didOverflow)
    }

    func testRuntimeLimitTrimsPreviouslyQueuedWork() {
        let queue = CoalescingQueue<Int>(capacity: 4)

        XCTAssertEqual(queue.enqueue(1), .scheduleDrain)
        XCTAssertEqual(queue.enqueue(2), .queued)
        XCTAssertEqual(queue.enqueue(3), .queued)
        XCTAssertEqual(queue.enqueue(4, limit: 2), .replacedOldest)

        let batch = queue.takeBatch()
        XCTAssertEqual(batch.elements, [3, 4])
        XCTAssertTrue(batch.didOverflow)
    }

    func testConcurrentProducersScheduleOnlyOneDrain() {
        let capacity = 64
        let producerCount = 256
        let queue = CoalescingQueue<Int>(capacity: capacity)
        let resultLock = NSLock()
        var results: [CoalescingQueue<Int>.EnqueueResult] = []

        DispatchQueue.concurrentPerform(iterations: producerCount) { value in
            let result = queue.enqueue(value)
            resultLock.lock()
            results.append(result)
            resultLock.unlock()
        }

        XCTAssertEqual(results.filter { $0 == .scheduleDrain }.count, 1)
        XCTAssertEqual(results.filter { $0 == .queued }.count, capacity - 1)
        XCTAssertEqual(
            results.filter { $0 == .replacedOldest }.count,
            producerCount - capacity
        )

        let batch = queue.takeBatch()
        XCTAssertEqual(batch.elements.count, capacity)
        XCTAssertTrue(batch.didOverflow)
    }

    func testResetClearsPendingWorkAndAllowsANewDrain() {
        let queue = CoalescingQueue<Int>(capacity: 2)

        XCTAssertEqual(queue.enqueue(1), .scheduleDrain)
        queue.reset()

        XCTAssertTrue(queue.takeBatch().elements.isEmpty)
        XCTAssertEqual(queue.enqueue(2), .scheduleDrain)
    }
}
