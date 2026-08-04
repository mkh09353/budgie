/// Keeps Live dictation responsive even when the machine is busy. The audio
/// queue is intentionally a latency budget, not a lossless recording buffer:
/// once it fills, newer speech is more useful than audio that is already late.
enum StreamingRuntimePolicy {
    static let audioTapBufferFrames = 4_096
    static let maximumPendingBufferCount = 4
    static let maximumPendingAudioSeconds = 0.35
    static let inferenceThreadCount = 4

    static func pendingBufferLimit(sampleRate: Double, frameCount: Int) -> Int {
        guard sampleRate > 0, frameCount > 0 else { return 1 }
        let count = Int(maximumPendingAudioSeconds * sampleRate / Double(frameCount))
        return min(maximumPendingBufferCount, max(1, count))
    }
}
