import SwiftUI

@main
struct FillMeUpApp: App {
    @State private var model = FuelModel.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
        }
    }
}
