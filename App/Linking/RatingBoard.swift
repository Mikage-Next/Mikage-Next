import SwiftUI
import VNCore

/// The game page's ratings: one ring per site, all out of 10, with no
/// average. The handle underneath opens a second view that puts every site
/// on one 5–10 line with its rank and number of ratings.
struct RatingBoard: View {
    struct Site: Identifiable {
        let id: String
        let name: String
        /// Out of 10.
        let rating: CommunityRating
        let url: URL?
        /// The site's own scale, such as "82/100", when it isn't out of 10.
        var native: String?
        /// A store's rating (DLsite), which runs high; shown in grey and
        /// left out of the shaded range.
        var store = false
    }

    let sites: [Site]
    @State private var expanded = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Ratings")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.primary.opacity(0.8))
                Spacer()
                Text("All out of 10")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 6)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            ZStack(alignment: .top) {
                if expanded {
                    axis
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .top)),
                            removal: .opacity
                        ))
                } else {
                    rings
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity)
            .clipped()

            handle
        }
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .shadow(color: .black.opacity(0.06), radius: 1.5, y: 1)
    }

    // MARK: Rings

    private var rings: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(sites) { site in
                Button {
                    if let url = site.url { openURL(url) }
                } label: {
                    VStack(spacing: 5) {
                        ZStack {
                            Circle()
                                .stroke(Color(uiColor: .systemGray5), lineWidth: 5)
                            Circle()
                                .trim(from: 0, to: min(max(site.rating.score / 10, 0), 1))
                                .stroke(tint(site), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                            score(site)
                                .font(.system(size: 15, weight: .bold))
                        }
                        .frame(width: 47, height: 47)
                        .padding(2.5)
                        Text(verbatim: site.name)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(site.store ? HierarchicalShapeStyle.secondary : HierarchicalShapeStyle.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(site.url == nil)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: site.name))
                .accessibilityValue(Text(site.rating.score, format: .number.precision(.fractionLength(1))))
                .accessibilityHint(site.url == nil ? Text(verbatim: "") : Text("Opens the game in \(site.name)"))
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 4)
        .padding(.bottom, 10)
    }

    // MARK: Shared axis

    private static let labelWidth: CGFloat = 92
    private static let valueWidth: CGFloat = 34

    private var axis: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(sites) { site in
                Button {
                    if let url = site.url { openURL(url) }
                } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: site.name)
                                .font(.subheadline.weight(.semibold))
                            detail(site)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .foregroundStyle(site.store ? HierarchicalShapeStyle.secondary : HierarchicalShapeStyle.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(width: Self.labelWidth, alignment: .leading)
                        track(site)
                        score(site)
                            .font(.callout.weight(.bold))
                            .frame(width: Self.valueWidth, alignment: .trailing)
                    }
                    .frame(height: 46)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(site.url == nil)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: site.name))
                .accessibilityValue(accessibilityDetail(site))
            }
            ticks
            Text(footnote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
                .padding(.bottom, 8)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }

    /// Where a score sits on the 5–10 line, from 0 to 1. Lower scores sit
    /// at the left end; their number still shows the real value.
    private static func position(_ score: Double) -> CGFloat {
        CGFloat(min(max((score - 5) / 5, 0), 1))
    }

    /// The lowest and highest review-site score, when there are two to
    /// span.
    private var range: (low: Double, high: Double)? {
        let scores = sites.filter { !$0.store }.map(\.rating.score)
        guard scores.count >= 2, let low = scores.min(), let high = scores.max() else { return nil }
        return (low, high)
    }

    private func track(_ site: Site) -> some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                if let range {
                    let low = Self.position(range.low), high = Self.position(range.high)
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.12))
                        .frame(width: max((high - low) * width, 2))
                        .offset(x: low * width)
                }
                Rectangle()
                    .fill(Color(uiColor: .systemGray5))
                    .frame(height: 2)
                Circle()
                    .fill(site.store ? Color(uiColor: .systemGray) : Color.accentColor)
                    .frame(width: 14, height: 14)
                    .overlay(Circle().stroke(Color(uiColor: .secondarySystemGroupedBackground), lineWidth: 2))
                    .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
                    .offset(x: Self.position(site.rating.score) * width - 7)
            }
            .frame(width: width, height: geometry.size.height)
        }
        .frame(height: 46)
        .accessibilityHidden(true)
    }

    private var ticks: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: Self.labelWidth, height: 1)
            GeometryReader { geometry in
                ForEach(5...10, id: \.self) { value in
                    Text(verbatim: "\(value)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .position(x: Self.position(Double(value)) * geometry.size.width, y: 8)
                }
            }
            .frame(height: 16)
            Color.clear.frame(width: Self.valueWidth, height: 1)
        }
        .padding(.top, 2)
        .accessibilityHidden(true)
    }

    // MARK: Handle

    private var handle: some View {
        Button {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                expanded.toggle()
            }
        } label: {
            VStack(spacing: 5) {
                Capsule()
                    .fill(Color(uiColor: .systemGray3))
                    .frame(width: 36, height: 4)
                HStack(spacing: 4) {
                    Text(expanded ? LocalizedStringKey("Show Less") : LocalizedStringKey("Ranks and Spread"))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary.opacity(0.75))
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) { Divider() }
        .accessibilityLabel(expanded ? Text("Show Less") : Text("Ranks and Spread"))
        .accessibilityAddTraits(.isButton)
    }

    // MARK: Text

    private func tint(_ site: Site) -> Color {
        site.store ? Color(uiColor: .systemGray3) : .accentColor
    }

    private func score(_ site: Site) -> some View {
        Text(site.rating.score, format: .number.precision(.fractionLength(1)))
            .monospacedDigit()
            .foregroundStyle(site.store ? HierarchicalShapeStyle.secondary : HierarchicalShapeStyle.primary)
    }

    /// "#530 · 82/100 · 312": rank, the site's own scale, ratings.
    private func detail(_ site: Site) -> Text {
        var parts: [Text] = []
        if let rank = site.rating.rank {
            parts.append(Text(verbatim: "#\(rank)").fontWeight(.bold))
        }
        if let native = site.native {
            parts.append(Text(verbatim: native))
        }
        parts.append(Text(site.rating.votes, format: .number))
        return parts.dropFirst().reduce(parts[0]) { $0 + Text(verbatim: " · ") + $1 }
    }

    private func accessibilityDetail(_ site: Site) -> Text {
        let score = site.rating.score.formatted(.number.precision(.fractionLength(1)))
        if let rank = site.rating.rank {
            return Text("\(score), rank \(rank), \(site.rating.votes) ratings")
        }
        return Text("\(score), \(site.rating.votes) ratings")
    }

    private var footnote: String {
        var sentences = [String(localized: "# is the rank on that site, then the number of ratings.")]
        if let range {
            let low = range.low.formatted(.number.precision(.fractionLength(1)))
            let high = range.high.formatted(.number.precision(.fractionLength(1)))
            sentences.append(String(localized: "The shaded band is the range of the review sites (\(low)–\(high))."))
        }
        if sites.contains(where: \.store) {
            sentences.append(String(localized: "DLsite, in grey, is a store rating and usually runs high."))
        }
        // Chinese and Japanese sentences run on without a space.
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        let separator = language.hasPrefix("zh") || language.hasPrefix("ja") ? "" : " "
        return sentences.joined(separator: separator)
    }
}

extension PlayLength {
    /// The site's name as the game page shows it.
    var sourceName: String {
        switch source {
        case "vndb": return "VNDB"
        case "erogamescape": return String(localized: "EGS")
        case "howlongtobeat": return "HowLongToBeat"
        case "bangumi": return "Bangumi"
        default: return source
        }
    }

    /// "About 24 hr", or minutes for short games.
    var summary: String {
        minutes >= 90
            ? String(localized: "About \(Int((Double(minutes) / 60).rounded())) hr")
            : String(localized: "About \(minutes) min")
    }
}
