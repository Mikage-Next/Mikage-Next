import SwiftUI
import VNCore

extension Color {
    /// The green of "done" marks, as in the new-games toast.
    static let archiveGreen = Color(red: 0x24 / 255, green: 0x8A / 255, blue: 0x3D / 255)
}

/// A rounded tile with the archive glyph, standing in for a cover.
struct ArchiveGlyphTile: View {
    let size: CGFloat
    let radius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Color.accentColor.opacity(0.14))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: "doc.zipper")
                    .font(.system(size: size * 0.46, weight: .regular))
                    .foregroundStyle(.tint)
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Library card

/// The placeholder under Recently Added while an archive is extracting. It
/// has the grid's columns so it sits like a game card.
struct ExtractionCardGrid: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    let extraction: ArchiveExtraction

    private var columns: [GridItem] {
        if model.settings.listLayout { return [GridItem(.flexible())] }
        return [GridItem(.adaptive(minimum: sizeClass == .regular ? 180 : 150), spacing: 12)]
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            Button {
                model.showExtractionSheet = true
            } label: {
                ExtractionCard(extraction: extraction)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Extracting \(extraction.archiveName), \(Int(extraction.fraction * 100))%"))
        }
    }
}

/// Dashed 16:9 tile with a band that fills as the archive is extracted, the
/// archive's file name under it. The game's name isn't known yet.
struct ExtractionCard: View {
    let extraction: ArchiveExtraction

    private var subline: String {
        if let engine = extraction.engine {
            return String(localized: "Extracting · \(engine.displayName)")
        }
        return String(localized: "Extracting…")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay { tile }
                .clipped()
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: extraction.archiveName)
                    .font(.subheadline.weight(.semibold).monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subline)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var tile: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.18))
                    .frame(width: proxy.size.width * extraction.fraction)
                    .frame(maxWidth: .infinity, alignment: .leading)
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    .padding(8)
                if let engine = extraction.engine {
                    Text(verbatim: engine.displayName)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(16)
                }
                VStack(spacing: 4) {
                    Image(systemName: "doc.zipper")
                        .font(.title2)
                        .foregroundStyle(.tint)
                    Text(verbatim: "\(Int(extraction.fraction * 100))%")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

// MARK: - Progress sheet

/// What the card opens: the archive's name, a progress bar and Stop. Below
/// iOS 26 it can't be swiped away, because leaving the app pauses the work.
struct ExtractionSheet: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if let extraction = model.extraction {
                content(extraction)
            } else {
                Color.clear
            }
        }
        .presentationDetents([.medium])
        .interactiveDismissDisabled(!(model.extraction?.systemProgress ?? false))
        .confirmationDialog(
            "Stop Extracting?",
            isPresented: $model.confirmingStopExtraction,
            titleVisibility: .visible
        ) {
            Button("Stop", role: .destructive) { model.stopExtraction() }
            Button("Keep Extracting", role: .cancel) {}
        } message: {
            Text("What was extracted so far is removed.")
        }
    }

    private func content(_ extraction: ArchiveExtraction) -> some View {
        VStack(spacing: 16) {
            if extraction.queueLength > 1 {
                Text("\(extraction.position) of \(extraction.queueLength)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            ArchiveGlyphTile(size: 64, radius: 16)
            Text(verbatim: extraction.archiveName)
                .font(.headline.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)

            VStack(spacing: 8) {
                HStack {
                    Text("Extracting…")
                    Spacer()
                    Text(verbatim: "\(Int(extraction.fraction * 100))%")
                        .monospacedDigit()
                }
                .font(.subheadline.weight(.semibold))
                ProgressView(value: extraction.fraction)
                HStack(alignment: .firstTextBaseline) {
                    Text("\(AppModel.size(extraction.doneBytes)) of \(AppModel.size(extraction.totalBytes)) · \(extraction.currentName)")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    if let remaining = extraction.remaining {
                        Text("about \(Self.duration(remaining))")
                            .layoutPriority(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            note(extraction)

            Spacer(minLength: 0)
            Button(role: .destructive) {
                model.confirmingStopExtraction = true
            } label: {
                Text("Stop Extracting")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        .padding(20)
    }

    @ViewBuilder
    private func note(_ extraction: ArchiveExtraction) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: extraction.systemProgress ? "arrow.triangle.2.circlepath" : "iphone")
                .foregroundStyle(.secondary)
            if extraction.systemProgress {
                Text("Extracting goes on in the background. You can leave Mikage.")
            } else {
                Text("Keep Mikage open. The screen stays on until it’s done. If you leave, extracting pauses and goes on when you come back.")
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .short
        formatter.maximumUnitCount = 1
        // Seconds are too fine to be useful above a minute.
        let rounded = seconds >= 90 ? (seconds / 60).rounded(.up) * 60 : max(seconds.rounded(.up), 1)
        return formatter.string(from: rounded) ?? ""
    }
}

// MARK: - Alerts and sheets of the import

/// Everything the archive import presents over the window, attached once.
/// A closing binding answers "cancel" a turn later, so a button's own answer
/// always lands first whichever order SwiftUI runs them in.
struct ArchiveImportPresentations: ViewModifier {
    @EnvironmentObject private var model: AppModel
    @State private var password = ""

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: Binding(
                get: { model.archiveCheck != nil },
                set: { if !$0 { model.cancelArchiveCheck() } }
            )) {
                ArchiveCheckView().environmentObject(model)
            }
            .sheet(isPresented: $model.showExtractionSheet) {
                ExtractionSheet().environmentObject(model)
            }
            .alert(
                model.archivePasswordRequest?.wrong == true
                    ? String(localized: "Wrong Password")
                    : String(localized: "Password Required"),
                isPresented: Binding(
                    get: { model.archivePasswordRequest != nil },
                    set: { if !$0 { DispatchQueue.main.async { model.answerArchivePassword(nil) } } }
                ),
                presenting: model.archivePasswordRequest
            ) { _ in
                SecureField("Password", text: $password)
                Button("Cancel", role: .cancel) {
                    password = ""
                    model.answerArchivePassword(nil)
                }
                Button("Extract") {
                    let entered = password
                    password = ""
                    model.answerArchivePassword(entered)
                }
            } message: { request in
                Text("“\(request.archiveName)” is protected. Enter the password from where you got it.")
            }
            .alert(
                model.archiveAlert?.title ?? "",
                isPresented: Binding(
                    get: { model.archiveAlert != nil },
                    set: { if !$0 { DispatchQueue.main.async { model.answerArchiveAlert(false) } } }
                ),
                presenting: model.archiveAlert
            ) { alert in
                if let primary = alert.primary {
                    Button(primary) { model.answerArchiveAlert(true) }
                    Button(alert.cancel, role: .cancel) { model.answerArchiveAlert(false) }
                } else {
                    Button(alert.cancel, role: .cancel) { model.answerArchiveAlert(false) }
                }
            } message: { alert in
                Text(alert.message)
            }
            .confirmationDialog(
                "Choose Game Engine",
                isPresented: Binding(
                    get: { model.archiveEngineRequest != nil },
                    set: { if !$0 { DispatchQueue.main.async { model.answerArchiveEngine(nil) } } }
                ),
                titleVisibility: .visible,
                presenting: model.archiveEngineRequest
            ) { request in
                ForEach(request.detected + EngineID.allCases.filter { !request.detected.contains($0) }) { engine in
                    Button(engine.displayName) { model.answerArchiveEngine(engine) }
                }
                Button("Cancel", role: .cancel) { model.answerArchiveEngine(nil) }
            } message: { request in
                if request.detected.isEmpty {
                    Text("Couldn’t recognize “\(request.archiveName)”. Choose the engine it uses.")
                } else {
                    Text("Several engines match “\(request.archiveName)”. Confirm which one it uses.")
                }
            }
    }
}
