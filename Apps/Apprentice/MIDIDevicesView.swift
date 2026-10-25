import SwiftUI

/// Settings > MIDI Devices, after Cakewalk's dialog: input ports on the left, output ports on the
/// right. Checked output devices become ports 1, 2, 3 in list order; rows can be dragged into
/// another order, and "Move checked devices to top" does what Cakewalk's button does.
struct MIDIDevicesView: View {
    @ObservedObject var model: PlayerModel
    @Environment(\.dismiss) private var dismiss
    @State private var devices: [PlayerModel.OutputDevice] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Input port(s):")
                    List(model.sources) { source in
                        Text(source.name).foregroundStyle(.secondary)
                    }
                    .frame(width: 220, height: 220)
                    .border(Color.secondary.opacity(0.4))
                    Text("Recording is not available yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Output port(s):")
                    List {
                        ForEach($devices) { $device in
                            HStack {
                                Toggle(isOn: $device.checked) { Text(device.name) }
                                Spacer()
                                if let port = portNumber(of: device) {
                                    Text("Port \(port)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .onMove { from, to in devices.move(fromOffsets: from, toOffset: to) }
                    }
                    .frame(width: 300, height: 220)
                    .border(Color.secondary.opacity(0.4))
                    Button("Move checked devices to top") {
                        devices = devices.filter { $0.checked } + devices.filter { !$0.checked }
                    }
                    .disabled(!devices.contains { $0.checked })
                }
            }
            Text("The checked output devices are Cakewalk ports 1, 2, 3 … in list order; a track whose port is beyond the last one plays through the last. Drag rows to reorder.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("OK") {
                    model.applyDeviceSettings(devices)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .onAppear { devices = model.outputDevices }
    }

    private func portNumber(of device: PlayerModel.OutputDevice) -> Int? {
        guard device.checked else { return nil }
        let checked = devices.filter { $0.checked }
        return checked.firstIndex(where: { $0.id == device.id }).map { $0 + 1 }
    }
}
