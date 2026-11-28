import SwiftUI
import VNCore

extension ArchiveNameEncoding {
    /// The short name shown beside a preview.
    var shortName: String {
        switch self {
        case .automatic: return String(localized: "Automatic")
        case .utf8: return "UTF-8"
        case .shiftJIS: return "Shift-JIS"
        case .gbk: return "GBK"
        case .big5: return "Big5"
        }
    }

    var title: String {
        switch self {
        case .automatic: return String(localized: "Automatic")
        case .utf8: return String(localized: "Unicode (UTF-8)")
        case .shiftJIS: return String(localized: "Japanese (Shift-JIS)")
        case .gbk: return String(localized: "Simplified Chinese (GBK)")
        case .big5: return String(localized: "Traditional Chinese (Big5)")
        }
    }

    var detail: String {
        switch self {
        case .automatic: return ""
        case .utf8: return String(localized: "Archives made on a Mac or with 7-Zip")
        case .shiftJIS: return String(localized: "Japanese Windows")
        case .gbk: return String(localized: "Chinese Windows, most CHS patches")
        case .big5: return String(localized: "Taiwan and Hong Kong Windows")
        }
    }
}

extension ArchiveCheck {
    /// "Automatic (Shift-JIS)" or the encoding chosen.
    var encodingSummary: String {
        encoding == .automatic
            ? String(localized: "Automatic (\(detectedEncoding.shortName))")
            : encoding.title
    }
}

/// How the file names of a ZIP are read, with a preview of the names.
struct ArchiveNamesView: View {
    @EnvironmentObject private var model: AppModel

    /// What the preview shows for the current choice.
    private struct Preview {
        struct Row: Identifiable {
            let id: Int
            let name: String
            let isDirectory: Bool
            let indented: Bool
            let readable: Bool
        }
        var total = 0
        var unreadable = 0
        var rows: [Row] = []
    }

    @State private var preview = Preview()

    var body: some View {
        if let check = model.archiveCheck {
            List {
                Section {
                    ForEach(ArchiveNameEncoding.allCases, id: \.self) { option in
                        Button {
                            model.setArchiveEncoding(option)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.title)
                                        .foregroundStyle(.primary)
                                    Text(subtitle(option, check))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if check.encoding == option {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                    }
                } footer: {
                    Text("Only for ZIP: RAR and 7z store names in Unicode. ZIPs made on Japanese or Chinese Windows often keep names in the local code page. Automatic picks the one where every name reads as real text; change it if the names below still look wrong.")
                }

                Section {
                    status(check)
                    ForEach(preview.rows) { row in
                        sampleRow(row)
                    }
                } header: {
                    HStack {
                        Text("Preview")
                        Spacer()
                        Text(verbatim: check.resolvedEncoding.shortName)
                    }
                } footer: {
                    Text("Shows names with Japanese or Chinese characters; plain English names read the same in every setting.")
                }
            }
            .navigationTitle("File Names")
            .navigationBarTitleDisplayMode(.inline)
            .task(id: "\(check.id)|\(check.resolvedEncoding.rawValue)") {
                let listing = check.listing
                let encoding = check.resolvedEncoding
                preview = await Task.detached(priority: .userInitiated) {
                    Self.makePreview(listing.entries, encoding: encoding)
                }.value
            }
        }
    }

    private func subtitle(_ option: ArchiveNameEncoding, _ check: ArchiveCheck) -> String {
        option == .automatic
            ? String(localized: "Found: \(check.detectedEncoding.shortName)")
            : option.detail
    }

    @ViewBuilder
    private func status(_ check: ArchiveCheck) -> some View {
        if preview.unreadable > 0 {
            Label {
                Text("\(preview.unreadable) names have unreadable characters")
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        } else if check.encoding != .automatic && check.encoding != check.detectedEncoding {
            Label {
                Text("Names read as text, but may be the wrong language. Check they look right.")
            } icon: {
                Image(systemName: "info.circle.fill").foregroundStyle(.yellow)
            }
        } else {
            Label {
                Text("All \(preview.total) names read correctly")
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.archiveGreen)
            }
        }
    }

    private func sampleRow(_ row: Preview.Row) -> some View {
        HStack(spacing: 8) {
            Image(systemName: row.isDirectory ? "folder" : "doc")
                .foregroundStyle(.secondary)
            Text(verbatim: row.name)
                .font(.callout.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if !row.readable {
                Text("Unreadable")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            }
        }
        .padding(.leading, row.indented ? 20 : 0)
        .listRowBackground(row.readable ? nil : Color.orange.opacity(0.12))
    }

    /// Counts the names and picks up to five samples: the first folder with
    /// non-ASCII bytes in its name and the names inside it.
    nonisolated private static func makePreview(_ entries: [ArchiveEntry], encoding: ArchiveNameEncoding) -> Preview {
        var preview = Preview()
        preview.total = entries.count
        preview.unreadable = ArchiveNames.unreadableCount(entries, as: encoding)

        let local = entries.filter { $0.unicodeName == nil && $0.rawName.contains { $0 >= 0x80 } }
        guard let first = local.first,
              let firstPath = ArchiveNames.sanitizedPath(ArchiveNames.decode(first, as: encoding).name),
              let top = firstPath.first else { return preview }

        var samples: [(name: String, isDirectory: Bool, indented: Bool, readable: Bool)] = []
        let hasFolder = firstPath.count > 1 || first.isDirectory
        if hasFolder {
            samples.append((top, true, false, !top.contains("\u{FFFD}")))
        }
        var seen = Set<String>()
        for entry in local {
            guard samples.count < 5 else { break }
            let decoded = ArchiveNames.decode(entry, as: encoding)
            guard let path = ArchiveNames.sanitizedPath(decoded.name), path.first == top else { continue }
            let child: String
            if hasFolder {
                guard path.count > 1 else { continue }
                child = path[1]
            } else {
                child = path[0]
            }
            let isDirectory = hasFolder ? (path.count > 2 || entry.isDirectory) : entry.isDirectory
            guard seen.insert(child).inserted else { continue }
            samples.append((child, isDirectory, hasFolder, !child.contains("\u{FFFD}") && decoded.readable))
        }
        preview.rows = samples.enumerated().map {
            Preview.Row(id: $0.offset, name: $0.element.name, isDirectory: $0.element.isDirectory,
                        indented: $0.element.indented, readable: $0.element.readable)
        }
        return preview
    }
}
