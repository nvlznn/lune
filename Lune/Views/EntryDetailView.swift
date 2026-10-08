import SwiftUI

/// One of your own pages: the photo, the text, and who it went to. A page you haven't sent can be
/// edited or deleted any time; today's page can be sent to more friends until the day ends.
struct EntryDetailView: View {
    @Environment(APIClient.self) private var api
    @Environment(\.dismiss) private var dismiss
    @State private var entry: Entry
    @State private var editing = false
    @State private var sending = false
    @State private var confirmDelete = false
    @State private var error: Error?

    init(entry: Entry) {
        _entry = State(initialValue: entry)
    }

    private var recipients: [Person] { entry.recipients ?? [] }
    /// The server has the final say; this only hides the option once the day is over.
    private var canSend: Bool { entry.day == LuneDay.today }

    var body: some View {
        List {
            Section {
                RemotePhoto(path: entry.storagePath)
                    .frame(maxWidth: .infinity)
                    .clipShape(.rect(cornerRadius: 10))
                    .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
                    .accessibilityLabel("Your photo")
                Text(entry.text)
                    .textSelection(.enabled)
            } footer: {
                Text(footer)
            }

            Section {
                if recipients.isEmpty {
                    Label("Only you can see this page.", systemImage: "lock")
                        .foregroundStyle(.secondary)
                }
                ForEach(recipients) { person in
                    HStack(spacing: 12) {
                        AvatarView(name: person.name, path: person.avatarPath, size: 32)
                        PersonLabel(name: person.name, username: person.username)
                    }
                }
                if canSend {
                    Button(recipients.isEmpty ? "Send…" : "Send to More…", systemImage: "paperplane") { sending = true }
                }
            } header: {
                Text("Sent To")
            } footer: {
                Text(entry.isSent
                    ? "Sent pages can’t be edited or deleted."
                    : "You can edit or delete this page until you send it.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(LuneDay.title(entry.day))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !entry.isSent {
                ToolbarItem(placement: .primaryAction) {
                    Menu("More", systemImage: "ellipsis.circle") {
                        Button("Edit", systemImage: "pencil") { editing = true }
                        Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = true }
                    }
                }
            }
        }
        .sheet(isPresented: $editing) {
            ComposeSheet(mode: .edit(entry)) { entry = $0 }
        }
        .sheet(isPresented: $sending) {
            SendSheet(entry: entry) { entry = $0 }
        }
        .alert("Delete This Page?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { Task { await delete() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its photo and words will be gone for good.")
        }
        .errorAlert("Something Went Wrong", error: $error)
    }

    private var footer: String {
        let time = PhotoTime.caption(takenAt: entry.takenAt, uploadedAt: entry.createdAt)
        return entry.editedAt == nil ? time : "\(time) · Edited"
    }

    private func delete() async {
        do {
            try await api.deleteEntry(entry.entryId)
            NotificationCenter.default.post(name: .luneDidChange, object: nil)
            dismiss()
        } catch {
            self.error = error
        }
    }
}

/// Sending one of today's pages to (more) friends.
private struct SendSheet: View {
    let entry: Entry
    let onSent: (Entry) -> Void

    @Environment(APIClient.self) private var api
    @Environment(\.dismiss) private var dismiss
    @State private var friends: [Friend] = []
    @State private var groups: [FriendGroup] = []
    @State private var selection: Set<UUID> = []
    @State private var loaded = false
    @State private var isSending = false
    @State private var confirm = false
    @State private var error: Error?

    private var alreadySent: Set<UUID> { Set((entry.recipients ?? []).map(\.userId)) }
    /// Friends who don't have it yet, for the summary and question.
    private var unsent: [Friend] { friends.filter { !alreadySent.contains($0.userId) } }

    var body: some View {
        NavigationStack {
            Group {
                if loaded {
                    RecipientsPicker(friends: friends, groups: groups, alreadySent: alreadySent, selection: $selection)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Send To")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSending {
                        ProgressView()
                    } else {
                        Button("Send") { confirm = true }
                            .disabled(selection.isEmpty)
                    }
                }
            }
            .task { await load() }
            .alert(Audience.question(selection, friends: unsent, groups: groups), isPresented: $confirm) {
                Button("Send") { Task { await send() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("It arrives right away and can’t be edited or deleted.")
            }
            .errorAlert("Couldn’t Send", error: $error)
        }
    }

    private func load() async {
        do {
            async let friends = api.friends()
            async let groups = api.groups()
            (self.friends, self.groups) = try await (friends, groups)
            loaded = true
        } catch is CancellationError {
        } catch {
            self.error = error
        }
    }

    private func send() async {
        isSending = true
        defer { isSending = false }
        do {
            let updated = try await api.addRecipients(entry.entryId, recipients: Array(selection))
            onSent(updated)
            NotificationCenter.default.post(name: .luneDidChange, object: nil)
            dismiss()
        } catch {
            self.error = error
        }
    }
}
