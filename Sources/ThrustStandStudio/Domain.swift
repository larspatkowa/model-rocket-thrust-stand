import Foundation

struct DataSample: Identifiable, Sendable {
    let id: Int
    let time: Double
    let raw: Double
}

struct TracePoint: Identifiable, Sendable {
    let id: Int
    let time: Double
    let raw: Double
}

struct TimeRange: Equatable, Sendable {
    var start: Double
    var end: Double

    var ordered: TimeRange {
        start <= end ? self : TimeRange(start: end, end: start)
    }

    var duration: Double { max(0, ordered.end - ordered.start) }
}

struct SyncMarker: Identifiable, Codable, Sendable {
    let id: UUID
    var label: String
    var dataTimeSeconds: Double
    var cameraTimeSeconds: Double?
    var notes: String
    var createdAt: String

    init(
        label: String,
        dataTimeSeconds: Double,
        cameraTimeSeconds: Double?,
        notes: String = "",
        createdAt: String = studioTimestamp()
    ) {
        self.id = UUID()
        self.label = label
        self.dataTimeSeconds = dataTimeSeconds
        self.cameraTimeSeconds = cameraTimeSeconds
        self.notes = notes
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case label
        case dataTimeSeconds
        case cameraTimeSeconds
        case notes
        case createdAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        label = try values.decodeIfPresent(String.self, forKey: .label) ?? "Marker"
        dataTimeSeconds = try values.decode(Double.self, forKey: .dataTimeSeconds)
        cameraTimeSeconds = try values.decodeIfPresent(Double.self, forKey: .cameraTimeSeconds)
        notes = try values.decodeIfPresent(String.self, forKey: .notes) ?? ""
        createdAt = try values.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
    }

    func asJSONObject() -> [String: Any] {
        var value: [String: Any] = [
            "label": label,
            "dataTimeSeconds": dataTimeSeconds,
            "createdAt": createdAt
        ]
        if let cameraTimeSeconds {
            value["cameraTimeSeconds"] = cameraTimeSeconds
        }
        if !notes.isEmpty {
            value["notes"] = notes
        }
        return value
    }
}

struct CalibrationPoint: Identifiable, Codable, Sendable {
    let id: UUID
    var runId: String
    var startS: Double
    var endS: Double
    var label: String
    var weightLb: Double
    var meanRaw: Double
    var stddevRaw: Double
    var sampleCount: Int

    init(
        runId: String,
        range: TimeRange,
        label: String,
        weightLb: Double,
        meanRaw: Double,
        stddevRaw: Double,
        sampleCount: Int,
        id: UUID = UUID()
    ) {
        self.id = id
        self.runId = runId
        self.startS = range.ordered.start
        self.endS = range.ordered.end
        self.label = label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Unnamed section" : label
        self.weightLb = weightLb
        self.meanRaw = meanRaw
        self.stddevRaw = stddevRaw
        self.sampleCount = sampleCount
    }

    enum CodingKeys: String, CodingKey {
        case id
        case runId
        case startS
        case endS
        case label
        case weightLb
        case meanRaw
        case stddevRaw
        case sampleCount
    }

    var range: TimeRange { TimeRange(start: startS, end: endS) }
}

struct CalibrationFit: Codable, Sendable {
    var zeroRaw: Double
    var countsPerPound: Double
    var residualsLb: [Double]
    var rmsErrorLb: Double
    var maxErrorLb: Double
    var rSquared: Double

    func calibratedForce(for raw: Double) -> Double {
        guard abs(countsPerPound) > .ulpOfOne else { return 0 }
        return (raw - zeroRaw) / countsPerPound
    }
}

struct Run: Identifiable, Sendable {
    let id: String
    var label: String
    let directoryURL: URL
    var samples: [DataSample]
    var cameraFile: String?
    var cameraOffsetSeconds: Double?
    var markers: [SyncMarker]

    var duration: Double { samples.last?.time ?? 0 }

    var sampleRate: Double {
        guard samples.count > 1, duration > 0 else { return 0 }
        return Double(samples.count - 1) / duration
    }

    var cameraURL: URL? {
        guard let cameraFile, !cameraFile.isEmpty else { return nil }
        let candidate = directoryURL.appendingPathComponent(cameraFile)
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    func tracePoints(maximumCount: Int = 2_400) -> [TracePoint] {
        guard !samples.isEmpty else { return [] }
        if samples.count <= maximumCount {
            return samples.map { TracePoint(id: $0.id, time: $0.time, raw: $0.raw) }
        }
        let stride = Double(samples.count - 1) / Double(maximumCount - 1)
        return (0..<maximumCount).map { index in
            let sampleIndex = min(samples.count - 1, Int((Double(index) * stride).rounded()))
            let sample = samples[sampleIndex]
            return TracePoint(id: sample.id, time: sample.time, raw: sample.raw)
        }
    }

    func tracePoints(in visibleRange: TimeRange, maximumCount: Int = 2_400) -> [TracePoint] {
        guard !samples.isEmpty else { return [] }
        let range = visibleRange.ordered

        func firstIndex(atOrAfter time: Double) -> Int {
            var lower = 0
            var upper = samples.count
            while lower < upper {
                let middle = (lower + upper) / 2
                if samples[middle].time < time {
                    lower = middle + 1
                } else {
                    upper = middle
                }
            }
            return lower
        }

        let start = max(0, firstIndex(atOrAfter: range.start) - 1)
        let end = min(samples.count, firstIndex(atOrAfter: range.end) + 1)
        guard start < end else { return [] }
        let count = end - start
        if count <= maximumCount {
            return samples[start..<end].map { TracePoint(id: $0.id, time: $0.time, raw: $0.raw) }
        }

        let bucketSize = max(1, Int(ceil(Double(count) / Double(maximumCount / 2))))
        var result: [TracePoint] = []
        result.reserveCapacity(maximumCount + 2)
        for bucketStart in stride(from: start, to: end, by: bucketSize) {
            let bucketEnd = min(bucketStart + bucketSize, end)
            var minimum = bucketStart
            var maximum = bucketStart
            for index in (bucketStart + 1)..<bucketEnd {
                if samples[index].raw < samples[minimum].raw { minimum = index }
                if samples[index].raw > samples[maximum].raw { maximum = index }
            }
            let ordered = minimum <= maximum ? [minimum, maximum] : [maximum, minimum]
            for index in ordered where result.last?.id != samples[index].id {
                let sample = samples[index]
                result.append(TracePoint(id: sample.id, time: sample.time, raw: sample.raw))
            }
        }
        return result
    }

    func statistics(for range: TimeRange) -> (mean: Double, standardDeviation: Double, count: Int)? {
        let ordered = range.ordered
        guard !samples.isEmpty else { return nil }
        let values = samples.filter { $0.time >= ordered.start && $0.time <= ordered.end }.map(\.raw)
        guard !values.isEmpty else { return nil }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + pow($1 - mean, 2) } / Double(values.count)
        return (mean, sqrt(variance), values.count)
    }
}

enum StudioError: LocalizedError {
    case noProject
    case invalidCSV(URL)
    case invalidRange
    case noSamplesInRange
    case invalidWeight
    case insufficientCalibrationPoints
    case identicalCalibrationWeights
    case noCalibrationFit
    case malformedManifest(URL)
    case missingCameraFile
    case cannotRead(URL, Error)

    var errorDescription: String? {
        switch self {
        case .noProject: return "No saved thrust-stand project was found."
        case .invalidCSV(let url): return "Could not find usable time/raw columns in \(url.lastPathComponent)."
        case .invalidRange: return "Select a non-zero time range inside the run."
        case .noSamplesInRange: return "That range contains no sensor samples."
        case .invalidWeight: return "Use a non-negative weight with ounces from 0 to less than 16."
        case .insufficientCalibrationPoints: return "Add at least two calibration sections with different known loads."
        case .identicalCalibrationWeights: return "The calibration sections need at least two different known loads."
        case .noCalibrationFit: return "Fit the calibration before applying or exporting it."
        case .malformedManifest(let url): return "Could not read the run manifest at \(url.path)."
        case .missingCameraFile: return "Choose a camera recording before saving a camera marker."
        case .cannotRead(let url, let error): return "Could not read \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }
}

func poundsAndOunces(pounds: String, ounces: String) throws -> Double {
    guard let poundsValue = Double(pounds.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "0" : pounds),
          let ouncesValue = Double(ounces.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "0" : ounces),
          poundsValue >= 0,
          ouncesValue >= 0,
          ouncesValue < 16 else {
        throw StudioError.invalidWeight
    }
    return poundsValue + ouncesValue / 16
}

func formattedWeight(_ pounds: Double) -> String {
    let wholePounds = floor(pounds)
    let ounces = (pounds - wholePounds) * 16
    return String(format: "%.0f lb %.2f oz", wholePounds, ounces)
}

func studioTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
}

extension String {
    var csvEscaped: String {
        if contains(",") || contains("\"") || contains("\n") {
            return "\"\(replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return self
    }
}
