import Foundation

/// The macOS this Mac runs, and when it last changed.
///
/// Kept so the month of history can be cut at the update: "is my Mac worse since the
/// update" is asked after every release, and the answer is two halves of data this
/// app already holds, once it knows where the cut is.
public struct SystemUpdateRecord: Codable, Equatable, Sendable {
    public var version: String
    public var build: String
    /// The version before the change, and when this app first saw the new one. Both
    /// nil until an update happens while the app is installed.
    public var previousVersion: String?
    public var updatedAt: Date?

    public init(version: String, build: String, previousVersion: String? = nil, updatedAt: Date? = nil) {
        self.version = version
        self.build = build
        self.previousVersion = previousVersion
        self.updatedAt = updatedAt
    }

    /// The record after a launch on `version` and `build`. A changed build is an
    /// update, dated now: the app starts at login, so the first launch on a new build
    /// is within minutes of the restart that installed it.
    public static func advance(_ stored: SystemUpdateRecord?, version: String, build: String,
                               now: Date) -> SystemUpdateRecord {
        guard let stored, !stored.build.isEmpty, !build.isEmpty else {
            return SystemUpdateRecord(version: version, build: build)
        }
        guard stored.build != build else { return stored }
        return SystemUpdateRecord(version: version, build: build,
                                  previousVersion: stored.version, updatedAt: now)
    }

    private static let defaultsKey = "system.updateRecord"

    /// The build string, "26A434": it changes with every update, the supplemental
    /// ones included, which leave the version number alone.
    private static func osBuild() -> String {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &buffer, &size, nil, 0) == 0 else { return "" }
        return String(cString: buffer)
    }

    /// Reads the stored record, advances it to the running system and stores it back.
    public static func noteLaunch(now: Date = Date(), defaults: UserDefaults = .standard) -> SystemUpdateRecord {
        let stored = defaults.data(forKey: defaultsKey)
            .flatMap { try? JSONDecoder().decode(SystemUpdateRecord.self, from: $0) }
        let system = ProcessInfo.processInfo.operatingSystemVersion
        let version = system.patchVersion > 0
            ? "\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)"
            : "\(system.majorVersion).\(system.minorVersion)"
        let record = advance(stored, version: version, build: osBuild(), now: now)
        if record != stored, let data = try? JSONEncoder().encode(record) {
            defaults.set(data, forKey: defaultsKey)
        }
        return record
    }
}

/// This Mac's typical hour before a macOS update and after it.
///
/// The median of the hourly means on each side of the update, up to a week either
/// way. A median, so one long export does not stand for the week; hourly means, so a
/// Mac that idles most of the day is compared idle to idle. It shows that something
/// changed at the update, not that the update changed it: a new project started the
/// same week reads the same.
public struct UpdateEffect: Equatable, Sendable {
    public struct Change: Equatable, Sendable, Identifiable {
        public let key: SeriesKey
        public let before: Double
        public let after: Double

        public var id: SeriesKey { key }
        public var delta: Double { after - before }
        /// Past the noise for this reading: worth an arrow.
        public var isNotable: Bool { abs(delta) >= UpdateEffect.margin(for: key) }
    }

    /// Days of readings since the update, capped at the window.
    public let days: Double
    public let changes: [Change]

    public var hasNotableChange: Bool { changes.contains { $0.isNotable } }

    /// A week each side.
    public static let window: TimeInterval = 7 * 86_400
    /// Hours each side must hold: a day of use spread over at least two.
    static let hoursMinimum = 24
    /// The readings compared: how busy, how hot, how short of memory.
    public static let keys: [SeriesKey] = [.cpuTotal, .cpuTemperature, .memoryPressure]

    /// Less than this is one week differing from the next.
    static func margin(for key: SeriesKey) -> Double {
        switch key {
        case .cpuTemperature: return 3
        default: return 0.05
        }
    }

    public static func make(month: MinuteHistory, updatedAt: Date?, now: Date) -> UpdateEffect? {
        guard let updatedAt, updatedAt < now else { return nil }
        let after = min(now.timeIntervalSince(updatedAt), window)
        var changes: [Change] = []
        for key in keys {
            let earlier = hours(key, month: month, from: updatedAt.addingTimeInterval(-window), to: updatedAt)
            let later = hours(key, month: month, from: updatedAt, to: updatedAt.addingTimeInterval(after))
            guard earlier.count >= hoursMinimum, later.count >= hoursMinimum else { continue }
            changes.append(Change(key: key, before: Usual.quantile(earlier.sorted(), 0.5),
                                  after: Usual.quantile(later.sorted(), 0.5)))
        }
        guard !changes.isEmpty else { return nil }
        return UpdateEffect(days: after / 86_400, changes: changes)
    }

    private static func hours(_ key: SeriesKey, month: MinuteHistory, from: Date, to: Date) -> [Double] {
        var values: [Double] = []
        var date = from
        while date < to {
            if let value = month.average(key, at: date) { values.append(value) }
            date = date.addingTimeInterval(month.bucketDuration)
        }
        return values
    }
}
