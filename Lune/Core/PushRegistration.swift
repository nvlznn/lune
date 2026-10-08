import UIKit
import UserNotifications

/// Lune notifies when the diary opens, when a friend writes, and for friend requests.
/// Permission is asked on first launch (notifications are on by default).
enum PushRegistration {
    private static let tokenKey = "pushDeviceToken"

    /// Asks once, then registers whenever permission is granted (device tokens can change).
    static func requestIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined:
            if (try? await center.requestAuthorization(options: [.alert, .sound])) == true {
                UIApplication.shared.registerForRemoteNotifications()
            }
        case .authorized, .provisional, .ephemeral:
            UIApplication.shared.registerForRemoteNotifications()
        default:
            break
        }
    }

    static func didRegister(deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(token, forKey: tokenKey)
        Task { try? await APIClient.shared.registerDevice(token: token) }
    }

    /// Call before signing out so this device stops getting the previous account's notifications.
    static func unregister() async {
        guard let token = UserDefaults.standard.string(forKey: tokenKey) else { return }
        try? await APIClient.shared.unregisterDevice(token: token)
    }
}
