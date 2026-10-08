import SwiftUI

struct StationListView: View {
    @Environment(FuelModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var directionsTo: StationResult?

    var body: some View {
        @Bindable var model = model

        NavigationStack {
            List {
                Section {
                    Picker("Fuel", selection: $model.fuel) {
                        ForEach(FuelType.pickerOptions) { fuel in
                            Text(fuel.shortName).tag(fuel)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())

                    Picker("Within", selection: $model.radiusMiles) {
                        ForEach(FuelModel.radiusOptions, id: \.self) { miles in
                            Text("\(Int(miles)) \(miles == 1 ? "mile" : "miles")").tag(miles)
                        }
                    }
                }

                if case .failed(let message) = model.status {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.subheadline)
                    }
                }

                if !model.results.isEmpty {
                    Section {
                        ForEach(Array(model.results.enumerated()), id: \.element.id) { index, result in
                            Button {
                                directionsTo = result
                            } label: {
                                StationRow(result: result, isCheapest: index == 0)
                            }
                            .tint(.primary)
                        }
                    } footer: {
                        footer
                    }
                }
            }
            .overlay { emptyState }
            .navigationTitle("Fill Me Up")
            .refreshable { await self.model.refresh(force: true) }
            .confirmationDialog(
                directionsTo.map { "Directions to \($0.station.title)" } ?? "",
                isPresented: Binding(get: { directionsTo != nil }, set: { if !$0 { directionsTo = nil } }),
                titleVisibility: .visible,
                presenting: directionsTo
            ) { result in
                ForEach(NavigationApp.allCases) { app in
                    Button(app.name) { navigate(to: result, with: app) }
                }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.results.isEmpty {
            if !model.hasStations, case .loading(let message) = model.status {
                VStack(spacing: 8) {
                    ProgressView()
                    Text(message)
                        .font(.headline)
                    Text("The first download can take a minute.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else if model.location.location == nil {
                if model.location.failed {
                    ContentUnavailableView("Can't find you", systemImage: "location.slash",
                                           description: Text("Check that Location Services are on, then pull to refresh."))
                } else {
                    ProgressView("Finding your location…")
                }
            } else if model.hasStations {
                ContentUnavailableView {
                    Label("Nothing within \(Int(model.radiusMiles)) miles", systemImage: "fuelpump.slash")
                } description: {
                    Text("No stations nearby have reported a \(model.fuel.name) price recently.")
                } actions: {
                    if let wider = FuelModel.radiusOptions.first(where: { $0 > model.radiusMiles }) {
                        Button("Search within \(Int(wider)) miles") { model.radiusMiles = wider }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let updatedAt = model.updatedAt {
                Text("Prices checked \(updatedAt, format: .relative(presentation: .named)).")
            }
            Text("Prices are reported by forecourts to the UK Government Fuel Finder scheme and may have changed.")
        }
        .font(.footnote)
    }

    private func navigate(to result: StationResult, with app: NavigationApp) {
        guard let coordinate = result.station.coordinate else { return }
        model.navigationApp = app
        openURL(app.directionsURL(to: coordinate))
    }
}

struct StationRow: View {
    let result: StationResult
    let isCheapest: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(result.station.title)
                        .font(.headline)
                    if isCheapest {
                        Text("CHEAPEST")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.green.opacity(0.2), in: Capsule())
                            .foregroundStyle(.green)
                    }
                }
                if let subtitle = result.station.subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                }
                Text([result.station.address, result.station.postcode].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                HStack(spacing: 4) {
                    Image(systemName: "car.fill")
                    Text(result.distanceText)
                    if let updated = result.price.updated {
                        Text("·")
                        Text("updated \(updated, format: .relative(presentation: .named))")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(result.price.formatted)
                .font(.title2.bold().monospacedDigit())
                .foregroundStyle(isCheapest ? Color.green : Color.primary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows directions options")
    }
}
