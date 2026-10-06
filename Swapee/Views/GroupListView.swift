import SwiftUI

/// Root screen: the group list, modeled on the Reminders list view.
struct GroupListView: View {
    @Environment(APIClient.self) private var api
    @Environment(AppRouter.self) private var router
    @Environment(\.scenePhase) private var scenePhase

    @State private var groups: [GroupSummary] = []
    @State private var loaded = false
    @State private var error: Error?
    @State private var showAccount = false
    @State private var showCreate = false
    @State private var showJoin = false
    @State private var leaving: GroupSummary?
    @State private var joined = 0

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.path) {
            List {
                ForEach(groups) { group in
                    NavigationLink(value: group.id) {
                        GroupRow(group: group)
                    }
                    .swipeActions {
                        Button("Leave") { leaving = group }
                            .tint(.red)
                    }
                    .contextMenu {
                        Button("Leave Group", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                            leaving = group
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .overlay {
                if loaded && groups.isEmpty {
                    ContentUnavailableView {
                        Label("No Groups", systemImage: "person.3")
                    } description: {
                        Text("Create a group, or enter an invite code from a friend.")
                    }
                }
            }
            .navigationTitle("Groups")
            .navigationDestination(for: UUID.self) { id in
                GroupView(groupID: id, summary: groups.first { $0.id == id })
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Account", systemImage: "person.crop.circle") { showAccount = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("Add", systemImage: "plus") {
                        Button("New Group", systemImage: "plus.circle") { showCreate = true }
                        Button("Join Group", systemImage: "person.badge.plus") { showJoin = true }
                    }
                }
            }
            .refreshable { await load() }
            .task { await load() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await load() } }
            }
            .onChange(of: router.path) { _, path in
                // Refresh the status text when coming back from a group.
                if path.isEmpty { Task { await load() } }
            }
            .onReceive(NotificationCenter.default.publisher(for: .swapeePhotoAvailable)) { _ in
                Task { await load() }
            }
            .sheet(isPresented: $showAccount) { AccountSheet() }
            .sheet(isPresented: $showCreate) {
                CreateGroupSheet { group in open(group) }
            }
            .sheet(isPresented: $showJoin) {
                JoinGroupSheet { group in
                    joined += 1
                    open(group)
                }
            }
            .alert(
                "Leave “\(leaving?.name ?? "")”?",
                isPresented: Binding(get: { leaving != nil }, set: { if !$0 { leaving = nil } }),
                presenting: leaving
            ) { group in
                Button("Leave Group", role: .destructive) { Task { await leave(group) } }
                Button("Cancel", role: .cancel) {}
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Photos you sent to this group will be deleted.")
            }
            .errorAlert("Something Went Wrong", error: $error)
            .sensoryFeedback(.success, trigger: joined)
        }
    }

    /// Claims photos for groups with credits first, so "waiting" in the list really means waiting.
    private func load() async {
        do {
            var result = try await api.myGroups()
            if result.contains(where: { $0.credits > 0 }) {
                for group in result where group.credits > 0 {
                    try? await api.claimAll(groupID: group.id)
                }
                result = try await api.myGroups()
            }
            groups = result
            loaded = true
        } catch is CancellationError {
        } catch let urlError as URLError where urlError.code == .cancelled {
        } catch {
            if !loaded { self.error = error }
        }
    }

    private func open(_ group: GroupInfo) {
        Task {
            await load()
            router.open(groupID: group.id)
        }
    }

    private func leave(_ group: GroupSummary) async {
        do {
            try await api.leaveGroup(group.id)
            groups.removeAll { $0.id == group.id }
        } catch {
            self.error = error
        }
    }
}

private struct GroupRow: View {
    let group: GroupSummary

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(group.name)
                Text(status)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: symbol)
                .foregroundStyle(group.uploadedToday ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                .imageScale(.large)
                .accessibilityHidden(true)
        }
    }

    private var hasUnseenPhoto: Bool {
        guard let received = group.lastReceivedAt else { return false }
        return received > SeenPhotos.lastSeen(group.id)
    }

    private var status: String {
        if hasUnseenPhoto { return "New photo" }
        if group.credits > 0 { return "Waiting for a photo" }
        if group.uploadedToday { return "Sent today" }
        if group.memberCount == 1 { return "Invite friends to join" }
        return "Ready for today’s photo"
    }

    private var symbol: String {
        if !group.uploadedToday { return "photo.badge.plus" }
        if group.credits > 0 { return "clock" }
        return "checkmark.circle.fill"
    }
}

/// When each group's received photos were last viewed, used for "New photo". Stored on this device only.
enum SeenPhotos {
    private static let key = "lastSeenReceivedPhotos"

    static func lastSeen(_ groupID: UUID) -> Date {
        let all = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        return Date(timeIntervalSince1970: all[groupID.lowercased] ?? 0)
    }

    static func markSeen(_ groupID: UUID) {
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        all[groupID.lowercased] = Date.now.timeIntervalSince1970
        UserDefaults.standard.set(all, forKey: key)
    }
}
