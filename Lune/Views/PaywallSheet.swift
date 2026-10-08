import StoreKit
import SwiftUI

/// Lune Premium with the system subscription store.
struct PaywallSheet: View {
    @Environment(LunePremium.self) private var premium
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SubscriptionStoreView(productIDs: LunePremium.productIDs) {
            VStack(spacing: 16) {
                MoonView(mood: .awake)
                    .frame(width: 96)
                Text("Lune Premium")
                    .font(.largeTitle.bold())
                Text("Read your whole diary, not just the last \(LunePremium.freeDays) days. Your pages are always kept, and export is always free.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
        .storeButton(.visible, for: .restorePurchases)
        .subscriptionStorePolicyDestination(url: AppConfig.termsURL, for: .termsOfService)
        .subscriptionStorePolicyDestination(url: AppConfig.privacyURL, for: .privacyPolicy)
        .onInAppPurchaseCompletion { _, _ in
            await premium.refresh()
            if premium.isActive { dismiss() }
        }
    }
}
