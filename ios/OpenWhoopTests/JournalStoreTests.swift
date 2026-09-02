import XCTest
@testable import OpenWhoop

@MainActor
final class JournalStoreTests: XCTestCase {

    /// Each test gets its own isolated UserDefaults suite so tests never see each other's data
    /// and never touch the real app's saved journal.
    private func makeStore() -> JournalStore {
        let suiteName = "journal-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return JournalStore(defaults: defaults)
    }

    func testDefaultTagsArePresentAndBuiltIn() {
        let store = makeStore()
        XCTAssertFalse(store.tags.isEmpty)
        XCTAssertTrue(store.tags.allSatisfy(\.isBuiltIn))
    }

    func testAddCustomTag() {
        let store = makeStore()
        let before = store.tags.count
        store.addTag(name: "Sauna", emoji: "🔥")
        XCTAssertEqual(store.tags.count, before + 1)
        XCTAssertTrue(store.tags.contains { $0.name == "Sauna" && !$0.isBuiltIn })
    }

    func testAddTagIgnoresBlankName() {
        let store = makeStore()
        let before = store.tags.count
        store.addTag(name: "   ", emoji: nil)
        XCTAssertEqual(store.tags.count, before)
    }

    func testAddTagIgnoresCaseInsensitiveDuplicate() {
        let store = makeStore()
        store.addTag(name: "Sauna", emoji: nil)
        let afterFirst = store.tags.count
        store.addTag(name: "sauna", emoji: nil)
        XCTAssertEqual(store.tags.count, afterFirst, "case-insensitive duplicate should be ignored")
    }

    func testBuiltInTagCannotBeRemoved() {
        let store = makeStore()
        let before = store.tags.count
        guard let builtIn = store.tags.first(where: \.isBuiltIn) else {
            return XCTFail("expected at least one built-in tag")
        }
        store.removeTag(builtIn)
        XCTAssertEqual(store.tags.count, before)
    }

    func testCustomTagCanBeRemovedAndIsStrippedFromEntries() {
        let store = makeStore()
        store.addTag(name: "Sauna", emoji: nil)
        guard let custom = store.tags.first(where: { $0.name == "Sauna" }) else {
            return XCTFail("expected the custom tag to exist")
        }

        var entry = store.entry(for: "2026-08-30")
        entry.tagIDs = [custom.id]
        store.save(entry)
        XCTAssertTrue(store.entry(for: "2026-08-30").tagIDs.contains(custom.id))

        store.removeTag(custom)
        XCTAssertFalse(store.tags.contains { $0.id == custom.id })
        XCTAssertFalse(store.entry(for: "2026-08-30").tagIDs.contains(custom.id),
                        "removing a tag should strip it from any entry that referenced it")
    }

    func testEntryForUnloggedDayIsEmptyNotNil() {
        let store = makeStore()
        let entry = store.entry(for: "2026-01-01")
        XCTAssertTrue(entry.tagIDs.isEmpty)
        XCTAssertTrue(entry.note.isEmpty)
    }

    func testSaveAndReadBackEntry() {
        let store = makeStore()
        let tagID = store.tags.first!.id
        var entry = store.entry(for: "2026-08-31")
        entry.tagIDs = [tagID]
        entry.note = "Slept great"
        store.save(entry)

        let reloaded = store.entry(for: "2026-08-31")
        XCTAssertEqual(reloaded.tagIDs, [tagID])
        XCTAssertEqual(reloaded.note, "Slept great")
    }

    func testLoggedEntriesExcludesEmptyEntriesAndSortsNewestFirst() {
        let store = makeStore()
        let tagID = store.tags.first!.id

        var day1 = store.entry(for: "2026-08-28")
        day1.tagIDs = [tagID]
        store.save(day1)

        var day2 = store.entry(for: "2026-08-30")
        day2.note = "note only"
        store.save(day2)

        // Opened but never actually logged — must not appear.
        _ = store.entry(for: "2026-08-29")

        let logged = store.loggedEntries
        XCTAssertEqual(logged.map(\.day), ["2026-08-30", "2026-08-28"])
    }

    func testDayStringFormat() {
        let components = DateComponents(year: 2026, month: 3, day: 5, hour: 12)
        let date = Calendar(identifier: .gregorian).date(from: components)!
        XCTAssertEqual(JournalStore.dayString(for: date), "2026-03-05")
    }
}
