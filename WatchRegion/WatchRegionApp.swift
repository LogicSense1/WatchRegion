// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import SwiftUI

@main
struct WatchRegionApp: App {
    var body: some Scene {
        WindowGroup {
            NavigationStack { RegionView() }
        }
    }
}

private struct RegionView: View {
    @AppStorage("regionWriteTime") private var regionWriteTime = 0.0
    @AppStorage("requestedSalesRegion") private var requestedSalesRegion = ""
    @State private var region: WatchRegion?
    @State private var error: String?
    @State private var confirmation: RegionEdit?
    @State private var running = false
    private let restartDelay: TimeInterval = 65

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Label("Sales Region", systemImage: "globe.americas.fill")
                    .font(.headline)
                    .foregroundStyle(.cyan)
                Text(region?.label ?? (error == nil ? "Checking region…" : "Region unavailable"))
                    .font(.title3.bold())
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let region, regionWriteTime > 0 {
                    restartStatus(region)
                }
                if let error {
                    Text(error).font(.footnote).foregroundStyle(.orange)
                }
                if running { ProgressView() }

                Button("Apply United States") { confirmation = .apply }
                    .buttonStyle(.borderedProminent)
                    .tint(.cyan)
                    .disabled(running || region?.label != "CH / CH/B")
                Button("Restore Original") { confirmation = .restore }
                    .disabled(running || region?.label != "US / LL/A")

                Button("Refresh Region") { refreshRegion() }
                    .font(.footnote)
                    .disabled(running)
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("Watch Region")
        .confirmationDialog(confirmation?.restoresOriginal == true ? "Restore original region?" : "Apply United States?",
                            isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }),
                            titleVisibility: .visible, presenting: confirmation) { edit in
            Button(edit.restoresOriginal ? "Restore" : "Apply") { refreshRegion(edit) }
            Button("Cancel", role: .cancel) {}
        } message: { edit in
            Text(edit.restoresOriginal ? "Restore the saved original cache, then restart your watch."
                 : "Back up the original cache, apply US / LL/A, then restart your watch.")
        }
        .task { refreshRegion() }
    }

    @ViewBuilder
    private func restartStatus(_ region: WatchRegion) -> some View {
        if region.bootTime > regionWriteTime {
            Text(region.label == requestedSalesRegion ? "Verified after restart." : "The region changed during restart.")
                .font(.footnote)
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = Int(ceil(regionWriteTime + restartDelay - context.date.timeIntervalSince1970))
                Text(remaining > 0 ? "Verified. Wait \(remaining)s before restarting." : "Restart your watch, then reopen this app.")
                    .font(.footnote)
            }
        }
    }

    private func refreshRegion(_ edit: RegionEdit? = nil) {
        guard !running else { return }
        running = true
        error = nil
        Task {
            defer { running = false }
            do {
                let status = try await Task.detached { try RegionCache.readOrUpdate(edit) }.value
                region = status
                if status.changed {
                    requestedSalesRegion = status.label
                    regionWriteTime = Date().timeIntervalSince1970
                }
            } catch {
                self.error = error.localizedDescription
                if edit == nil { region = nil }
            }
        }
    }

}
