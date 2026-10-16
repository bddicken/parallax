import Darwin
import Foundation
import Testing
@testable import ParallaxRemote

@Suite struct LocalServerTests {
    @Test func importsServerDotenv() {
        var c = LocalServerCredentials()
        c.youtubeClientID = "kept"
        c.merge(dotenv: """
            # Copy to .env
            TWITCH_CLIENT_ID=abc123
            export TWITCH_CLIENT_SECRET="s3cret"
            YOUTUBE_CLIENT_ID=
            X_RTMP_URL = 'rtmps://va.pscp.tv:443/x'
            X_STREAM_KEY=key=with=equals
            PARALLAX_ADDR=0.0.0.0:8080
            """)
        #expect(c.twitchClientID == "abc123")
        #expect(c.twitchClientSecret == "s3cret")
        #expect(c.youtubeClientID == "kept", "empty values don't clear what's there")
        #expect(c.xRTMPURL == "rtmps://va.pscp.tv:443/x")
        #expect(c.xStreamKey == "key=with=equals")
    }

    @Test func environmentSetsEveryPlatformVariable() {
        var c = LocalServerCredentials()
        c.twitchClientID = "  abc  "
        let env = c.environment
        #expect(env["TWITCH_CLIENT_ID"] == "abc")
        // Set even when empty, so a stray .env can't turn a platform on.
        #expect(env["YOUTUBE_CLIENT_ID"] == "")
        #expect(env.count == 7)
    }

    @Test func credentialsDecodeWithMissingFields() throws {
        let c = try JSONDecoder().decode(LocalServerCredentials.self, from: Data(#"{"twitchClientID":"abc"}"#.utf8))
        #expect(c.twitchClientID == "abc" && c.xUsername == "")
    }

    @Test func secretsRoundTripInAnOwnerOnlyFile() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let secrets = SecretStore(url: dir.appending(path: "secrets.json"))
        #expect(secrets.read("server-token") == nil)

        var c = LocalServerCredentials()
        c.twitchClientID = "abc"
        c.save(to: secrets)
        secrets.write("tok", for: "server-token")
        #expect(LocalServerCredentials.load(from: secrets) == c)
        #expect(secrets.read("server-token") == "tok")

        let attributes = try FileManager.default.attributesOfItem(atPath: secrets.url.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["secrets.json"])

        secrets.write("", for: "server-token")
        #expect(secrets.read("server-token") == nil)
        // Once the file exists, the Keychain is never read again.
        secrets.importFromKeychain(["server-token"])
        #expect(secrets.read("server-token") == nil)
        #expect(LocalServerCredentials.load(from: secrets) == c)
    }

    @Test func freePortsAreDistinct() throws {
        let ports = try #require(LocalServer.freePorts([SOCK_STREAM, SOCK_STREAM, SOCK_DGRAM, SOCK_STREAM]))
        #expect(ports.count == 4)
        #expect(ports.allSatisfy { $0 > 0 })
        let tcp = [ports[0], ports[1], ports[3]]
        #expect(Set(tcp).count == 3)
    }

    @Test func portsInUseArentFree() throws {
        let types = [SOCK_STREAM, SOCK_DGRAM]
        let ports = try #require(LocalServer.freePorts(types))
        #expect(LocalServer.arePortsFree(ports, types))
        // Hold the TCP one.
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = ports[0].bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        try #require(bound == 0 && listen(fd, 1) == 0)
        #expect(!LocalServer.arePortsFree(ports, types))
        #expect(!LocalServer.arePortsFree([ports[1]], types), "one port per type")
    }

    @MainActor @Test func savedEndpointIsOwnerOnlyAndClearedOnStop() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let server = LocalServer(directory: dir)
        let saved = LocalServer.Saved(url: URL(string: "http://127.0.0.1:1")!, token: "t", pid: 1, ports: [1, 2, 3, 4])
        try JSONEncoder().encode(saved).write(to: server.savedURL)
        server.stop()
        #expect(!FileManager.default.fileExists(atPath: server.savedURL.path))
    }

    @Test func findsToolsByOverrideAndPath() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let tool = dir.appending(path: "parallax-test-tool")
        FileManager.default.createFile(atPath: tool.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])

        #expect(LocalServer.findTool("parallax-test-tool", environment: ["PATH": dir.path])?.path == tool.path)
        #expect(LocalServer.findTool("parallax-test-tool", environment: ["PATH": "/nonexistent"]) == nil)
        let override = ["PARALLAX_PARALLAX-TEST-TOOL": tool.path]
        #expect(LocalServer.findTool("parallax-test-tool", environment: override)?.path == tool.path)
        #expect(LocalServer.serverExecutable(environment: ["PARALLAX_SERVER_BIN": tool.path])?.path == tool.path)
    }
}
