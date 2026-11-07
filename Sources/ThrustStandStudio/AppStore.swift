import AVFoundation
import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class AppStore {
    private static let projectPathKey = "ThrustStandStudio.projectPath"

    enum Mode: String, CaseIterable, Identifiable {
        case calibrate = "Weight points"
        case sync = "Time points"

        var id: String { rawValue }
    }

    var projectURL: URL?
    var runs: [Run] = []
    var selectedRunID: String?
    var mode: Mode = .calibrate
    var calibrationPoints: [CalibrationPoint] = []
    var calibrationFit: CalibrationFit?
    var selectedRange: TimeRange?
    var syncDataTime: Double?
    var cameraPlayer: AVPlayer?
    var cameraLabel = "double tap 1"
    var cameraNotes = ""
    var statusMessage = "No saved runs found."
    var errorMessage: String?

    init() {
        if let project = Self.discoverProjectURL() {
            openProject(project)
        }
    }

    private static func discoverProjectURL() -> URL? {
        var candidates: [URL] = []
        var seenPaths = Set<String>()

        func add(_ url: URL) {
            let root = url.standardizedFileURL
            let possibleRoots = [root]
            for possibleRoot in possibleRoots {
                let candidate = possibleRoot.standardizedFileURL
                if seenPaths.insert(candidate.path).inserted {
                    candidates.append(candidate)
                }
            }
        }

        if let savedPath = UserDefaults.standard.string(forKey: projectPathKey) {
            add(URL(fileURLWithPath: savedPath, isDirectory: true))
        }

        add(URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))

        var ancestor = Bundle.main.bundleURL.standardizedFileURL
        for _ in 0..<8 {
            add(ancestor)
            let parent = ancestor.deletingLastPathComponent()
            if parent == ancestor { break }
            ancestor = parent
        }

        return candidates.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("runs", isDirectory: true).path)
        }
    }

    var selectedRun: Run? {
        guard let selectedRunID else { return nil }
        return runs.first { $0.id == selectedRunID }
    }

    var cameraOffset: Double? {
        selectedRun?.cameraOffsetSeconds
    }

    var currentCameraTime: Double? {
        guard let seconds = cameraPlayer?.currentTime().seconds, seconds.isFinite else { return nil }
        return seconds
    }

    var projectedDataTime: Double? {
        guard let cameraTime = currentCameraTime,
              let offset = selectedRun?.cameraOffsetSeconds else {
            return nil
        }
        return cameraTime + offset
    }

    func openProject(_ url: URL) {
        let root = url.standardizedFileURL
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("runs").path) else {
            showError(StudioError.noProject)
            return
        }
        projectURL = root
        UserDefaults.standard.set(root.path, forKey: Self.projectPathKey)
        do {
            try loadRuns()
            try loadWorkspace()
            let suffix = runs.count == 1 ? "" : "s"
            statusMessage = "Loaded \(runs.count) saved run\(suffix)."
            errorMessage = nil
        } catch {
            showError(error)
        }
    }

    func refresh() {
        guard projectURL != nil else {
            showError(StudioError.noProject)
            return
        }
        do {
            try loadRuns()
            try loadWorkspace()
            let suffix = runs.count == 1 ? "" : "s"
            statusMessage = "Refreshed \(runs.count) run\(suffix)."
            errorMessage = nil
        } catch {
            showError(error)
        }
    }

    func selectRun(_ id: String?) {
        selectedRunID = id
        selectedRange = nil
        syncDataTime = nil
        cameraLabel = "double tap \((selectedRun?.markers.count ?? 0) + 1)"
        cameraNotes = ""
        loadCameraPlayer()
    }

    func addCalibrationPoint(label: String, pounds: String, ounces: String) {
        guard let run = selectedRun, let selectedRange else {
            showError(StudioError.invalidRange)
            return
        }
        do {
            let weight = try poundsAndOunces(pounds: pounds, ounces: ounces)
            guard selectedRange.duration > 0 else { throw StudioError.invalidRange }
            guard let statistics = run.statistics(for: selectedRange) else {
                throw StudioError.noSamplesInRange
            }
            let point = CalibrationPoint(
                runId: run.id,
                range: selectedRange,
                label: label,
                weightLb: weight,
                meanRaw: statistics.mean,
                stddevRaw: statistics.standardDeviation,
                sampleCount: statistics.count
            )
            calibrationPoints.append(point)
            calibrationFit = nil
            statusMessage = "Added \(point.label) at \(formattedWeight(point.weightLb))."
            errorMessage = nil
        } catch {
            showError(error)
        }
    }

    func removeCalibrationPoint(_ point: CalibrationPoint) {
        calibrationPoints.removeAll { $0.id == point.id }
        calibrationFit = nil
        statusMessage = "Removed \(point.label)."
    }

    func fitCalibration() {
        do {
            calibrationFit = try Self.fit(points: calibrationPoints)
            statusMessage = "Fit \(calibrationPoints.count) calibration sections."
            errorMessage = nil
        } catch {
            showError(error)
        }
    }

    func saveWorkspace() {
        guard let projectURL else {
            showError(StudioError.noProject)
            return
        }
        do {
            var workspace: [String: Any] = [
                "version": 1,
                "updatedAt": studioTimestamp(),
                "sections": calibrationPoints.map { point in
                    [
                        "id": point.id.uuidString,
                        "runId": point.runId,
                        "startS": point.startS,
                        "endS": point.endS,
                        "label": point.label,
                        "weightLb": point.weightLb,
                        "meanRaw": point.meanRaw,
                        "stddevRaw": point.stddevRaw,
                        "sampleCount": point.sampleCount
                    ]
                }
            ]
            if let fit = calibrationFit {
                workspace["fit"] = [
                    "zeroRaw": fit.zeroRaw,
                    "countsPerPound": fit.countsPerPound,
                    "rmsErrorLb": fit.rmsErrorLb,
                    "maxErrorLb": fit.maxErrorLb,
                    "rSquared": fit.rSquared
                ]
            } else {
                workspace["fit"] = NSNull()
            }
            try writeJSON(workspace, to: projectURL.appendingPathComponent(".studio/run-calibration-workspace.json"))
            statusMessage = "Saved calibration workspace."
            errorMessage = nil
        } catch {
            showError(error)
        }
    }

    func exportCorrectedCSVs() {
        guard let calibrationFit else {
            showError(StudioError.noCalibrationFit)
            return
        }
        do {
            for run in runs {
                try export(run: run, fit: calibrationFit)
            }
            statusMessage = "Wrote data-calibrated.csv beside each saved run. Raw data.csv files were not changed."
            errorMessage = nil
        } catch {
            showError(error)
        }
    }

    func chooseCameraVideo() {
        guard let run = selectedRun else {
            showError(StudioError.noProject)
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Choose camera recording"
        panel.message = "The recording is copied into this run's camera folder."
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie, .avi]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let source = panel.url {
            do {
                let cameraDirectory = run.directoryURL.appendingPathComponent("camera", isDirectory: true)
                try FileManager.default.createDirectory(at: cameraDirectory, withIntermediateDirectories: true)
                let destination = uniqueCameraDestination(for: source, in: cameraDirectory)
                if source.standardizedFileURL != destination.standardizedFileURL {
                    try FileManager.default.copyItem(at: source, to: destination)
                }
                let relative = "camera/\(destination.lastPathComponent)"
                try updateCamera(runID: run.id, file: relative, offset: run.cameraOffsetSeconds, marker: nil)
                statusMessage = "Camera recording ready: \(destination.lastPathComponent)."
                errorMessage = nil
            } catch {
                showError(error)
            }
        }
    }

    func saveCameraMarker() {
        guard let run = selectedRun, let syncDataTime else {
            showError(StudioError.invalidRange)
            return
        }
        guard let cameraTime = currentCameraTime else {
            showError(StudioError.missingCameraFile)
            return
        }
        do {
            let defaultLabel = "double tap \(run.markers.count + 1)"
            let marker = SyncMarker(
                label: cameraLabel,
                dataTimeSeconds: syncDataTime,
                cameraTimeSeconds: cameraTime,
                notes: cameraNotes
            )
            try updateCamera(
                runID: run.id,
                file: run.cameraFile,
                offset: syncDataTime - cameraTime,
                marker: marker
            )
            if cameraLabel == defaultLabel {
                cameraLabel = "double tap \(run.markers.count + 2)"
            }
            self.syncDataTime = nil
            cameraNotes = ""
            statusMessage = String(format: "Saved %@: data %.3f s − camera %.3f s = offset %+.3f s. data.csv camera times updated.", marker.label, syncDataTime, cameraTime, syncDataTime - cameraTime)
            errorMessage = nil
        } catch {
            showError(error)
        }
    }

    func setSyncDataTime(_ time: Double) {
        syncDataTime = time
    }

    func seekCamera(to cameraTime: Double) {
        guard let cameraPlayer else { return }
        let seconds = max(0, cameraTime)
        cameraPlayer.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    func seekCamera(by delta: Double) {
        guard let cameraPlayer else { return }
        let duration = cameraPlayer.currentItem?.duration.seconds ?? .infinity
        let target = (currentCameraTime ?? 0) + delta
        seekCamera(to: min(max(0, target), duration.isFinite ? duration : target))
    }

    func stepCameraFrame(by count: Int) {
        guard let player = cameraPlayer, let item = player.currentItem else { return }
        player.pause()
        item.step(byCount: count)
    }

    func seekCameraToDataTime(_ dataTime: Double) {
        guard let offset = selectedRun?.cameraOffsetSeconds else {
            statusMessage = "Save a camera marker first; then trace clicks can seek the video."
            return
        }
        seekCamera(to: dataTime - offset)
    }

    func clearError() {
        errorMessage = nil
    }

    private func loadRuns() throws {
        guard let projectURL else { throw StudioError.noProject }
        let runsURL = projectURL.appendingPathComponent("runs", isDirectory: true)
        let directories = try FileManager.default.contentsOfDirectory(
            at: runsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true &&
            FileManager.default.fileExists(atPath: url.appendingPathComponent("data.csv").path)
        }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        let previousID = selectedRunID
        runs = try directories.compactMap { try Self.loadRun(at: $0) }
        selectedRunID = runs.contains(where: { $0.id == previousID }) ? previousID : runs.first?.id
        cameraLabel = "double tap \((selectedRun?.markers.count ?? 0) + 1)"
        loadCameraPlayer()
    }

    private func loadWorkspace() throws {
        guard let projectURL else { throw StudioError.noProject }
        let path = projectURL.appendingPathComponent(".studio/run-calibration-workspace.json")
        guard let object = try readJSONObject(at: path) else {
            calibrationPoints = []
            calibrationFit = nil
            return
        }
        let sections = object["sections"] as? [[String: Any]] ?? []
        calibrationPoints = sections.compactMap(Self.decodeCalibrationPoint)
        if let fitObject = object["fit"] as? [String: Any] {
            let savedFit = Self.decodeFit(fitObject)
            calibrationFit = (try? Self.fit(points: calibrationPoints)) ?? savedFit
        } else {
            calibrationFit = nil
        }
    }

    private func loadCameraPlayer() {
        cameraPlayer = nil
        guard let url = selectedRun?.cameraURL else { return }
        cameraPlayer = AVPlayer(url: url)
    }

    private func updateCamera(runID: String, file: String?, offset: Double?, marker: SyncMarker?) throws {
        guard let run = runs.first(where: { $0.id == runID }) else { return }
        let previousFile = run.cameraFile
        let path = run.directoryURL.appendingPathComponent("run.json")
        var manifest = try readJSONObject(at: path) ?? [:]
        var camera = manifest["camera"] as? [String: Any] ?? [:]
        if let file {
            camera["file"] = file
        }
        if let offset {
            camera["offsetSeconds"] = offset
        }
        camera["updatedAt"] = studioTimestamp()
        var markers = camera["markers"] as? [[String: Any]] ?? []
        if let marker {
            markers.append(marker.asJSONObject())
        }
        camera["markers"] = markers
        manifest["camera"] = camera
        try writeJSON(manifest, to: path)

        let syncURL = run.directoryURL.appendingPathComponent("camera/sync.csv")
        try FileManager.default.createDirectory(at: syncURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var csv = "camera_time_s,data_time_s,label,notes\n"
        for item in markers {
            let cameraText = (item["cameraTimeSeconds"] as? NSNumber).map { String(format: "%.6f", $0.doubleValue) } ?? ""
            let dataText = (item["dataTimeSeconds"] as? NSNumber).map { String(format: "%.6f", $0.doubleValue) } ?? ""
            let label = (item["label"] as? String ?? "").csvEscaped
            let notes = (item["notes"] as? String ?? "").csvEscaped
            csv += "\(cameraText),\(dataText),\(label),\(notes)\n"
        }
        try csv.write(to: syncURL, atomically: true, encoding: .utf8)
        if let offset {
            try exportCameraTimes(run: run, offset: offset)
        }

        if let index = runs.firstIndex(where: { $0.id == runID }) {
            runs[index].cameraFile = camera["file"] as? String
            runs[index].cameraOffsetSeconds = (camera["offsetSeconds"] as? NSNumber)?.doubleValue
            runs[index].markers = markers.compactMap(Self.decodeMarker)
            if selectedRunID == runID, previousFile != runs[index].cameraFile {
                loadCameraPlayer()
            }
        }
    }

    private func export(run: Run, fit: CalibrationFit) throws {
        let source = run.directoryURL.appendingPathComponent("data.csv")
        let destination = run.directoryURL.appendingPathComponent("data-calibrated.csv")
        let text = try String(contentsOf: source, encoding: .utf8)
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard let header = lines.first else { throw StudioError.invalidCSV(source) }
        var columns = header.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard let rawIndex = columns.firstIndex(of: "raw") else { throw StudioError.invalidCSV(source) }
        let forceIndex: Int
        if let existing = columns.firstIndex(of: "calibrated_force_lb") {
            forceIndex = existing
        } else {
            columns.append("calibrated_force_lb")
            forceIndex = columns.count - 1
        }
        var output = columns.joined(separator: ",") + "\n"
        for line in lines.dropFirst() {
            var fields = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard fields.count > rawIndex, let raw = Double(fields[rawIndex].trimmingCharacters(in: .whitespacesAndNewlines)) else {
                continue
            }
            if fields.count <= forceIndex {
                fields.append(contentsOf: repeatElement("", count: forceIndex + 1 - fields.count))
            }
            fields[forceIndex] = String(format: "%.9f", fit.calibratedForce(for: raw))
            output += fields.joined(separator: ",") + "\n"
        }
        try output.write(to: destination, atomically: true, encoding: .utf8)
    }

    private func exportCameraTimes(run: Run, offset: Double) throws {
        let source = run.directoryURL.appendingPathComponent("data.csv")
        let text = try String(contentsOf: source, encoding: .utf8)
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard let header = lines.first else { throw StudioError.invalidCSV(source) }
        var columns = header.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard let timeIndex = columns.firstIndex(of: "time_s") else { throw StudioError.invalidCSV(source) }
        let cameraIndex: Int
        if let existing = columns.firstIndex(of: "camera_time_s") {
            cameraIndex = existing
        } else {
            columns.append("camera_time_s")
            cameraIndex = columns.count - 1
        }
        var output = columns.joined(separator: ",") + "\n"
        for line in lines.dropFirst() {
            var fields = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard fields.count > timeIndex,
                  let time = Double(fields[timeIndex].trimmingCharacters(in: .whitespacesAndNewlines)) else {
                continue
            }
            if fields.count <= cameraIndex {
                fields.append(contentsOf: repeatElement("", count: cameraIndex + 1 - fields.count))
            }
            fields[cameraIndex] = String(format: "%.6f", time - offset)
            output += fields.joined(separator: ",") + "\n"
        }
        try output.write(to: source, atomically: true, encoding: .utf8)
    }

    private func showError(_ error: Error) {
        errorMessage = error.localizedDescription
        statusMessage = "Needs attention."
    }

    nonisolated private static func loadRun(at directory: URL) throws -> Run? {
        let manifestURL = directory.appendingPathComponent("run.json")
        let manifest = try readJSONObject(at: manifestURL)
        let id = manifest?["runId"] as? String ?? directory.lastPathComponent
        let label = manifest?["label"] as? String ?? id
        let dataURL = directory.appendingPathComponent("data.csv")
        let samples = try loadSamples(from: dataURL)
        guard samples.count > 1 else { return nil }
        let camera = manifest?["camera"] as? [String: Any] ?? [:]
        let markers = (camera["markers"] as? [[String: Any]] ?? []).compactMap(decodeMarker)
        return Run(
            id: id,
            label: label,
            directoryURL: directory,
            samples: samples,
            cameraFile: camera["file"] as? String,
            cameraOffsetSeconds: (camera["offsetSeconds"] as? NSNumber)?.doubleValue,
            markers: markers
        )
    }

    nonisolated private static func loadSamples(from url: URL) throws -> [DataSample] {
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw StudioError.cannotRead(url, error)
        }
        let lines = text.split(whereSeparator: \.isNewline)
        guard let headerLine = lines.first else { throw StudioError.invalidCSV(url) }
        let headers = headerLine.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard let timeIndex = headers.firstIndex(of: "time_s"),
              let rawIndex = headers.firstIndex(of: "raw") else {
            throw StudioError.invalidCSV(url)
        }
        var samples: [DataSample] = []
        samples.reserveCapacity(lines.count - 1)
        for (index, line) in lines.dropFirst().enumerated() {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count > max(timeIndex, rawIndex),
                  let time = Double(fields[timeIndex].trimmingCharacters(in: .whitespacesAndNewlines)),
                  let raw = Double(fields[rawIndex].trimmingCharacters(in: .whitespacesAndNewlines)) else {
                continue
            }
            samples.append(DataSample(id: index, time: time, raw: raw))
        }
        guard samples.count > 1 else { throw StudioError.invalidCSV(url) }
        return samples
    }

    nonisolated static func fit(points: [CalibrationPoint]) throws -> CalibrationFit {
        guard points.count >= 2 else { throw StudioError.insufficientCalibrationPoints }
        let count = Double(points.count)
        let weights = points.map(\.weightLb)
        let raws = points.map(\.meanRaw)
        let sumX = weights.reduce(0, +)
        let sumY = raws.reduce(0, +)
        let sumXX = weights.reduce(0) { $0 + $1 * $1 }
        let sumXY = zip(weights, raws).reduce(0) { $0 + $1.0 * $1.1 }
        let denominator = count * sumXX - sumX * sumX
        guard abs(denominator) > 1e-12 else { throw StudioError.identicalCalibrationWeights }
        let slope = (count * sumXY - sumX * sumY) / denominator
        guard abs(slope) > 1e-12 else { throw StudioError.identicalCalibrationWeights }
        let intercept = (sumY - slope * sumX) / count
        let residualsRaw = zip(raws, weights).map { $0.0 - (intercept + slope * $0.1) }
        let residualsLb = residualsRaw.map { $0 / slope }
        let rms = sqrt(residualsLb.reduce(0) { $0 + $1 * $1 } / count)
        let maxError = residualsLb.map(abs).max() ?? 0
        let meanRaw = sumY / count
        let total = raws.reduce(0) { $0 + pow($1 - meanRaw, 2) }
        let residualTotal = residualsRaw.reduce(0) { $0 + $1 * $1 }
        let rSquared = total > 0 ? 1 - residualTotal / total : 1
        return CalibrationFit(
            zeroRaw: intercept,
            countsPerPound: slope,
            residualsLb: residualsLb,
            rmsErrorLb: rms,
            maxErrorLb: maxError,
            rSquared: rSquared
        )
    }

    nonisolated private static func decodeCalibrationPoint(_ object: [String: Any]) -> CalibrationPoint? {
        guard let runId = object["runId"] as? String,
              let start = (object["startS"] as? NSNumber)?.doubleValue,
              let end = (object["endS"] as? NSNumber)?.doubleValue,
              let weight = (object["weightLb"] as? NSNumber)?.doubleValue else { return nil }
        return CalibrationPoint(
            runId: runId,
            range: TimeRange(start: start, end: end),
            label: object["label"] as? String ?? "Unnamed section",
            weightLb: weight,
            meanRaw: (object["meanRaw"] as? NSNumber)?.doubleValue ?? 0,
            stddevRaw: (object["stddevRaw"] as? NSNumber)?.doubleValue ?? 0,
            sampleCount: (object["sampleCount"] as? NSNumber)?.intValue ?? 0,
            id: UUID(uuidString: object["id"] as? String ?? "") ?? UUID()
        )
    }

    nonisolated private static func decodeFit(_ object: [String: Any]) -> CalibrationFit? {
        guard let zero = (object["zeroRaw"] as? NSNumber)?.doubleValue,
              let slope = (object["countsPerPound"] as? NSNumber)?.doubleValue else { return nil }
        return CalibrationFit(
            zeroRaw: zero,
            countsPerPound: slope,
            residualsLb: [],
            rmsErrorLb: (object["rmsErrorLb"] as? NSNumber)?.doubleValue ?? 0,
            maxErrorLb: (object["maxErrorLb"] as? NSNumber)?.doubleValue ?? 0,
            rSquared: (object["rSquared"] as? NSNumber)?.doubleValue ?? 0
        )
    }

    nonisolated private static func decodeMarker(_ object: [String: Any]) -> SyncMarker? {
        guard let dataTime = (object["dataTimeSeconds"] as? NSNumber)?.doubleValue else { return nil }
        var marker = SyncMarker(
            label: object["label"] as? String ?? "Marker",
            dataTimeSeconds: dataTime,
            cameraTimeSeconds: (object["cameraTimeSeconds"] as? NSNumber)?.doubleValue,
            notes: object["notes"] as? String ?? "",
            createdAt: object["createdAt"] as? String ?? ""
        )
        if let id = object["id"] as? String, let uuid = UUID(uuidString: id) {
            marker = SyncMarker(
                label: marker.label,
                dataTimeSeconds: marker.dataTimeSeconds,
                cameraTimeSeconds: marker.cameraTimeSeconds,
                notes: marker.notes,
                createdAt: marker.createdAt
            )
            _ = uuid
        }
        return marker
    }
}

private func readJSONObject(at url: URL) throws -> [String: Any]? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let data = try Data(contentsOf: url)
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw StudioError.malformedManifest(url)
    }
    return object
}

private func writeJSON(_ object: [String: Any], to url: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
}

private func uniqueCameraDestination(for source: URL, in directory: URL) -> URL {
    let base = source.deletingPathExtension().lastPathComponent
    let extensionName = source.pathExtension
    var candidate = directory.appendingPathComponent(source.lastPathComponent)
    var index = 2
    while FileManager.default.fileExists(atPath: candidate.path),
          candidate.standardizedFileURL != source.standardizedFileURL {
        let filename = extensionName.isEmpty ? "\(base)-\(index)" : "\(base)-\(index).\(extensionName)"
        candidate = directory.appendingPathComponent(filename)
        index += 1
    }
    return candidate
}
