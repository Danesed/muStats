import Foundation
import WidgetKit
import MuStatsKit

/// Hands the widget extension what it needs from the settings.
///
/// The extension is sandboxed and cannot read the settings file, which holds far more
/// than a widget should see anyway. Its sandbox has one read-only exception, the app's
/// own Application Support folder, so the app writes a small `WidgetPayload` there and
/// asks macOS to redraw the widgets. Written only when the payload actually changes:
/// a colour dragged in the picker would otherwise reload every widget at display rate.
@MainActor
public final class WidgetBridge {
    private let store: SettingsStore
    private let fileURL: URL
    private var lastWritten: WidgetPayload?
    private var task: Task<Void, Never>?

    public init(store: SettingsStore) {
        self.store = store
        fileURL = store.settingsFileURL.deletingLastPathComponent()
            .appendingPathComponent(WidgetPayload.fileName)
    }

    public func start() {
        write()
        let changes = store.changes
        task = Task { @MainActor [weak self] in
            for await _ in changes {
                guard let self else { return }
                self.write()
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    private func write() {
        let payload = WidgetPayload(settings: store.settings)
        guard payload != lastWritten else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload),
              (try? data.write(to: fileURL, options: .atomic)) != nil else { return }
        // The first write after launch also reloads: the widgets may have been drawn
        // from a payload an older version wrote.
        lastWritten = payload
        WidgetCenter.shared.reloadAllTimelines()
    }
}
