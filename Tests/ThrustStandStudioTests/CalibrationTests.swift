import AVFoundation
import XCTest
@testable import ThrustStandStudio

final class CalibrationTests: XCTestCase {
    @MainActor
    func testAppStoreDiscoversSavedRunsAtLaunch() throws {
        let store = AppStore()
        let fixture = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("runs/launch-04/data.csv")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: fixture.path), "local four-run capture fixture is not present")

        XCTAssertEqual(store.projectURL?.lastPathComponent, "model-rocket-thrust-stand")
        XCTAssertEqual(store.runs.count, 4)
        XCTAssertNotNil(store.selectedRunID)
    }

    @MainActor
    func testWebsiteExamplesLoadWithClipOffsets() throws {
        let store = AppStore()
        try XCTSkipUnless(store.runs.count == 4, "example runs are not present")
        let first = try XCTUnwrap(store.runs.first { $0.id == "launch-01" })
        let second = try XCTUnwrap(store.runs.first { $0.id == "launch-02" })
        XCTAssertEqual(try XCTUnwrap(first.cameraOffsetSeconds), 293.2554516471308 - 288, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(second.cameraOffsetSeconds), 18.64513636172016 - 15, accuracy: 0.000001)
        XCTAssertNotNil(first.cameraURL)
        XCTAssertNotNil(second.cameraURL)
        XCTAssertTrue(store.runs.filter { $0.id == "launch-03" || $0.id == "launch-04" }.allSatisfy { $0.cameraURL == nil })
    }

    func testPoundsAndOunces() throws {
        XCTAssertEqual(try poundsAndOunces(pounds: "10", ounces: "1.4"), 10.0875, accuracy: 0.0000001)
    }

    func testFitMatchesKnownStraightLine() throws {
        let points = [
            CalibrationPoint(runId: "a", range: TimeRange(start: 0, end: 1), label: "empty", weightLb: 0, meanRaw: 100, stddevRaw: 1, sampleCount: 100),
            CalibrationPoint(runId: "a", range: TimeRange(start: 1, end: 2), label: "one", weightLb: 1, meanRaw: 350, stddevRaw: 1, sampleCount: 100),
            CalibrationPoint(runId: "a", range: TimeRange(start: 2, end: 3), label: "two", weightLb: 2, meanRaw: 600, stddevRaw: 1, sampleCount: 100)
        ]
        let fit = try AppStore.fit(points: points)
        XCTAssertEqual(fit.zeroRaw, 100, accuracy: 0.000001)
        XCTAssertEqual(fit.countsPerPound, 250, accuracy: 0.000001)
        XCTAssertEqual(fit.rSquared, 1, accuracy: 0.000001)
        XCTAssertEqual(fit.calibratedForce(for: 475), 1.5, accuracy: 0.000001)
    }

    func testZoomedTraceKeepsNarrowSpike() {
        let samples = (0..<10_000).map { index in
            DataSample(id: index, time: Double(index) / 100, raw: index == 5_001 ? 1_000 : 10)
        }
        let run = Run(
            id: "test",
            label: "test",
            directoryURL: URL(fileURLWithPath: NSTemporaryDirectory()),
            samples: samples,
            cameraFile: nil,
            cameraOffsetSeconds: nil,
            markers: []
        )

        let overview = run.tracePoints(in: TimeRange(start: 0, end: run.duration))
        let zoomed = run.tracePoints(in: TimeRange(start: 49.5, end: 50.5))

        XCTAssertTrue(overview.contains { $0.id == 5_001 })
        XCTAssertTrue(zoomed.contains { $0.id == 5_001 })
        XCTAssertTrue(zoomed.allSatisfy { $0.time >= 49.49 && $0.time <= 50.51 })
    }

    @MainActor
    func testCameraPlayerSurfaceUsesNativePlayerLayer() {
        let surface = CameraPlayerSurface(frame: .zero)
        let player = AVPlayer()

        surface.player = player

        XCTAssertTrue(surface.layer is AVPlayerLayer)
        XCTAssertIdentical((surface.layer as? AVPlayerLayer)?.player, player)
    }

    func testImportedCanonAVIAndMP4Load() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let importDirectory = root
            .appendingPathComponent(".local-archive/thrust-stand-mcs", isDirectory: true)
            .appendingPathComponent("camera-imports", isDirectory: true)
            .appendingPathComponent("140___08", isDirectory: true)
        let videoURLs = [
            importDirectory.appendingPathComponent("MVI_0812.AVI"),
            importDirectory.appendingPathComponent("converted/MVI_0812.mp4")
        ]
        try XCTSkipUnless(videoURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "staged Canon media is not present")

        for videoURL in videoURLs {
            let asset = AVURLAsset(url: videoURL)
            let duration = try await asset.load(.duration)
            let tracks = try await asset.load(.tracks)

            XCTAssertGreaterThan(duration.seconds, 300, videoURL.lastPathComponent)
            XCTAssertTrue(tracks.contains { $0.mediaType == .video }, videoURL.lastPathComponent)
            XCTAssertTrue(tracks.contains { $0.mediaType == .audio }, videoURL.lastPathComponent)
        }
    }
}
