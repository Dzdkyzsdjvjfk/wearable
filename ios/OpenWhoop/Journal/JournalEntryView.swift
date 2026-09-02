import SwiftUI

// MARK: - JournalEntryView
// Sheet for logging (or editing) one day's journal: toggle tags on/off, add a free-text note,
// and manage the tag library (add a custom tag; remove a previously-added custom tag via
// long-press). iOS 16 safe.

struct JournalEntryView: View {
    @EnvironmentObject private var journal: JournalStore
    @Environment(\.dismiss) private var dismiss

    let day: String
    /// Human-readable heading, e.g. "Today" or "Aug 30".
    let dayLabel: String

    @State private var selectedTagIDs: Set<String>
    @State private var note: String
    @State private var newTagName = ""
    @State private var showAddTag = false

    /// `journal` is also read synchronously here (not just via @EnvironmentObject) so the initial
    /// selection/note can be seeded into @State before the first render.
    init(day: String, dayLabel: String, journal: JournalStore) {
        self.day = day
        self.dayLabel = dayLabel
        let existing = journal.entry(for: day)
        _selectedTagIDs = State(initialValue: Set(existing.tagIDs))
        _note = State(initialValue: existing.note)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                WH.Color.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: WH.Spacing.lg) {
                        tagSection
                        noteSection
                    }
                    .padding(WH.Spacing.md)
                }
            }
            .navigationTitle(dayLabel)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Tags

    private var tagSection: some View {
        VStack(alignment: .leading, spacing: WH.Spacing.sm) {
            HStack {
                Text("WHAT HAPPENED TODAY?")
                    .font(WH.Font.cardTitle)
                    .foregroundStyle(WH.Color.textSecondary)
                    .tracking(1.2)
                Spacer()
                Button {
                    showAddTag = true
                } label: {
                    Label("Add tag", systemImage: "plus.circle.fill")
                        .font(.system(.footnote, design: .rounded).weight(.semibold))
                }
                .foregroundStyle(WH.Color.teal)
                .accessibilityLabel("Add a custom tag")
            }

            FlowLayout(spacing: WH.Spacing.sm) {
                ForEach(journal.tags) { tag in
                    TagChip(tag: tag,
                            isSelected: selectedTagIDs.contains(tag.id),
                            onToggle: { toggle(tag) },
                            onDelete: { journal.removeTag(tag) })
                }
            }

            Text("Long-press a custom tag to delete it. Built-in tags can't be deleted.")
                .font(WH.Font.caption)
                .foregroundStyle(WH.Color.textSecondary.opacity(0.6))
        }
        .alert("New Tag", isPresented: $showAddTag) {
            TextField("Name", text: $newTagName)
            Button("Add") {
                journal.addTag(name: newTagName, emoji: nil)
                newTagName = ""
            }
            Button("Cancel", role: .cancel) { newTagName = "" }
        }
    }

    private func toggle(_ tag: JournalTag) {
        if selectedTagIDs.contains(tag.id) {
            selectedTagIDs.remove(tag.id)
        } else {
            selectedTagIDs.insert(tag.id)
        }
    }

    // MARK: - Note

    private var noteSection: some View {
        VStack(alignment: .leading, spacing: WH.Spacing.sm) {
            Text("NOTE")
                .font(WH.Font.cardTitle)
                .foregroundStyle(WH.Color.textSecondary)
                .tracking(1.2)
            TextEditor(text: $note)
                .frame(minHeight: 100)
                .scrollContentBackground(.hidden)
                .padding(WH.Spacing.sm)
                .background(WH.Color.surface,
                            in: RoundedRectangle(cornerRadius: WH.Radius.card, style: .continuous))
                .foregroundStyle(WH.Color.textPrimary)
                .font(.system(.body, design: .default))
                .accessibilityLabel("Note")
        }
    }

    private func save() {
        var entry = journal.entry(for: day)
        entry.tagIDs = Array(selectedTagIDs)
        entry.note = note
        journal.save(entry)
        dismiss()
    }
}

// MARK: - TagChip

private struct TagChip: View {
    let tag: JournalTag
    let isSelected: Bool
    let onToggle: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 4) {
                if let emoji = tag.emoji {
                    Text(emoji).accessibilityHidden(true)
                }
                Text(tag.name)
                    .font(.system(.subheadline, design: .rounded).weight(.medium))
            }
            .padding(.horizontal, WH.Spacing.md)
            .padding(.vertical, WH.Spacing.sm)
            .background(isSelected ? WH.Color.teal.opacity(0.25) : WH.Color.surface2,
                        in: Capsule())
            .overlay(
                Capsule().stroke(isSelected ? WH.Color.teal : WH.Color.separator, lineWidth: 1)
            )
            .foregroundStyle(isSelected ? WH.Color.teal : WH.Color.textPrimary)
        }
        .buttonStyle(.plain)
        .contextMenu {
            if !tag.isBuiltIn {
                Button("Delete Tag", role: .destructive, action: onDelete)
            }
        }
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
        .accessibilityLabel(Text(tag.name))
        .accessibilityHint(Text(isSelected ? "Selected. Double tap to remove." : "Double tap to add."))
    }
}

// MARK: - Preview

#Preview("Journal Entry") {
    JournalEntryView(day: JournalStore.dayString(), dayLabel: "Today", journal: JournalStore())
        .environmentObject(JournalStore())
}
