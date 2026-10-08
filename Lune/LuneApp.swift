import SwiftUI

@main
struct LuneApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var api = APIClient.shared
    @State private var router = AppRouter.shared
    @State private var photos = PhotoLoader(api: APIClient.shared)
    @State private var premium = LunePremium.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(api)
                .environment(router)
                .environment(photos)
                .environment(premium)
                // Lune is a night app: always dark.
                .preferredColorScheme(.dark)
        }
    }
}

/// Sign in → set a name → Tonight / Diary / Friends.
struct RootView: View {
    @Environment(APIClient.self) private var api

    var body: some View {
        Group {
            if api.session == nil {
                SignInView()
            } else if !api.profileLoaded {
                ProgressView()
                    .task(id: api.session?.userID) { await loadProfile() }
            } else if api.profile?.termsAcceptedAt == nil || api.profile?.username == nil {
                ProfileSetupView()
            } else {
                MainTabView()
            }
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

struct MainTabView: View {
    @Environment(APIClient.self) private var api
    @Environment(AppRouter.self) private var router

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.tab) {
            TonightView()
                .tabItem { Label("Tonight", systemImage: "moon.stars") }
                .tag(AppRouter.Tab.tonight)
            DiaryView()
                .tabItem { Label("Diary", systemImage: "book.closed") }
                .tag(AppRouter.Tab.diary)
            FriendsView()
                .tabItem { Label("Friends", systemImage: "person.2") }
                .tag(AppRouter.Tab.friends)
        }
        .task {
            // Your days and night window follow where you are.
            try? await api.setTimeZone()
            await PushRegistration.requestIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
            Task { try? await api.setTimeZone() }
        }
    }
}

@Observable
final class AppRouter {
    static let shared = AppRouter()

    enum Tab: Hashable { case tonight, diary, friends }
    var tab: Tab = .tonight
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
        NotificationCenter.default.post(name: .luneDidChange, object: nil)
        return [.banner, .list, .sound]
    }

    // Friend requests open Friends; everything else opens Tonight.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let kind = response.notification.request.content.userInfo["kind"] as? String
        AppRouter.shared.tab = kind == "friends" ? .friends : .tonight
    }
}

extension Notification.Name {
    /// Something changed (a push arrived, or you wrote or edited a page); screens refresh.
    static let luneDidChange = Notification.Name("luneDidChange")
}
