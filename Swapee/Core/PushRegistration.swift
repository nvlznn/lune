import UIKit
import UserNotifications

/// There's only one notification: "a new photo is ready". Permission is requested after the first successful upload.
enum PushRegistration {
    private static let tokenKey = "pushDeviceToken"

    /// Call after a successful upload; does nothing if the user has already been asked.
    static func requestAfterFirstUpload() async {
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
        if (try? await center.requestAuthorization(options: [.alert, .sound])) == true {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    /// Call on every sign-in or launch, since the device token can change.
    static func refreshIfAuthorized() async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        if status == .authorized {
            UIApplication.shared.registerForRemoteNotifications()
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
