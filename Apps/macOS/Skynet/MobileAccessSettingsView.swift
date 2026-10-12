import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

struct MobileAccessSettingsView: View {
    @Bindable var model: AppModel
    @Bindable var host: MobileHostController

    var body: some View {
        Form {
            Text("Mobile Access").font(.largeTitle.bold()).padding(.bottom, 6)
            Section("Connection") {
                Toggle("Allow paired iPhones and iPads", isOn: Binding(
                    get: { host.isEnabled || host.isWorking },
                    set: { $0 ? host.enable() : host.disable() }
                ))
                Text("Connect on the same network or through your private VPN. Only selected projects are shared; the Mac must stay awake and Skynet must remain open.")
                    .foregroundStyle(.secondary)
                if host.isWorking { ProgressView("Starting secure relay…") }
                if host.isEnabled {
                    TextField("Mac address", text: $host.address)
                    if let port = host.port {
                        LabeledContent("Port", value: String(port))
                    }
                }
                if let error = host.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }
            Section("Shared projects") {
                if model.projects.isEmpty {
                    Text("Add a project before sharing it with your phone.").foregroundStyle(.secondary)
                }
                ForEach(model.projects) { project in
                    Toggle(project.name, isOn: Binding(
                        get: { host.sharedProjectIDs.contains(project.id.description) },
                        set: { selected in
                            if selected { host.sharedProjectIDs.insert(project.id.description) }
                            else { host.sharedProjectIDs.remove(project.id.description) }
                        }
                    ))
                }
                Text("No projects are shared by default. Unchecking a project immediately blocks mobile access to its sessions.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if host.isEnabled {
                Section("Pair a device") {
                    Button("New pairing invitation", systemImage: "qrcode", action: host.generateInvitation)
                        .disabled(host.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        if let expiry = host.invitationExpiresAt, expiry > context.date, !host.pairingCode.isEmpty {
                            HStack(alignment: .top, spacing: 24) {
                                if let qr = qrImage(host.pairingCode) {
                                    Image(nsImage: qr).interpolation(.none).resizable()
                                        .frame(width: 148, height: 148)
                                        .accessibilityLabel("Pairing invitation QR code")
                                }
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("Scan this invitation in Skynet on your phone, then enter the verification code shown only on this Mac.")
                                    Text(host.verificationCode).font(.system(.title, design: .monospaced).bold())
                                        .accessibilityLabel("Verification code: \(host.verificationCode)")
                                    Text("Expires in \(max(0, Int(expiry.timeIntervalSince(context.date)))) seconds")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Button("Copy invitation") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(host.pairingCode, forType: .string)
                                    }
                                }
                            }
                            Text("Keep the invitation and verification code private.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("Generate an invitation to pair a device. Invitations expire after 3 minutes.")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Section("Paired devices") {
                    LabeledContent("Devices", value: String(host.deviceCount))
                    Button("Revoke all devices", role: .destructive, action: host.revokeDevices)
                        .disabled(host.deviceCount == 0)
                    Text("Revocation also turns off mobile access and closes current connections.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func qrImage(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let image = filter.outputImage,
              let bitmap = CIContext().createCGImage(image.transformed(by: .init(scaleX: 5, y: 5)),
                                                     from: image.extent.applying(.init(scaleX: 5, y: 5))) else { return nil }
        return NSImage(cgImage: bitmap, size: .init(width: bitmap.width, height: bitmap.height))
    }
}
