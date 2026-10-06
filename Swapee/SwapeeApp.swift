import SwiftUI

@main
struct SwapeeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var api = APIClient.shared
    @State private var router = AppRouter.shared
    @State private var photos = PhotoLoader(api: APIClient.shared)

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(api)
                .environment(router)
                .environment(photos)
        }
    }
}

/// Sign in → set a name → group list.
struct RootView: View {
    @Environment(APIClient.self) private var api

    var body: some View {
        Group {
            if api.session == nil {
                SignInView()
            } else if !api.profileLoaded {
                ProgressView()
                    .task(id: api.session?.userID) { await loadProfile() }
            } else if api.profile?.termsAcceptedAt == nil {
                ProfileSetupView()
            } else {
                GroupListView()
            }
        }
        .task(id: api.session?.userID) {
            if api.session != nil { await PushRegistration.refreshIfAuthorized() }
        }
    }

    private func loadProfile() async {
        // Retry on network errors; a rejected refresh token signs out automatically.
        while api.session != nil, !api.profileLoaded {
            do {
                try await api.loadProfile()
            } catch {
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

/// Navigation path for the group list. Tapping a notification opens that group directly.
@Observable
final class AppRouter {
    static let shared = AppRouter()
    var path: [UUID] = []

    func open(groupID: UUID) {
        path = [groupID]
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushRegistration.didRegister(deviceToken: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {}

    // Show notifications while the app is open, and refresh what's on screen.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        NotificationCenter.default.post(name: .swapeePhotoAvailable, object: nil)
        return [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        if let id = (info["group_id"] as? String).flatMap(UUID.init(uuidString:)) {
            AppRouter.shared.open(groupID: id)
        }
    }
}

extension Notification.Name {
    static let swapeePhotoAvailable = Notification.Name("swapeePhotoAvailable")
}
