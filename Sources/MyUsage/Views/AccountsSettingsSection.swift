import SwiftUI

/// Settings → Accounts: sign in to Claude or Codex inside MyUsage instead of reading the CLI's login.
struct AccountsSettingsSection: View {
    @State private var store = SignInStore()
    @State private var pastedCodes: [SignInProvider: String] = [:]
    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular

    var body: some View {
        VStack(alignment: .leading, spacing: density.headerToCardSpacing) {
            Text("Accounts")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
            VStack(spacing: 0) {
                ForEach(Array(SignInProvider.allCases.enumerated()), id: \.element) { index, provider in
                    if index > 0 { Divider() }
                    providerRows(provider)
                }
                caption("Signing in here keeps MyUsage’s login separate from the CLI’s, so neither signs the other out. MyUsage restarts to apply.")
            }
            .cardSurface()
        }
    }

    @ViewBuilder
    private func providerRows(_ provider: SignInProvider) -> some View {
        HStack(spacing: 10) {
            Text(provider.displayName)
            Spacer(minLength: 8)
            trailingControl(provider)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, density.controlRowPadding)

        switch store.phase(provider) {
        case .waiting(.browser(_, let acceptsPastedCode)):
            caption("Finish signing in in your browser.")
            if acceptsPastedCode { pasteRow(provider) }
        case .waiting(.deviceCode(let userCode, _)):
            caption("Enter this code on the page that opened:")
            Text(userCode)
                .font(.title3.monospaced().weight(.semibold))
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .failed(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(Theme.notice)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .idle, .starting:
            EmptyView()
        }
    }

    @ViewBuilder
    private func trailingControl(_ provider: SignInProvider) -> some View {
        switch store.phase(provider) {
        case .starting, .waiting:
            Button("Cancel") { store.cancel(provider) }
        case .idle, .failed:
            if let label = store.labels[provider] {
                Text(label)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Sign Out") { store.signOut(provider) }
            } else {
                Text("Using CLI Login")
                    .foregroundStyle(.secondary)
                Button("Sign In") { store.signIn(provider) }
            }
        }
    }

    private func pasteRow(_ provider: SignInProvider) -> some View {
        HStack(spacing: 8) {
            TextField("Paste Code", text: Binding(
                get: { pastedCodes[provider] ?? "" },
                set: { pastedCodes[provider] = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .onSubmit { submit(provider) }
            Button("Submit") { submit(provider) }
                .disabled((pastedCodes[provider] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func submit(_ provider: SignInProvider) {
        store.submitPastedCode(pastedCodes[provider] ?? "", for: provider)
        pastedCodes[provider] = nil
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
