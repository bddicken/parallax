import Foundation
import Testing
@testable import ParallaxCore

@Suite struct DeviceMatchingTests {
    let builtIn = DeviceMatching.Display(id: 1, uuid: "AAA", name: "Built-in Retina Display")
    let external = DeviceMatching.Display(id: 4, uuid: "BBB", name: "XV322QK V")

    @Test func displayIsFoundByUUIDAfterRestartRenumbersIt() {
        let renumbered = DeviceMatching.Display(id: 7, uuid: "BBB", name: "XV322QK V")
        #expect(DeviceMatching.display(id: 4, uuid: "BBB", name: "XV322QK V", among: [builtIn, renumbered]) == renumbered)
    }

    @Test func missingUUIDMeansDisplayIsGoneEvenIfIDIsReused() {
        let other = DeviceMatching.Display(id: 4, uuid: "CCC", name: "Studio Display")
        #expect(DeviceMatching.display(id: 4, uuid: "BBB", name: "XV322QK V", among: [builtIn, other]) == nil)
    }

    @Test func legacyDisplayWithoutUUIDMatchesByNameBeforeID() {
        // Old profile: ID 3 from before the restart; the monitor is now ID 4.
        let stale = DeviceMatching.Display(id: 3, uuid: "ZZZ", name: "Sidecar")
        #expect(DeviceMatching.display(id: 3, uuid: nil, name: "XV322QK V", among: [builtIn, external, stale]) == external)
        #expect(DeviceMatching.display(id: 4, uuid: nil, name: nil, among: [builtIn, external]) == external)
    }

    @Test func cameraReplugWithNewIDFallsBackToNameAndModel() {
        let camLink = DeviceMatching.Device(uniqueID: "0x1200000fd9006b", name: "Cam Link 4K", modelID: "UVC 0FD9:0066")
        let facetime = DeviceMatching.Device(uniqueID: "builtin", name: "FaceTime HD Camera", modelID: "FaceTime")
        #expect(DeviceMatching.device(uniqueID: "0x1100000fd9006b", name: "Cam Link 4K", modelID: "UVC 0FD9:0066",
                                      among: [facetime, camLink]) == camLink)
        #expect(DeviceMatching.device(uniqueID: "0x1100000fd9006b", name: nil, modelID: nil, among: [facetime, camLink]) == nil)
    }

    @Test func twoIdenticalCamerasAreNotGuessed() {
        let a = DeviceMatching.Device(uniqueID: "a", name: "Cam Link 4K", modelID: "m")
        let b = DeviceMatching.Device(uniqueID: "b", name: "Cam Link 4K", modelID: "m")
        #expect(DeviceMatching.device(uniqueID: "gone", name: "Cam Link 4K", modelID: "m", among: [a, b]) == nil)
        #expect(DeviceMatching.device(uniqueID: "b", name: "Cam Link 4K", modelID: "m", among: [a, b]) == b)
    }

    @Test func windowIsFoundAgainAfterAppRelaunch() {
        let editor = DeviceMatching.Window(id: 900, bundleID: "com.microsoft.VSCode", title: "parallax — Compositor.swift")
        let other = DeviceMatching.Window(id: 901, bundleID: "com.microsoft.VSCode", title: "notes")
        #expect(DeviceMatching.window(id: 12, bundleID: "com.microsoft.VSCode", title: "parallax — Compositor.swift",
                                      among: [other, editor]) == editor)
        // Title changed and the app has several windows: don't guess.
        #expect(DeviceMatching.window(id: 12, bundleID: "com.microsoft.VSCode", title: "old", among: [other, editor]) == nil)
        // Only one window from that app: use it.
        #expect(DeviceMatching.window(id: 12, bundleID: "com.microsoft.VSCode", title: "old", among: [editor]) == editor)
    }

    @Test func legacyKindsBorrowTheSourceNameForMatching() {
        #expect(VideoSourceKind.display(displayID: 4).withNameHint("XV322QK V") == .display(displayID: 4, uuid: nil, name: "XV322QK V"))
        // Kinds that already carry an identity are left alone.
        let modern = VideoSourceKind.display(displayID: 5, uuid: "U", name: "XV322QK V")
        #expect(modern.withNameHint("Renamed by user") == modern)
        #expect(AudioSourceKind.device(uniqueID: "m").withNameHint("RØDE PodMic USB") == .device(uniqueID: "m", name: "RØDE PodMic USB"))
        // The real-world case: saved as display 4, now display 5 after a restart.
        let now = [DeviceMatching.Display(id: 1, uuid: "A", name: "Built-in Retina Display"),
                   DeviceMatching.Display(id: 5, uuid: "B", name: "XV322QK V")]
        #expect(DeviceMatching.display(id: 4, uuid: nil, name: "XV322QK V", among: now)?.id == 5)
    }

    @Test func kindsSavedByOlderBuildsStillDecode() throws {
        let old = #"{"display":{"displayID":3}}"#
        let kind = try JSONDecoder().decode(VideoSourceKind.self, from: Data(old.utf8))
        #expect(kind == .display(displayID: 3))
        let cam = try JSONDecoder().decode(VideoSourceKind.self, from: Data(#"{"camera":{"uniqueID":"x"}}"#.utf8))
        #expect(cam == .camera(uniqueID: "x"))
        let mic = try JSONDecoder().decode(AudioSourceKind.self, from: Data(#"{"device":{"uniqueID":"m"}}"#.utf8))
        #expect(mic == .device(uniqueID: "m"))
    }
}
