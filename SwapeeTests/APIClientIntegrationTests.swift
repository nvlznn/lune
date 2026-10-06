import Foundation
import Testing
import UniformTypeIdentifiers
@testable import Swapee

/// Runs the real client against local Supabase (`supabase start`). Skipped when it isn't running.
@Suite(.serialized, .timeLimit(.minutes(1)), .enabled("needs local Supabase") { await LocalSupabase.isRunning() })
struct APIClientIntegrationTests {
    @Test func swapsPhotosEndToEnd() async throws {
        let alice = try await LocalSupabase.signedInClient(name: "Alice")
        let bob = try await LocalSupabase.signedInClient(name: "Bob")

        // Create and join
        let group = try await alice.createGroup(name: "Integration")
        #expect(group.inviteCode.count == 6)
        #expect(try await bob.joinGroup(code: "ZZZZZZ") == nil)
        let joined = try #require(try await bob.joinGroup(code: group.inviteCode.lowercased()))
        #expect(joined.id == group.id)
        #expect(try await alice.members(of: group.id).map(\.profile.displayName) == ["Alice", "Bob"])

        // Nothing to claim before uploading
        await #expect(throws: APIError.server(code: "no_credits")) { try await alice.claimPhoto(groupID: group.id) }

        // Alice uploads and waits
        let photo = try ImageProcessing.process(try SamplePhoto.make(width: 2000, height: 1500, type: .jpeg))
        try await alice.uploadPhoto(groupID: group.id, jpeg: photo.jpeg, takenAt: photo.takenAt, caption: "Lunch")
        await #expect(throws: APIError.server(code: "upload_rejected")) {
            try await alice.uploadPhoto(groupID: group.id, jpeg: photo.jpeg, takenAt: nil)
        }
        #expect(try await alice.claimPhoto(groupID: group.id) == .waiting)
        var aliceState = try await alice.groupState(group.id)
        #expect(aliceState.uploadedToday)
        #expect(aliceState.isWaiting)

        // Bob uploads, then each receives the other's photo
        try await bob.uploadPhoto(groupID: group.id, jpeg: photo.jpeg, takenAt: nil)
        try await bob.claimAll(groupID: group.id)
        try await alice.claimAll(groupID: group.id)

        aliceState = try await alice.groupState(group.id)
        #expect(aliceState.credits == 0)
        let received = try #require(aliceState.received.first)
        #expect(received.senderName == "Bob")
        #expect(received.takenAt == nil)

        let bobReceived = try #require(try await bob.groupState(group.id).received.first)
        #expect(bobReceived.senderName == "Alice")
        #expect(bobReceived.caption == "Lunch")
        #expect(received.caption == nil)

        // Alice sees that Bob received her photo
        let seenBy = try #require(try await alice.groupState(group.id).todayPhoto?.seenBy)
        #expect(seenBy.map(\.name) == ["Bob"])
        let takenAt = try #require(bobReceived.takenAt)
        #expect(Calendar.current.dateComponents([.hour, .minute], from: takenAt) == DateComponents(hour: 21, minute: 14))

        // The downloaded file is the stripped JPEG
        let downloaded = try await bob.downloadImage(at: bobReceived.storagePath)
        #expect(downloaded == photo.jpeg)
        #expect(!ImageProcessing.containsPersonalMetadata(downloaded))

        // The group list reflects today
        let summary = try #require(try await alice.myGroups().first { $0.id == group.id })
        #expect(summary.uploadedToday)
        #expect(summary.memberCount == 2)
        #expect(summary.lastReceivedAt != nil)

        // Report and block
        try await alice.report(photoID: received.photoId, reason: "Spam")
        try await alice.block(userID: received.senderId)
        #expect(try await alice.groupState(group.id).received.isEmpty)

        // Leave, then delete accounts
        try await bob.leaveGroup(group.id)
        await #expect(throws: APIError.server(code: "not_member")) { try await bob.groupState(group.id) }
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

    static func signedInClient(name: String) async throws -> APIClient {
        let client = APIClient(config: config, store: InMemorySessionStore())
        try await client.signInForDevelopment(email: "\(name.lowercased())-\(UUID().lowercased)@swapee.test", password: "test-password-123")
        try await client.saveProfile(displayName: name, acceptTerms: true)
        return client
    }
}
