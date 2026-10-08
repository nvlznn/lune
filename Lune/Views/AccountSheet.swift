import StoreKit
import SwiftUI

/// Account: photo, name, username, Lune Premium, legal and support links, Sign Out, Delete Account.
struct AccountSheet: View {
    @Environment(APIClient.self) private var api
    @Environment(LunePremium.self) private var premium
    @Environment(\.dismiss) private var dismiss
    @State private var showPaywall = false
    @State private var manageSubscription = false
    @State private var confirmSignOut = false
    @State private var confirmDelete = false
    @State private var isDeleting = false
    @State private var error: Error?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    EditableAvatar()
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                }

                Section {
                    NavigationLink {
                        EditNameView()
                    } label: {
                        LabeledContent("Name", value: api.profile?.displayName ?? "")
                    }
                    NavigationLink {
                        EditUsernameView()
                    } label: {
                        LabeledContent("Username", value: api.profile?.username.map { "@\($0)" } ?? "")
                    }
                }

                Section {
                    if premium.isActive {
                        LabeledContent("Lune Premium", value: "Active")
                        Button("Manage Subscription") { manageSubscription = true }
                    } else {
                        Button("Lune Premium") { showPaywall = true }
                    }
                } footer: {
                    Text("Lune Premium lets you read your whole diary, not just the last \(LunePremium.freeDays) days.")
                }

                Section {
                    Link("Terms of Service", destination: AppConfig.termsURL)
                    Link("Privacy Policy", destination: AppConfig.privacyURL)
                    Link("Contact Us", destination: AppConfig.supportURL)
                }

                #if DEBUG
                Section {
                    Button("Pretend It’s Night") { Task { await pretend(hour: 22) } }
                    Button("Pretend It’s Day") { Task { await pretend(hour: 12) } }
                } header: {
                    Text("Developer")
                } footer: {
                    Text("Debug builds only. Moves you to a time zone where it’s 10 PM or noon right now; relaunching restores your real time zone.")
                }
                #endif

                Section {
                    Button("Sign Out") { confirmSignOut = true }
                }

                Section {
                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        HStack {
                            Text("Delete Account")
                            Spacer()
                            if isDeleting { ProgressView() }
                        }
                    }
                    .disabled(isDeleting)
                } footer: {
                    Text("Your account, your diary and your friendships will be permanently deleted. A Lune Premium subscription is managed by Apple and needs to be canceled separately.")
                }
            }
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Sign Out?", isPresented: $confirmSignOut) {
                Button("Sign Out", role: .destructive) {
                    Task {
                        await PushRegistration.unregister()
                        await api.signOut()
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Delete Your Account?", isPresented: $confirmDelete) {
                Button("Delete Account", role: .destructive) { Task { await deleteAccount() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This can’t be undone.")
            }
            .errorAlert("Couldn’t Delete Account", error: $error)
            .sheet(isPresented: $showPaywall) { PaywallSheet() }
            .manageSubscriptionsSheet(isPresented: $manageSubscription)
        }
    }

    #if DEBUG
    /// A time zone where it's `hour` o'clock right now ("Etc/GMT-8" is UTC+8).
    private func pretend(hour: Int) async {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = .gmt
        let offset = ((hour - utc.component(.hour, from: .now) + 36) % 24) - 12
        let zone = offset == 0 ? "Etc/GMT" : offset > 0 ? "Etc/GMT-\(offset)" : "Etc/GMT+\(-offset)"
        do {
            try await api.setTimeZone(zone)
            NotificationCenter.default.post(name: .luneDidChange, object: nil)
            dismiss()
        } catch {
            self.error = error
        }
    }
    #endif

    private func deleteAccount() async {
        isDeleting = true
        defer { isDeleting = false }
        do {
            try await api.deleteAccount()
        } catch {
            self.error = error
        }
    }
}

/// Changing your name.
private struct EditNameView: View {
    @Environment(APIClient.self) private var api
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var isSaving = false
    @State private var error: Error?

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                    .textContentType(.nickname)
                    .submitLabel(.done)
                    .onSubmit { Task { await save() } }
            } footer: {
                Text("Friends see this name on your pages.")
            }
        }
        .navigationTitle("Name")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if isSaving {
                    ProgressView()
                } else {
                    Button("Done") { Task { await save() } }
                        .disabled(trimmed.isEmpty || trimmed.count > 30 || trimmed == api.profile?.displayName)
                }
            }
        }
        .onAppear { if name.isEmpty { name = api.profile?.displayName ?? "" } }
        .errorAlert("Couldn’t Save", error: $error)
    }

    private func save() async {
        guard !trimmed.isEmpty, trimmed.count <= 30, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await api.saveProfile(displayName: trimmed, acceptTerms: true)
            dismiss()
        } catch {
            self.error = error
        }
    }
}

/// Changing your username; the old one is freed for others.
private struct EditUsernameView: View {
    @Environment(APIClient.self) private var api
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var usernameOK = false
    @State private var isSaving = false
    @State private var error: Error?

    var body: some View {
        Form {
            UsernameField(username: $username, isValid: $usernameOK)
        }
        .navigationTitle("Username")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if isSaving {
                    ProgressView()
                } else {
                    Button("Done") { Task { await save() } }
                        .disabled(!usernameOK || username == api.profile?.username)
                }
            }
        }
        .onAppear { if username.isEmpty { username = api.profile?.username ?? "" } }
        .errorAlert("Couldn’t Save", error: $error)
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await api.setUsername(username)
            dismiss()
        } catch {
            self.error = error
        }
    }
}
