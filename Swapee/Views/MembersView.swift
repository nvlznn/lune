import SwiftUI

/// Members, the invite code, and Leave Group.
struct MembersView: View {
    let group: GroupSummary
    let onLeft: () -> Void

    @Environment(APIClient.self) private var api
    @State private var members: [Member] = []
    @State private var confirmLeave = false
    @State private var error: Error?

    var body: some View {
        List {
            Section {
                ForEach(members) { member in
                    LabeledContent {
                        if member.userId == group.ownerId { Text("Owner") }
                    } label: {
                        Text(member.userId == api.session?.userID ? "\(member.profile.displayName) (You)" : member.profile.displayName)
                    }
                }
            } header: {
                Text("Members")
            } footer: {
                Text("\(members.count) of 20")
            }

            Section {
                InviteCodeRow(group: group)
            } header: {
                Text("Invite Code")
            } footer: {
                Text("Anyone in the group can invite friends with this code.")
            }

            Section {
                Button("Leave Group", role: .destructive) { confirmLeave = true }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Members")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .alert("Leave “\(group.name)”?", isPresented: $confirmLeave) {
            Button("Leave Group", role: .destructive) { Task { await leave() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Photos you sent to this group will be deleted.")
        }
        .errorAlert("Something Went Wrong", error: $error)
    }

    private func load() async {
        do {
            members = try await api.members(of: group.id)
        } catch is CancellationError {
        } catch {
            self.error = error
        }
    }

    private func leave() async {
        do {
            try await api.leaveGroup(group.id)
            onLeft()
        } catch {
            self.error = error
        }
    }
}
