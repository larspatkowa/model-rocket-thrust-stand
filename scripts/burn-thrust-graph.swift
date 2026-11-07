import AVFoundation
import AppKit
import CoreGraphics
import Foundation
import QuartzCore

struct Sample {
	let cameraTime: Double
	let thrust: Double
}

func fail(_ message: String) -> Never {
	fputs("\(message)\n", stderr)
	exit(1)
}

guard CommandLine.arguments.count == 7 else {
	fail("Usage: swift burn-thrust-graph.swift COMPRESSED.mp4 CALIBRATED.csv SENSOR_MINUS_CAMERA_OFFSET CLIP_CAMERA_START FIRE_CAMERA_TIME OUTPUT.mp4")
}

let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let csvURL = URL(fileURLWithPath: CommandLine.arguments[2])
let sensorMinusCamera = Double(CommandLine.arguments[3]) ?? .nan
let clipCameraStart = Double(CommandLine.arguments[4]) ?? .nan
let fireCameraTime = Double(CommandLine.arguments[5]) ?? .nan
let outputURL = URL(fileURLWithPath: CommandLine.arguments[6])
guard inputURL.isFileURL, csvURL.isFileURL, outputURL.isFileURL,
	FileManager.default.fileExists(atPath: inputURL.path),
	FileManager.default.fileExists(atPath: csvURL.path),
	inputURL.standardizedFileURL != outputURL.standardizedFileURL,
	!FileManager.default.fileExists(atPath: outputURL.path),
	sensorMinusCamera.isFinite, clipCameraStart.isFinite, fireCameraTime.isFinite
else {
	fail("Check that both inputs exist, times are finite, and the output path does not already exist.")
}

func readSamples(from url: URL, offset: Double) throws -> [Sample] {
	let text = try String(contentsOf: url, encoding: .utf8)
	let rows = text.split(whereSeparator: \.isNewline)
	guard let header = rows.first else { return [] }
	let columns = header.split(separator: ",", omittingEmptySubsequences: false)
	guard let timeColumn = columns.firstIndex(of: "time_s"),
		let thrustColumn = columns.firstIndex(of: "calibrated_force_lb")
	else { throw NSError(domain: "ThrustGraph", code: 1, userInfo: [NSLocalizedDescriptionKey: "CSV needs time_s and calibrated_force_lb columns."]) }
	var samples: [Sample] = []
	for (index, row) in rows.dropFirst().enumerated() where index % 10 == 0 {
		let values = row.split(separator: ",", omittingEmptySubsequences: false)
		guard values.count > max(timeColumn, thrustColumn),
			let time = Double(values[timeColumn]),
			let thrust = Double(values[thrustColumn]),
			time.isFinite, thrust.isFinite
		else { continue }
		samples.append(Sample(cameraTime: time - offset, thrust: thrust))
	}
	return samples
}

func smooth(_ samples: [Sample], radius: Int = 5) -> [Sample] {
	guard samples.count > radius * 2 else { return samples }
	return samples.indices.map { index in
		let lower = max(0, index - radius)
		let upper = min(samples.count - 1, index + radius)
	let average = samples[lower...upper].reduce(0.0) { $0 + $1.thrust } / Double(upper - lower + 1)
		return Sample(cameraTime: samples[index].cameraTime, thrust: average)
	}
}

func interpolatedThrust(at cameraTime: Double, samples: [Sample]) -> Double {
	var low = 0
	var high = samples.count
	while low < high {
		let middle = (low + high) / 2
		if samples[middle].cameraTime < cameraTime { low = middle + 1 }
		else { high = middle }
	}
	if low == 0 { return samples[0].thrust }
	if low >= samples.count { return samples[samples.count - 1].thrust }
	let before = samples[low - 1]
	let after = samples[low]
	let fraction = (cameraTime - before.cameraTime) / max(0.000001, after.cameraTime - before.cameraTime)
	return before.thrust + (after.thrust - before.thrust) * fraction
}

func textImage(_ text: String, frame: CGRect, size: CGFloat, alignment: CATextLayerAlignmentMode = .left, color: CGColor = CGColor(gray: 1, alpha: 1)) -> CGImage {
	let scale: CGFloat = 2
	let pixelWidth = max(1, Int(ceil(frame.width * scale)))
	let pixelHeight = max(1, Int(ceil(frame.height * scale)))
	let context = CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
		space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
	context.scaleBy(x: scale, y: scale)
	let font = CTFontCreateWithName("HelveticaNeue-Medium" as CFString, size, nil)
	let attributes = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color] as CFDictionary
	let attributed = CFAttributedStringCreate(nil, text as CFString, attributes)!
	let line = CTLineCreateWithAttributedString(attributed)
	let textWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
	let x: CGFloat
	switch alignment {
	case .center: x = max(0, (frame.width - textWidth) / 2)
	case .right: x = max(0, frame.width - textWidth)
	default: x = 0
	}
	context.textPosition = CGPoint(x: x, y: max(0, (frame.height - size) / 2))
	CTLineDraw(line, context)
	return context.makeImage()!
}

func textLayer(_ text: String, frame: CGRect, size: CGFloat, alignment: CATextLayerAlignmentMode = .left, color: CGColor = CGColor(gray: 1, alpha: 1)) -> CALayer {
	let layer = CALayer()
	layer.frame = frame
	layer.contentsScale = 2
	layer.contents = textImage(text, frame: frame, size: size, alignment: alignment, color: color)
	return layer
}

func keyframe(_ keyPath: String, values: [Any], keyTimes: [NSNumber], duration: Double) -> CAKeyframeAnimation {
	let animation = CAKeyframeAnimation(keyPath: keyPath)
	animation.values = values
	animation.keyTimes = keyTimes
	animation.calculationMode = .linear
	animation.beginTime = AVCoreAnimationBeginTimeAtZero
	animation.duration = duration
	animation.fillMode = .both
	animation.isRemovedOnCompletion = false
	return animation
}

do {
	let samples = smooth(try readSamples(from: csvURL, offset: sensorMinusCamera))
	guard samples.count > 1 else { fail("The calibration CSV has no usable samples.") }
	let asset = AVURLAsset(url: inputURL)
	guard let track = asset.tracks(withMediaType: .video).first else { fail("The compressed video has no video track.") }
	let duration = CMTimeGetSeconds(asset.duration)
	let sourceSize = track.naturalSize.applying(track.preferredTransform)
	let upscale: CGFloat = 2
	let width = abs(sourceSize.width) * upscale
	let height = abs(sourceSize.height) * upscale
	// These Canon clips are approximately 30 fps. Their reported minFrameDuration
	// is not a reliable cadence, so use a normal 30 fps render instead.
	let frameDuration = CMTime(value: 1, timescale: 30)
	let frameRate = 30.0
	let frameCount = max(1, Int(ceil(duration * frameRate)))
	let keyTimes = (0..<frameCount).map { NSNumber(value: Double($0) / Double(frameCount)) }

	let graphWidth: CGFloat = min(520, width * 0.46)
	let graphHeight: CGFloat = 330
	let inset: CGFloat = 28
	let box = CGRect(x: inset, y: inset, width: graphWidth, height: graphHeight)
	let left: CGFloat = 78
	let right: CGFloat = graphWidth - 20
	let top: CGFloat = 226
	let bottom: CGFloat = 78
	let plotWidth = right - left
	let plotHeight = top - bottom
	let clipEnd = clipCameraStart + duration
	let clipSamples = samples.filter { $0.cameraTime >= clipCameraStart && $0.cameraTime <= clipEnd }
	guard clipSamples.count > 1 else { fail("No calibrated samples overlap the selected camera clip.") }
	let maximumForce = max(0.1, clipSamples.map(\.thrust).max() ?? 1)
	let forceUnit = pow(10, floor(log10(maximumForce)))
	let forceTop = max(forceUnit, ceil(maximumForce / forceUnit) * forceUnit)
	let royalBlue = CGColor(red: 65.0 / 255, green: 105.0 / 255, blue: 225.0 / 255, alpha: 1)
	let eventYellow = CGColor(red: 1, green: 0.89, blue: 0.25, alpha: 1)

	let videoLayer = CALayer()
	videoLayer.frame = CGRect(x: 0, y: 0, width: width, height: height)
	let parentLayer = CALayer()
	parentLayer.frame = videoLayer.frame
	parentLayer.addSublayer(videoLayer)
	let graph = CALayer()
	graph.frame = box
	graph.backgroundColor = CGColor(gray: 0, alpha: 0.56)
	graph.cornerRadius = 12
	graph.borderColor = CGColor(gray: 1, alpha: 0.24)
	graph.borderWidth = 1
	graph.masksToBounds = true
	parentLayer.addSublayer(graph)

	let gridPath = CGMutablePath()
	for division in 0...4 {
		let x = left + plotWidth * CGFloat(division) / 4
		gridPath.move(to: CGPoint(x: x, y: bottom))
		gridPath.addLine(to: CGPoint(x: x, y: top))
	}
	for division in 0...4 {
		let y = bottom + plotHeight * CGFloat(division) / 4
		gridPath.move(to: CGPoint(x: left, y: y))
		gridPath.addLine(to: CGPoint(x: right, y: y))
	}
	let grid = CAShapeLayer()
	grid.frame = graph.bounds
	grid.path = gridPath
	grid.strokeColor = CGColor(gray: 1, alpha: 0.46)
	grid.fillColor = nil
	grid.lineWidth = 0.8
	grid.lineDashPattern = [NSNumber(value: 1), NSNumber(value: 5)]
	grid.shadowColor = CGColor(gray: 0, alpha: 1)
	grid.shadowRadius = 2
	grid.shadowOpacity = 0.85
	graph.addSublayer(grid)

	let axisPath = CGMutablePath()
	axisPath.move(to: CGPoint(x: left, y: bottom))
	axisPath.addLine(to: CGPoint(x: left, y: top))
	axisPath.move(to: CGPoint(x: left, y: bottom))
	axisPath.addLine(to: CGPoint(x: right, y: bottom))
	let axis = CAShapeLayer()
	axis.frame = graph.bounds
	axis.path = axisPath
	axis.strokeColor = CGColor(gray: 1, alpha: 0.88)
	axis.fillColor = nil
	axis.lineWidth = 1
	axis.shadowColor = CGColor(gray: 0, alpha: 1)
	axis.shadowRadius = 2
	axis.shadowOpacity = 0.9
	graph.addSublayer(axis)

	graph.addSublayer(textLayer("RUN 1", frame: CGRect(x: 18, y: graphHeight - 39, width: 100, height: 25), size: 19))
	graph.addSublayer(textLayer("THRUST (lb)", frame: CGRect(x: 18, y: graphHeight - 70, width: 180, height: 25), size: 17))
	let currentValue = textLayer("0.0 lb", frame: CGRect(x: 18, y: graphHeight - 100, width: 180, height: 27), size: 23)
	let currentTime = textLayer("0.0 s", frame: CGRect(x: graphWidth - 106, y: 16, width: 86, height: 22), size: 16, alignment: .right)
	let zeroLabel = textLayer("0", frame: CGRect(x: 26, y: bottom - 11, width: 40, height: 22), size: 15, alignment: .right)
	let highLabel = textLayer(String(format: "%.0f", forceTop), frame: CGRect(x: 26, y: top - 11, width: 40, height: 22), size: 15, alignment: .right)
	let xLabels = (0...4).map { index in
		let time = clipCameraStart + duration * Double(index) / 4
		return textLayer(String(format: "%.0f", time),
			frame: CGRect(x: left - 24 + plotWidth * CGFloat(index) / 4, y: 43, width: 55, height: 22),
			size: 15, alignment: .center)
	}
	let xTitle = textLayer("CAMERA TIME (s)", frame: CGRect(x: left, y: 12, width: plotWidth, height: 22), size: 15, alignment: .center)
	[currentValue, currentTime, zeroLabel, highLabel, xTitle].forEach(graph.addSublayer)
	xLabels.forEach(graph.addSublayer)

	let trace = CAShapeLayer()
	trace.frame = graph.bounds
	trace.fillColor = nil
	trace.strokeColor = royalBlue
	trace.lineWidth = 4
	trace.lineCap = .round
	trace.lineJoin = .round
	graph.addSublayer(trace)

	let fireLine = CAShapeLayer()
	fireLine.frame = graph.bounds
	fireLine.fillColor = nil
	fireLine.strokeColor = eventYellow
	fireLine.lineWidth = 2
	fireLine.lineDashPattern = [NSNumber(value: 4), NSNumber(value: 4)]
	if fireCameraTime >= clipCameraStart && fireCameraTime <= clipEnd {
		let x = left + plotWidth * CGFloat((fireCameraTime - clipCameraStart) / duration)
		let eventPath = CGMutablePath()
		eventPath.move(to: CGPoint(x: x, y: bottom))
		eventPath.addLine(to: CGPoint(x: x, y: top))
		fireLine.path = eventPath
		graph.addSublayer(fireLine)
		graph.addSublayer(textLayer("FIRE", frame: CGRect(x: x - 32, y: top - 25, width: 64, height: 22), size: 16, alignment: .center, color: eventYellow))
	}
	let cursor = CAShapeLayer()
	cursor.frame = graph.bounds
	cursor.fillColor = nil
	cursor.strokeColor = CGColor(gray: 1, alpha: 0.88)
	cursor.lineWidth = 1.5
	graph.addSublayer(cursor)

	let pointsPerClip = max(240, Int(duration * 60))
	let tracePath = CGMutablePath()
	for point in 0...pointsPerClip {
		let fraction = Double(point) / Double(pointsPerClip)
		let time = clipCameraStart + fraction * duration
		let force = interpolatedThrust(at: time, samples: samples)
		let x = left + plotWidth * CGFloat(fraction)
		let y = bottom + plotHeight * CGFloat(max(0, min(forceTop, force)) / forceTop)
		if point == 0 { tracePath.move(to: CGPoint(x: x, y: y)) }
		else { tracePath.addLine(to: CGPoint(x: x, y: y)) }
	}
	trace.path = tracePath

	var cursorPaths: [Any] = []
	var valueImages: [Any] = []
	var timeImages: [Any] = []
	cursorPaths.reserveCapacity(frameCount)
	valueImages.reserveCapacity(frameCount)
	timeImages.reserveCapacity(frameCount)

	for frame in 0..<frameCount {
		let absoluteTime = clipCameraStart + Double(frame) / frameRate
		let cursorX = left + plotWidth * CGFloat((absoluteTime - clipCameraStart) / duration)
		let cursorPath = CGMutablePath()
		cursorPath.move(to: CGPoint(x: cursorX, y: bottom))
		cursorPath.addLine(to: CGPoint(x: cursorX, y: top))
		cursorPaths.append(cursorPath)
		let currentForce = interpolatedThrust(at: absoluteTime, samples: samples)
		valueImages.append(textImage(String(format: "%.1f lb", max(0, currentForce)), frame: currentValue.bounds, size: 23))
		timeImages.append(textImage(String(format: "%.1f s", absoluteTime), frame: currentTime.bounds, size: 16, alignment: .right))
	}
	cursor.add(keyframe("path", values: cursorPaths, keyTimes: keyTimes, duration: duration), forKey: "cursor")
	currentValue.add(keyframe("contents", values: valueImages, keyTimes: keyTimes, duration: duration), forKey: "value")
	currentTime.add(keyframe("contents", values: timeImages, keyTimes: keyTimes, duration: duration), forKey: "time")

	let composition = AVMutableVideoComposition()
	composition.renderSize = CGSize(width: width, height: height)
	composition.frameDuration = frameDuration
	let instruction = AVMutableVideoCompositionInstruction()
	instruction.timeRange = CMTimeRange(start: .zero, duration: asset.duration)
	let videoInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
	videoInstruction.setTransform(track.preferredTransform.concatenating(CGAffineTransform(scaleX: upscale, y: upscale)), at: .zero)
	instruction.layerInstructions = [videoInstruction]
	composition.instructions = [instruction]
	composition.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer, in: parentLayer)

	guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
		fail("Could not create the high-quality H.264 exporter.")
	}
	exporter.videoComposition = composition
	exporter.outputURL = outputURL
	exporter.outputFileType = .mp4
	exporter.shouldOptimizeForNetworkUse = true
	let completed = DispatchSemaphore(value: 0)
	exporter.exportAsynchronously { completed.signal() }
	completed.wait()
	guard exporter.status == .completed else {
		try? FileManager.default.removeItem(at: outputURL)
		fail("Overlay export failed: \(exporter.error?.localizedDescription ?? exporter.status.rawValue.description)")
	}
	print("Created \(outputURL.path) (\(Int(width))×\(Int(height)), \(String(format: "%.1f", duration)) seconds, \(frameCount) frames)")
} catch {
	fail(error.localizedDescription)
}
