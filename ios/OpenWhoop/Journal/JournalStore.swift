import Foundation

// MARK: - JournalTag
// A lifestyle/behavior tag (e.g. "Alcohol", "Late meal") a user can attach to a day's journal
// entry. Purely a personal wellness log — no health/medical claims, no diagnosis, nothing sent
// anywhere. See JournalStore for persistence.
struct JournalTag: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    /// Optional single-emoji glyph shown next to the tag name.
    var emoji: String?
    /// Built-in starter tags can't be deleted from the library (only left unselected on a given
    /// day) — only user-added tags can be removed entirely.
    var isBuiltIn: Bool = false

    init(id: String = UUID().uuidString, name: String, emoji: String? = nil, isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.isBuiltIn = isBuiltIn
    }
}

// MARK: - JournalEntry
// One day's journal log: which tags applied, plus an optional free-text note.
struct JournalEntry: Codable, Identifiable, Equatable {
    let id: String
    /// yyyy-MM-dd, in the device's LOCAL calendar — this is a personal "what happened today"
    /// log, not yet joined against DailyMetric.day (which MetricsRepository keys in UTC). If you
    /// want to correlate tags against recovery/strain later, align the two day conventions first.
    var day: String
    var tagIDs: [String]
    var note: String
    var updatedAt: Date

    init(id: String = UUID().uuidString, day: String, tagIDs: [String] = [], note: String = "",
         updatedAt: Date = Date()) {
        self.id = id
        self.day = day
        self.tagIDs = tagIDs
        self.note = note
        self.updatedAt = updatedAt
    }
}

// MARK: - JournalStore
// Local-only persistence for journal tags + entries, via UserDefaults (JSON-encoded) — mirrors
// TodayView's TileOrderStore pattern. Nothing here is uploaded to the optional server or leaves
// the device; there is currently no backend model for this data at all.
@MainActor
final class JournalStore: ObservableObject {
    @Published private(set) var tags: [JournalTag]
    @Published private(set) var entries: [String: JournalEntry]   // keyed by day

    private static let tagsKey = "journal.tags.v1"
    private static let entriesKey = "journal.entries.v1"

    static let defaultTags: [JournalTag] = [
        JournalTag(id: "builtin.alcohol",  name: "Alcohol",             emoji: "🍷", isBuiltIn: true),
        JournalTag(id: "builtin.caffeine", name: "Caffeine late",       emoji: "☕️", isBuiltIn: true),
        JournalTag(id: "builtin.lateMeal", name: "Late meal",           emoji: "🍽️", isBuiltIn: true),
        JournalTag(id: "builtin.screens",  name: "Screens before bed",  emoji: "📱", isBuiltIn: true),
        JournalTag(id: "builtin.stress",   name: "Stressful day",       emoji: "😣", isBuiltIn: true),
        JournalTag(id: "builtin.relaxed",  name: "Relaxed evening",     emoji: "🧘", isBuiltIn: true),
        JournalTag(id: "builtin.exercise", name: "Exercised",           emoji: "🏃", isBuiltIn: true),
        JournalTag(id: "builtin.travel",   name: "Traveled",            emoji: "✈️", isBuiltIn: true),
    ]

    /// UserDefaults backing this store. Defaults to `.standard` for the real app; tests inject
    /// an isolated suite so they never read/write the real app's saved journal.
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.tags = Self.loadTags(from: defaults)
        self.entries = Self.loadEntries(from: defaults)
    }

    // MARK: - Day key

    /// yyyy-MM-dd in the device's local calendar/timezone. See JournalEntry.day for why this is
    /// intentionally local rather than UTC.
    static func dayString(for date: Date = Date()) -> String {
        let fmt = DateFormatter()
        // Pin calendar/locale so this always yields a plain Gregorian "yyyy-MM-dd" — without
        // this, a device set to a non-Gregorian preferred calendar (Japanese, Buddhist, Islamic,
        // Hebrew, …) would format against THAT calendar instead (e.g. an era-based year),
        // corrupting the dictionary key this string is used as.
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: date)
    }

    // MARK: - Tags

    /// Adds a new custom tag. No-ops on an empty (whitespace-only) name or an exact
    /// case-insensitive duplicate of an existing tag, so the picker doesn't get cluttered.
    func addTag(name: String, emoji: String?) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !tags.contains(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return }
        tags.append(JournalTag(name: trimmed, emoji: emoji))
        saveTags()
    }

    /// Built-in tags can't be removed — only user-added ones. Also strips the tag from any
    /// entries that reference it, so old logs don't end up pointing at a dangling id.
    func removeTag(_ tag: JournalTag) {
        guard !tag.isBuiltIn else { return }
        tags.removeAll { $0.id == tag.id }
        for day in entries.keys {
            entries[day]?.tagIDs.removeAll { $0 == tag.id }
        }
        saveTags()
        saveEntries()
    }

    // MARK: - Entries

    /// The entry for `day`, or an empty (unsaved) one if nothing's been logged yet.
    func entry(for day: String) -> JournalEntry {
        entries[day] ?? JournalEntry(day: day)
    }

    func save(_ entry: JournalEntry) {
        var updated = entry
        updated.updatedAt = Date()
        entries[entry.day] = updated
        saveEntries()
    }

    /// Entries with at least one tag or a non-empty note, most-recent day first. Entries that
    /// were opened but never actually logged (no tags, no note) don't show up here.
    var loggedEntries: [JournalEntry] {
        entries.values
            .filter { !$0.tagIDs.isEmpty || !$0.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.day > $1.day }
    }

    // MARK: - Persistence

    private static func loadTags(from defaults: UserDefaults) -> [JournalTag] {
        guard let data = defaults.data(forKey: tagsKey),
              let decoded = try? JSONDecoder().decode([JournalTag].self, from: data),
              !decoded.isEmpty else {
            return defaultTags
        }
        return decoded
    }

    private func saveTags() {
        guard let data = try? JSONEncoder().encode(tags) else { return }
        defaults.set(data, forKey: Self.tagsKey)
    }

    private static func loadEntries(from defaults: UserDefaults) -> [String: JournalEntry] {
        guard let data = defaults.data(forKey: entriesKey),
              let decoded = try? JSONDecoder().decode([String: JournalEntry].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private func saveEntries() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.entriesKey)
    }
}
