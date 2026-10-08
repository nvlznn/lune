import SwiftUI

/// Choosing who gets a page: all friends, only you, groups, or friends one by one.
/// A group adds all its members, or removes them when they're all already chosen.
struct RecipientsPicker: View {
    let friends: [Friend]
    let groups: [FriendGroup]
    /// Friends who already have the page: shown checked, and can't be taken back.
    var alreadySent: Set<UUID> = []
    @Binding var selection: Set<UUID>

    private var available: Set<UUID> { Set(friends.map(\.userId)).subtracting(alreadySent) }

    var body: some View {
        List {
            Section {
                CheckRow(checked: !available.isEmpty && available.isSubset(of: selection)) {
                    Label("All Friends", systemImage: "person.2")
                } action: {
                    selection = available
                }
                if alreadySent.isEmpty {
                    CheckRow(checked: selection.isEmpty) {
                        Label("Only Me", systemImage: "lock")
                    } action: {
                        selection = []
                    }
                }
            }

            let usable = groups.filter { !Set($0.memberIds).isDisjoint(with: available) }
            if !usable.isEmpty {
                Section("Groups") {
                    ForEach(usable) { group in
                        let members = Set(group.memberIds).intersection(available)
                        CheckRow(checked: members.isSubset(of: selection)) {
                            LabeledContent(group.name, value: "\(members.count)")
                        } action: {
                            if members.isSubset(of: selection) {
                                selection.subtract(members)
                            } else {
                                selection.formUnion(members)
                            }
                        }
                    }
                }
            }

            Section("Friends") {
                ForEach(friends) { friend in
                    let sent = alreadySent.contains(friend.userId)
                    CheckRow(checked: sent || selection.contains(friend.userId)) {
                        HStack(spacing: 12) {
                            AvatarView(name: friend.name, path: friend.avatarPath, size: 32)
                            PersonLabel(name: friend.name, username: friend.username)
                        }
                    } action: {
                        if selection.contains(friend.userId) {
                            selection.remove(friend.userId)
                        } else {
                            selection.insert(friend.userId)
                        }
                    }
                    .disabled(sent)
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}

/// A list row that toggles, with a checkmark on the right.
private struct CheckRow<Content: View>: View {
    let checked: Bool
    @ViewBuilder let content: Content
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                content
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "checkmark")
                    .fontWeight(.semibold)
                    .foregroundStyle(.tint)
                    .opacity(checked ? 1 : 0)
            }
            .contentShape(.rect)
        }
        .accessibilityAddTraits(checked ? .isSelected : [])
    }
}

/// How a choice of recipients reads in the app.
enum Audience {
    /// "All Friends (12)", "Only Me", "Close Friends", "Alice", "Alice, Bob and 3 others".
    static func summary(_ selection: Set<UUID>, friends: [Friend], groups: [FriendGroup]) -> String {
        if selection.isEmpty { return "Only Me" }
        if !friends.isEmpty && selection == Set(friends.map(\.userId)) { return "All Friends (\(friends.count))" }
        if let group = groups.first(where: { Set($0.memberIds).intersection(friends.map(\.userId)) == selection }) {
            return group.name
        }
        return names(friends.filter { selection.contains($0.userId) }.map(\.name))
    }

    /// The question asked before sending: "Send to all 12 friends?", "Send to Close Friends?", "Send to Alice?".
    static func question(_ selection: Set<UUID>, friends: [Friend], groups: [FriendGroup]) -> String {
        if selection.isEmpty { return "Keep This Page to Yourself?" }
        if !friends.isEmpty && selection == Set(friends.map(\.userId)) {
            return friends.count == 1 ? "Send to \(friends[0].name)?" : "Send to All \(friends.count) Friends?"
        }
        return "Send to \(summary(selection, friends: friends, groups: groups))?"
    }

    /// "Alice", "Alice and Bob", "Alice, Bob and Carol", "Alice, Bob and 3 others".
    static func names(_ list: [String]) -> String {
        switch list.count {
        case 0: ""
        case 1...3: list.formatted(.list(type: .and))
        default: "\(list[0]), \(list[1]) and \(list.count - 2) others"
        }
    }
}
