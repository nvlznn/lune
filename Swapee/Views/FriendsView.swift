import SwiftUI

/// Your username, adding friends by username, requests to answer, and your friends.
struct FriendsView: View {
    @Environment(APIClient.self) private var api
    @Environment(\.scenePhase) private var scenePhase

    @State private var friends: [Friend] = []
    @State private var requests: [FriendRequest] = []
    @State private var loaded = false
    @State private var search = ""
    @State private var searching = false
    @State private var found: FoundUser?
    @State private var notFound = false
    @State private var removing: Friend?
    @State private var blocking: Friend?
    @State private var madeFriends = 0
    @State private var limitReached = false
    @State private var error: Error?

    var body: some View {
        NavigationStack {
            List {
                if let username = api.profile?.username {
                    Section {
                        LabeledContent("Your Username") {
                            Text("@\(username)").textSelection(.enabled)
                        }
                    } footer: {
                        Text("Friends add you by your username.")
                    }
                }

                Section {
                    HStack(spacing: 2) {
                        Text("@").foregroundStyle(.secondary)
                        TextField("username", text: $search)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.asciiCapable)
                            .submitLabel(.search)
                            .onSubmit { Task { await find() } }
                            .onChange(of: search) { _, newValue in
                                let cleaned = Username.clean(newValue)
                                if cleaned != newValue { search = cleaned }
                                found = nil
                                notFound = false
                            }
                        if searching { ProgressView() }
                    }
                    if let found {
                        FoundUserRow(user: found) { await add(found) }
                    } else if notFound {
                        Text("No one has that username.")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Add a Friend")
                } footer: {
                    Text("Type a friend’s exact username.")
                }

                if !requests.isEmpty {
                    Section("Requests") {
                        ForEach(requests) { request in
                            HStack(spacing: 12) {
                                AvatarView(name: request.name, path: request.avatarPath)
                                PersonLabel(name: request.name, username: request.username)
                                Spacer()
                                Button("Decline") { Task { await respond(request, accept: false) } }
                                    .buttonStyle(.bordered)
                                Button("Accept") { Task { await respond(request, accept: true) } }
                                    .buttonStyle(.borderedProminent)
                            }
                            .buttonBorderShape(.capsule)
                        }
                    }
                }

                Section {
                    if loaded && friends.isEmpty {
                        HStack(spacing: 16) {
                            GhostView(mood: .awake, floating: false).frame(width: 40)
                            Text("No friends yet. Tell friends your username to start an exchange diary.")
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                    ForEach(friends) { friend in
                        HStack(spacing: 12) {
                            AvatarView(name: friend.name, path: friend.avatarPath)
                            PersonLabel(name: friend.name, username: friend.username)
                        }
                        .swipeActions {
                            Button("Remove") { removing = friend }.tint(.red)
                        }
                        .contextMenu {
                            Button("Remove Friend", systemImage: "person.badge.minus", role: .destructive) { removing = friend }
                            Button("Block \(friend.name)", systemImage: "hand.raised", role: .destructive) { blocking = friend }
                        }
                    }
                } header: {
                    Text("Friends")
                }
            }
            .listStyle(.insetGrouped)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Friends")
            .refreshable { await load() }
            .task { await load() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await load() } }
            }
            .onReceive(NotificationCenter.default.publisher(for: .luneDidChange)) { _ in
                Task { await load() }
            }
            .alert(
                "Remove \(removing?.name ?? "")?",
                isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                presenting: removing
            ) { friend in
                Button("Remove", role: .destructive) { Task { await remove(friend) } }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("You won’t see each other’s pages anymore.")
            }
            .alert(
                "Block \(blocking?.name ?? "")?",
                isPresented: Binding(get: { blocking != nil }, set: { if !$0 { blocking = nil } }),
                presenting: blocking
            ) { friend in
                Button("Block", role: .destructive) { Task { await block(friend) } }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("You’ll stop being friends, and they can’t find you or send you requests.")
            }
            .alert("Friend Limit Reached", isPresented: $limitReached) {
                Button("OK") {}
            } message: {
                Text("Each person can have up to 1,000 friends.")
            }
            .errorAlert("Something Went Wrong", error: $error)
            .sensoryFeedback(.success, trigger: madeFriends)
        }
    }

    private func load() async {
        do {
            async let friends = api.friends()
            async let requests = api.friendRequests()
            (self.friends, self.requests) = try await (friends, requests)
            loaded = true
        } catch is CancellationError {
        } catch {
            if !loaded { self.error = error }
        }
    }

    private func find() async {
        guard Username.problem(search) == nil, !searching else { return }
        searching = true
        defer { searching = false }
        do {
            found = try await api.findUser(username: search)
            notFound = found == nil
        } catch {
            self.error = error
        }
    }

    private func add(_ user: FoundUser) async {
        do {
            let result = try await api.addFriend(username: user.username)
            switch result.status {
            case .requested: found?.relationship = .requested
            case .friends, .alreadyFriends:
                found?.relationship = .friend
                madeFriends += 1
            case .notFound:
                found = nil
                notFound = true
            }
            await load()
        } catch APIError.server(code: "too_many_friends") {
            limitReached = true
        } catch {
            self.error = error
        }
    }

    private func respond(_ request: FriendRequest, accept: Bool) async {
        do {
            try await api.respondToFriendRequest(from: request.userId, accept: accept)
            if accept { madeFriends += 1 }
            await load()
        } catch APIError.server(code: "too_many_friends") {
            limitReached = true
        } catch {
            self.error = error
        }
    }

    private func remove(_ friend: Friend) async {
        do {
            try await api.removeFriend(friend.userId)
            friends.removeAll { $0.id == friend.id }
        } catch {
            self.error = error
        }
    }

    private func block(_ friend: Friend) async {
        do {
            try await api.block(userID: friend.userId)
            friends.removeAll { $0.id == friend.id }
        } catch {
            self.error = error
        }
    }
}

/// Name over @username.
private struct PersonLabel: View {
    let name: String
    let username: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
            if let username {
                Text("@\(username)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The person a username search found, with what you can do next.
private struct FoundUserRow: View {
    let user: FoundUser
    let add: () async -> Void

    @State private var adding = false

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(name: user.name, path: user.avatarPath)
            PersonLabel(name: user.name, username: user.username)
            Spacer()
            switch user.relationship {
            case .self:
                Text("You").foregroundStyle(.secondary)
            case .friend:
                Text("Friends").foregroundStyle(.secondary)
            case .requested:
                Text("Requested").foregroundStyle(.secondary)
            case .incoming, .none:
                Button(user.relationship == .incoming ? "Accept" : "Add") {
                    Task {
                        adding = true
                        await add()
                        adding = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .disabled(adding)
            }
        }
    }
}
