import SwiftUI

struct SyncView: View {
    let store: AppStore

    private var dataBinding: Binding<TimeRange?> {
        Binding(
            get: {
                guard let time = store.syncDataTime else { return nil }
                return TimeRange(start: time, end: time)
            },
            set: { value in
                store.syncDataTime = value?.ordered.start
            }
        )
    }

    var body: some View {
        if let run = store.selectedRun {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    RunReviewView(
                        store: store,
                        run: run,
                        selection: dataBinding,
                        allowsSelection: false,
                        markerTime: store.syncDataTime,
                        markerTimes: run.markers.map(\.dataTimeSeconds),
                        onTraceTimeTap: { time in
                            store.setSyncDataTime(time)
                        }
                    )
                    markerPanel(run)
                }
                .padding(18)
            }
        } else {
            ContentUnavailableView(
                "No run selected",
                systemImage: "video",
                description: Text("Choose a run in the sidebar.")
            )
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Sync")
                .font(.title2)
            Text("Pause on a frame, click the matching graph point, then add it. Repeat for each tap.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func markerPanel(_ run: Run) -> some View {
        GroupBox("Time points") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    if let dataTime = store.syncDataTime, let videoTime = store.currentCameraTime {
                        Text(String(format: "Video %.3f s   Graph %.3f s", videoTime, dataTime))
                            .font(.caption.monospacedDigit())
                    } else {
                        Text("Pause on a frame and click its matching graph point.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Add time point", action: store.saveCameraMarker)
                        .disabled(store.syncDataTime == nil || store.cameraPlayer == nil)
                }

                if !run.markers.isEmpty {
                    Divider()
                    ForEach(run.markers) { marker in
                        HStack {
                            Text(marker.label)
                                .frame(minWidth: 120, alignment: .leading)
                            Text(String(format: "video %.3f s", marker.cameraTimeSeconds ?? 0))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text(String(format: "graph %.3f s", marker.dataTimeSeconds))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .padding(2)
        }
    }
}
