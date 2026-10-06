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
                Text("Swapee")
                    .font(.largeTitle.bold())
                Text("Swap one photo a day with friends.")
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

/// First sign-in: set a display name and accept the terms.
struct ProfileSetupView: View {
    @Environment(APIClient.self) private var api
    @State private var name = ""
    @State private var isSaving = false
    @State private var error: Error?

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .textContentType(.nickname)
                        .submitLabel(.done)
                        .onSubmit(save)
                } footer: {
                    Text("Friends will see this name next to your photos.")
                }

                Section {
                } footer: {
                    Text(markdown: "By tapping Done, you agree to Swapee’s [Terms of Service](\(AppConfig.termsURL)) and [Privacy Policy](\(AppConfig.privacyURL)).")
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Your Name")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Sign Out") { Task { await api.signOut() } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Done", action: save)
                            .disabled(trimmedName.isEmpty || trimmedName.count > 30)
                    }
                }
            }
            .errorAlert("Couldn’t Save", error: $error)
        }
        .onAppear {
            if name.isEmpty { name = api.profile?.displayName ?? api.suggestedDisplayName ?? "" }
        }
    }

    private func save() {
        guard !trimmedName.isEmpty, trimmedName.count <= 30, !isSaving else { return }
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await api.saveProfile(displayName: trimmedName, acceptTerms: true)
            } catch {
                self.error = error
            }
        }
    }
}

#if DEBUG
/// Local development: Sign in with Apple needs a developer account in the simulator, so sign in to local Supabase with email instead.
private struct DevelopmentSignInSheet: View {
    @Environment(APIClient.self) private var api
    @Environment(\.dismiss) private var dismiss
    @State private var email = "alice@swapee.test"
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
                                try await api.signInForDevelopment(email: email, password: "swapee-dev-password")
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
