import SwiftUI

struct TracePlot: View {
    let points: [TracePoint]
    let visibleRange: TimeRange
    @Binding var selection: TimeRange?
    var sectionRanges: [TimeRange] = []
    var markerTime: Double?
    var markerTimes: [Double] = []
    var allowsSelection = true
    var onTimeTap: ((Double) -> Void)?

    private var rawBounds: (min: Double, max: Double) {
        let values = points.map(\.raw)
        guard let minimum = values.min(), let maximum = values.max() else {
            return (0, 1)
        }
        if minimum == maximum {
            return (minimum - 1, maximum + 1)
        }
        let padding = (maximum - minimum) * 0.04
        return (minimum - padding, maximum + padding)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    drawTrace(in: &context, size: size)
                }
                .background(Color(nsColor: .textBackgroundColor))

                if allowsSelection {
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(selectionGesture(width: proxy.size.width))
                        .simultaneousGesture(
                            SpatialTapGesture().onEnded { value in
                                onTimeTap?(time(atX: value.location.x, width: proxy.size.width))
                            }
                        )
                } else {
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(
                            SpatialTapGesture().onEnded { value in
                                onTimeTap?(time(atX: value.location.x, width: proxy.size.width))
                            }
                        )
                }
            }
        }
        .frame(minHeight: 220)
        .overlay {
            Rectangle().stroke(Color.secondary.opacity(0.35), lineWidth: 1)
        }
        .accessibilityLabel("Sensor graph")
        .accessibilityHint(allowsSelection ? "Drag to select a section. Click to set the zoom center." : "Click to mark a tap and set the zoom center.")
    }

    private func drawTrace(in context: inout GraphicsContext, size: CGSize) {
        let range = visibleRange.ordered
        guard points.count > 1, range.duration > 0 else { return }
        let bounds = rawBounds
        let xScale = size.width / range.duration
        let yScale = size.height / max(bounds.max - bounds.min, .ulpOfOne)

        for section in sectionRanges {
            let ordered = section.ordered
            let start = max(range.start, ordered.start)
            let end = min(range.end, ordered.end)
            guard end > start else { continue }
            let rect = CGRect(
                x: CGFloat((start - range.start) * xScale),
                y: 0,
                width: CGFloat((end - start) * xScale),
                height: size.height
            )
            context.fill(Path(rect), with: .color(.green.opacity(0.16)))
        }

        var path = Path()
        for (index, point) in points.enumerated() {
            let x = CGFloat((point.time - range.start) * xScale)
            let y = size.height - CGFloat((point.raw - bounds.min) * yScale)
            let coordinate = CGPoint(x: x, y: y)
            if index == 0 {
                path.move(to: coordinate)
            } else {
                path.addLine(to: coordinate)
            }
        }
        context.stroke(path, with: .color(.accentColor), lineWidth: 1.25)

        if let selection {
            let ordered = selection.ordered
            let start = max(range.start, min(range.end, ordered.start))
            let end = max(range.start, min(range.end, ordered.end))
            if end > start {
                let startX = CGFloat((start - range.start) / range.duration) * size.width
                let endX = CGFloat((end - range.start) / range.duration) * size.width
                let rect = CGRect(x: startX, y: 0, width: max(endX - startX, 2), height: size.height)
                context.fill(Path(rect), with: .color(.accentColor.opacity(0.16)))
                context.stroke(Path(rect), with: .color(.accentColor.opacity(0.75)), lineWidth: 1)
            }
        }

        for time in markerTimes {
            guard time >= range.start, time <= range.end else { continue }
            let x = CGFloat((time - range.start) / range.duration) * size.width
            var marker = Path()
            marker.move(to: CGPoint(x: x, y: 0))
            marker.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(marker, with: .color(.orange.opacity(0.55)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }

        if let markerTime {
            if markerTime >= range.start, markerTime <= range.end {
                let x = CGFloat((markerTime - range.start) / range.duration) * size.width
                var marker = Path()
                marker.move(to: CGPoint(x: x, y: 0))
                marker.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(marker, with: .color(.orange), style: StrokeStyle(lineWidth: 1.75, dash: [4, 3]))
            }
        }
    }

    private func selectionGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard abs(value.translation.width) >= 4 else { return }
                let start = time(atX: value.startLocation.x, width: width)
                let end = time(atX: value.location.x, width: width)
                selection = TimeRange(start: start, end: end).ordered
            }
            .onEnded { value in
                guard abs(value.translation.width) >= 4 else { return }
                let start = time(atX: value.startLocation.x, width: width)
                let end = time(atX: value.location.x, width: width)
                let range = TimeRange(start: start, end: end).ordered
                if range.duration >= max(visibleRange.duration * 0.001, 0.005) {
                    selection = range
                }
            }
    }

    private func time(atX x: CGFloat, width: CGFloat) -> Double {
        let range = visibleRange.ordered
        guard range.duration > 0 else { return range.start }
        let fraction = min(1, max(0, Double(x / max(width, 1))))
        return range.start + fraction * range.duration
    }
}
