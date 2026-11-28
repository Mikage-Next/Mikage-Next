import SwiftUI
import VNCore

/// "Import Archive": what Mikage found in the file list, before anything is
/// extracted. The player checks the game's folder, name and engine, and the
/// space it needs.
struct ArchiveCheckView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingEngineChoice = false
    @State private var showingSpaceProblem = false

    var body: some View {
        NavigationStack {
            Group {
                if let check = model.archiveCheck {
                    form(check)
                } else {
                    Color.clear
                }
            }
            .navigationTitle("Import Archive")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.cancelArchiveCheck() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        importTapped()
                    } label: {
                        Text("Import").bold()
                    }
                    .disabled(!canImport)
                }
            }
        }
        .confirmationDialog(
            "Choose Game Engine",
            isPresented: $showingEngineChoice,
            titleVisibility: .visible
        ) {
            ForEach(EngineID.allCases) { engine in
                Button(engine.displayName) {
                    model.archiveCheck?.engineChoice = engine
                    model.confirmArchiveCheck()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let name = model.archiveCheck?.archiveURL.lastPathComponent ?? ""
            if model.archiveCheck?.candidate.engines.isEmpty ?? true {
                Text("Couldn’t recognize “\(name)”. Choose the engine it uses.")
            } else {
                Text("Several engines match “\(name)”. Confirm which one it uses.")
            }
        }
        .alert("Not Enough Space", isPresented: $showingSpaceProblem) {
            Button("OK", role: .cancel) {}
        } message: {
            if let check = model.archiveCheck {
                Text(ArchiveReaderError.notEnoughSpace(needed: check.neededBytes, free: check.freeBytes).localizedDescription)
            }
        }
    }

    private var canImport: Bool {
        guard let check = model.archiveCheck else { return false }
        return check.folderNameIsValid && !model.archiveFolderNameTaken(check.folderName)
    }

    private func importTapped() {
        guard let check = model.archiveCheck else { return }
        if !check.hasEnoughSpace {
            showingSpaceProblem = true
        } else if check.engine == nil {
            showingEngineChoice = true
        } else {
            model.confirmArchiveCheck()
        }
    }

    // MARK: Form

    private func form(_ check: ArchiveCheck) -> some View {
        Form {
            header(check)
            gameSection(check)
            contentsSection(check)
            spaceSection(check)
        }
    }

    private func header(_ check: ArchiveCheck) -> some View {
        Section {
            HStack(spacing: 12) {
                ArchiveGlyphTile(size: 44, radius: 11)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: check.archiveURL.lastPathComponent)
                        .font(.subheadline.weight(.semibold).monospaced())
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Text(headerDetail(check))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func headerDetail(_ check: ArchiveCheck) -> String {
        let size = AppModel.size(check.listing.archiveSize)
        let files = check.layout.files(under: [])
        if let container = check.container {
            return String(localized: "\(size) · \(files) files · inside \(container)")
        }
        return check.inDocuments
            ? String(localized: "\(size) · \(files) files · in Mikage’s folder")
            : String(localized: "\(size) · \(files) files · from Files")
    }

    private func gameSection(_ check: ArchiveCheck) -> some View {
        Section {
            HStack {
                Text("Folder Name")
                TextField("Folder Name", text: Binding(
                    get: { model.archiveCheck?.folderName ?? "" },
                    set: {
                        model.archiveCheck?.folderName = $0
                        model.archiveCheck?.folderNameEdited = true
                    }
                ))
                .multilineTextAlignment(.trailing)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            }
            if model.archiveFolderNameTaken(check.folderName) {
                nameTaken(check)
            }
            HStack {
                Text("Engine")
                Spacer()
                engineMenu(check)
            }
            NavigationLink {
                ArchiveRootPickerView()
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Game Folder in Archive")
                    Text(rootSummary(check.candidate))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Game")
        } footer: {
            Text("Found from the file list, before anything is extracted. Change the folder name if one with the same name is already in your library.")
        }
    }

    private func nameTaken(_ check: ArchiveCheck) -> some View {
        let suggestion = model.repository.uniqueFolderName(check.folderName)
        return VStack(alignment: .leading, spacing: 6) {
            Label {
                Text("“\(check.folderName)” is already in your library.")
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            .font(.footnote)
            Button("Use “\(suggestion)”") {
                model.suggestUniqueArchiveFolderName()
            }
            .font(.footnote.weight(.semibold))
            .buttonStyle(.borderless)
        }
    }

    private func engineMenu(_ check: ArchiveCheck) -> some View {
        Menu {
            ForEach(EngineID.allCases) { engine in
                Button {
                    model.archiveCheck?.engineChoice = engine
                } label: {
                    if check.engine == engine {
                        Label(engine.displayName, systemImage: "checkmark")
                    } else {
                        Text(engine.displayName)
                    }
                }
            }
        } label: {
            if let engine = check.engine {
                HStack(spacing: 6) {
                    Text(verbatim: engine.displayName)
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.archiveGreen)
                }
            } else {
                Text("Choose…")
            }
        }
    }

    private func rootSummary(_ candidate: ArchiveRootCandidate) -> String {
        let count = candidate.fileCount
        if candidate.path.isEmpty {
            return String(localized: "Whole Archive · \(count) files")
        }
        return String(localized: "\(candidate.path.joined(separator: "/"))/ · \(count) files")
    }

    // MARK: Contents

    private func contentsSection(_ check: ArchiveCheck) -> some View {
        let root = check.candidate.path
        let children = check.layout.children(of: root)
        let shown = children.prefix(4)
        let outside = check.layout.topLevelOutside(root).prefix(2)
        return Section {
            if check.listing.format.hasLegacyNames {
                NavigationLink {
                    ArchiveNamesView()
                } label: {
                    HStack {
                        Text("File Names")
                        Spacer()
                        Text(check.encodingSummary).foregroundStyle(.secondary)
                    }
                }
            }
            row(icon: "folder", name: (root.last ?? String(localized: "Whole Archive")) + "/", bytes: check.candidate.byteCount, dimmed: false, indent: false)
            ForEach(Array(shown), id: \.name) { child in
                row(icon: child.isDirectory ? "folder" : "doc", name: child.name + (child.isDirectory ? "/" : ""), bytes: child.byteCount, dimmed: false, indent: true)
            }
            if children.count > shown.count {
                Text("\(children.count - shown.count) more")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 20)
            }
            ForEach(Array(outside), id: \.name) { child in
                row(icon: child.isDirectory ? "folder" : "doc", name: child.name + (child.isDirectory ? "/" : ""), bytes: child.byteCount, dimmed: true, indent: false)
            }
        } header: {
            Text("Contents")
        }
    }

    private func row(icon: String, name: String, bytes: Int64, dimmed: Bool, indent: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(.secondary)
            Text(verbatim: name)
                .font(.callout.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(verbatim: AppModel.size(bytes))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.leading, indent ? 20 : 0)
        .opacity(dimmed ? 0.45 : 1)
    }

    // MARK: Space

    private func spaceSection(_ check: ArchiveCheck) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Needs \(AppModel.size(check.neededBytes))")
                        .foregroundStyle(check.hasEnoughSpace ? Color.primary : Color.red)
                    Spacer()
                    Text("\(AppModel.size(check.freeBytes)) free")
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
                spaceBar(check)
            }
            if check.offersDelete {
                Toggle("Delete Archive After Import", isOn: Binding(
                    get: { model.archiveCheck?.deleteAfter ?? true },
                    set: { model.archiveCheck?.deleteAfter = $0 }
                ))
            }
        } header: {
            Text("Space")
        } footer: {
            if let container = check.container, check.offersDelete {
                Text("On by default. Deletes “\(container)” from Mikage’s folder once everything in it is imported.")
            } else if check.offersDelete {
                Text("On by default. Shown only for archives in Mikage’s own folder; an archive picked from elsewhere is read in place and always left as it is.")
            }
        }
    }

    private func spaceBar(_ check: ArchiveCheck) -> some View {
        let fraction = check.freeBytes > 0 ? min(Double(check.neededBytes) / Double(check.freeBytes), 1) : 1
        return GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule()
                    .fill(check.hasEnoughSpace ? Color.accentColor : Color.red)
                    .frame(width: max(proxy.size.width * fraction, 6))
            }
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }
}

/// The folders of the archive that may hold the game.
struct ArchiveRootPickerView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let check = model.archiveCheck {
            List {
                Section {
                    ForEach(Array(check.candidates.enumerated()), id: \.offset) { index, candidate in
                        Button {
                            model.selectArchiveCandidate(index)
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: candidate.path.isEmpty ? String(localized: "Whole Archive") : candidate.path.joined(separator: "/") + "/")
                                        .foregroundStyle(.primary)
                                    Text(subtitle(candidate))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if index == check.candidateIndex {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                    }
                } footer: {
                    Text("Only the files inside this folder are extracted.")
                }
            }
            .navigationTitle("Game Folder in Archive")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func subtitle(_ candidate: ArchiveRootCandidate) -> String {
        let engines = candidate.engines.map(\.displayName).joined(separator: ", ")
        let files = String(localized: "\(candidate.fileCount) files")
        return engines.isEmpty ? files : "\(engines) · \(files)"
    }
}
