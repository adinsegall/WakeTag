import SwiftUI

@main
struct WakeTagApp: App {
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            // Ringing replaces the whole hierarchy rather than presenting a
            // cover: a fullScreenCover loses the presentation slot to any open
            // sheet (alarm editor, settings), while dismantling HomeView tears
            // its sheets down automatically.
            if model.isRinging {
                RingingView()
            } else if model.isOnboarded {
                HomeView()
            } else {
                OnboardingView()
            }
        }
        .task {
            await model.observeAlarmUpdates()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            model.sweepAlertingAlarms()
            model.reconcileAlarms()
            if model.isRinging {
                // An interruption while suspended defers its `.ended`
                // notification — kick playback and the volume pin directly.
                MusicService.shared.resumeIfNeeded()
                if model.volumeGuardEnabled {
                    VolumeGuard.shared.reassert()
                }
            }
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.lastError != nil },
            set: { if !$0 { model.lastError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.lastError ?? "")
        }
    }
}
