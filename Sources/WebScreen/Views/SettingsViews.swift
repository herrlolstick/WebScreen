import AppKit
import ServiceManagement
import SwiftUI

// MARK: - Assignment

struct AssignmentSettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section {
                Picker("Mode", selection: $model.assignmentMode) {
                    ForEach(AssignmentMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                switch model.assignmentMode {
                case .shared:
                    Text("All devices show the same screen – handy for presentations or several viewers.")
                        .foregroundStyle(.secondary)
                    Picker("Main screen", selection: $model.primaryScreenID) {
                        ForEach(model.fixedScreens) { Text($0.config.name).tag($0.id) }
                    }
                case .perDevice:
                    Text("Every device gets its own screen. WebScreen recognizes devices again – they always land on “their” screen, and macOS remembers its position.")
                        .foregroundStyle(.secondary)
                    Toggle(isOn: $model.autoMatchDevice) {
                        Text("Match the device’s resolution")
                        Text("New device screens get exactly the size of the device – including Retina on iPads and smartphones.")
                    }
                }
            } header: {
                Text("Automatic Assignment")
            }

            Section {
                LabeledContent {
                    EmptyView()
                } label: {
                    Text("Per-device exceptions")
                    Text("Under **Devices** you can permanently assign a specific screen to each device. This takes precedence over the mode.")
                }
                LabeledContent {
                    EmptyView()
                } label: {
                    Text("Open a screen directly")
                    Text("Every screen has its own code. Use it to open that screen on a device – just for this connection, without changing anything.")
                }
                LabeledContent {
                    EmptyView()
                } label: {
                    Text("Only active when needed")
                    Text("A screen is created when a device connects to it and disappears 20 seconds after it disconnects – unless “Keep Always Ready” is on.")
                }
            } header: {
                Text("How It Works")
            }

            Section {
                Picker("Resolution", selection: $model.defaultPresetID) {
                    ForEach(DisplayPreset.all) { preset in
                        Text(preset.label).tag(preset.id)
                    }
                    Divider()
                    Text("Custom Resolution").tag(AppModel.customPresetID)
                }

                if model.defaultPresetID == AppModel.customPresetID {
                    LabeledContent("Width") {
                        TextField("Width", value: $model.defaultCustomWidth, format: .number.grouping(.never))
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                        Text("pt").foregroundStyle(.secondary)
                    }
                    LabeledContent("Height") {
                        TextField("Height", value: $model.defaultCustomHeight, format: .number.grouping(.never))
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                        Text("pt").foregroundStyle(.secondary)
                    }
                }

                Toggle("Retina (HiDPI)", isOn: $model.defaultHiDPI)
            } header: {
                Text("Defaults for New Screens")
            } footer: {
                let size = model.defaultSize
                let scale = model.defaultHiDPI ? 2 : 1
                Text("\(size.width) × \(size.height) points (\(size.width * scale) × \(size.height * scale) pixels). Used for “Add Screen” and for device screens when the device resolution is not matched.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Assignment")
    }
}

// MARK: - Streaming

struct StreamSettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section {
                Picker("Method", selection: $model.mode) {
                    ForEach(StreamMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Text(modeDescription)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Picker("Frame rate", selection: $model.fps) {
                    Text("30 Hz").tag(30)
                    Text("60 Hz").tag(60)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Method")
            }

            if model.mode == .jpeg {
                Section("Still Images") {
                    LabeledContent {
                        HStack {
                            Slider(value: qualityBinding, in: 40...95, step: 5) {
                                EmptyView()
                            } minimumValueLabel: {
                                Image(systemName: "hare")
                            } maximumValueLabel: {
                                Image(systemName: "sparkles")
                            }
                            .frame(width: 220)
                            Text("\(model.quality) %")
                                .monospacedDigit()
                                .frame(width: 44, alignment: .trailing)
                        }
                    } label: {
                        Text(model.adaptive ? "Maximum quality" : "Quality")
                    }

                    Toggle(isOn: $model.deltaUpdates) {
                        Text("Send changed areas only")
                        Text("Often saves more than 90 % bandwidth while typing, moving the mouse or chatting.")
                    }
                }
            } else {
                Section("Video") {
                    Picker(selection: $model.bitrateMbps) {
                        ForEach([2, 4, 6, 8, 12, 20, 30], id: \.self) { Text("\($0) Mbit/s").tag($0) }
                    } label: {
                        Text(model.adaptive ? "Maximum bitrate" : "Bitrate")
                        Text("Applies to Full HD – larger screens (Retina, 4K) automatically get proportionally more, up to four times as much.")
                    }
                }
            }

            Section {
                Toggle(isOn: $model.adaptive) {
                    Text("Adjust quality automatically")
                    Text(model.mode == .jpeg
                         ? "Lowers image quality during sustained dropouts (down to 45 % at most) and raises it again afterwards."
                         : "Lowers the bitrate during sustained dropouts (down to 45 % at most) and raises it again afterwards.")
                }
                Toggle("Show mouse pointer", isOn: $model.showsCursor)
            } header: {
                Text("Adaptation")
            }

            Section {
                LabeledContent("Port") {
                    TextField("Port", value: $model.port, format: .number.grouping(.never))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                }
            } header: {
                Text("Network")
            } footer: {
                Text("The receiver page runs on port \(String(model.port)), the image data on port \(String(model.port + 1)).")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Streaming")
    }

    private var modeDescription: String {
        switch model.mode {
        case .jpeg:
            return "Still images: lowest latency and works in every browser – but needs more bandwidth when a lot is moving."
        case .h264:
            return "H.264 video: low bandwidth and works in practically every browser. About 0.1–0.2 s latency, at most 4096 pixels wide."
        case .hevc:
            return "HEVC video: another 30–50 % less bandwidth than H.264 and up to 8K. Works on all Apple devices, on Windows/Android only with a hardware decoder."
        case .videoAuto:
            return "Recommended: HEVC if all devices on a screen can play it, otherwise H.264 automatically. Switches on the fly without windows jumping around."
        }
    }

    private var qualityBinding: Binding<Double> {
        Binding(get: { Double(model.quality) }, set: { model.quality = Int($0) })
    }
}

// MARK: - Devices

struct DevicesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var forgetting: KnownDevice?

    var body: some View {
        Group {
            if model.devices.isEmpty {
                ContentUnavailableView {
                    Label("No Devices Yet", systemImage: "ipad.and.iphone")
                } description: {
                    if model.isRunning, let url = model.url(for: nil) {
                        Text("Open \(url) on a device in the same network.")
                    } else {
                        Text("Start streaming and connect a device.")
                    }
                } actions: {
                    if !model.isRunning {
                        StartStopButton()
                            .glassButton(prominent: true)
                    }
                }
            } else {
                Form {
                    Section {
                        ForEach(sortedDevices) { device in
                            KnownDeviceRow(device: device) { forgetting = device }
                        }
                    } header: {
                        Text("Known Devices")
                    } footer: {
                        Text("“Automatic” follows the mode under Assignment (currently: \(model.assignmentMode.title)). A fixed assignment applies permanently to this device.")
                            .foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
            }
        }
        .navigationTitle("Devices")
        .confirmationDialog("Forget “\(forgetting?.name ?? "")”?",
                            isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } })) {
            Button("Forget", role: .destructive) {
                if let device = forgetting {
                    Task { await model.forget(device) }
                }
                forgetting = nil
            }
        } message: {
            Text("The device’s assignment and its own screen will be deleted. If it connects again, it is treated as a new device.")
        }
    }

    private var sortedDevices: [KnownDevice] {
        model.devices.sorted { lhs, rhs in
            let l = model.isOnline(lhs), r = model.isOnline(rhs)
            if l != r { return l }
            return lhs.lastSeen > rhs.lastSeen
        }
    }
}

private struct KnownDeviceRow: View {
    @EnvironmentObject private var model: AppModel
    let device: KnownDevice
    let onForget: () -> Void
    @State private var name = ""

    var body: some View {
        let online = model.isOnline(device)
        let connection = model.clients.first { $0.deviceKey == device.id }

        HStack(spacing: 12) {
            Image(systemName: DeviceSymbol.name(for: device.name))
                .font(.title3)
                .frame(width: 36, height: 36)
                .liquidGlass(in: RoundedRectangle(cornerRadius: 10, style: .continuous),
                             tint: online ? .green.opacity(0.3) : nil)

            VStack(alignment: .leading, spacing: 2) {
                TextField("Name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.headline)
                    .onSubmit { model.rename(device, to: name) }
                Group {
                    if let connection {
                        Text("Connected · \(connection.address) · \(model.screen(connection.screenID)?.config.name ?? "–")")
                    } else {
                        Text("Last seen ") + Text(device.lastSeen, style: .relative) + Text(" ago")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            Picker("Screen", selection: pinBinding) {
                Text("Automatic (\(model.automaticTargetName(for: device)))").tag(Int?.none)
                Divider()
                ForEach(model.fixedScreens) { screen in
                    Text(screen.config.name).tag(Int?.some(screen.id))
                }
                if let own = model.screen(device.ownScreenID) {
                    Text("Own: \(own.config.name)").tag(Int?.some(own.id))
                }
            }
            .labelsHidden()
            .frame(width: 210)

            Menu {
                if let connection {
                    Button("Disconnect") { model.disconnect(connection) }
                }
                Button("Forget …", role: .destructive, action: onForget)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .onAppear { name = device.name }
        .onChange(of: device.name) { _, new in name = new }
    }

    private var pinBinding: Binding<Int?> {
        Binding(
            get: { device.pinnedScreenID },
            set: { model.pin(device, to: $0) }
        )
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true
    @State private var hasPermission = CGPreflightScreenCaptureAccess()

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Open at login", isOn: $model.launchAtLogin)
                Toggle(isOn: $model.autoStart) {
                    Text("Start streaming automatically on launch")
                    Text("Useful together with “Open at login”.")
                }
                Toggle("Show icon in the menu bar", isOn: $showMenuBarIcon)
            }

            Section("Permissions") {
                LabeledContent {
                    if hasPermission {
                        Label("Allowed", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button("Allow …") {
                            CGRequestScreenCaptureAccess()
                            model.openPrivacySettings()
                        }
                    }
                } label: {
                    Text("Screen Recording")
                    Text("Required to capture the virtual screens. Restart WebScreen after allowing it.")
                }
            }

            Section("About WebScreen") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")
                LabeledContent("Source code") {
                    Link("GitHub", destination: URL(string: "https://github.com/herrlolstick/WebScreen")!)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("General")
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            hasPermission = CGPreflightScreenCaptureAccess()
        }
    }
}
