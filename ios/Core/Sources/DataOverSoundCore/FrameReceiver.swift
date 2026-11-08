public enum ReceiverEvent: Equatable, Sendable {
    case frameStarted
    case messageReceived(String)
    case frameRejected(FrameError)
}

/// Streaming demodulator. Feed microphone samples of any chunk size; get decoded events back.
///
/// Pipeline: sliding Hann windows (hop = window/4) → per-window tone classification → a tone is
/// accepted once `minimumRunWindows` consecutive windows agree → frame state machine.
///
/// Not thread-safe: call `process` and `reset` from one serial queue.
public final class FrameReceiver {
    public let configuration: FSKConfiguration
    public let sampleRate: Double

    private enum State {
        case idle
        case receiving(nibbles: [UInt8], awaitingSeparator: Bool)
    }

    private let detector: ToneDetector
    private let timeoutWindows: Int
    private let maximumNibbles: Int

    private var buffer: [Float] = []
    private var readIndex = 0
    private var currentLabel: ToneSymbol?
    private var runLength = 0
    private var state: State = .idle
    private var windowsSinceAcceptedTone = 0

    public init(configuration: FSKConfiguration = .standard, sampleRate: Double, analyzer: SpectrumAnalyzer? = nil) throws {
        self.configuration = configuration
        self.sampleRate = sampleRate
        self.detector = try ToneDetector(configuration: configuration, sampleRate: sampleRate, analyzer: analyzer)
        self.timeoutWindows = max(1, Int((configuration.frameTimeoutDuration * sampleRate / Double(detector.hopSize)).rounded(.up)))
        self.maximumNibbles = 2 * FrameCodec.frameSize(payloadLength: configuration.maxPayloadBytes)
        buffer.reserveCapacity(detector.windowSize * 8)
    }

    public var windowSize: Int { detector.windowSize }
    public var hopSize: Int { detector.hopSize }

    public var isReceivingFrame: Bool {
        if case .receiving = state { return true }
        return false
    }

    /// Drops buffered audio and any partially received frame (e.g. after an audio dropout).
    public func reset() {
        buffer.removeAll(keepingCapacity: true)
        readIndex = 0
        currentLabel = nil
        runLength = 0
        state = .idle
        windowsSinceAcceptedTone = 0
    }

    public func process<C: Collection>(_ samples: C) -> [ReceiverEvent] where C.Element == Float {
        guard !samples.isEmpty else { return [] }
        buffer.append(contentsOf: samples)
        var events: [ReceiverEvent] = []
        let window = detector.windowSize
        while buffer.count - readIndex >= window {
            let label = detector.classify(buffer[readIndex..<(readIndex + window)])
            readIndex += detector.hopSize
            consume(label, into: &events)
        }
        if readIndex >= window * 4 {
            buffer.removeFirst(readIndex)
            readIndex = 0
        }
        return events
    }

    private func consume(_ label: ToneSymbol?, into events: inout [ReceiverEvent]) {
        if label == currentLabel {
            runLength += 1
        } else {
            currentLabel = label
            runLength = 1
        }
        if let label, runLength == configuration.minimumRunWindows {
            accept(label, into: &events)
            return
        }
        if isReceivingFrame {
            windowsSinceAcceptedTone += 1
            if windowsSinceAcceptedTone > timeoutWindows {
                state = .idle
                events.append(.frameRejected(.timeout))
            }
        }
    }

    private func accept(_ symbol: ToneSymbol, into events: inout [ReceiverEvent]) {
        windowsSinceAcceptedTone = 0
        switch state {
        case .idle:
            if symbol == .start {
                state = .receiving(nibbles: [], awaitingSeparator: false)
                events.append(.frameStarted)
            }
        case .receiving(var nibbles, let awaitingSeparator):
            switch symbol {
            case .start:
                // A preamble split by a glitch is harmless; a preamble after data means a new transmission.
                if !nibbles.isEmpty {
                    events.append(.frameRejected(.unexpectedRestart))
                    events.append(.frameStarted)
                    state = .receiving(nibbles: [], awaitingSeparator: false)
                }
            case .separator:
                state = .receiving(nibbles: nibbles, awaitingSeparator: false)
            case .data(let nibble):
                // A second data run before a separator is the same tone re-confirmed after a glitch
                // (or a lost separator, which the length/CRC check will catch).
                guard !awaitingSeparator else { return }
                nibbles.append(nibble)
                if let error = earlyError(nibbles) {
                    state = .idle
                    events.append(.frameRejected(error))
                } else {
                    state = .receiving(nibbles: nibbles, awaitingSeparator: true)
                }
            case .end:
                state = .idle
                events.append(finish(nibbles))
            }
        }
    }

    private func earlyError(_ nibbles: [UInt8]) -> FrameError? {
        if nibbles.count == 2 * FrameCodec.headerSize {
            let version = nibbles[0] << 4 | nibbles[1]
            let length = Int(nibbles[2] << 4 | nibbles[3])
            do {
                try FrameCodec.validateHeader(version: version, declaredLength: length, maxPayloadBytes: configuration.maxPayloadBytes)
            } catch let error as FrameError {
                return error
            } catch {
                return .frameTooShort(bytes: nibbles.count / 2)
            }
        }
        if nibbles.count > maximumNibbles {
            return .lengthMismatch(expectedFrameBytes: maximumNibbles / 2, actualFrameBytes: (nibbles.count + 1) / 2)
        }
        return nil
    }

    private func finish(_ nibbles: [UInt8]) -> ReceiverEvent {
        do {
            let frame = try FrameCodec.bytes(fromNibbles: nibbles)
            return .messageReceived(try FrameCodec.decodeMessage(frame: frame, maxPayloadBytes: configuration.maxPayloadBytes))
        } catch let error as FrameError {
            return .frameRejected(error)
        } catch {
            return .frameRejected(.invalidUTF8)
        }
    }
}
