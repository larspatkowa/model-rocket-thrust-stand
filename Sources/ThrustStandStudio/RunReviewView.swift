import AVFoundation
import SwiftUI

struct RunReviewView: View {
    let store: AppStore
    let run: Run
    @Binding var selection: TimeRange?
    let allowsSelection: Bool
    let markerTime: Double?
    let markerTimes: [Double]
    let sectionRanges: [TimeRange]
    let onTraceTimeTap: ((Double) -> Void)?
    @FocusState private var keyboardFocused: Bool
    @State private var graphRange: TimeRange?
    @State private var graphFocusTime: Double?
    @State private var graphPoints: [TracePoint] = []

    init(
        store: AppStore,
        run: Run,
        selection: Binding<TimeRange?>,
        allowsSelection: Bool,
        markerTime: Double?,
        markerTimes: [Double] = [],
        sectionRanges: [TimeRange] = [],
        onTraceTimeTap: ((Double) -> Void)?
    ) {
        self.store = store
        self.run = run
        self._selection = selection
        self.allowsSelection = allowsSelection
        self.markerTime = markerTime
        self.markerTimes = markerTimes
        self.sectionRanges = sectionRanges
        self.onTraceTimeTap = onTraceTimeTap
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.05)) { _ in
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    videoPane
                        .frame(minWidth: 330, idealWidth: 440, maxWidth: .infinity)
                    tracePane
                        .frame(minWidth: 390, idealWidth: 560, maxWidth: .infinity)
                }

                VStack(alignment: .leading, spacing: 14) {
                    videoPane
                    tracePane
                }
            }
        }
        .focusable()
        .focused($keyboardFocused)
        .simultaneousGesture(TapGesture().onEnded { keyboardFocused = true })
        .onKeyPress(keys: Set([.leftArrow, .rightArrow]), phases: [.down, .repeat]) { press in
            switch press.key {
            case .leftArrow:
                store.stepCameraFrame(by: -1)
                return .handled
            case .rightArrow:
                store.stepCameraFrame(by: 1)
                return .handled
            default:
                return .ignored
            }
        }
        .onChange(of: run.id) { _, _ in
            graphRange = nil
            graphFocusTime = nil
            graphPoints = run.tracePoints(in: fullGraphRange)
        }
        .onChange(of: currentGraphRange) { _, newValue in
            graphPoints = run.tracePoints(in: newValue)
        }
        .onAppear {
            graphPoints = run.tracePoints(in: currentGraphRange)
        }
    }

    private var videoPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Video")
                .font(.headline)

            if let player = store.cameraPlayer {
                CameraPlayerView(player: player)
                    .aspectRatio(4.0 / 3.0, contentMode: .fit)
                    .frame(minHeight: 260, maxHeight: 390)
                    .background(Color.black)

                HStack(spacing: 8) {
                    Button {
                        if player.timeControlStatus == .playing {
                            player.pause()
                        } else {
                            player.play()
                        }
                    } label: {
                        Image(systemName: player.timeControlStatus == .playing ? "pause.fill" : "play.fill")
                            .frame(width: 16, height: 16)
                    }
                    .accessibilityLabel(player.timeControlStatus == .playing ? "Pause video" : "Play video")
                    .help(player.timeControlStatus == .playing ? "Pause video" : "Play video")

                    Button {
                        store.stepCameraFrame(by: -1)
                    } label: {
                        Image(systemName: "chevron.left")
                            .frame(width: 16, height: 16)
                    }
                    .accessibilityLabel("Back one frame")
                    .help("Back 1 frame")

                    Button {
                        store.stepCameraFrame(by: 1)
                    } label: {
                        Image(systemName: "chevron.right")
                            .frame(width: 16, height: 16)
                    }
                    .accessibilityLabel("Forward one frame")
                    .help("Forward 1 frame")

                    Text(cameraTimeLabel)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("← → 1 frame")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Slider(
                    value: Binding(
                        get: { cameraProgress(for: player) },
                        set: { store.seekCamera(to: $0 * cameraDuration(for: player)) }
                    ),
                    in: 0...1
                )
                .controlSize(.small)

            } else {
                Text("No video is attached to this run.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 160, alignment: .center)
            }

            Button(store.cameraPlayer == nil ? "Add video…" : "Replace video…", action: store.chooseCameraVideo)
                .controlSize(.small)
        }
    }

    private var tracePane: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Graph")
                    .font(.headline)
                Spacer()
                if let markerTime = activeMarkerTime {
                    Text(String(format: "%.3f s", markerTime))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 6) {
                Button("−") {
                    zoomGraph(by: 2)
                }
                .controlSize(.small)
                .help("Zoom out")
                .disabled(graphRange == nil)
                Button("+") {
                    zoomGraph(by: 0.5)
                }
                .controlSize(.small)
                .help("Zoom in around the clicked point")
                Button("Fit") {
                    graphRange = nil
                }
                .controlSize(.small)
                .disabled(graphRange == nil)
                Spacer()
                Text(graphWindowLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            TracePlot(
                points: graphPoints,
                visibleRange: currentGraphRange,
                selection: $selection,
                sectionRanges: sectionRanges,
                markerTime: activeMarkerTime,
                markerTimes: markerTimes,
                allowsSelection: allowsSelection,
                onTimeTap: handleTraceTimeTap
            )
            .frame(minHeight: 260, maxHeight: 390)

            if graphRange != nil {
                HStack(spacing: 8) {
                    Text("0")
                    Slider(value: graphPosition, in: 0...1)
                        .accessibilityLabel("Graph position")
                    Text(String(format: "%.0f s", run.duration))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
    }

    private var activeMarkerTime: Double? {
        markerTime ?? store.projectedDataTime
    }

    private var cameraTimeLabel: String {
        guard let cameraTime = store.currentCameraTime else { return "Video —" }
        if let projected = store.projectedDataTime {
            return String(format: "Video %.3f s  •  Graph %.3f s", cameraTime, projected)
        }
        return String(format: "Video %.3f s", cameraTime)
    }

    private var fullGraphRange: TimeRange {
        TimeRange(start: 0, end: max(run.duration, 0.001))
    }

    private var currentGraphRange: TimeRange {
        graphRange?.ordered ?? fullGraphRange
    }

    private var graphWindowLabel: String {
        let range = currentGraphRange
        return String(format: "%.2f–%.2f s", range.start, range.end)
    }

    private var graphPosition: Binding<Double> {
        Binding(
            get: {
                let available = max(0, fullGraphRange.duration - currentGraphRange.duration)
                guard available > 0 else { return 0 }
                return min(1, max(0, currentGraphRange.start / available))
            },
            set: { position in
                let width = currentGraphRange.duration
                let available = max(0, fullGraphRange.duration - width)
                let start = position * available
                graphRange = TimeRange(start: start, end: start + width)
                graphFocusTime = nil
            }
        )
    }

    private var graphFocus: Double {
        let range = currentGraphRange
        let candidate = graphFocusTime ?? activeMarkerTime ?? ((range.start + range.end) / 2)
        guard candidate >= range.start, candidate <= range.end else {
            return (range.start + range.end) / 2
        }
        return min(max(candidate, 0), run.duration)
    }

    private func handleTraceTimeTap(_ time: Double) {
        graphFocusTime = time
        onTraceTimeTap?(time)
    }

    private func zoomGraph(by factor: Double) {
        let full = fullGraphRange
        let current = currentGraphRange
        let minimumWindow = min(full.duration, max(0.25, full.duration / 1_000))
        let targetDuration = min(full.duration, max(minimumWindow, current.duration * factor))
        guard targetDuration < full.duration * 0.999 else {
            graphRange = nil
            return
        }
        let start = min(max(0, graphFocus - targetDuration / 2), full.duration - targetDuration)
        graphRange = TimeRange(start: start, end: start + targetDuration)
    }

    private func cameraDuration(for player: AVPlayer) -> Double {
        let duration = player.currentItem?.duration.seconds ?? 0
        return duration.isFinite && duration > 0 ? duration : max(run.duration, 1)
    }

    private func cameraProgress(for player: AVPlayer) -> Double {
        guard let cameraTime = store.currentCameraTime else { return 0 }
        return min(1, max(0, cameraTime / cameraDuration(for: player)))
    }

}
