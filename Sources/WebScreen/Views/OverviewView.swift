import AppKit
import SwiftUI

struct OverviewView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var page: Page?

    private let columns = [GridItem(.adaptive(minimum: 250, maximum: 400), spacing: 16)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                hero
                if let error = model.errorText {
                    ErrorBanner(text: error) { model.errorText = nil }
                }
                HStack {
                    Text("Screens").font(.title3.weight(.semibold))
                    Spacer()
                    Button {
                        let screen = model.addScreen()
                        page = .screen(screen.id)
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .glassButton()
                }
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(model.screens) { screen in
                        Button {
                            page = .screen(screen.id)
                        } label: {
                            ScreenCard(screen: screen)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Overview")
    }

    // MARK: Header – slim: status and controls on the left, the code on the right

    private var hero: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.isRunning ? "Ready for devices" : "WebScreen")
                        .font(.title.weight(.bold))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                GlassGroup(spacing: 10) {
                    ViewThatFits(in: .horizontal) {
                        controls(compact: false)
                        controls(compact: true)
                    }
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)

            if model.isRunning, let url = model.url(for: nil) {
                VStack(spacing: 8) {
                    QRCard(url: url, size: 96)
                    Text(url.replacingOccurrences(of: "http://", with: ""))
                        .font(.system(.caption, design: .monospaced).weight(.medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .fixedSize()
                        .textSelection(.enabled)
                }
                .padding(12)
                .glassCard(cornerRadius: 18)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(22)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(LinearGradient(colors: [Color.accentColor.opacity(0.5), Color.purple.opacity(0.4), Color.black.opacity(0.55)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .animation(.smooth, value: model.state)
    }

    @ViewBuilder
    private func controls(compact: Bool) -> some View {
        HStack(spacing: 8) {
            StatusChip()
            GlassChip(compact ? "\(model.runningScreenCount)" : "\(model.runningScreenCount) active", systemImage: "display")
            GlassChip(compact ? "\(model.clients.count)" : "\(model.clients.count) devices", systemImage: "ipad.and.iphone")
            if !compact {
                GlassChip(model.assignmentMode == .shared ? "Shared" : "Per device",
                          systemImage: model.assignmentMode == .shared ? "rectangle.on.rectangle" : "rectangle.split.2x1")
            }
            StartStopButton()
                .glassButton(prominent: true)
            if model.isRunning {
                Button {
                    model.openDisplaySettings()
                } label: {
                    Image(systemName: "rectangle.3.group")
                }
                .glassButton()
                .help("Arrange displays")
            }
        }
        .fixedSize()
    }

    private var subtitle: String {
        guard model.isRunning else {
            return "Start streaming and open the address on a device in the same network."
        }
        switch model.assignmentMode {
        case .shared:
            return "Every device shows “\(model.primaryScreen?.config.name ?? "Main screen")”."
        case .perDevice:
            return "Every device gets its own screen."
        }
    }
}

// MARK: - Screen card

struct ScreenCard: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var screen: ScreenSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.black.opacity(0.35))
                if let preview = screen.preview {
                    Image(nsImage: preview)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .padding(6)
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: screen.isRunning ? "rectangle.dashed" : "moon.zzz")
                            .font(.system(size: 26, weight: .light))
                            .symbolEffect(.pulse, isActive: screen.isBusy)
                        Text(screen.isRunning ? "Active" : (model.isRunning ? "Waiting for a device" : "Inactive"))
                            .font(.caption)
                            .lineLimit(1)
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .aspectRatio(CGFloat(screen.config.width) / CGFloat(max(screen.config.height, 1)), contentMode: .fit)
            .frame(maxHeight: 150)
            .frame(maxWidth: .infinity)

            HStack(spacing: 8) {
                Image(systemName: screen.config.isDeviceScreen ? "ipad.landscape" : "display")
                    .foregroundStyle(screen.isRunning ? Color.green : Color.secondary)
                Text(screen.config.name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if screen.id == model.primaryScreen?.id && model.assignmentMode == .shared {
                    Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow)
                }
                Spacer(minLength: 4)
                Label("\(model.clients(on: screen).count)", systemImage: "ipad.and.iphone")
                    .labelStyle(CompactLabelStyle())
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                Text(screen.sizeLabel)
                if let codec = screen.codec {
                    Text("·")
                    Text(codec.title)
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)

            if let error = screen.errorText {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .help(error)
            }
        }
        .padding(14)
        .glassCard(cornerRadius: 20)
        .opacity(screen.isRunning || !model.isRunning ? 1 : 0.8)
        .contentShape(Rectangle())
    }
}
