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
            if model.isOnboarded {
                HomeView()
            } else {
                OnboardingView()
            }
        }
        .fullScreenCover(isPresented: $model.isRinging) {
            RingingView()
        }
        .task {
            await model.observeAlarmUpdates()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.sweepAlertingAlarms()
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
