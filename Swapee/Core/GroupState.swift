import Foundation

/// The current state of one group (`group_state` RPC).
struct GroupState: Codable, Equatable {
    var uploadedToday: Bool
    var todayPhoto: OwnPhoto?
    /// Photos you can still receive = photos sent − photos received.
    var credits: Int
    /// Photos received in the last 7 days, newest first.
    var received: [ReceivedPhoto]

    /// Has credits but the pool is empty. Only meaningful after claiming.
    var isWaiting: Bool { credits > 0 }
}
