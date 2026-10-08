import Foundation
import Testing
import UniformTypeIdentifiers
@testable import Lune

/// Runs the real client against local Supabase (`supabase start`). Skipped when it isn't running.
@Suite(.serialized, .timeLimit(.minutes(1)), .enabled("needs local Supabase") { await LocalSupabase.isRunning() })
struct APIClientIntegrationTests {
    @Test func exchangesPagesEndToEnd() async throws {
        let alice = try await LocalSupabase.signedInClient(name: "Alice", localHour: 22)
        let bob = try await LocalSupabase.signedInClient(name: "Bob", localHour: 22)

        // Usernames, photos, and friends by username + accept
        let aliceUsername = try #require(alice.profile?.username)
        #expect(try await bob.isUsernameAvailable(aliceUsername) == false)
        let avatar = try ImageProcessing.avatar(try SamplePhoto.make(width: 1200, height: 900, type: .jpeg))
        try await alice.setAvatar(jpeg: avatar)
        let avatarPath = try #require(alice.profile?.avatarPath)

        #expect(try await bob.findUser(username: "nobody_\(UUID().uuidString.prefix(6).lowercased())") == nil)
        let found = try #require(try await bob.findUser(username: "@" + aliceUsername.uppercased()))
        #expect(found.name == "Alice")
        #expect(found.relationship == .none)
        #expect(found.avatarPath == avatarPath)
        #expect(try await bob.addFriend(username: aliceUsername).status == .requested)
        let request = try #require(try await alice.friendRequests().first)
        #expect(request.name == "Bob")
        #expect(request.username == bob.profile?.username)
        try await alice.respondToFriendRequest(from: request.userId, accept: true)
        #expect(try await bob.friends().map(\.name) == ["Alice"])

        // Alice writes tonight; Bob sees only that she wrote
        let photo = try ImageProcessing.process(try SamplePhoto.make(width: 2000, height: 1500, type: .jpeg))
        var aliceTonight = try await alice.tonight()
        #expect(aliceTonight.open)
        let today = try #require(aliceTonight.tonight?.day)
        let page = try await alice.writeEntry(day: today, jpeg: photo.jpeg, takenAt: photo.takenAt, text: "Lunch by the sea.\nSleepy now.")
        #expect(page.text == "Lunch by the sea.\nSleepy now.")
        await #expect(throws: APIError.server(code: "already_written")) {
            try await alice.writeEntry(day: today, jpeg: photo.jpeg, takenAt: nil, text: "Again")
        }

        var bobTonight = try await bob.tonight()
        #expect(bobTonight.tonight?.friends.isEmpty == true)
        #expect(bobTonight.tonight?.lockedWriters == ["Alice"])

        // Bob writes, then reads Alice's page
        _ = try await bob.writeEntry(day: today, jpeg: photo.jpeg, takenAt: nil, text: "Rainy.")
        bobTonight = try await bob.tonight()
        let fromAlice = try #require(bobTonight.tonight?.friends.first)
        #expect(fromAlice.name == "Alice")
        #expect(fromAlice.avatarPath == avatarPath)
        #expect(try await bob.downloadImage(at: avatarPath, in: .avatars) == avatar)
        let takenAt = try #require(fromAlice.takenAt)
        #expect(Calendar.current.dateComponents([.hour, .minute], from: takenAt) == DateComponents(hour: 21, minute: 14))
        let downloaded = try await bob.downloadImage(at: fromAlice.storagePath)
        #expect(downloaded == photo.jpeg)
        #expect(!ImageProcessing.containsPersonalMetadata(downloaded))

        // Alice sees Bob saw it, and can edit her text
        aliceTonight = try await alice.tonight()
        #expect(aliceTonight.tonight?.mine?.seenBy?.map(\.name) == ["Bob"])
        let edited = try await alice.editEntryText(page.entryId, text: "Lunch by the sea.")
        #expect(edited.editedAt != nil)

        // Backfilling yesterday
        let yesterday = try #require(aliceTonight.lastNight?.day)
        _ = try await alice.writeEntry(day: yesterday, jpeg: photo.jpeg, takenAt: nil, text: "Written late.")
        #expect(try await alice.myEntries().map(\.day) == [today, yesterday])
        #expect(try await alice.exportEntries().count == 2)

        // Closed during the day
        try await alice.setTimeZone(LocalSupabase.zone(forLocalHour: 12))
        aliceTonight = try await alice.tonight()
        #expect(!aliceTonight.open)
        #expect(aliceTonight.opensAt != nil)
        #expect(aliceTonight.tonight?.friends.isEmpty == true)
        await #expect(throws: APIError.server(code: "closed")) {
            try await alice.editEntryText(page.entryId, text: "Daytime edit")
        }

        // Report, block, delete
        try await bob.report(entryID: fromAlice.entryId, reason: "Spam")
        try await bob.block(userID: fromAlice.userId)
        #expect(try await bob.friends().isEmpty)
        try await alice.deleteAccount()
        #expect(alice.session == nil)
        try await bob.deleteAccount()
    }
}

enum LocalSupabase {
    static let config = AppConfig.main

    static func isRunning() async -> Bool {
        var request = URLRequest(url: config.url.appending(path: "auth/v1/health"))
        request.setValue(config.key, forHTTPHeaderField: "apikey")
        request.timeoutInterval = 2
        let response = try? await URLSession.shared.data(for: request).1 as? HTTPURLResponse
        return response?.statusCode == 200
    }

    /// A time zone where it's `hour` o'clock right now ("Etc/GMT-8" is UTC+8: the sign is inverted).
    static func zone(forLocalHour hour: Int) -> String {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = .gmt
        let offset = ((hour - utc.component(.hour, from: .now) + 36) % 24) - 12
        return offset == 0 ? "Etc/GMT" : offset > 0 ? "Etc/GMT-\(offset)" : "Etc/GMT+\(-offset)"
    }

    static func signedInClient(name: String, localHour: Int) async throws -> APIClient {
        let client = APIClient(config: config, store: InMemorySessionStore())
        try await client.signInForDevelopment(email: "\(name.lowercased())-\(UUID().lowercased)@lune.test", password: "test-password-123")
        try await client.saveProfile(displayName: name, acceptTerms: true)
        try await client.setUsername("\(name.lowercased())_\(UUID().uuidString.prefix(8).lowercased())")
        try await client.setTimeZone(zone(forLocalHour: localHour))
        return client
    }
}
