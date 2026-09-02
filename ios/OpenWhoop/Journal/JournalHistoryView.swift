import SwiftUI

// MARK: - JournalHistoryView
// Simple chronological list of past journal entries (most recent first). Tapping one reopens it
// in JournalEntryView for editing. iOS 16 safe — pushed via NavigationLink from TodayView, same
// pattern as MetricDetailView.

struct JournalHistoryView: View {
    @EnvironmentObject private var journal: JournalStore
    @State private var editingDay: String?

    var body: some View {
        ZStack {
            WH.Color.background.ignoresSafeArea()
            if journal.loggedEntries.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .navigationTitle("Journal")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .sheet(item: Binding(
            get: { editingDay.map(IdentifiableDay.init) },
            set: { editingDay = $0?.day }
        )) { wrapped in
            JournalEntryView(day: wrapped.day, dayLabel: label(for: wrapped.day), journal: journal)
                .environmentObject(journal)
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: WH.Spacing.sm) {
                ForEach(journal.loggedEntries) { entry in
                    Button { editingDay = entry.day } label: {
                        row(for: entry)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(WH.Spacing.md)
        }
    }

    private func row(for entry: JournalEntry) -> some View {
        let tagNames = entry.tagIDs.compactMap { id in journal.tags.first { $0.id == id }?.name }
        let noteText = entry.note.trimmingCharacters(in: .whitespacesAndNewlines)

        return VStack(alignment: .leading, spacing: WH.Spacing.xs) {
            Text(label(for: entry.day))
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundStyle(WH.Color.textPrimary)

            if !tagNames.isEmpty {
                Text(tagNames.joined(separator: " · "))
                    .font(.system(.footnote, design: .default))
                    .foregroundStyle(WH.Color.textSecondary)
            }
            if !noteText.isEmpty {
                Text(noteText)
                    .font(.system(.footnote, design: .default))
                    .foregroundStyle(WH.Color.textSecondary)
                    .lineLimit(2)
            }
        }
        .padding(WH.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WH.Color.surface, in: RoundedRectangle(cornerRadius: WH.Radius.card, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var emptyState: some View {
        VStack(spacing: WH.Spacing.sm) {
            Image(systemName: "book.closed")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(WH.Color.textSecondary)
            Text("No journal entries yet")
                .font(.system(.body, design: .rounded).weight(.semibold))
                .foregroundStyle(WH.Color.textPrimary)
            Text("Log your day from the Today tab")
                .font(WH.Font.caption)
                .foregroundStyle(WH.Color.textSecondary)
        }
    }

    private func label(for day: String) -> String {
        let fmt = DateFormatter()
        // Must match JournalStore.dayString(for:)'s pinned Gregorian/POSIX formatting exactly,
        // or a device on a non-Gregorian preferred calendar fails to parse its own day keys back.
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        guard let date = fmt.date(from: day) else { return day }
        let out = DateFormatter()
        out.dateFormat = "MMM d"
        return out.string(from: date)
    }
}

private struct IdentifiableDay: Identifiable {
    let day: String
    var id: String { day }
}

// MARK: - Preview

#Preview("Journal History") {
    NavigationStack {
        JournalHistoryView()
            .environmentObject(JournalStore())
    }
}
