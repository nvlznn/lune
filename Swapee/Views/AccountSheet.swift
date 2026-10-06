import SwiftUI

/// Account: name, legal and support links, Sign Out, Delete Account.
struct AccountSheet: View {
    @Environment(APIClient.self) private var api
    @Environment(\.dismiss) private var dismiss
    @State private var confirmSignOut = false
    @State private var confirmDelete = false
    @State private var isDeleting = false
    @State private var error: Error?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Name", value: api.profile?.displayName ?? "")
                }

                Section {
                    Link("Terms of Service", destination: AppConfig.termsURL)
                    Link("Privacy Policy", destination: AppConfig.privacyURL)
                    Link("Contact Us", destination: AppConfig.supportURL)
                }

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
                    Text("Your account, the photos you’ve sent, and all your group data will be permanently deleted.")
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
        }
    }

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
