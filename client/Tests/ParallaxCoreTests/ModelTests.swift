import CoreGraphics
import Foundation
import Testing
@testable import ParallaxCore

@Suite struct PlacementTests {
    let wide = CGSize(width: 1920, height: 1080)

    @Test func fitLetterboxesSquareSourceInWideFrame() throws {
        let p = try #require(Placement.compute(
            sourceSize: CGSize(width: 100, height: 100), crop: .none,
            frame: CGRect(origin: .zero, size: wide), mode: .fit))
        #expect(p.destRect == CGRect(x: 420, y: 0, width: 1080, height: 1080))
        #expect(p.sourceRect == CGRect(x: 0, y: 0, width: 100, height: 100))
    }

    @Test func fillCropsSourceToFrameAspect() throws {
        let p = try #require(Placement.compute(
            sourceSize: CGSize(width: 1920, height: 1080), crop: .none,
            frame: CGRect(x: 0, y: 0, width: 500, height: 500), mode: .fill))
        #expect(p.sourceRect == CGRect(x: 420, y: 0, width: 1080, height: 1080))
        #expect(p.destRect == CGRect(x: 0, y: 0, width: 500, height: 500))
    }

    @Test func cropIsAppliedBeforeFitting() throws {
        let p = try #require(Placement.compute(
            sourceSize: CGSize(width: 200, height: 100), crop: CropInsets(left: 0.25, right: 0.25),
            frame: CGRect(x: 0, y: 0, width: 50, height: 50), mode: .stretch))
        #expect(p.sourceRect == CGRect(x: 50, y: 0, width: 100, height: 100))
    }

    @Test func fullCropYieldsNothing() {
        #expect(Placement.compute(
            sourceSize: wide, crop: CropInsets(left: 0.5, right: 0.5),
            frame: CGRect(origin: .zero, size: wide), mode: .fit) == nil)
    }

    @Test func clampKeepsRectOnCanvas() {
        let r = NormalizedRect(x: 0.9, y: -0.2, width: 0.5, height: 0.5).clamped()
        #expect(r == NormalizedRect(x: 0.5, y: 0, width: 0.5, height: 0.5))
    }
}

@Suite struct ProfileTests {
    @Test func roundTripsThroughStore() throws {
        var profile = Profile.makeDefault()
        let camera = VideoSource(name: "Cam", kind: .camera(uniqueID: "abc"), delayMs: 120)
        profile.videoSources.append(camera)
        profile.scenes[0].items.append(SceneItem(sourceID: camera.id, frame: LayoutPreset.pipBottomRight.rect))
        profile.audioSources.append(AudioSource(name: "Mic", kind: .device(uniqueID: "mic"), gainDB: 3, delayMs: 80))

        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ProfileStore(url: dir.appending(path: "profile.json"))
        try store.save(profile)
        #expect(store.load() == profile)
    }

    @Test func corruptFileFallsBackToDefaultAndIsKept() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "profile.json")
        try Data("not json".utf8).write(to: url)

        let loaded = ProfileStore(url: url).load()
        #expect(loaded.scenes.count == 3)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(leftovers.contains { $0.contains("corrupt") })
    }
}
