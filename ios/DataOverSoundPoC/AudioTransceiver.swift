import AVFoundation
import Foundation

struct ReceivedMessage: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let date: Date
}

/// Owns the audio session and engines. Half-duplex: idle, sending, or listening — never both.
@MainActor
final class AudioTransceiver: ObservableObject {
    enum Mode: Equatable {
        case idle
        case sending
        case listening
    }

    enum TransceiverError: LocalizedError {
        case noAudioInput
        case noAudioOutput
        case bufferAllocationFailed

        var errorDescription: String? {
            switch self {
            case .noAudioInput: return "No microphone input is available (the Simulator or a disconnected route?)."
            case .noAudioOutput: return "No audio output is available."
            case .bufferAllocationFailed: return "Could not allocate the audio buffer."
            }
        }
    }

    @Published private(set) var mode: Mode = .idle
    @Published private(set) var status = "Idle"
    @Published private(set) var received: [ReceivedMessage] = []
    @Published private(set) var lastError: String?

    let configuration = FSKConfiguration.standard

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var pipeline: ListenPipeline?
    /// Incremented on every start/stop so late callbacks from a finished operation are ignored.
    private var operationID = 0
    private var observers: [NSObjectProtocol] = []
    private var configurationObserver: NSObjectProtocol?

    init() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .began else { return }
            Task { @MainActor [weak self] in self?.stop(reason: "Stopped: audio was interrupted (call, Siri, alarm…).") }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.stop(reason: "Stopped: the system reset audio services.") }
        })
    }

    func payloadPreview(for text: String) -> (bytes: Int, truncated: Bool) {
        let result = FrameCodec.truncatedUTF8(text, maxBytes: configuration.maxPayloadBytes)
        return (result.bytes.count, result.wasTruncated)
    }

    func send(_ text: String) {
        stop(reason: nil)
        lastError = nil
        let encoded: EncodedMessage
        do {
            encoded = try FrameCodec.encodeMessage(text, configuration: configuration)
        } catch {
            lastError = "Nothing to send: enter a message."
            return
        }

        do {
            try activateSession()
            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            engine.attach(player)
            let sampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
            guard sampleRate > 0, let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
                throw TransceiverError.noAudioOutput
            }
            try configuration.validate(sampleRate: sampleRate)
            engine.connect(player, to: engine.mainMixerNode, format: format)

            let samples = ToneSynthesizer.render(symbols: encoded.symbols, configuration: configuration, sampleRate: sampleRate)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
                  let channel = buffer.floatChannelData?[0] else {
                throw TransceiverError.bufferAllocationFailed
            }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { source in
                channel.update(from: source.baseAddress!, count: source.count)
            }

            observeConfigurationChanges(of: engine)
            engine.prepare()
            try engine.start()

            operationID += 1
            let id = operationID
            player.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack,
                                  completionHandler: Self.playbackCompletion(for: self, id: id))
            player.play()

            self.engine = engine
            self.player = player
            mode = .sending
            let seconds = Double(samples.count) / sampleRate
            status = String(format: "Sending %d bytes (≈%.1f s)%@…", encoded.payload.count, seconds,
                            encoded.wasTruncated ? ", truncated" : "")
        } catch {
            teardown()
            lastError = "Send failed: \(error.localizedDescription)"
        }
    }

    func startListening() async {
        stop(reason: nil)
        lastError = nil
        let requestID = operationID
        guard await requestMicrophonePermission() else {
            lastError = "Microphone access denied. Enable it in Settings › Privacy & Security › Microphone."
            return
        }
        // Another action (or a stop) happened while the permission prompt was showing.
        guard requestID == operationID, mode == .idle else { return }

        do {
            try activateSession()
            let engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw TransceiverError.noAudioInput }

            operationID += 1
            let id = operationID
            let pipeline = try ListenPipeline(configuration: configuration, sampleRate: format.sampleRate,
                                              onEvents: Self.eventHandler(for: self, id: id))
            input.installTap(onBus: 0, bufferSize: 4096, format: format, block: Self.tapBlock(for: pipeline))
            observeConfigurationChanges(of: engine)
            engine.prepare()
            do {
                try engine.start()
            } catch {
                input.removeTap(onBus: 0)
                throw error
            }

            self.engine = engine
            self.pipeline = pipeline
            mode = .listening
            status = String(format: "Listening at %.0f Hz… waiting for start tone", format.sampleRate)
        } catch {
            teardown()
            lastError = "Listen failed: \(error.localizedDescription)"
        }
    }

    func stop() {
        stop(reason: "Stopped")
    }

    func stop(reason: String?) {
        guard mode != .idle else { return }
        teardown()
        if let reason { status = reason }
    }

    func clearReceived() {
        received.removeAll()
    }

    private func finishSending(id: Int) {
        guard id == operationID, mode == .sending else { return }
        teardown()
        status = "Sent"
    }

    private func handle(_ events: [ReceiverEvent], id: Int) {
        guard id == operationID, mode == .listening else { return }
        for event in events {
            switch event {
            case .frameStarted:
                status = "Receiving…"
            case .messageReceived(let text):
                received.insert(ReceivedMessage(text: text, date: Date()), at: 0)
                status = "Received a message. Still listening…"
            case .frameRejected(let error):
                status = "Discarded a damaged transmission (\(Self.describe(error))). Still listening…"
            }
        }
    }

    private func teardown() {
        operationID += 1
        pipeline?.cancel()
        if mode == .listening {
            engine?.inputNode.removeTap(onBus: 0)
        }
        player?.stop()
        engine?.stop()
        removeConfigurationObserver()
        pipeline = nil
        player = nil
        engine = nil
        mode = .idle
        status = "Idle"
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func activateSession() throws {
        let session = AVAudioSession.sharedInstance()
        // .measurement disables voice processing / AGC that would otherwise distort the tones;
        // .defaultToSpeaker is ignored in .measurement mode, so the loudspeaker is forced explicitly below.
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker])
        try? session.setPreferredSampleRate(48_000)
        try session.setActive(true)
        try session.overrideOutputAudioPort(.speaker)
    }

    private func observeConfigurationChanges(of engine: AVAudioEngine) {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.stop(reason: "Stopped: the audio route changed (headphones, Bluetooth…). Try again.")
            }
        }
    }

    private func removeConfigurationObserver() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = nil
    }

    private func requestMicrophonePermission() async -> Bool {
        if #available(iOS 17.0, *) {
            return await AVAudioApplication.requestRecordPermission()
        }
        return await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    // Audio callbacks run on real-time / background threads. Building them in nonisolated functions keeps them
    // from inheriting main-actor isolation, which would trap at runtime under Swift 6 isolation checking.
    nonisolated private static func tapBlock(for pipeline: ListenPipeline) -> AVAudioNodeTapBlock {
        { buffer, _ in pipeline.enqueue(buffer) }
    }

    nonisolated private static func eventHandler(for owner: AudioTransceiver, id: Int) -> @Sendable ([ReceiverEvent]) -> Void {
        { [weak owner] events in
            Task { @MainActor in owner?.handle(events, id: id) }
        }
    }

    nonisolated private static func playbackCompletion(for owner: AudioTransceiver, id: Int) -> @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void {
        { [weak owner] _ in
            Task { @MainActor in owner?.finishSending(id: id) }
        }
    }

    private static func describe(_ error: FrameError) -> String {
        switch error {
        case .checksumMismatch: return "checksum mismatch"
        case .lengthMismatch, .oddNibbleCount, .frameTooShort: return "wrong length"
        case .unsupportedVersion, .declaredLengthExceedsMaximum: return "bad header"
        case .invalidUTF8: return "invalid UTF-8"
        case .timeout: return "signal lost"
        case .unexpectedRestart: return "restarted mid-frame"
        case .emptyMessage, .payloadTooLarge: return "invalid frame"
        }
    }
}
