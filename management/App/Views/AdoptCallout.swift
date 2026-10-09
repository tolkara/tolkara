import SwiftUI

/// Offers to manage a Tolkara that is already on the device under another
/// bundle ID, such as one installed by hand with tools/install.sh.
struct AdoptCallout: View {
    @Environment(SetupModel.self) private var model

    var body: some View {
        if model.tolkaraOnDevice != true, let other = model.otherTolkara.first {
            Callout(.info, "Tolkara is already on \(model.deviceName)",
                    message: "It was installed as \(other). Manage that copy to keep its games, settings and connection to the developer service. Building again installs over it.") {
                Button("Use This Tolkara") { model.adoptTolkara(other) }
            }
        }
    }
}
