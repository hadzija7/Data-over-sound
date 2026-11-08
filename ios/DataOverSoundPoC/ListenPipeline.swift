import AVFoundation
import Foundation

/// Moves microphone buffers off the real-time audio thread and runs the demodulator on a serial queue.
///
/// The tap callback only copies samples and enqueues them; FFT work never runs on the audio thread.
/// If processing falls behind, chunks are dropped and the receiver is reset, because a gap in the
/// audio would otherwise corrupt the frame being received.
final class ListenPipeline: @unchecked Sendable {
    private static let maximumQueuedChunks = 32

    private let queue = DispatchQueue(label: "DataOverSoundPoC.listen", qos: .userInitiated)
    private let receiver: FrameReceiver
    private let onEvents: @Sendable ([ReceiverEvent]) -> Void

    private let lock = NSLock()
    private var cancelled = false
    private var queuedChunks = 0
    private var droppedAudio = false

    init(configuration: FSKConfiguration, sampleRate: Double, onEvents: @escaping @Sendable ([ReceiverEvent]) -> Void) throws {
        receiver = try FrameReceiver(configuration: configuration, sampleRate: sampleRate)
        self.onEvents = onEvents
    }

    /// Called on the audio render thread.
    func enqueue(_ buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let channels = buffer.floatChannelData else { return }
        let stride = buffer.stride
        let channel = channels[0]
        let samples: [Float]
        if stride == 1 {
            samples = Array(UnsafeBufferPointer(start: channel, count: frames))
        } else {
            samples = (0..<frames).map { channel[$0 * stride] }
        }

        lock.lock()
        if cancelled || queuedChunks >= Self.maximumQueuedChunks {
            droppedAudio = droppedAudio || !cancelled
            lock.unlock()
            return
        }
        queuedChunks += 1
        lock.unlock()

        queue.async { [self] in
            lock.lock()
            queuedChunks -= 1
            let isCancelled = cancelled
            let mustReset = droppedAudio
            droppedAudio = false
            lock.unlock()
            guard !isCancelled else { return }

            if mustReset { receiver.reset() }
            let events = receiver.process(samples)
            if !events.isEmpty { onEvents(events) }
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}
