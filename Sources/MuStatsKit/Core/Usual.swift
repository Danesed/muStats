import Foundation

/// Where a reading usually sits on this Mac at one hour of the day.
///
/// The middle half of the same hour on the earlier days the month tier still holds:
/// `low` and `high` are the quartiles, so half of those days fell inside the range.
/// A fixed threshold says whether 60% is a lot; this says whether 60% is a lot *here*,
/// which is the question a person looking at the number is actually asking.
public struct UsualRange: Equatable, Sendable {
    public let low: Double
    public let median: Double
    public let high: Double
    /// Earlier days that had a reading at this hour.
    public let days: Int

    public init(low: Double, median: Double, high: Double, days: Int) {
        self.low = low
        self.median = median
        self.high = high
        self.days = days
    }

    public func contains(_ value: Double) -> Bool { value >= low && value <= high }
}

public enum Usual {
    /// Earlier days at this hour the range needs before it means anything. A range
    /// drawn from three days is the last three days, not a habit.
    public static let daysMinimum = 7

    /// Series a usual range is drawn for: the ones with a fixed scale, where a band
    /// has a place to sit whatever the reading is doing. A rate has no ceiling, and a
    /// charge level has no habit worth the name.
    public static func isDrawn(for key: SeriesKey) -> Bool {
        switch key {
        case .cpuTotal, .memoryUsed, .memoryPressure, .gpuUtilization, .cpuTemperature: return true
        default: return false
        }
    }

    /// The range for the hour holding `date`. Twenty-nine single-cell reads and one
    /// short sort: cheap enough to ask per row, per render.
    public static func range(_ key: SeriesKey, month: MinuteHistory, at date: Date) -> UsualRange? {
        var values: [Double] = []
        values.reserveCapacity(29)
        for day in 1..<30 {
            if let value = month.average(key, at: date.addingTimeInterval(-86_400 * Double(day))) {
                values.append(value)
            }
        }
        guard values.count >= daysMinimum else { return nil }
        values.sort()
        return UsualRange(low: quantile(values, 0.25), median: quantile(values, 0.5),
                          high: quantile(values, 0.75), days: values.count)
    }

    /// Linear interpolation between the two nearest ranks of a sorted list.
    static func quantile(_ sorted: [Double], _ q: Double) -> Double {
        guard let first = sorted.first else { return 0 }
        guard sorted.count > 1 else { return first }
        let position = q * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, sorted.count - 1)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * (position - Double(lower))
    }
}

/// When the startup disk fills, if it keeps filling the way it has.
///
/// A straight line through the hourly "disk used" readings of the last two weeks. The
/// free-space number says how much room is left; this says how long it lasts, which
/// is what decides whether to do something about it today.
public struct DiskForecast: Equatable, Sendable {
    /// Fraction of the volume gained per day. Positive: the disk is filling.
    public let growthPerDay: Double
    /// Days until the line reaches a full volume.
    public let daysUntilFull: Double

    /// The window the line is fitted over.
    public static let window: TimeInterval = 14 * 86_400
    /// Hours of it that must hold a reading, and how far apart the first and last must
    /// be. Two days of readings cannot tell a download from a habit.
    static let hoursMinimum = 48
    static let spanMinimum: TimeInterval = 3 * 86_400
    /// Growth below this is noise: a tenth of a percent of the volume per day.
    static let growthMinimum = 0.001
    /// Past this the forecast is not a plan anyone makes.
    public static let horizon: Double = 180

    public static func make(month: MinuteHistory, now: Date) -> DiskForecast? {
        var xs: [Double] = []
        var ys: [Double] = []
        let hours = Int(window / month.bucketDuration)
        for hour in 0..<hours {
            let offset = -Double(hour) * month.bucketDuration
            if let used = month.average(.diskUsed, at: now.addingTimeInterval(offset)) {
                xs.append(offset / 86_400)
                ys.append(used)
            }
        }
        guard xs.count >= hoursMinimum, let newest = xs.max(), let oldest = xs.min(),
              (newest - oldest) * 86_400 >= spanMinimum else { return nil }
        let n = Double(xs.count)
        let meanX = xs.reduce(0, +) / n
        let meanY = ys.reduce(0, +) / n
        var covariance = 0.0
        var variance = 0.0
        for index in xs.indices {
            covariance += (xs[index] - meanX) * (ys[index] - meanY)
            variance += (xs[index] - meanX) * (xs[index] - meanX)
        }
        guard variance > 0 else { return nil }
        let slope = covariance / variance
        guard slope >= growthMinimum else { return nil }
        // From the fitted line's value now, not the last reading: one large download
        // an hour ago should not shorten the forecast by itself.
        let fitted = min(max(meanY + slope * (0 - meanX), 0), 1)
        let days = (1 - fitted) / slope
        guard days <= horizon else { return nil }
        return DiskForecast(growthPerDay: slope, daysUntilFull: days)
    }
}
