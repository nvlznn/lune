import SwiftUI

/// Creating or editing one of your groups: a name and which friends are in it.
struct GroupEditorSheet: View {
    /// nil creates a new group.
    let group: FriendGroup?
    let friends: [Friend]
    let onChange: () -> Void

    @Environment(APIClient.self) private var api
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var members: Set<UUID>
    @State private var isSaving = false
    @State private var confirmDelete = false
    @State private var error: Error?

    init(group: FriendGroup?, friends: [Friend], onChange: @escaping () -> Void) {
        self.group = group
        self.friends = friends
        self.onChange = onChange
        _name = State(initialValue: group?.name ?? "")
        _members = State(initialValue: Set(group?.memberIds ?? []))
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .onChange(of: name) { _, newValue in
                            if newValue.count > 30 { name = String(newValue.prefix(30)) }
                        }
                } footer: {
                    Text("Only you can see your groups.")
                }

                Section("Friends") {
                    ForEach(friends) { friend in
                        Button {
                            if members.contains(friend.userId) {
                                members.remove(friend.userId)
                            } else {
                                members.insert(friend.userId)
                            }
                        } label: {
                            HStack(spacing: 12) {
                                AvatarView(name: friend.name, path: friend.avatarPath, size: 32)
                                PersonLabel(name: friend.name, username: friend.username)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "checkmark")
                                    .fontWeight(.semibold)
                                    .opacity(members.contains(friend.userId) ? 1 : 0)
                            }
                            .contentShape(.rect)
                        }
                        .accessibilityAddTraits(members.contains(friend.userId) ? .isSelected : [])
                    }
                }

                if group != nil {
                    Section {
                        Button("Delete Group", role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .disabled(isSaving)
            .navigationTitle(group == nil ? "New Group" : "Edit Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button(group == nil ? "Create" : "Save") { Task { await save() } }
                            .disabled(trimmed.isEmpty)
                    }
                }
            }
            .alert("Delete \(group?.name ?? "Group")?", isPresented: $confirmDelete) {
                Button("Delete", role: .destructive) { Task { await delete() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your friends stay your friends.")
            }
            .errorAlert("Something Went Wrong", error: $error)
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            _ = try await api.saveGroup(id: group?.id, name: trimmed, memberIDs: Array(members))
            onChange()
            dismiss()
        } catch {
            self.error = error
        }
    }

    private func delete() async {
        guard let group else { return }
        do {
            try await api.deleteGroup(group.id)
            onChange()
            dismiss()
        } catch {
            self.error = error
        }
    }
}
