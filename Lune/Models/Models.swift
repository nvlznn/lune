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

/// One page: a photo and the day's text.
struct Entry: Codable, Identifiable, Hashable {
    let entryId: UUID
    let userId: UUID
    let name: String
    let avatarPath: String?
    /// The writer's day, `yyyy-MM-dd` (days roll over at 04:00 local time).
    let day: String
    let storagePath: String
    var text: String
    /// The photographer's local time (EXIF has no offset), shown in the viewer's time zone.
    let takenAt: Date?
    let createdAt: Date
    var editedAt: Date?
    /// Only for your own pages: who has seen it, earliest first.
    var seenBy: [Viewer]?

    var id: UUID { entryId }

    struct Viewer: Codable, Hashable, Identifiable {
        let userId: UUID
        let name: String
        let avatarPath: String?
        let seenAt: Date
        var id: UUID { userId }
    }
}

/// Today and yesterday as you see them right now (`tonight` RPC).
struct TonightState: Codable, Equatable {
    var open: Bool
    var today: String
    /// When closed: when the diary opens tonight.
    var opensAt: Date?
    /// When open: when it closes (04:00).
    var closesAt: Date?
    /// Today first, then yesterday.
    var days: [DayState]

    struct DayState: Codable, Equatable, Identifiable {
        var day: String
        var mine: Entry?
        /// Friends' pages you can see (only while open, and only if you wrote this day).
        var friends: [Entry]
        /// Friends who wrote this day, earliest first, whether or not you can see their pages.
        var writers: [String]

        var id: String { day }
        /// Names of friends whose pages are still hidden from you.
        var lockedWriters: [String] {
            let visible = Set(friends.map(\.name))
            return writers.filter { !visible.contains($0) }
        }
    }

    var tonight: DayState? { days.first }
    var lastNight: DayState? { days.count > 1 ? days[1] : nil }
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
