import SwiftUI

@main
struct OpenWhoopApp: App {
    var body: some Scene {
        WindowGroup {
            AppRoot()
        }
    }
}

/// Thin root wrapper that creates a MetricsRepository and LiveViewModel synchronously (no
/// async window) and immediately injects them as environment objects so RootTabView + its
/// tabs always receive non-nil @EnvironmentObjects from the very first render frame.
///
/// LiveViewModel owns the single BLEManager / CBCentralManager. Creating it here (at app
/// launch) means state-restoration fires in the same process lifetime as the manager, and
/// both the Device tab and the Alarm sheet share the same BLE connection.
///
/// The MetricsRepository opens its on-disk store lazily (on the first load/refresh call),
/// so there is no need to wait for an async factory before showing the UI.
private struct AppRoot: View {
    @StateObject private var metrics = MetricsRepository(deviceId: AppConfig.deviceId)
    @StateObject private var live    = LiveViewModel(deviceId: AppConfig.deviceId)
    // Local-only journal (tags + notes per day) — see JournalStore.swift. No async open needed
    // (UserDefaults-backed), so it can be created synchronously here like the other two.
    @StateObject private var journal = JournalStore()

    var body: some View {
        RootTabView()
            .environmentObject(metrics)
            .environmentObject(live)
            .environmentObject(journal)
    }
}
