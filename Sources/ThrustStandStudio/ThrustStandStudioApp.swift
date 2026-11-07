import SwiftUI

@main
struct ThrustStandStudioApp: App {
    @State private var store = AppStore()

    var body: some Scene {
        WindowGroup("Thrust Stand Studio") {
            ContentView(store: store)
                .frame(minWidth: 980, minHeight: 720)
        }
        .defaultSize(width: 1220, height: 860)
    }
}

struct ContentView: View {
    let store: AppStore

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            sidebar
        } detail: {
            VStack(spacing: 0) {
                Picker("Workspace", selection: $store.mode) {
                    ForEach(AppStore.Mode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)
                .padding(.top, 12)

                Group {
                    switch store.mode {
                    case .calibrate:
                        CalibrationView(store: store)
                    case .sync:
                        SyncView(store: store)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .toolbar {
                ToolbarItem { Button("Refresh", action: store.refresh) }
            }
            .alert(
                "Needs attention",
                isPresented: Binding(
                    get: { store.errorMessage != nil },
                    set: { if !$0 { store.clearError() } }
                )
            ) {
                Button("OK", action: store.clearError)
            } message: {
                Text(store.errorMessage ?? "")
            }
        }
        .onChange(of: store.selectedRunID) { _, newValue in
            store.selectRun(newValue)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Saved runs")
                .font(.headline)
                .padding(.horizontal, 10)
                .padding(.top, 10)

            if store.runs.isEmpty {
                Text("No saved runs found.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
            } else {
                List(selection: Binding(
                    get: { store.selectedRunID },
                    set: { store.selectedRunID = $0 }
                )) {
                    ForEach(store.runs) { run in
                        Text(run.label)
                        .tag(run.id as String?)
                        .padding(.vertical, 2)
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .frame(minWidth: 220)
    }
}
