import SwiftUI

struct ContentView: View {
    @Environment(FuelModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if !model.isConfigured {
                ContentUnavailableView(
                    "Not set up",
                    systemImage: "wrench.and.screwdriver",
                    description: Text(FuelDataError.notConfigured.localizedDescription)
                )
            } else if model.location.authorization == .notDetermined {
                WelcomeView { model.location.start() }
            } else if model.location.isDenied {
                LocationDeniedView()
            } else {
                StationListView()
            }
        }
        .task { await model.start() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await model.refresh(force: false) }
            }
        }
    }
}

private struct WelcomeView: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "fuelpump.fill")
                .font(.system(size: 72))
                .foregroundStyle(.tint)
            VStack(spacing: 8) {
                Text("Fill Me Up")
                    .font(.largeTitle.bold())
                Text("The cheapest fuel near you, from official UK government price data.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
            Button(action: onContinue) {
                Label("Use My Location", systemImage: "location.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Text("Your location stays on your phone. It's only used to work out which stations are nearby.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
    }
}

private struct LocationDeniedView: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        ContentUnavailableView {
            Label("Location is off", systemImage: "location.slash")
        } description: {
            Text("Fill Me Up needs your location to find nearby fuel stations. You can turn it on in Settings.")
        } actions: {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            .buttonStyle(.borderedProminent)
        }
    }
}
