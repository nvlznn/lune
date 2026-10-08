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

        // Alice keeps a draft to herself, edits it, then sends it to Bob
        let photo = try ImageProcessing.process(try SamplePhoto.make(width: 2000, height: 1500, type: .jpeg))
        var aliceTonight = try await alice.tonight()
        #expect(aliceTonight.open)
        let today = aliceTonight.today
        var page = try await alice.writeEntry(
            day: today, jpeg: photo.jpeg, takenAt: photo.takenAt, text: "Lunch by the sea.\nSleepy now.", recipients: []
        )
        #expect(page.text == "Lunch by the sea.\nSleepy now.")
        #expect(!page.isSent)
        await #expect(throws: APIError.server(code: "already_written")) {
            try await alice.writeEntry(day: today, jpeg: photo.jpeg, takenAt: nil, text: "Again", recipients: [])
        }
        let firstPath = page.storagePath
        page = try await alice.updateEntry(page.entryId, text: "Lunch by the sea.", jpeg: photo.jpeg, takenAt: photo.takenAt)
        #expect(page.editedAt != nil)
        #expect(page.storagePath != firstPath)

        let bobID = try #require(bob.session?.userID)
        page = try await alice.addRecipients(page.entryId, recipients: [bobID])
        #expect(page.isSent)
        #expect(page.recipients?.map(\.name) == ["Bob"])
        await #expect(throws: APIError.server(code: "already_sent")) {
            try await alice.updateEntry(page.entryId, text: "Too late")
        }

        // Bob sees a locked letter until he writes his own page (kept to himself)
        var bobTonight = try await bob.tonight()
        #expect(bobTonight.letters.isEmpty)
        #expect(bobTonight.locked.map(\.username) == [aliceUsername])
        _ = try await bob.writeEntry(day: today, jpeg: photo.jpeg, takenAt: nil, text: "Rainy.", recipients: [])
        bobTonight = try await bob.tonight()
        let fromAlice = try #require(bobTonight.letters.first)
        #expect(fromAlice.name == "Alice")
        #expect(fromAlice.username == aliceUsername)
        #expect(fromAlice.avatarPath == avatarPath)
        #expect(fromAlice.recipients == nil)
        #expect(try await bob.downloadImage(at: avatarPath, in: .avatars) == avatar)
        let takenAt = try #require(fromAlice.takenAt)
        #expect(Calendar.current.dateComponents([.hour, .minute], from: takenAt) == DateComponents(hour: 21, minute: 14))
        let downloaded = try await bob.downloadImage(at: fromAlice.storagePath)
        #expect(downloaded == photo.jpeg)
        #expect(!ImageProcessing.containsPersonalMetadata(downloaded))

        // Groups
        let group = try await alice.saveGroup(id: nil, name: "Close", memberIDs: [bobID])
        #expect(try await alice.groups() == [group])
        try await alice.deleteGroup(group.id)
        #expect(try await alice.groups().isEmpty)

        // Diary and export
        #expect(try await alice.myEntries().map(\.day) == [today])
        #expect(try await alice.exportEntries().count == 1)

        // During the day writing is closed (reading during the day is covered by pgTAP)
        try await alice.setTimeZone(LocalSupabase.zone(forLocalHour: 12))
        aliceTonight = try await alice.tonight()
        #expect(!aliceTonight.open)
        #expect(aliceTonight.opensAt != nil)

        // Report, block, delete
        try await bob.report(entryID: fromAlice.entryId, reason: "Spam")
        try await bob.block(userID: fromAlice.userId)
        #expect(try await bob.friends().isEmpty)
        try await alice.deleteAccount()
        #expect(alice.session == nil)
        try await bob.deleteAccount()
    }

    /// The hidden email sign-in used by the App Review account: signs in, never creates accounts.
    @Test func signsInWithEmailOnly() async throws {
        let email = "review-\(UUID().lowercased)@lune.test"
        let creator = APIClient(config: LocalSupabase.config, store: InMemorySessionStore())
        try await creator.signInForDevelopment(email: email, password: "review-password-123")

        let client = APIClient(config: LocalSupabase.config, store: InMemorySessionStore())
        let wrong = await #expect(throws: APIError.self) {
            try await client.signIn(email: email, password: "wrong-password")
        }
        #expect(wrong?.errorDescription == "The email or password is incorrect.")
        await #expect(throws: APIError.self) {
            try await client.signIn(email: "nobody-\(UUID().lowercased)@lune.test", password: "review-password-123")
        }
        #expect(client.session == nil)

        try await client.signIn(email: email, password: "review-password-123")
        #expect(client.session?.userID == creator.session?.userID)
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
