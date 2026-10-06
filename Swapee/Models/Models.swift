import Foundation

struct Profile: Codable, Equatable {
    let id: UUID
    var displayName: String
    var termsAcceptedAt: Date?
}

/// One row of the group list (`my_groups` RPC).
struct GroupSummary: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var inviteCode: String
    var ownerId: UUID
    var memberCount: Int
    var uploadedToday: Bool
    var credits: Int
    var lastReceivedAt: Date?
}

/// A group returned by `create_group` / `join_group`.
struct GroupInfo: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var inviteCode: String
    var ownerId: UUID
}

struct Member: Codable, Identifiable, Hashable {
    let userId: UUID
    let joinedAt: Date
    let profile: MemberProfile

    var id: UUID { userId }

    struct MemberProfile: Codable, Hashable {
        let displayName: String
    }
}

/// The photo you sent to a group today.
struct OwnPhoto: Codable, Hashable {
    let photoId: UUID
    let storagePath: String
    let takenAt: Date?
    let caption: String?
    let uploadedAt: Date
    /// Who has received it, earliest first.
    let seenBy: [Viewer]

    struct Viewer: Codable, Hashable, Identifiable {
        let userId: UUID
        let name: String
        let seenAt: Date
        var id: UUID { userId }
    }
}

/// A photo you received (one delivery).
struct ReceivedPhoto: Codable, Identifiable, Hashable {
    let photoId: UUID
    let senderId: UUID
    let senderName: String
    let storagePath: String
    /// The photographer's local time (EXIF has no offset), shown in the viewer's time zone.
    let takenAt: Date?
    let caption: String?
    let uploadedAt: Date
    let deliveredAt: Date

    var id: UUID { photoId }
}

enum ClaimResult: Decodable, Equatable {
    case delivered(ReceivedPhoto)
    case waiting

    private enum CodingKeys: String, CodingKey { case status, photo }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .status) {
        case "delivered": self = .delivered(try container.decode(ReceivedPhoto.self, forKey: .photo))
        default: self = .waiting
        }
    }
}
