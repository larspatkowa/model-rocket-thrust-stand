import AVFoundation
import CoreGraphics
import Foundation

struct ConversionError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

func export(asset: AVAsset, to outputURL: URL, upscale: Bool) throws {
    guard !FileManager.default.fileExists(atPath: outputURL.path) else {
        throw ConversionError(message: "Output already exists: \(outputURL.path)")
    }

    guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
        throw ConversionError(message: "Could not create an AVAssetExportSession for \(asset)")
    }

    let videoTracks = asset.tracks(withMediaType: .video)
    if upscale {
        guard let videoTrack = videoTracks.first else {
            throw ConversionError(message: "No video track found in \(asset)")
        }

        let naturalSize = videoTrack.naturalSize
        let renderSize = CGSize(width: abs(naturalSize.width) * 2.0,
                                height: abs(naturalSize.height) * 2.0)
        let composition = AVMutableVideoComposition()
        composition.renderSize = renderSize
        composition.frameDuration = videoTrack.minFrameDuration.isValid
            ? videoTrack.minFrameDuration
            : CMTime(value: 1001, timescale: 30000)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: asset.duration)

        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        layerInstruction.setTransform(CGAffineTransform(scaleX: 2.0, y: 2.0), at: .zero)
        instruction.layerInstructions = [layerInstruction]
        composition.instructions = [instruction]
        session.videoComposition = composition
    }

    session.outputURL = outputURL
    session.outputFileType = .mp4
    session.shouldOptimizeForNetworkUse = false

    let semaphore = DispatchSemaphore(value: 0)
    session.exportAsynchronously {
        semaphore.signal()
    }
    semaphore.wait()

    guard session.status == .completed else {
        let detail = session.error?.localizedDescription ?? "status \(session.status.rawValue)"
        throw ConversionError(message: "Export failed for \(outputURL.lastPathComponent): \(detail)")
    }
}

func convert(inputURL: URL, outputDirectory: URL) throws {
    let asset = AVURLAsset(url: inputURL)
    let baseName = inputURL.deletingPathExtension().lastPathComponent
    let regularURL = outputDirectory.appendingPathComponent("\(baseName).mp4")
    let upscaleURL = outputDirectory.appendingPathComponent("\(baseName)-2x.mp4")

    print("Converting \(inputURL.lastPathComponent) → \(regularURL.lastPathComponent)")
    try export(asset: asset, to: regularURL, upscale: false)
    print("  wrote \(regularURL.lastPathComponent)")

    print("Upscaling \(inputURL.lastPathComponent) → \(upscaleURL.lastPathComponent)")
    try export(asset: asset, to: upscaleURL, upscale: true)
    print("  wrote \(upscaleURL.lastPathComponent)")
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 2 else {
    fputs("usage: swift scripts/convert_camera_media.swift OUTPUT_DIRECTORY INPUT.AVI [INPUT.AVI ...]\n", stderr)
    exit(EXIT_FAILURE)
}

let outputDirectory = URL(fileURLWithPath: arguments[0], isDirectory: true)
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

do {
    for inputPath in arguments.dropFirst() {
        try convert(inputURL: URL(fileURLWithPath: inputPath), outputDirectory: outputDirectory)
    }
} catch {
    fputs("error: \(error.localizedDescription)\n", stderr)
    exit(EXIT_FAILURE)
}
