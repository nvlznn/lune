import AuthenticationServices
import CryptoKit
import SwiftUI

struct SignInView: View {
    @Environment(APIClient.self) private var api
    @Environment(\.colorScheme) private var colorScheme
    @State private var nonce = ""
    @State private var isSigningIn = false
    @State private var error: Error?
    #if DEBUG
    @State private var showDevelopmentSignIn = false
    #endif

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 8) {
                GhostView(mood: .awake)
                    .frame(width: 120)
                    .padding(.bottom, 16)
                Text("Lune")
                    .font(.largeTitle.bold())
                Text("A diary with friends, open at night.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            Spacer()

            VStack(spacing: 16) {
                SignInWithAppleButton(.continue) { request in
                    nonce = Self.randomNonce()
                    request.requestedScopes = [.fullName]
                    request.nonce = Self.sha256(nonce)
                } onCompletion: { result in
                    Task { await handle(result) }
                }
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                .frame(height: 50)
                .disabled(isSigningIn)

                #if DEBUG
                Button("Developer Sign-In") { showDevelopmentSignIn = true }
                    .font(.footnote)
                #endif
            }
        }
        .padding()
        .errorAlert("Couldn’t Sign In", error: $error)
        #if DEBUG
        .sheet(isPresented: $showDevelopmentSignIn) { DevelopmentSignInSheet() }
        #endif
    }

    private func handle(_ result: Result<ASAuthorization, Error>) async {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let idToken = String(data: tokenData, encoding: .utf8) else { return }
            if let name = credential.fullName {
                let formatted = PersonNameComponentsFormatter.localizedString(from: name, style: .default)
                if !formatted.isEmpty { api.suggestedDisplayName = formatted }
            }
            isSigningIn = true
            defer { isSigningIn = false }
            do {
                try await api.signInWithApple(idToken: idToken, nonce: nonce)
            } catch {
                self.error = error
            }
        case .failure(let failure):
            if (failure as? ASAuthorizationError)?.code != .canceled {
                error = failure
            }
        }
    }

    private static func randomNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

private typealias ASAppleIDCredential = ASAuthorizationAppleIDCredential

/// First sign-in: a photo, a name and a username, and accepting the terms.
struct ProfileSetupView: View {
    @Environment(APIClient.self) private var api
    @State private var name = ""
    @State private var username = ""
    @State private var usernameOK = false
    @State private var avatar: Data?
    @State private var isSaving = false
    @State private var error: Error?

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool { !trimmedName.isEmpty && trimmedName.count <= 30 && usernameOK && !isSaving }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    AvatarDraftPicker(name: trimmedName, jpeg: $avatar)
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                }

                Section {
                    TextField("Name", text: $name)
                        .textContentType(.nickname)
                } header: {
                    Text("Name")
                } footer: {
                    Text("Friends see this name on your pages.")
                }

                UsernameField(username: $username, isValid: $usernameOK)

                Section {
                } footer: {
                    Text(markdown: "By tapping Done, you agree to Lune’s [Terms of Service](\(AppConfig.termsURL)) and [Privacy Policy](\(AppConfig.privacyURL)).")
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Welcome to Lune")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Sign Out") { Task { await api.signOut() } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Done") { Task { await save() } }
                            .disabled(!canSave)
                    }
                }
            }
            .errorAlert("Couldn’t Save", error: $error)
        }
        .onAppear {
            if name.isEmpty { name = api.profile?.displayName ?? api.suggestedDisplayName ?? "" }
            if username.isEmpty { username = api.profile?.username ?? "" }
        }
    }

    private func save() async {
        guard canSave else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await api.saveProfile(displayName: trimmedName, acceptTerms: true)
            if let avatar, api.profile?.avatarPath == nil { try await api.setAvatar(jpeg: avatar) }
            try await api.setUsername(username)
        } catch {
            self.error = error
        }
    }
}

/// A username field with Instagram's rules, checking availability as you type.
struct UsernameField: View {
    @Binding var username: String
    /// True once the username follows the rules and is available.
    @Binding var isValid: Bool

    @Environment(APIClient.self) private var api
    @State private var status: Status = .idle

    enum Status: Equatable {
        case idle, checking, available, taken, invalid(String)
    }

    var body: some View {
        Section {
            HStack(spacing: 2) {
                Text("@").foregroundStyle(.secondary)
                TextField("username", text: $username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
            }
        } header: {
            Text("Username")
        } footer: {
            switch status {
            case .idle: Text("Friends add you by your username. Letters, numbers, periods and underscores.")
            case .checking: Text("Checking…")
            case .available: Label("Available", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .taken: Label("That username is taken.", systemImage: "xmark.circle.fill").foregroundStyle(.red)
            case .invalid(let message): Text(message)
            }
        }
        .onChange(of: username, initial: true) { _, newValue in
            let cleaned = Username.clean(newValue)
            if cleaned != newValue { username = cleaned }
        }
        .task(id: username) { await check() }
    }

    private func check() async {
        isValid = false
        if let problem = Username.problem(username) {
            status = username.isEmpty ? .idle : .invalid(problem)
            return
        }
        status = .checking
        // Wait for a pause in typing.
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        do {
            let available = try await api.isUsernameAvailable(username)
            guard !Task.isCancelled else { return }
            status = available ? .available : .taken
            isValid = available
        } catch {
            status = .idle
        }
    }
}

#if DEBUG
/// Local development: Sign in with Apple needs a developer account in the simulator, so sign in to local Supabase with email instead.
private struct DevelopmentSignInSheet: View {
    @Environment(APIClient.self) private var api
    @Environment(\.dismiss) private var dismiss
    @State private var email = "alice@lune.test"
    @State private var error: Error?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Email", text: $email)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("Debug builds only. Creates the account if it doesn’t exist; the password is fixed.")
                }
            }
            .navigationTitle("Developer Sign-In")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sign In") {
                        Task {
                            do {
                                try await api.signInForDevelopment(email: email, password: "lune-dev-password")
                                dismiss()
                            } catch {
                                self.error = error
                            }
                        }
                    }
                    .disabled(email.isEmpty)
                }
            }
            .errorAlert("Couldn’t Sign In", error: $error)
        }
    }
}
#endif
