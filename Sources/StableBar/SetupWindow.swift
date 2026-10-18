import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class SetupWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show(store: BarStore) {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Set up StableBar"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: SetupView(store: store) { [weak window] in window?.close() })
        window.center()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

struct SetupView: View {
    let store: BarStore
    let close: () -> Void
    @State private var step = 0
    @State private var preferences = SetupPreferences()
    @State private var preview = BarStore()
    @State private var error: String?
    @State private var loginStatus = SMAppService.mainApp.status
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var installed: Bool {
        let directory = Bundle.main.bundleURL.deletingLastPathComponent().standardizedFileURL
        return directory == URL(filePath: "/Applications", directoryHint: .isDirectory)
            || directory == FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications", directoryHint: .isDirectory)
    }

    private var themes: [ThemeChoice] {
        themeChoices(packages: store.configurationURL.deletingLastPathComponent().appending(path: "packages"))
    }

    private var menuBarHeight: Double {
        max(NSStatusBar.system.thickness, NSScreen.main?.safeAreaInsets.top ?? 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.topthird.inset.filled")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                Text("StableBar").font(.headline)
                Spacer()
                Text("\(step + 1) of 3").font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.horizontal, 36)
            .padding(.top, 24)
            HStack(spacing: 6) {
                ForEach(0..<3) { index in
                    Capsule().fill(index <= step ? Color.accentColor : Color.primary.opacity(0.08)).frame(height: 3)
                }
            }
            .accessibilityLabel("Setup step \(step + 1) of 3")
            .padding(.horizontal, 36)
            .padding(.top, 20)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    switch step {
                    case 0: welcome
                    case 1: customization
                    default: access
                    }
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .font(.callout)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(36)
            }
            Divider()
            HStack {
                if step > 0 {
                    Button("Back") { step -= 1 }
                } else {
                    Button("Set up later", action: close)
                }
                Spacer()
                Text(step == 2 ? "You can run setup again from Customize StableBar → General." : "Changes apply when you finish.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(step == 2 ? "Start StableBar" : "Continue") {
                    if step == 2 { finish() } else { step += 1 }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .padding(20)
        }
        .frame(width: 720, height: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: step)
        .onAppear(perform: refreshPreview)
        .onChange(of: preferences) { refreshPreview() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginStatus = SMAppService.mainApp.status
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 24) {
            heading("Your Mac, at a glance.", detail: "Your active app, the time, and room for what matters to you. A quiet bar that stays close at hand.")
            barPreview
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title2).frame(width: 28)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Ready with the essentials").font(.headline)
                    Text("The starter bar works without extra permissions, accounts, or downloads.")
                        .foregroundStyle(.secondary)
                }
            }
            if !installed {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "folder").foregroundStyle(.secondary).font(.title2).frame(width: 28)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Give StableBar a home").font(.headline)
                        Text("Drag the app to Applications, then open it there. You can try the setup here first.")
                            .foregroundStyle(.secondary)
                        Button("Show app in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                        }
                    }
                }
            }
        }
    }

    private var customization: some View {
        VStack(alignment: .leading, spacing: 20) {
            heading("A bar that feels like yours.", detail: "Start with a few essentials. Your custom widgets and settings stay in place.")
            barPreview
            Form {
                Picker("Theme", selection: $preferences.theme) {
                    Text("Keep current").tag(SetupPreferences.Theme.current)
                    Text("Built-in").tag(SetupPreferences.Theme.builtIn)
                    ForEach(themes, id: \.key) {
                        Text($0.title).tag(SetupPreferences.Theme.package(id: $0.manifest.id, version: $0.isBundled ? nil : $0.manifest.version))
                    }
                }
                .pickerStyle(.menu)
                Picker("Appearance", selection: $preferences.appearance) {
                    ForEach(SetupPreferences.Appearance.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Picker("Placement", selection: $preferences.placement) {
                    ForEach(SetupPreferences.Placement.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Picker("Clock", selection: $preferences.clock) {
                    ForEach(SetupPreferences.Clock.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .disabled(store.configuration?.widgets.contains { if case .clock = $0.content { true } else { false } } != true)
            }
            .formStyle(.columns)
            .pickerStyle(.segmented)
            .controlSize(.large)
            Text("Below menu bar keeps the macOS menu bar visible. Top edge works best with an automatically hidden menu bar. Either way, windows can extend under the bar unless a window manager such as AeroSpace leaves room for it.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var access: some View {
        VStack(alignment: .leading, spacing: 20) {
            heading("Just the access you need.", detail: "The starter bar needs no special access. Optional integrations ask for permission when you use them.")
            VStack(alignment: .leading, spacing: 18) {
                Label("Built-in widgets are ready", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.headline)
                Divider()
                SourcePermissionList(permissions: store.registry.permissions(for: store.configuration))
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "app.connected.to.app.below.fill").font(.title2).frame(width: 28)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("App automation").font(.headline)
                        Text("Widgets that control another app may trigger a macOS prompt. You can review those choices in System Settings.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button("Review…") { openPrivacyPane("Privacy_Automation") }
                }
                Divider()
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "rectangle.3.group").font(.title2).frame(width: 28)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Window manager · Optional").font(.headline)
                        Text("Without a window manager, enable Keep windows clear of StableBar in Customize → Appearance and grant StableBar Accessibility access. For AeroSpace, set \(Text("gaps.outer.top = \(String(format: "%g", store.configuration?.bar.height ?? 40))").monospaced()) in its configuration, or use yabai's external_bar setting. Grant your window manager access in its own setup.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button("Review…") { openPrivacyPane("Privacy_Accessibility") }
                }
            }
            .padding(20)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
            Toggle(isOn: Binding(get: { loginStatus == .enabled || loginStatus == .requiresApproval }, set: { setLaunchAtLogin($0) })) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Open at login").font(.headline)
                    Text(installed ? "Have your bar ready when you sign in." : "Move the app to Applications to enable this.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .accessibilityLabel("Open at login")
            .disabled(!installed)
            if loginStatus == .requiresApproval {
                Button("Allow StableBar in Login Items…") { SMAppService.openSystemSettingsLoginItems() }
            }
        }
    }

    private var barPreview: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("YOUR BAR").font(.system(size: 10, weight: .semibold)).tracking(1.4)
                Spacer()
                Text("Preview").font(.caption)
            }
            .foregroundStyle(.secondary)
            VStack(spacing: 0) {
                if let configuration = preview.configuration, configuration.bar.offset >= menuBarHeight {
                    HStack(spacing: 16) {
                        Image(systemName: "apple.logo")
                        Text("Finder").bold()
                        Text("File")
                        Text("Edit")
                        Spacer()
                    }
                    .font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 16).frame(height: 24)
                }
                BarView(store: preview, display: BarDisplay(id: 1, isBuiltIn: true, isMain: true, notch: nil))
                    .frame(height: preview.configuration?.barGeometry(for: BarDisplay(id: 1, isBuiltIn: true, isMain: true, notch: nil)).panelHeight ?? 40)
                    .allowsHitTesting(false)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Preview of your bar")
                Spacer(minLength: 24)
            }
            .frame(height: 100)
            .background(Color(nsColor: .underPageBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private func heading(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 30, weight: .semibold)).tracking(-0.7)
            Text(detail).foregroundStyle(.secondary).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func refreshPreview() {
        do {
            let data = try preferences.applying(to: Data(contentsOf: store.configurationURL), menuBarHeight: menuBarHeight,
                                               configurationURL: store.configurationURL, context: store.context)
            var loader = ConfigurationLoader()
            preview.configuration = try loader.load(store.configurationURL, data: data, context: store.context)
            preview.scripts = store.scripts
            preview.preparePresentations()
            preview.workspaceStore.workspaces = store.workspaceStore.workspaces
            error = nil
        } catch {
            self.error = errorMessage(error)
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            error = nil
        } catch {
            self.error = errorMessage(error)
        }
        loginStatus = SMAppService.mainApp.status
    }

    private func finish() {
        do {
            try preferences.save(to: store.configurationURL, menuBarHeight: menuBarHeight, context: store.context)
            store.reloadConfiguration()
            UserDefaults.standard.set(true, forKey: "setupCompleted")
            close()
        } catch {
            self.error = errorMessage(error)
        }
    }
}

/// The access that the data sources of enabled widgets need, each with a link to System Settings.
struct SourcePermissionList: View {
    let permissions: [SourcePermission]

    var body: some View {
        ForEach(permissions, id: \.self) { permission in
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: permission.symbol).font(.title2).frame(width: 28)
                VStack(alignment: .leading, spacing: 5) {
                    Text(permission.title).font(.headline)
                    Text(permission.detail).font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("Review…") { openPrivacyPane(permission.privacyPane) }
            }
            Divider()
        }
    }
}

@MainActor
private func openPrivacyPane(_ pane: String) {
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
}
