// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import TokenMoonCore

struct ChartSeriesData: Sendable {
    struct Column: Identifiable {
        let bucket: UsageSeriesBucket
        let lower: Double
        let upper: Double
        let value: Double
        var id: UsageSeriesBucket.ID { bucket.id }
    }

    struct Point: Identifiable {
        let bucket: UsageSeriesBucket
        let value: Double
        let series: String
        var id: UsageSeriesBucket.ID { bucket.id }
    }

    private let buckets: [UsageSeriesBucket]
    private let indices: [Date: Int]
    private let bucketsByDate: [Date: [UsageSeriesBucket]]
    let seriesIDs: [String]
    let grouping: UsageChartDimension

    static let empty = Self(timeline: [], series: [], grouping: .model)

    init(timeline: [UsageBucket], series: [UsageSeriesBucket], grouping: UsageChartDimension) {
        self.grouping = grouping
        buckets = series
        indices = Dictionary(uniqueKeysWithValues: timeline.enumerated().map { ($0.element.date, $0.offset) })
        bucketsByDate = Dictionary(grouping: series, by: \.date)
        seriesIDs = Set(series.lazy.map(\.seriesIdentity)).sorted()
    }

    func groups(at date: Date) -> [UsageSeriesBucket] { bucketsByDate[date] ?? [] }

    func columns(value: (UsageMetrics) -> Double?) -> [Column] {
        var date: Date?
        var top = 0.0
        return buckets.compactMap { bucket in
            if bucket.date != date {
                date = bucket.date
                top = 0
            }
            guard let sample = value(bucket.metrics), sample.isFinite, sample > 0 else { return nil }
            let lower = top
            top += sample
            return Column(bucket: bucket, lower: lower, upper: top, value: sample)
        }
    }

    func lines(value: (UsageMetrics) -> Double?) -> [Point] {
        struct Segment {
            let index: Int
            let start: Int
        }
        var last: [String: Segment] = [:]
        return buckets.compactMap { bucket in
            guard let sample = value(bucket.metrics), sample.isFinite, let index = indices[bucket.date] else { return nil }
            let identity = bucket.seriesIdentity
            let previous = last[identity]
            let segment = previous.flatMap { $0.index + 1 == index ? $0.start : nil } ?? index
            last[identity] = Segment(index: index, start: segment)
            // Length prefix avoids ambiguous series keys even for opaque identities.
            return Point(bucket: bucket, value: sample, series: "\(identity.utf8.count):\(identity):\(segment)")
        }
    }
}
