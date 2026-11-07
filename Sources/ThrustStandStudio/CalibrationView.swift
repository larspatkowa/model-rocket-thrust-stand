import SwiftUI

struct CalibrationView: View {
    let store: AppStore
    @State private var label = ""
    @State private var pounds = "0"
    @State private var ounces = "0"

    private var selectionBinding: Binding<TimeRange?> {
        Binding(
            get: { store.selectedRange },
            set: { store.selectedRange = $0 }
        )
    }

    var body: some View {
        if let run = store.selectedRun {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    runHeader
                    RunReviewView(
                        store: store,
                        run: run,
                        selection: selectionBinding,
                        allowsSelection: true,
                        markerTime: nil,
                        sectionRanges: store.calibrationPoints
                            .filter { $0.runId == run.id }
                            .map(\.range),
                        onTraceTimeTap: store.seekCameraToDataTime
                    )
                    selectionEditor
                    sections
                    fitSummary
                }
                .padding(18)
            }
        } else {
            ContentUnavailableView(
                "No run selected",
                systemImage: "waveform.path.ecg",
                description: Text("Choose a run in the sidebar.")
            )
        }
    }

    private var runHeader: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Weight points")
                .font(.title2)
            Text("Select a steady range, then enter the total weight on the mount.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var selectionEditor: some View {
        GroupBox("Add section") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    if let selection = store.selectedRange {
                        Text(String(format: "Selected %.3f–%.3f s  (%.3f s)", selection.ordered.start, selection.ordered.end, selection.duration))
                            .font(.caption.monospacedDigit())
                    } else {
                        Text("No range selected yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Clear") {
                        store.selectedRange = nil
                    }
                    .controlSize(.small)
                    .disabled(store.selectedRange == nil)
                }

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Text("Section name")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Rocket holder, dumbbell holder, speaker…", text: $label)
                        .textFieldStyle(.roundedBorder)
                }

                HStack(alignment: .bottom, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Pounds")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("0", text: $pounds)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Ounces")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("0", text: $ounces)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                    }
                    Button("Add weight point") {
                        store.addCalibrationPoint(label: label, pounds: pounds, ounces: ounces)
                        label = ""
                    }
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(store.selectedRange == nil)
                }
            }
            .padding(2)
        }
    }

    private var sections: some View {
        GroupBox("Weight points") {
            VStack(alignment: .leading, spacing: 0) {
                if store.calibrationPoints.isEmpty {
                    Text("No sections yet.")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    HStack {
                        Text("Name").frame(minWidth: 170, alignment: .leading)
                        Text("Time").frame(width: 132, alignment: .leading)
                        Text("Load").frame(width: 92, alignment: .leading)
                        Text("Run").frame(width: 92, alignment: .leading)
                        Spacer()
                    }
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 5)

                    ForEach(store.calibrationPoints) { point in
                        HStack {
                            Text(point.label).frame(minWidth: 170, alignment: .leading)
                            Text(String(format: "%.3f–%.3f s", point.startS, point.endS))
                                .frame(width: 132, alignment: .leading)
                            Text(formattedWeight(point.weightLb)).frame(width: 92, alignment: .leading)
                            Text(point.runId).frame(width: 92, alignment: .leading)
                            Button {
                                store.removeCalibrationPoint(point)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove section")
                            Spacer()
                        }
                        .font(.caption.monospacedDigit())
                        .padding(.vertical, 4)
                        Divider()
                    }
                }
            }
            .padding(2)
        }
    }

    private var fitSummary: some View {
        GroupBox("Calibration") {
            VStack(alignment: .leading, spacing: 8) {
                if let fit = store.calibrationFit {
                    DisclosureGroup("Fit details") {
                        HStack(spacing: 24) {
                            metric("Zero", value: String(format: "%.3f", fit.zeroRaw))
                            metric("Counts/lb", value: String(format: "%.3f", fit.countsPerPound))
                            metric("R²", value: String(format: "%.5f", fit.rSquared))
                            metric("RMS error", value: String(format: "%.4f lb", fit.rmsErrorLb))
                        }
                    }
                }

                HStack(spacing: 8) {
                    Button("Fit calibration", action: store.fitCalibration)
                    Button("Save workspace", action: store.saveWorkspace)
                    Button("Export corrected CSVs", action: store.exportCorrectedCSVs)
                        .disabled(store.calibrationFit == nil)
                }
                .controlSize(.small)
            }
            .padding(2)
        }
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.body.monospacedDigit())
        }
    }
}
