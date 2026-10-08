import Observation
import StoreKit

/// Lune+: keeps your whole diary viewable (free users see their last 30 days). Checked on device with StoreKit 2.
@Observable
final class LunePlus {
    static let shared = LunePlus()

    static let monthly = "dev.noky.swapee.plus.monthly"
    static let yearly = "dev.noky.swapee.plus.yearly"
    static let productIDs = [monthly, yearly]
    /// Free users can look back this many days in their own diary.
    static let freeDays = 30

    private(set) var isActive = false
    @ObservationIgnored private var updates: Task<Void, Never>?

    private init() {
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                if case .verified(let transaction) = result { await transaction.finish() }
                await self?.refresh()
            }
        }
        Task { await refresh() }
    }

    /// Reads the current, Apple-signed entitlements; refunds and expiry are reflected automatically.
    func refresh() async {
        var active = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result,
               Self.productIDs.contains(transaction.productID),
               transaction.revocationDate == nil {
                active = true
            }
        }
        isActive = active
    }
}
