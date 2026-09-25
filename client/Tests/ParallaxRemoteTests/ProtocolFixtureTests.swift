import Foundation
import Testing
@testable import ParallaxRemote

/// Decodes the samples in docs/protocol-fixtures, which the server's tests
/// also round-trip, so the Swift and Rust wire types can't drift apart.
@Suite struct ProtocolFixtureTests {
    private func fixture(_ name: String) throws -> Data {
        let root = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../../docs/protocol-fixtures")
        return try Data(contentsOf: root.appending(path: "\(name).json"))
    }

    private func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try WireCoding.decoder().decode(type, from: fixture(name))
    }

    @Test func decodesDestinationsAndIngest() throws {
        let destinations = try decode([Destination].self, "destinations")
        #expect(destinations.map(\.platform) == [.twitch, .youtube, .custom])
        #expect(destinations[0].chatURL == "https://www.twitch.tv/popout/parallaxdev/chat?popout=")
        #expect(destinations[2].rtmpURL == "rtmp://127.0.0.1:1935/test")
        #expect(try decode(IngestInfo.self, "ingest").srtURL.hasPrefix("srt://"))
    }

    @Test func decodesAccounts() throws {
        let accounts = try decode([Account].self, "accounts")
        #expect(accounts[0].state == .pending)
        #expect(accounts[0].pending?.userCode == "ABCD-EFGH")
        #expect(accounts[1].error == "Not supported yet.")
    }

    @Test func decodesEvents() throws {
        guard case .chat(let message) = try decode(ServerEvent.self, "event-chat") else { Issue.record("not chat"); return }
        #expect(message.author.isModerator)
        #expect(message.timestamp == ISO8601DateFormatter().date(from: "2026-09-24T18:21:07Z")!.addingTimeInterval(0.412))

        guard case .status(let status) = try decode(ServerEvent.self, "event-status") else { Issue.record("not status"); return }
        #expect(status.destinations.map(\.state) == [.live, .error])
        #expect(status.startedAt != nil)

        guard case .accounts(let accounts) = try decode(ServerEvent.self, "event-accounts") else { Issue.record("not accounts"); return }
        #expect(accounts.map(\.platform) == [.twitch, .youtube])
        #expect(accounts[1].displayName == "Parallax Dev")
    }

    @Test func decodesHealthAndEncodesUpdates() throws {
        #expect(try decode(ServerHealth.self, "health") == ServerHealth(version: "0.1.0", canUpdate: true))
        let encoded = try JSONSerialization.jsonObject(with: WireCoding.encoder().encode(UpdateServerRequest(version: "0.2.0"))) as? NSDictionary
        let expected = try JSONSerialization.jsonObject(with: fixture("update-server")) as? NSDictionary
        #expect(encoded == expected)
    }

    @Test func encodesStartRequestLikeTheFixture() throws {
        let request = StartBroadcastRequest(destinationIDs: ["twitch", "youtube"], title: "Building Parallax", privacy: "public")
        let encoded = try JSONSerialization.jsonObject(with: WireCoding.encoder().encode(request)) as? NSDictionary
        let expected = try JSONSerialization.jsonObject(with: fixture("start-broadcast")) as? NSDictionary
        #expect(encoded == expected)
    }
}
