import SwiftUI

/// Customize → a server card: where its traffic probe lives and the plan's allowance. Saving writes
/// `~/.config/openusage/server.json` and forces a refresh, like the API-key card. "Add Another Server"
/// appends a new entry; its card appears on the next launch, since cards are built at startup.
struct ServerProbeSection: View {
    let providerID: String
    var store = ServerTrafficConfigStore()

    @Environment(WidgetDataStore.self) private var dataStore
    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular

    @State private var name = ""
    @State private var url = ""
    @State private var token = ""
    @State private var quotaGB: Double = 500
    @State private var resetDay = 1
    @State private var countMode = ServerTrafficCountMode.total
    @State private var carryOverGB: Double?
    @State private var carryOverSetAt: Date?
    @State private var isSaved = false
    @State private var isAdding = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: density.headerToCardSpacing) {
            Text(isAdding ? "New Server" : "Server")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
            VStack(alignment: .leading, spacing: 8) {
                field("Name") { TextField("", text: $name, prompt: Text("gomami")) }
                field("Probe URL") {
                    TextField("", text: $url, prompt: Text("https://host:4443/openusage/traffic.json"))
                }
                field("Token") { SecureField("", text: $token, prompt: Text("Contents of /etc/openusage-probe/token")) }
                field("Monthly quota") {
                    HStack(spacing: 4) {
                        TextField("", value: $quotaGB, format: .number)
                            .frame(width: 80)
                        Text("GB").foregroundStyle(.secondary)
                    }
                }
                field("Resets on day") {
                    Stepper(value: $resetDay, in: 1...31) {
                        Text("\(resetDay)").monospacedDigit()
                    }
                }
                field("Counts") {
                    Picker("", selection: $countMode) {
                        ForEach(ServerTrafficCountMode.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
                field("Used before probe") {
                    HStack(spacing: 4) {
                        TextField("", value: $carryOverGB, format: .number, prompt: Text("0"))
                            .frame(width: 80)
                        Text("GB this period").foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 8) {
                    Button("Save", action: save)
                        .buttonStyle(.borderedProminent)
                    if isAdding {
                        Button("Cancel") { isAdding = false; message = nil; load() }
                            .buttonStyle(.borderless)
                    } else if isSaved {
                        Button("Remove", role: .destructive, action: remove)
                            .buttonStyle(.borderless)
                        Spacer()
                        Button("Add Another Server", action: startAdding)
                            .buttonStyle(.borderless)
                    }
                }
                .controlSize(.small)
                if let message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(Theme.notice)
                }
            }
            .textFieldStyle(.roundedBorder)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
        }
        .onAppear(perform: load)
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            content()
        }
    }

    private func load() {
        guard let config = store.load(cardID: providerID) else {
            clearForm()
            return
        }
        name = config.name
        url = config.url
        token = config.token
        quotaGB = config.quotaGB
        resetDay = config.resetDay
        countMode = config.countMode
        carryOverGB = config.carryOverGB
        carryOverSetAt = config.carryOverSetAt
        isSaved = true
    }

    private func clearForm() {
        name = ""; url = ""; token = ""; quotaGB = 500; resetDay = 1
        countMode = .total; carryOverGB = nil; carryOverSetAt = nil
    }

    private func startAdding() {
        clearForm()
        isAdding = true
        message = nil
    }

    private func save() {
        // A carry-over belongs to the period it was entered in; re-stamp it only when the number changes.
        let previous = isAdding ? nil : store.load(cardID: providerID)
        let carryOver = (carryOverGB ?? 0) > 0 ? carryOverGB : nil
        let setAt = carryOver == nil ? nil
            : (carryOver == previous?.carryOverGB ? (previous?.carryOverSetAt ?? Date()) : Date())
        do {
            let saved = try store.save(ServerTrafficConfig(name: name, url: url, token: token, quotaGB: quotaGB,
                                                           resetDay: resetDay, countMode: countMode,
                                                           carryOverGB: carryOver, carryOverSetAt: setAt,
                                                           id: previous?.id))
            if saved.id != providerID {
                isAdding = false
                load()
                message = "Added \(saved.name.isEmpty ? "the server" : saved.name). Quit and reopen OpenUsage to show its card."
                return
            }
            isAdding = false
            isSaved = true
            message = nil
            dataStore.clearFailureBackoff(for: providerID)
            Task { await dataStore.refresh(providerID: providerID, force: true) }
        } catch {
            message = error.localizedDescription
        }
    }

    private func remove() {
        do {
            try store.delete(cardID: providerID)
            clearForm()
            isSaved = false
            message = providerID == ServerTrafficConfigStore.family ? nil
                : "Removed. Quit and reopen OpenUsage to drop its card."

            Task { await dataStore.refresh(providerID: providerID, force: true) }
        } catch {
            message = error.localizedDescription
        }
    }
}
