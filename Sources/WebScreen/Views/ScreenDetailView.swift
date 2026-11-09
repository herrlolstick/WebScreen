import AppKit
import SwiftUI

/// Page of a single virtual screen
struct ScreenDetailView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var screen: ScreenSession
    @State private var confirmRemove = false
    @State private var customMode = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                stage
                if let error = screen.errorText {
                    ErrorBanner(text: error) { screen.errorText = nil }
                }
                HStack(alignment: .top, spacing: 20) {
                    connectCard
                    settingsCard
                }
                devicesCard
            }
            .padding(24)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(screen.config.name)
        .confirmationDialog(removeTitle, isPresented: $confirmRemove) {
            Button(screen.config.isDeviceScreen ? "Reset" : "Remove", role: .destructive) {
                Task { await model.removeScreen(screen) }
            }
        } message: {
            Text(screen.config.isDeviceScreen
                 ? "The device will get a new screen the next time it connects."
                 : "Windows on it move to your main display, and devices are reassigned.")
        }
    }

    private var removeTitle: String {
        screen.config.isDeviceScreen ? "Reset the screen of “\(screen.config.name)”?"
                                     : "Remove “\(screen.config.name)”?"
    }

    private var isPrimary: Bool { screen.id == model.primaryScreen?.id }

    // MARK: Preview

    private var stage: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(LinearGradient(colors: [Color.accentColor.opacity(0.35), Color.purple.opacity(0.25), Color.black.opacity(0.6)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))

            Group {
                if let preview = screen.preview {
                    Image(nsImage: preview)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: screen.isRunning ? "rectangle.dashed" : "moon.zzz")
                            .font(.system(size: 48, weight: .light))
                            .symbolEffect(.pulse, isActive: screen.isBusy)
                        Text(placeholderText)
                            .font(.title3.weight(.medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(.white.opacity(0.85))
                }
            }
            .padding(EdgeInsets(top: 24, leading: 24, bottom: 72, trailing: 24))
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            GlassGroup(spacing: 10) {
                ViewThatFits(in: .horizontal) {
                    bar(compact: false)
                    bar(compact: true)
                }
            }
            .padding(14)
        }
        .frame(height: 360)
        .animation(.smooth, value: screen.preview == nil)
    }

    private var placeholderText: String {
        if screen.isRunning { return "Drag a window onto this screen" }
        if model.isRunning { return "Becomes active as soon as a device connects" }
        return "Streaming is stopped"
    }

    private func bar(compact: Bool) -> some View {
        HStack(spacing: 8) {
            GlassChip(screen.isRunning ? "Active" : "Inactive",
                      systemImage: "circle.fill",
                      tint: screen.isRunning ? .green.opacity(0.35) : nil)
            GlassChip(screen.sizeLabel, systemImage: "aspectratio")
            if !compact, let quality = screen.liveQualityText {
                GlassChip(quality, systemImage: "speedometer")
            }
            Spacer(minLength: 8)
            Button {
                model.openDisplaySettings()
            } label: {
                Image(systemName: "rectangle.3.group")
            }
            .glassButton()
            .help("Arrange displays")
            Button(role: .destructive) {
                confirmRemove = true
            } label: {
                Image(systemName: screen.config.isDeviceScreen ? "arrow.counterclockwise" : "trash")
            }
            .glassButton()
            .help(screen.config.isDeviceScreen ? "Reset" : "Remove")
            .disabled(!screen.config.isDeviceScreen && model.fixedScreens.count <= 1)
        }
    }

    // MARK: Connect

    private var connectCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Open Directly", systemImage: "qrcode")
                .font(.headline)

            if model.isRunning, let url = model.url(for: screen) {
                HStack(alignment: .top, spacing: 14) {
                    QRCard(url: url, size: 104)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Opens exactly this screen – regardless of the automatic assignment.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(url.replacingOccurrences(of: "http://", with: ""))
                            .font(.system(.callout, design: .monospaced).weight(.medium))
                            .lineLimit(1)
                            .textSelection(.enabled)
                        CopyLinkButton(url: url)
                    }
                }
            } else {
                Text("Once streaming is running, a dedicated code for this screen appears here.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
        .glassCard()
    }

    // MARK: Settings

    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Settings", systemImage: "slider.horizontal.3")
                .font(.headline)

            TextField("Name", text: $screen.config.name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.screenChanged() }

            Picker("Resolution", selection: presetBinding) {
                ForEach(DisplayPreset.all) { Text($0.label).tag($0.id) }
                Divider()
                Text("Custom").tag(AppModel.customPresetID)
            }

            if screen.config.presetID == AppModel.customPresetID || customMode {
                HStack(spacing: 6) {
                    TextField("Width", value: $screen.config.width, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 72)
                    Text("×")
                    TextField("Height", value: $screen.config.height, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 72)
                    Text("pt").foregroundStyle(.secondary)
                }
            }

            Toggle("Retina (HiDPI)", isOn: $screen.config.hiDPI)

            Toggle("Keep Always Ready", isOn: Binding(
                get: { screen.config.keepAlive },
                set: { model.setKeepAlive(screen, $0) }
            ))
            .help("Keep this screen active even without a connected device")

            if !screen.config.isDeviceScreen {
                if isPrimary {
                    Label("Main Screen", systemImage: "star.fill")
                        .font(.callout)
                        .foregroundStyle(.yellow)
                } else {
                    Button("Use as Main Screen") { model.primaryScreenID = screen.id }
                        .buttonStyle(.link)
                }
            }

            Text("\(screen.config.pixelWidth) × \(screen.config.pixelHeight) pixels")
                .font(.caption)
                .foregroundStyle(.secondary)

            if screen.hasPendingChanges {
                Button {
                    screen.config.width = AppModel.sanitize(screen.config.width)
                    screen.config.height = AppModel.sanitize(screen.config.height)
                    model.apply(screen)
                } label: {
                    Label("Apply", systemImage: "arrow.triangle.2.circlepath")
                }
                .glassButton(prominent: true)
            }
        }
        .padding(18)
        .frame(width: 320, alignment: .topLeading)
        .frame(minHeight: 180)
        .glassCard()
        .onChange(of: screen.config) { _, _ in
            if !screen.isRunning { model.screenChanged() }
        }
    }

    private var presetBinding: Binding<String> {
        Binding(
            get: { customMode ? AppModel.customPresetID : screen.config.presetID },
            set: { id in
                if id == AppModel.customPresetID {
                    customMode = true
                } else {
                    customMode = false
                    let preset = DisplayPreset.find(id)
                    screen.config.width = preset.width
                    screen.config.height = preset.height
                }
            }
        )
    }

    // MARK: Devices

    private var devicesCard: some View {
        let devices = model.clients(on: screen)
        return VStack(alignment: .leading, spacing: 10) {
            Label("Devices on This Screen", systemImage: "ipad.and.iphone")
                .font(.headline)
            if devices.isEmpty {
                Text("No device connected yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(devices) { client in
                    ConnectionRow(client: client)
                    if client.id != devices.last?.id { Divider() }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .glassCard()
    }
}

/// An active connection (compact, single line)
struct ConnectionRow: View {
    @EnvironmentObject private var model: AppModel
    let client: ClientInfo

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: DeviceSymbol.name(for: client.deviceName))
                .font(.title3)
                .frame(width: 28)
            Text(model.devices.first { $0.id == client.deviceKey }?.name ?? client.deviceName)
                .lineLimit(1)
            Text(client.address)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text("\(Int(client.fps)) fps · " + String(format: "%.1f Mbit/s", client.mbps))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            Button {
                model.disconnect(client)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Disconnect")
        }
    }
}

enum DeviceSymbol {
    static func name(for deviceName: String) -> String {
        if deviceName.contains("iPad") { return "ipad" }
        if deviceName.contains("iPhone") { return "iphone" }
        if deviceName.contains("Android") { return "smartphone" }
        if deviceName.contains("Mac") { return "laptopcomputer" }
        return "desktopcomputer"
    }
}
