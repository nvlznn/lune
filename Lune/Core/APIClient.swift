import Foundation
import Observation
import Security

/// Every backend call lives here: Supabase Auth, PostgREST RPCs, and Storage.
@Observable
final class APIClient {
    static let shared = APIClient()

    /// nil means signed out.
    private(set) var session: AuthSession?
    /// The signed-in user's profile. nil with `profileLoaded == true` means no name has been set yet.
    private(set) var profile: Profile?
    private(set) var profileLoaded = false
    /// The name Sign in with Apple provides on first sign-in, used to prefill the display name.
    var suggestedDisplayName: String?

    private let config: AppConfig
    private let store: SessionStore
    private let urlSession: URLSession
    private var refreshTask: Task<AuthSession, Error>?

    init(config: AppConfig = .main, store: SessionStore = KeychainSessionStore(), urlSession: URLSession = .shared) {
        self.config = config
        self.store = store
        self.urlSession = urlSession
        self.session = store.load()
    }

    // MARK: - Auth

    func signInWithApple(idToken: String, nonce: String) async throws {
        let session = try await sendAuth(
            authRequest("token?grant_type=id_token", body: ["provider": "apple", "id_token": idToken, "nonce": nonce])
        )
        setSession(session)
    }

    #if DEBUG
    /// Local development only: signs in with email and password, creating the account if needed.
    func signInForDevelopment(email: String, password: String) async throws {
        let credentials = ["email": email, "password": password]
        do {
            let session: AuthSession = try await sendAuth(authRequest("token?grant_type=password", body: credentials))
            setSession(session)
        } catch {
            let session: AuthSession = try await sendAuth(authRequest("signup", body: credentials))
            setSession(session)
        }
    }
    #endif

    func signOut() async {
        if let token = session?.accessToken {
            var request = authRequest("logout", body: [String: String]())
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            _ = try? await urlSession.data(for: request)
        }
        setSession(nil)
    }

    func deleteAccount() async throws {
        try await rpc("delete_account")
        setSession(nil)
    }

    private func setSession(_ newValue: AuthSession?) {
        if newValue?.userID != session?.userID {
            profile = nil
            profileLoaded = false
        }
        session = newValue
        if let newValue { store.save(newValue) } else { store.clear() }
    }

    private func refresh(using refreshToken: String) async throws -> AuthSession {
        try await sendAuth(authRequest("token?grant_type=refresh_token", body: ["refresh_token": refreshToken]))
    }

    /// Refreshes the access token shortly before it expires; signs out if the refresh token is rejected.
    private func accessToken() async throws -> String {
        guard let current = session else { throw APIError.notSignedIn }
        if current.expiresAt > .now.addingTimeInterval(60) { return current.accessToken }

        let task = refreshTask ?? Task { try await refresh(using: current.refreshToken) }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let renewed = try await task.value
            setSession(renewed)
            return renewed.accessToken
        } catch APIError.http(let status, _) where (400..<500).contains(status) {
            setSession(nil)
            throw APIError.notSignedIn
        }
    }

    // MARK: - Profile

    func loadProfile() async throws {
        guard let userID = session?.userID else { throw APIError.notSignedIn }
        let rows: [Profile] = try await get(
            "profiles",
            query: ["select": "id,display_name,username,avatar_path,time_zone,terms_accepted_at", "id": "eq.\(userID.lowercased)"]
        )
        profile = rows.first
        profileLoaded = true
    }

    func saveProfile(displayName: String, acceptTerms: Bool) async throws {
        profile = try await rpc("save_profile", ["p_display_name": displayName, "p_accept_terms": acceptTerms])
        profileLoaded = true
    }

    func setUsername(_ username: String) async throws {
        profile = try await rpc("set_username", ["p_username": username])
    }

    /// Uploads a square JPEG and makes it your avatar (the old one is deleted).
    func setAvatar(jpeg: Data) async throws {
        guard let userID = session?.userID else { throw APIError.notSignedIn }
        let path = "\(userID.lowercased)/\(UUID().lowercased).jpg"
        var request = URLRequest(url: config.url.appending(path: "storage/v1/object/avatars/\(path)"))
        request.httpMethod = "POST"
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.setValue("false", forHTTPHeaderField: "x-upsert")
        request.httpBody = jpeg
        try await sendDiscardingBody(authorized(request))
        profile = try await rpc("set_avatar", ["p_path": path])
    }

    func removeAvatar() async throws {
        profile = try await rpc("remove_avatar")
    }

    func isUsernameAvailable(_ username: String) async throws -> Bool {
        try await rpc("username_available", ["p_username": username])
    }

    /// Your days and night window follow this time zone.
    func setTimeZone(_ identifier: String = TimeZone.current.identifier) async throws {
        try await rpc("set_time_zone", ["p_time_zone": identifier])
        profile?.timeZone = identifier
    }

    // MARK: - Pages

    func tonight() async throws -> TonightState {
        try await rpc("tonight")
    }

    /// Uploads the photo, then writes the page for `day` (today or yesterday).
    func writeEntry(day: String, jpeg: Data, takenAt: String?, text: String) async throws -> Entry {
        guard let userID = session?.userID else { throw APIError.notSignedIn }
        let path = "\(userID.lowercased)/\(UUID().lowercased).jpg"

        var request = URLRequest(url: config.url.appending(path: "storage/v1/object/entries/\(path)"))
        request.httpMethod = "POST"
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.setValue("false", forHTTPHeaderField: "x-upsert")
        request.httpBody = jpeg
        do {
            try await sendDiscardingBody(authorized(request))
        } catch APIError.http(_, let message) where message.contains("row-level security") {
            // Storage only takes photos while your diary is open and you still have a day to write.
            throw APIError.server(code: "upload_rejected")
        }

        var args: [String: Any] = ["p_day": day, "p_storage_path": path, "p_text": text]
        args["p_taken_at"] = takenAt ?? NSNull()
        return try await rpc("write_entry", args)
    }

    func editEntryText(_ entryID: UUID, text: String) async throws -> Entry {
        try await rpc("edit_entry_text", ["p_entry_id": entryID.lowercased, "p_text": text])
    }

    /// Your own pages, newest first, before `day` (`yyyy-MM-dd`).
    func myEntries(before day: String? = nil, limit: Int = 60) async throws -> [Entry] {
        var args: [String: Any] = ["p_limit": limit]
        args["p_before"] = day ?? NSNull()
        return try await rpc("my_entries", args)
    }

    /// Everything you wrote, oldest first.
    func exportEntries() async throws -> [Entry] {
        try await rpc("export_entries")
    }

    /// Short-lived signed URL (1 hour).
    func signedURL(for path: String, in bucket: StorageBucket = .entries) async throws -> URL {
        var request = URLRequest(url: config.url.appending(path: "storage/v1/object/sign/\(bucket.rawValue)/\(path)"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["expiresIn": 3600])
        struct Signed: Decodable { let signedURL: String }
        let signed: Signed = try await send(authorized(request))
        guard let url = URL(string: config.url.absoluteString + "/storage/v1" + signed.signedURL) else {
            throw APIError.decoding
        }
        return url
    }

    func downloadImage(at path: String, in bucket: StorageBucket = .entries) async throws -> Data {
        let (data, response) = try await urlSession.data(from: try await signedURL(for: path, in: bucket))
        try Self.check(response, data: data)
        return data
    }

    // MARK: - Friends

    /// Someone by their exact username; nil if there's no such person.
    func findUser(username: String) async throws -> FoundUser? {
        try await rpc("find_user", ["p_username": username])
    }

    func addFriend(username: String) async throws -> AddFriendResult {
        try await rpc("add_friend", ["p_username": username])
    }

    func respondToFriendRequest(from userID: UUID, accept: Bool) async throws {
        try await rpc("respond_friend_request", ["p_from_id": userID.lowercased, "p_accept": accept])
    }

    func friendRequests() async throws -> [FriendRequest] {
        try await rpc("friend_requests")
    }

    func friends() async throws -> [Friend] {
        try await rpc("friends")
    }

    func removeFriend(_ userID: UUID) async throws {
        try await rpc("remove_friend", ["p_user_id": userID.lowercased])
    }

    // MARK: - Report & block

    func report(entryID: UUID, reason: String) async throws {
        try await rpc("report_entry", ["p_entry_id": entryID.lowercased, "p_reason": reason])
    }

    /// Also ends the friendship.
    func block(userID: UUID) async throws {
        try await rpc("block_user", ["p_user_id": userID.lowercased])
    }

    // MARK: - Push

    func registerDevice(token: String) async throws {
        try await rpc("register_device", ["p_token": token])
    }

    func unregisterDevice(token: String) async throws {
        try await rpc("unregister_device", ["p_token": token])
    }

    // MARK: - HTTP

    private func authRequest(_ endpoint: String, body: [String: String]) -> URLRequest {
        var request = URLRequest(url: URL(string: config.url.absoluteString + "/auth/v1/" + endpoint)!)
        request.httpMethod = "POST"
        request.setValue(config.key, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func authorized(_ request: URLRequest) async throws -> URLRequest {
        var request = request
        request.setValue(config.key, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        return request
    }

    private func rpcRequest(_ function: String, _ args: [String: Any]) throws -> URLRequest {
        var request = URLRequest(url: config.url.appending(path: "rest/v1/rpc/\(function)"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: args)
        return request
    }

    private func rpc<T: Decodable>(_ function: String, _ args: [String: Any] = [:]) async throws -> T {
        try await send(authorized(rpcRequest(function, args)))
    }

    private func rpc(_ function: String, _ args: [String: Any] = [:]) async throws {
        try await sendDiscardingBody(authorized(rpcRequest(function, args)))
    }

    private func get<T: Decodable>(_ table: String, query: [String: String]) async throws -> T {
        var components = URLComponents(url: config.url.appending(path: "rest/v1/\(table)"), resolvingAgainstBaseURL: false)!
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        return try await send(authorized(URLRequest(url: components.url!)))
    }

    private func send<T: Decodable>(_ request: URLRequest, decoder: JSONDecoder = .supabase) async throws -> T {
        let (data, response) = try await urlSession.data(for: request)
        try Self.check(response, data: data)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decoding
        }
    }

    /// Auth responses decode with a plain decoder: `AuthSession` declares its own snake_case keys.
    private func sendAuth(_ request: URLRequest) async throws -> AuthSession {
        try await send(request, decoder: JSONDecoder())
    }

    private func sendDiscardingBody(_ request: URLRequest) async throws {
        let (data, response) = try await urlSession.data(for: request)
        try Self.check(response, data: data)
    }

    private static func check(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw APIError.decoding }
        guard !(200..<300).contains(http.statusCode) else { return }
        throw APIError(status: http.statusCode, body: data)
    }
}

enum StorageBucket: String, Sendable {
    /// Page photos.
    case entries
    case avatars
}

// MARK: - Session

struct AuthSession: Codable, Equatable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let userID: UUID

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token", refreshToken = "refresh_token"
        case expiresAt = "expires_at", user, userID = "user_id"
    }
    private struct User: Codable { let id: UUID }

    init(accessToken: String, refreshToken: String, expiresAt: Date, userID: UUID) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.userID = userID
    }

    /// Decodes both Supabase Auth responses (`expires_at` in Unix seconds, `user.id`) and the locally stored format.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try c.decode(String.self, forKey: .accessToken)
        refreshToken = try c.decode(String.self, forKey: .refreshToken)
        expiresAt = Date(timeIntervalSince1970: try c.decode(Double.self, forKey: .expiresAt))
        if let id = try c.decodeIfPresent(UUID.self, forKey: .userID) {
            userID = id
        } else {
            userID = try c.decode(User.self, forKey: .user).id
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(accessToken, forKey: .accessToken)
        try c.encode(refreshToken, forKey: .refreshToken)
        try c.encode(expiresAt.timeIntervalSince1970, forKey: .expiresAt)
        try c.encode(userID, forKey: .userID)
    }
}

protocol SessionStore {
    func load() -> AuthSession?
    func save(_ session: AuthSession)
    func clear()
}

struct KeychainSessionStore: SessionStore {
    private let query: [CFString: Any] = [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: "dev.noky.lune.session",
        kSecAttrAccount: "default",
    ]

    func load() -> AuthSession? {
        var item: CFTypeRef?
        var search = query
        search[kSecReturnData] = true
        guard SecItemCopyMatching(search as CFDictionary, &item) == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(AuthSession.self, from: data)
    }

    func save(_ session: AuthSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        clear()
        var item = query
        item[kSecValueData] = data
        item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }

    func clear() {
        SecItemDelete(query as CFDictionary)
    }
}

final class InMemorySessionStore: SessionStore {
    private var session: AuthSession?
    func load() -> AuthSession? { session }
    func save(_ session: AuthSession) { self.session = session }
    func clear() { session = nil }
}

// MARK: - Config

struct AppConfig {
    let url: URL
    let key: String

    static let main = AppConfig(
        url: URL(string: Bundle.main.object(forInfoDictionaryKey: "SupabaseURL") as! String)!,
        key: Bundle.main.object(forInfoDictionaryKey: "SupabaseKey") as! String
    )

    static let termsURL = URL(string: "https://lune.noky.dev/terms")!
    static let privacyURL = URL(string: "https://lune.noky.dev/privacy")!
    // TODO: Confirm the support email address.
    static let supportURL = URL(string: "mailto:support@lune.noky.dev")!
}

// MARK: - Errors

enum APIError: LocalizedError, Equatable {
    /// An error code raised by an RPC with `raise exception '<code>'`.
    case server(code: String)
    case http(status: Int, message: String)
    case notSignedIn
    case decoding

    init(status: Int, body: Data) {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        let message = ["message", "msg", "error_description", "error"]
            .lazy.compactMap { json[$0] as? String }.first ?? ""
        if json["code"] as? String == "P0001" {
            self = .server(code: message)
        } else {
            self = .http(status: status, message: message)
        }
    }

    var errorDescription: String? {
        switch self {
        case .server(let code):
            switch code {
            case "closed": "Lune is closed. It opens at 8:00 PM."
            case "already_written", "upload_rejected": "You've already written this page."
            case "invalid_day": "You can only write tonight's or yesterday's page."
            case "text_required": "Write a few words about your day."
            case "text_too_long": "Pages can be up to 500 characters."
            case "entry_not_found": "This page couldn't be found."
            case "too_many_attempts": "Too many attempts. Try again later."
            case "own_username": "That's your own username."
            case "invalid_username": "Usernames can use letters, numbers, periods and underscores (up to 30)."
            case "username_taken": "That username is taken."
            case "too_many_friends": "Each person can have up to 1,000 friends."
            case "request_not_found": "This request is no longer there."
            case "profile_required": "Set your name first."
            default: "Something went wrong. Try again later."
            }
        case .http(let status, _) where status == 413:
            "This photo is too large."
        case .http, .decoding:
            "Something went wrong. Try again later."
        case .notSignedIn:
            "Please sign in again."
        }
    }
}

// MARK: - Coding

extension JSONDecoder {
    static let supabase: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            guard let date = PostgresDate.parse(string) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Bad date: \(string)")
            }
            return date
        }
        return decoder
    }()
}

/// Postgres timestamps: `timestamptz` carries an offset (microsecond precision); a bare `timestamp` is read as the user's local time.
enum PostgresDate {
    nonisolated static func parse(_ string: String) -> Date? {
        let pattern = /^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,9}))?(Z|[+-]\d{2}(?::?\d{2})?)?$/
        guard let m = string.wholeMatch(of: pattern) else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        if let zone = m.8 {
            calendar.timeZone = zone == "Z" ? .gmt : TimeZone(secondsFromGMT: offsetSeconds(String(zone))) ?? .gmt
        } else {
            calendar.timeZone = .current
        }

        var components = DateComponents()
        components.year = Int(m.1)
        components.month = Int(m.2)
        components.day = Int(m.3)
        components.hour = Int(m.4)
        components.minute = Int(m.5)
        components.second = Int(m.6)
        if let fraction = m.7 {
            components.nanosecond = Int(fraction.padding(toLength: 9, withPad: "0", startingAt: 0))
        }
        return calendar.date(from: components)
    }

    private nonisolated static func offsetSeconds(_ zone: String) -> Int {
        let sign = zone.hasPrefix("-") ? -1 : 1
        let digits = zone.dropFirst().replacingOccurrences(of: ":", with: "")
        let hours = Int(digits.prefix(2)) ?? 0
        let minutes = Int(digits.dropFirst(2)) ?? 0
        return sign * (hours * 3600 + minutes * 60)
    }
}

extension UUID {
    /// Postgres and Storage paths always use lowercase UUIDs.
    var lowercased: String { uuidString.lowercased() }
}
