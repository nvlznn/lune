import Foundation

struct Profile: Codable, Equatable {
    let id: UUID
    var displayName: String
    /// Instagram-style handle friends use to add you. Nil until chosen at first sign-in.
    var username: String?
    /// Path in the avatars bucket; nil shows initials.
    var avatarPath: String?
    var timeZone: String
    var termsAcceptedAt: Date?
}

/// One page: a photo and the day's text. Sent to anyone, it's a letter and can't change.
struct Entry: Codable, Identifiable, Hashable {
    let entryId: UUID
    let userId: UUID
    let name: String
    let username: String?
    let avatarPath: String?
    /// The writer's day, `yyyy-MM-dd` (days start at 20:00 local time).
    let day: String
    let storagePath: String
    var text: String
    /// The photographer's local time (EXIF has no offset), shown in the viewer's time zone.
    let takenAt: Date?
    let createdAt: Date
    var editedAt: Date?
    /// When it was first sent to someone; nil while it's only for its writer.
    var sentAt: Date?
    /// Only for your own pages: who it was sent to.
    var recipients: [Person]?

    var id: UUID { entryId }
    var isSent: Bool { sentAt != nil }
}

/// Someone shown with their photo and username.
struct Person: Codable, Hashable, Identifiable {
    let userId: UUID
    let name: String
    let username: String?
    let avatarPath: String?
    var id: UUID { userId }
}

/// Your current day (`tonight` RPC): your page and the letters friends sent you.
struct TonightState: Codable, Equatable {
    var today: String
    /// Whether pages can be written now (20:00–04:00).
    var open: Bool
    /// When closed: when writing opens (20:00).
    var opensAt: Date?
    /// When open: when writing closes (04:00).
    var closesAt: Date?
    /// When today's letters disappear and a new day starts (20:00 tomorrow).
    var endsAt: Date
    var mine: Entry?
    /// Letters you can read, newest first (only once you've written today's page).
    var letters: [Entry]
    /// Letters waiting for you to write today's page, newest first.
    var locked: [LockedLetter]

    struct LockedLetter: Codable, Equatable, Identifiable {
        let userId: UUID
        let name: String
        let username: String?
        let avatarPath: String?
        let sentAt: Date
        var id: UUID { userId }
    }
}

/// One of your own lists of friends, for sending to several at once.
struct FriendGroup: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var memberIds: [UUID]
}

struct Friend: Codable, Identifiable, Hashable {
    let userId: UUID
    let name: String
    let username: String?
    let avatarPath: String?
    let since: Date
    var id: UUID { userId }
}

struct FriendRequest: Codable, Identifiable, Hashable {
    let userId: UUID
    let name: String
    let username: String?
    let avatarPath: String?
    let createdAt: Date
    var id: UUID { userId }
}

/// Someone found by their exact username.
struct FoundUser: Codable, Equatable, Identifiable {
    enum Relationship: String, Codable {
        case `self`, friend, requested, incoming, none
    }
    let userId: UUID
    let name: String
    let username: String
    let avatarPath: String?
    var relationship: Relationship
    var id: UUID { userId }
}

struct AddFriendResult: Codable, Equatable {
    enum Status: String, Codable {
        case requested, friends, alreadyFriends = "already_friends", notFound = "not_found"
    }
    let status: Status
    let name: String?
}
