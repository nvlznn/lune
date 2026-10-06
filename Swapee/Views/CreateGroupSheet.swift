import SwiftUI

/// Modeled on Reminders' New Reminder sheet: Cancel on the left, Done on the right.
struct CreateGroupSheet: View {
    let onCreated: (GroupInfo) -> Void

    @Environment(APIClient.self) private var api
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var isSaving = false
    @State private var error: Error?
    @FocusState private var focused: Bool

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool { !trimmedName.isEmpty && trimmedName.count <= 40 && !isSaving }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Group Name", text: $name)
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit(save)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("New Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Done", action: save).disabled(!canSave)
                    }
                }
            }
            .errorAlert("Couldn’t Create Group", error: $error)
            .onAppear { focused = true }
        }
        .interactiveDismissDisabled(!name.isEmpty)
    }

    private func save() {
        guard canSave else { return }
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                let group = try await api.createGroup(name: trimmedName)
                dismiss()
                onCreated(group)
            } catch {
                self.error = error
            }
        }
    }
}
