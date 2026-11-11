import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Closing the window does not quit the app – streaming keeps running.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Right-click on the Dock icon
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let item = NSMenuItem(title: "Settings …", action: #selector(openSettings), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    @MainActor @objc private func openSettings() {
        SettingsOpener.open?()
    }

    /// Clicking the Dock icon reopens the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            for window in sender.windows where window.canBecomeMain {
                window.makeKeyAndOrderFront(nil)
                return true
            }
        }
        return true
    }
}

@main
struct WebScreenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true

    var body: some Scene {
        Window("WebScreen", id: "main") {
            MainView()
                .environmentObject(model)
        }
        .defaultSize(width: 980, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Screen") {
                Button(model.isRunning ? "Stop Streaming" : "Start Streaming") {
                    model.toggle()
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(model.isBusy)

                Button("Arrange Displays …") { model.openDisplaySettings() }
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
        }

        MenuBarExtra(isInserted: $showMenuBarIcon) {
            MenuBarContent()
                .environmentObject(model)
        } label: {
            Image(systemName: model.isRunning ? "rectangle.on.rectangle.angled.fill" : "rectangle.on.rectangle.angled")
        }
        .menuBarExtraStyle(.window)
    }
}

/// Compact menu bar window for quick access
private struct MenuBarContent: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                StatusDot(state: model.state)
                Text("WebScreen").font(.headline)
                Spacer()
                Text(model.statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if model.isRunning, let url = model.url(for: nil) {
                HStack(spacing: 12) {
                    if let qr = QRCode.image(for: url) {
                        Image(nsImage: qr)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 84, height: 84)
                            .padding(5)
                            .background(.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    Text(url)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                }
            }

            GlassGroup {
                HStack {
                    StartStopButton()
                        .glassButton(prominent: true)
                    Spacer()
                    SettingsLink {
                        Image(systemName: "gearshape")
                    }
                    .glassButton()
                    .help("Settings")
                    Button("Open Window") {
                        openWindow(id: "main")
                        NSApp.activate(ignoringOtherApps: true)
                    }
                    .glassButton()
                }
            }

            Divider()
            Button("Quit WebScreen") {
                Task {
                    await model.stop()
                    NSApp.terminate(nil)
                }
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 300)
    }
}
