import AppKit
import AVFoundation
import BuddyCore
import QuartzCore
import SwiftUI
import Testing
@testable import Buddy

private nonisolated final class PenAudioCapture: @unchecked Sendable {
    private struct Block {
        let start: Double
        let rate: Double
        let samples: [Float]
    }
    private let lock = NSLock()
    private var blocks: [Block] = []

    func append(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let block = Block(start: AVAudioTime.seconds(forHostTime: time.hostTime), rate: buffer.format.sampleRate,
                          samples: Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))))
        lock.lock()
        blocks.append(block)
        lock.unlock()
    }

    func level(from start: Double, through end: Double) -> (peak: Float, count: Int) {
        lock.lock()
        defer { lock.unlock() }
        return blocks.reduce((peak: Float(0), count: 0)) { result, block in
            let first = max(0, Int(ceil((start - block.start) * block.rate)))
            let last = min(block.samples.count, Int(floor((end - block.start) * block.rate)))
            guard first < last else { return result }
            return (max(result.peak, block.samples[first..<last].map(abs).max() ?? 0), result.count + last - first)
        }
    }

    func save(to url: URL) throws {
        lock.lock()
        let recorded = blocks
        lock.unlock()
        let rate = try #require(recorded.first?.rate)
        let samples = recorded.flatMap(\.samples)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
        buffer.frameLength = buffer.frameCapacity
        buffer.floatChannelData![0].update(from: samples, count: samples.count)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}

@MainActor
@Suite(.serialized)
struct PenSoundsFunctionalTests {
    private var evidence: URL {
        URL(filePath: "/tmp/buddy-frontier-issue-33/functional", directoryHint: .isDirectory)
    }

    private func picture(_ view: NSView, name: String) throws {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width), pixelsHigh: Int(view.bounds.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let context = try #require(CGContext(
            data: bitmap.bitmapData, width: bitmap.pixelsWide, height: bitmap.pixelsHigh,
            bitsPerComponent: 8, bytesPerRow: bitmap.bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        if view.isFlipped {
            context.translateBy(x: 0, y: view.bounds.height)
            context.scaleBy(x: 1, y: -1)
        }
        let layer = try #require(view.layer?.presentation() ?? view.layer)
        layer.render(in: context)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: evidence.appending(path: name))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["BUDDY_LIVE_PEN_SOUNDS"] == "1"))
    func renderedRevealsAndOutputAudioShareAClockAndDisablingSilencesQueuedStrokes() async throws {
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        let frame = NSRect(x: 0, y: 0, width: 1280, height: 800)
        let view = DrawMarksView(screenFrame: frame, scale: 1)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Buddy issue 33 sound check"
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = view
        view.layer?.backgroundColor = NSColor.black.cgColor
        window.orderFront(nil)
        defer { window.close() }

        var engine = BuddyEngine(providerConnected: true)
        _ = engine.handle(.pushToTalkPressed)
        _ = engine.handle(.pushToTalkReleased)
        _ = engine.handle(.transcriptFinished("Draw."))
        _ = engine.handle(.screensCaptured([ScreenCapture(
            jpeg: Data([1]), display: DisplayRect(x: 0, y: 0, width: 1280, height: 800),
            pixelWidth: 1280, pixelHeight: 800, containsCursor: true
        )]))
        _ = engine.handle(.provider(.textDelta("""
        ```draw
        beat("Pen, words, then pen.");
        stroke([[200, 250], [290, 250]]);
        text("paper", 200, 320, 20);
        stroke([[200, 420], [650, 420]]);
        beat("Still drawing, now silent.");
        stroke([[200, 520], [650, 520]]);
        ```

        """)))
        let effects = engine.handle(.lineStarted)
        let marks = try #require(effects.compactMap { effect -> [DrawMark<DisplayPoint>]? in
            if case .draw(let marks, _) = effect { return marks }
            return nil
        }.first)
        let cues = try #require(effects.compactMap { effect -> [PenSoundCue]? in
            if case .playPenSounds(let cues) = effect { return cues }
            return nil
        }.first)
        #expect(cues == [PenSoundCue(offset: 0, duration: 0.25), PenSoundCue(offset: 0.5, duration: 0.5)])
        let sounds = PenSounds()
        let buffer = try #require(sounds.prepare(cues))
        let simultaneous = try #require(sounds.prepare(Array(repeating: PenSoundCue(offset: 0, duration: 0.08), count: 200)))
        let peak = UnsafeBufferPointer(start: simultaneous.floatChannelData![0], count: Int(simultaneous.frameLength)).map(abs).max() ?? 0
        #expect(peak > 0.09 && peak <= 0.100001)
        let capture = PenAudioCapture()
        let mixer = sounds.audio.mainMixerNode
        mixer.installTap(onBus: 0, bufferSize: 256, format: nil) { buffer, time in capture.append(buffer, at: time) }
        defer {
            sounds.stop()
            mixer.removeTap(onBus: 0)
            sounds.audio.stop()
        }
        let start = CACurrentMediaTime() + 0.15
        view.add(marks, animated: true, startingAt: start)
        sounds.play(buffer, startingAt: start)
        let layers = try #require(view.layer?.sublayers)
        #expect(layers[0].animation(forKey: "draw")?.beginTime == start)
        #expect(layers[2].animation(forKey: "draw")?.beginTime == start + 0.5)
        try await Task.sleep(for: .milliseconds(240))
        let first = try #require(layers[0].presentation() as? CAShapeLayer)
        #expect(first.strokeEnd > 0 && first.strokeEnd < 1)
        try picture(view, name: "enabled-first.png")
        try await Task.sleep(for: .milliseconds(560))
        let last = try #require(layers[2].presentation() as? CAShapeLayer)
        #expect(last.strokeEnd > 0 && last.strokeEnd < 1)
        try picture(view, name: "enabled-second.png")
        #expect(capture.level(from: start + 0.04, through: start + 0.18).peak > 0.005)
        let gap = capture.level(from: start + 0.30, through: start + 0.42)
        #expect(gap.count > 1000 && gap.peak < 0.00001)
        #expect(capture.level(from: start + 0.54, through: start + 0.62).peak > 0.005)

        #expect(engine.handle(.penSoundsChanged(false)) == [.stopPenSounds])
        sounds.stop()
        let stopped = CACurrentMediaTime()
        _ = engine.handle(.lineFinished)
        let disabled = engine.handle(.lineStarted)
        #expect(disabled == [
            .showNotch(.line("Still drawing, now silent.")),
            .draw([.stroke([DisplayPoint(x: 200, y: 280), DisplayPoint(x: 650, y: 280)])],
                  on: DisplayRect(x: 0, y: 0, width: 1280, height: 800))
        ])
        view.add([.stroke([DisplayPoint(x: 200, y: 280), DisplayPoint(x: 650, y: 280)])], animated: true)
        try await Task.sleep(for: .milliseconds(300))
        let silent = capture.level(from: stopped + 0.1, through: stopped + 0.25)
        #expect(silent.count > 1000 && silent.peak < 0.00001)
        try picture(view, name: "disabled.png")
        try capture.save(to: evidence.appending(path: "output.wav"))
        print("PEN_FUNCTIONAL start=\(start) reveals=[0,0.5] audio=nonzero,silent,nonzero disabled=silent")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["BUDDY_LIVE_PEN_SOUNDS"] == "1"))
    func settingsRendersTheSavedPenSoundSwitch() async throws {
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        let suite = "dev.steven.buddy.issue33.ui.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let manager = CompanionManager(historyURL: evidence.appending(path: "history.json"),
                                       profileURL: evidence.appending(path: "profile.md"), preferences: preferences,
                                       codexScreenshotRoot: evidence.appending(path: "screenshots"))
        let view = NSHostingView(rootView: ScrollView { CompanionPanelView(manager: manager) }.background(DS.Colors.background))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 710),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = view
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(300))
        try picture(view, name: "settings-on.png")
        func switches(in root: NSView) -> [NSSwitch] {
            (root as? NSSwitch).map { [$0] } ?? root.subviews.flatMap { switches(in: $0) }
        }
        let controls = switches(in: view).sorted {
            view.convert($0.bounds, from: $0).midY < view.convert($1.bounds, from: $1).midY
        }
        let penSwitch = try #require(controls.dropFirst().first)
        penSwitch.performClick(nil)
        #expect(preferences.object(forKey: "penSounds") as? Bool == false)
        try await Task.sleep(for: .milliseconds(300))
        try picture(view, name: "settings-off.png")
        let reopened = CompanionManager(historyURL: evidence.appending(path: "history.json"),
                                        profileURL: evidence.appending(path: "profile.md"), preferences: preferences,
                                        codexScreenshotRoot: evidence.appending(path: "screenshots"))
        #expect(reopened.state.penSounds == false)
    }
}
