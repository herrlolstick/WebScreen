import AppKit
import SwiftUI

enum Page: Hashable {
    case overview
    case screen(Int)
}

struct MainView: View {
    @EnvironmentObject private var model: AppModel
    @State private var page: Page? = .overview

    var body: some View {
        NavigationSplitView {
            List(selection: $page) {
                Section {
                    Label("Overview", systemImage: "rectangle.on.rectangle.angled")
                        .tag(Page.overview)
                }
                switch model.assignmentMode {
                case .shared:
                    Section("Screens") {
                        ForEach(model.fixedScreens) { screen in
                            ScreenSidebarRow(screen: screen)
                                .tag(Page.screen(screen.id))
                        }
                        Button {
                            let screen = model.addScreen()
                            page = .screen(screen.id)
                        } label: {
                            Label("Add Screen", systemImage: "plus")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.tint)
                    }
                    // Only reachable via a fixed assignment or a screen code
                    if !model.deviceScreens.isEmpty {
                        Section("Device Screens") {
                            ForEach(model.deviceScreens) { screen in
                                ScreenSidebarRow(screen: screen)
                                    .tag(Page.screen(screen.id))
                            }
                        }
                    }
                case .perDevice:
                    // One section per computer/tablet – its browsers' screens below it
                    ForEach(model.deviceGroups) { group in
                        Section {
                            ForEach(group.screens) { screen in
                                ScreenSidebarRow(screen: screen, title: model.browserName(of: screen))
                                    .tag(Page.screen(screen.id))
                            }
                        } header: {
                            Label(group.title, systemImage: group.symbol)
                        }
                    }
                    if model.deviceScreens.isEmpty {
                        Section("Devices") {
                            Text("Appears as soon as a device connects")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 280)
            .safeAreaInset(edge: .bottom) { sidebarStatus }
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .bottom) { restartBanner }
                .animation(.smooth, value: model.needsRestart)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        StartStopButton()
                    }
                }
        }
        .frame(minWidth: 860, minHeight: 600)
        .onChange(of: model.visibleScreens.map(\.id)) { _, ids in
            if case .screen(let id) = page, !ids.contains(id) { page = .overview }
        }
        .background(SettingsOpenerBridge())
    }

    @ViewBuilder
    private var detail: some View {
        switch page ?? .overview {
        case .overview:
            OverviewView(page: $page)
        case .screen(let id):
            if let screen = model.screen(id), model.isUsable(screen) {
                ScreenDetailView(screen: screen)
                    .id(screen.id)
            } else {
                OverviewView(page: $page)
            }
        }
    }

    private var sidebarStatus: some View {
        HStack(spacing: 10) {
            StatusDot(state: model.state)
            Text(model.statusLine)
                .lineLimit(1)
            Spacer(minLength: 4)
            Label("\(model.runningScreenCount)", systemImage: "display")
            Label("\(model.clients.count)", systemImage: "ipad.and.iphone")
            SettingsLink {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings (⌘,)")
        }
        .labelStyle(CompactLabelStyle())
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .liquidGlass(in: Capsule())
        .padding(10)
    }

    @ViewBuilder
    private var restartBanner: some View {
        if model.needsRestart {
            GlassGroup {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.tint)
                    Text("Network settings changed – restart streaming")
                        .font(.callout)
                        .lineLimit(1)
                    Button("Apply") { model.restartAll() }
                        .glassButton(prominent: true)
                }
                .fixedSize()
                .padding(.leading, 18)
                .padding(.trailing, 8)
                .padding(.vertical, 8)
                .liquidGlass(in: Capsule())
            }
            .padding(.bottom, 20)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

private struct ScreenSidebarRow: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var screen: ScreenSession
    var title: String? = nil

    var body: some View {
        Label {
            HStack(spacing: 6) {
                Text(title ?? screen.config.name).lineLimit(1)
                if screen.id == model.primaryScreen?.id && model.assignmentMode == .shared {
                    Image(systemName: "star.fill")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                        .help("Main screen")
                }
            }
        } icon: {
            Image(systemName: screen.config.isDeviceScreen ? "ipad.landscape" : "display")
                .foregroundStyle(screen.isRunning ? Color.green : Color.secondary)
        }
        .badge(model.clients(on: screen).count)
    }
}

// MARK: - Reusable building blocks

/// Icon + short text without wasted spacing
struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
            configuration.title.monospacedDigit()
        }
    }
}

/// Slim glass capsule with icon and text – always a single line
struct GlassChip: View {
    let systemImage: String?
    let text: String
    var tint: Color? = nil

    init(_ text: String, systemImage: String? = nil, tint: Color? = nil) {
        self.text = text
        self.systemImage = systemImage
        self.tint = tint
    }

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .imageScale(.small)
            }
            Text(text)
                .monospacedDigit()
        }
        .font(.callout.weight(.medium))
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .liquidGlass(in: Capsule(), tint: tint)
    }
}

struct StatusChip: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 7) {
            StatusDot(state: model.state)
            Text(model.statusLine)
        }
        .font(.callout.weight(.medium))
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .liquidGlass(in: Capsule())
    }
}

struct StatusDot: View {
    let state: AppModel.State

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .shadow(color: color.opacity(0.6), radius: state == .running ? 4 : 0)
    }

    private var color: Color {
        switch state {
        case .running: return .green
        case .starting, .stopping: return .orange
        case .stopped: return .secondary.opacity(0.5)
        }
    }
}

struct StartStopButton: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Button {
            model.toggle()
        } label: {
            if model.isBusy {
                Label(model.state == .starting ? "Starting" : "Stopping", systemImage: "hourglass")
            } else if model.isRunning {
                Label("Stop", systemImage: "stop.fill")
            } else {
                Label("Start", systemImage: "play.fill")
            }
        }
        .lineLimit(1)
        .fixedSize()
        .disabled(model.isBusy)
        .help(model.isRunning ? "Remove all virtual screens and stop streaming"
                              : "Start streaming – screens are created as soon as devices connect")
    }
}

struct QRCard: View {
    let url: String
    var size: CGFloat = 118

    var body: some View {
        if let qr = QRCode.image(for: url) {
            Image(nsImage: qr)
                .interpolation(.none)
                .resizable()
                .frame(width: size, height: size)
                .padding(7)
                .background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

struct CopyLinkButton: View {
    let url: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
        } label: {
            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                .lineLimit(1)
        }
        .fixedSize()
        .glassButton()
    }
}

struct ErrorBanner: View {
    @EnvironmentObject private var model: AppModel
    let text: String
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if text.contains("Screen Recording") {
                Button("Open Settings") { model.openPrivacySettings() }
                    .glassButton()
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .liquidGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous), tint: .orange.opacity(0.25))
    }
}

// MARK: - Opening the settings window from AppKit (Dock menu)

enum SettingsOpener {
    @MainActor static var open: (() -> Void)?
}

/// Hands SwiftUI's `openSettings` action to AppKit code such as the Dock menu
private struct SettingsOpenerBridge: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear
            .onAppear {
                SettingsOpener.open = {
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                }
            }
    }
}
