import SwiftUI
import VNCore

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var info: String?
    @State private var showInfo = false
    @AppStorage(AppDiagnostics.preferenceKey) private var diagnosticLogging = false
    /// Owned here rather than by the Advanced page so a logging failure is
    /// caught while that page is closed.
    @State private var diagnosticError: String?
    @State private var showingWelcome = false
    @State private var storageReport: StorageReport?

    var body: some View {
        NavigationStack {
            Form {
                Section("Appearance") {
                    Picker("Appearance", selection: $model.settings.appearance) {
                        ForEach(Appearance.allCases, id: \.self) {
                            Text($0.displayName).tag($0)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    NavigationLink {
                        AccountsSettingsView()
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Accounts & Sync")
                                    Spacer()
                                    accountsSyncState
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                                HStack(spacing: 8) {
                                    ForEach(MetadataService.allCases) { service in
                                        accountChip(service)
                                    }
                                }
                            }
                        } icon: {
                            Image(systemName: "person.crop.circle.badge.checkmark")
                                .foregroundStyle(.tint)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    .accessibilityIdentifier("accounts-settings-link")
                }

                Section("In Game") {
                    Picker(selection: $model.settings.background) {
                        ForEach(PlayerBackground.allCases, id: \.self) {
                            Text($0.displayName).tag($0)
                        }
                    } label: {
                        SettingLabel("Background Fill", systemImage: "photo")
                    }
                    .pickerStyle(.menu)

                    Toggle(isOn: $model.settings.stretchToScreen) {
                        SettingLabel("Stretch 4:3 Games to 16:9", systemImage: "arrow.left.and.right")
                    }

                    Toggle(isOn: $model.settings.skipPatchVideos) {
                        SettingLabel("Skip Translation Group Credit Videos", systemImage: "forward.end.fill")
                    }
                    .accessibilityIdentifier("skip-patch-videos-toggle")
                }

                Section("Controls") {
                    NavigationLink {
                        FloatingButtonSettingsView()
                    } label: {
                        HStack {
                            SettingLabel("Floating Button", systemImage: "moon.stars.fill")
                            Spacer()
                            Text(floatingButtonSummary)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("floating-button-settings-link")

                    Toggle(isOn: $model.settings.threeFingerMenu) {
                        SettingLabel("Three-Finger Tap for Menu", systemImage: "hand.tap")
                    }
                }

                Section {
                    Toggle(isOn: $model.settings.respectSilentMode) {
                        SettingLabel("Respect Silent Mode", systemImage: "speaker.slash")
                    }
                    .accessibilityIdentifier("respect-ios-silent-mode-toggle")
                } header: {
                    Text("Sound")
                } footer: {
                    Text("When on, games stay silent while the device is in Silent Mode; when off, they play anyway. Takes effect the next time a game launches.")
                }

                Section {
                    NavigationLink {
                        StorageView()
                    } label: {
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                SettingLabel("Storage", systemImage: "internaldrive")
                                Spacer()
                                Text(storageTotal)
                                    .foregroundStyle(.secondary)
                            }
                            storageBar
                            storageLegend
                        }
                    }
                    .accessibilityIdentifier("storage-settings-link")
                } header: {
                    Text("General")
                }

                Section {
                    NavigationLink {
                        AdvancedSettingsView(diagnosticError: $diagnosticError)
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Advanced")
                                Text("Rendering, Emote animation, diagnostic logs")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "slider.horizontal.3")
                                .foregroundStyle(.tint)
                        }
                    }
                    .accessibilityIdentifier("advanced-settings-link")
                }

                Section("More") {
                    ShareLink(item: String(localized: "Mikage 0.1\nDevice: \(UIDevice.current.model)\nSystem: \(UIDevice.current.systemVersion)\nRenderer: \(model.settings.renderer.displayName)\nFull diagnostic log: Settings → Advanced → turn on Full Diagnostic Log, reproduce the issue, then export\nDescription:\nSteps to reproduce:")) {
                        SettingLabel("Send Feedback", systemImage: "envelope")
                    }

                    Button {
                        showingWelcome = true
                    } label: {
                        SettingLabel("Welcome Guide", systemImage: "sparkles")
                    }

                    NavigationLink {
                        AboutView()
                    } label: {
                        SettingLabel("About Mikage", systemImage: "info.circle")
                    }
                }

                Section {
                    let buildInfo = AppBuildInfo()
                    VStack(spacing: 4) {
                        Text(buildInfo.versionLine)
                            .tracking(3)
                        Text(buildInfo.headLine)
                            .font(.system(.caption2, design: .monospaced))
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("app-build-info")
                }
                .listRowBackground(Color.clear)
            }
            .scrollContentBackground(.hidden)
            .background(AppBackground())
            .navigationTitle("Settings")
            .task { storageReport = await model.measureStorage() }
        }
        .sheet(isPresented: $showingWelcome) {
            WelcomeGuideView().environmentObject(model)
        }
        .alert("Mikage", isPresented: $showInfo) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(info ?? "")
        }
        .onChange(of: diagnosticLogging) { enabled in
            if enabled { diagnosticError = nil }
            do { try AppDiagnostics.shared.configure(enabled: enabled) }
            catch {
                diagnosticLogging = false
                explain(String(localized: "Couldn’t start logging: \(error.localizedDescription)"))
            }
        }
        .task(id: diagnosticLogging) {
            while diagnosticLogging && !Task.isCancelled {
                if let error = AppDiagnostics.shared.lastError {
                    diagnosticError = error
                    diagnosticLogging = false
                    break
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    /// "On · 2 actions", or "Off".
    private var floatingButtonSummary: String {
        model.settings.floatingButton
            ? String(localized: "On · \(model.settings.quickActions.count) actions")
            : String(localized: "Off")
    }

    /// Trailing sync state on the Accounts & Sync row; empty without accounts.
    @ViewBuilder
    private var accountsSyncState: some View {
        if model.syncing {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Syncing…")
            }
        } else if model.accounts.isEmpty {
            EmptyView()
        } else if model.pendingSyncCount > 0 {
            HStack(spacing: 4) {
                Image(systemName: "clock.fill")
                    .foregroundStyle(.orange)
                Text("\(model.pendingSyncCount) Waiting")
            }
        } else {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.green)
                Text("Synced")
            }
        }
    }

    private func accountChip(_ service: MetadataService) -> some View {
        let account = model.accounts[service]
        let expired = account != nil && service == .bangumi && model.bangumiSignInExpired
        return HStack(spacing: 7) {
            ServiceAccountIcon(service: service, account: account, size: 28)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: service.displayName)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if let account {
                        Circle()
                            .fill(expired ? Color.orange : Color.green)
                            .frame(width: 6, height: 6)
                        if expired {
                            Text("Sign-In Expired")
                                .foregroundStyle(.orange)
                        } else {
                            Text(verbatim: "@\(account.username)")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Circle()
                            .strokeBorder(Color.secondary, lineWidth: 1)
                            .frame(width: 6, height: 6)
                        Text("Not Connected")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// Storage categories in the order of the usage bar and legend.
    private var storageSegments: [StorageSegment] {
        [
            StorageSegment(id: "Game Files", color: .accentColor, bytes: model.games.reduce(0) { $0 + $1.byteCount }),
            StorageSegment(id: "Saves", color: .orange, bytes: storageReport?.totalSaves ?? 0),
            StorageSegment(id: "Covers & Details", color: .teal, bytes: storageReport?.metadata ?? 0),
            StorageSegment(id: "Logs", color: .gray, bytes: storageReport?.logs ?? 0)
        ]
    }

    private var storageBar: some View {
        let segments = storageSegments.filter { $0.bytes > 0 }
        let total = segments.reduce(Int64(0)) { $0 + $1.bytes }
        return GeometryReader { proxy in
            HStack(spacing: 0) {
                ForEach(segments) { segment in
                    Rectangle()
                        .fill(segment.color)
                        .frame(width: max(3, proxy.size.width * CGFloat(segment.bytes) / CGFloat(max(total, 1))))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 6)
        .background(Color(uiColor: .tertiarySystemFill))
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }

    private var storageLegend: some View {
        HStack(spacing: 12) {
            ForEach(storageSegments) { segment in
                HStack(spacing: 4) {
                    Circle()
                        .fill(segment.color)
                        .frame(width: 7, height: 7)
                    Text(segment.title)
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .accessibilityHidden(true)
    }

    private var storageTotal: String {
        AppModel.size(model.games.reduce(0) { $0 + $1.byteCount })
    }

    private func explain(_ text: String) {
        info = text
        showInfo = true
    }
}

/// One category of the Storage row's usage bar.
private struct StorageSegment: Identifiable {
    /// The English name, which doubles as the localization key.
    let id: String
    let color: Color
    let bytes: Int64
    var title: LocalizedStringKey { LocalizedStringKey(id) }
}

/// Rendering, Emote and diagnostics options most players never need.
struct AdvancedSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var diagnosticError: String?
    @AppStorage(AppDiagnostics.preferenceKey) private var diagnosticLogging = false
    @State private var exportingLogs = false
    @State private var logExport: URL?
    @State private var showLogExport = false
    @State private var confirmClearLogs = false
    @State private var info: String?
    @State private var showInfo = false

    var body: some View {
        Form {
            Section {
                Picker("Renderer", selection: $model.settings.renderer) {
                    ForEach(RendererPreference.allCases, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
                .pickerStyle(.menu)

                Toggle("Show Performance Stats on Launch", isOn: $model.settings.performance)

                Picker("Performance Stats", selection: $model.settings.performanceDetail) {
                    ForEach(PerformanceDetail.allCases, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
                .pickerStyle(.menu)
            } header: {
                Text("Graphics")
            } footer: {
                Text("If the picture looks wrong, switch to Software Compositing · Metal. Metal accelerates offscreen drawing, Emote and D3DLayer; regular KRKR layers are still composited on the CPU. Performance stats can also be toggled any time from the in-game menu.")
            }


            Section {
                Toggle("Full Diagnostic Log", isOn: $diagnosticLogging)
                    .accessibilityIdentifier("diagnostic-logging-toggle")
                if let diagnosticError {
                    Text("Logging stopped: \(diagnosticError)")
                        .foregroundStyle(.red)
                }
                Button {
                    exportingLogs = true
                    Task {
                        do {
                            logExport = try await Task.detached(priority: .utility) {
                                try AppDiagnostics.shared.export()
                            }.value
                            showLogExport = true
                        } catch { explain(error.localizedDescription) }
                        exportingLogs = false
                    }
                } label: {
                    exportingLogs ? Text("Exporting…") : Text("Export Diagnostic Log")
                }
                .disabled(exportingLogs)
                .accessibilityIdentifier("export-diagnostic-logs")
                Button("Clear Diagnostic Log", role: .destructive) { confirmClearLogs = true }
                    .disabled(exportingLogs)
                    .accessibilityIdentifier("clear-diagnostic-logs")
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("Helps track down problems such as black screens. Off by default. Records app, window orientation, foreground and background, audio route, KRKR and SDL events; up to about 16 MB with automatic rotation, and existing records are kept after turning it off. May include game names, resource names and error text, so check before sharing. Doesn’t read game files or saves, and can’t replace system crash reports.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppBackground())
        .navigationTitle("Advanced")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Mikage", isPresented: $showInfo) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(info ?? "")
        }
        .sheet(isPresented: $showLogExport) {
            if let logExport { ActivitySheet(items: [logExport]) }
        }
        .confirmationDialog("Clear recorded diagnostic logs?", isPresented: $confirmClearLogs, titleVisibility: .visible) {
            Button("Clear Logs", role: .destructive) {
                do { try AppDiagnostics.shared.clear() }
                catch { explain(String(localized: "Couldn’t clear logs: \(error.localizedDescription)")) }
            }
        }
    }

    private func explain(_ text: String) {
        info = text
        showInfo = true
    }
}
