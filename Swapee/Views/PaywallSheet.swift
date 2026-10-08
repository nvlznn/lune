import StoreKit
import SwiftUI

/// Lune+ with the system subscription store.
struct PaywallSheet: View {
    @Environment(LunePlus.self) private var plus
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SubscriptionStoreView(productIDs: LunePlus.productIDs) {
            VStack(spacing: 16) {
                GhostView(mood: .awake)
                    .frame(width: 96)
                Text("Lune+")
                    .font(.largeTitle.bold())
                Text("Read your whole diary, not just the last \(LunePlus.freeDays) days. Your pages are always kept, and export is always free.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
        .storeButton(.visible, for: .restorePurchases)
        .subscriptionStorePolicyDestination(url: AppConfig.termsURL, for: .termsOfService)
        .subscriptionStorePolicyDestination(url: AppConfig.privacyURL, for: .privacyPolicy)
        .onInAppPurchaseCompletion { _, _ in
            await plus.refresh()
            if plus.isActive { dismiss() }
        }
    }
}
