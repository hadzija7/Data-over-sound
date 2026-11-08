import SwiftUI

@main
struct DataOverSoundPoCApp: App {
    @StateObject private var transceiver = AudioTransceiver()

    var body: some Scene {
        WindowGroup {
            ContentView(transceiver: transceiver)
        }
    }
}
