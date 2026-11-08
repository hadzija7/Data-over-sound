import SwiftUI

struct ContentView: View {
    @ObservedObject var transceiver: AudioTransceiver
    @State private var message = "Hello from iPhone"
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Message", text: $message, axis: .vertical)
                        .lineLimit(1...3)
                        .disabled(transceiver.mode != .idle)
                    let preview = transceiver.payloadPreview(for: message)
                    Text("\(preview.bytes) / \(transceiver.configuration.maxPayloadBytes) UTF-8 bytes"
                         + (preview.truncated ? " — will be truncated" : ""))
                        .font(.footnote)
                        .foregroundStyle(preview.truncated ? .orange : .secondary)
                    if transceiver.mode == .sending {
                        Button("Stop sending", role: .destructive) { transceiver.stop() }
                    } else {
                        Button("Send") { transceiver.send(message) }
                            .disabled(transceiver.mode != .idle || preview.bytes == 0)
                    }
                } header: {
                    Text("Send")
                } footer: {
                    Text("Plays audible tones (1.5–4.7 kHz) through the loudspeaker. Turn the volume up. Not encrypted: anyone nearby can decode it.")
                }

                Section("Listen") {
                    if transceiver.mode == .listening {
                        Button("Stop listening", role: .destructive) { transceiver.stop() }
                    } else {
                        Button("Listen") { Task { await transceiver.startListening() } }
                            .disabled(transceiver.mode != .idle)
                    }
                }

                Section("Status") {
                    Text(transceiver.status)
                    if let error = transceiver.lastError {
                        Text(error).foregroundStyle(.red)
                    }
                }

                Section {
                    if transceiver.received.isEmpty {
                        Text("Nothing received yet").foregroundStyle(.secondary)
                    }
                    ForEach(transceiver.received) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.text).textSelection(.enabled)
                            Text(item.date, style: .time).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    HStack {
                        Text("Received")
                        Spacer()
                        if !transceiver.received.isEmpty {
                            Button("Clear") { transceiver.clearReceived() }.font(.caption)
                        }
                    }
                }
            }
            .navigationTitle("Data over Sound")
        }
        .onChange(of: scenePhase) { phase in
            // No background audio mode, so release the microphone/speaker. Only on .background: the
            // microphone permission alert and Control Center also make the scene .inactive.
            if phase == .background {
                transceiver.stop(reason: "Stopped: app left the foreground.")
            }
        }
    }
}
