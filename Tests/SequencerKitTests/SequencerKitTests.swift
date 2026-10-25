import XCTest
@testable import SequencerKit

final class FakeClock: SequencerClock {
    var now: Double = 0
}

final class RecordingOutput: MIDIOutput {
    var messages: [MIDIMessage] = []
    var sysex: [(Double, Int, [UInt8])] = []
    var flushes = 0

    func send(_ message: MIDIMessage) { messages.append(message) }
    func sendSysex(at time: Double, port: Int, bytes: [UInt8]) { sysex.append((time, port, bytes)) }
    func flush() { flushes += 1 }
}

final class SequencerKitTests: XCTestCase {
    /// 120 bpm, 120 ppq (240 ticks per second): one track, three quarter notes.
    func makeWork() -> Work {
        let work = Work()
        let index = work.addTrack(number: 0)
        var track = work.track(at: index)!
        track.name = "Lead"
        track.parameters.channel = 2
        track.parameters.patch = 40
        track.parameters.volume = 100
        XCTAssertTrue(work.update(track))
        work.insert(.note(240, channel: 2, key: 64, velocity: 80, duration: 120), inTrack: index)
        work.insert(.note(0, channel: 2, key: 60, velocity: 100, duration: 120), inTrack: index)
        work.insert(.note(120, channel: 2, key: 62, velocity: 90, duration: 120), inTrack: index)
        return work
    }

    func testModelAndFiles() throws {
        let work = makeWork()
        XCTAssertEqual(work.ppq, 120)
        XCTAssertEqual(work.trackCount, 1)
        XCTAssertEqual(work.endTick, 360)
        let track = try XCTUnwrap(work.track(at: 0))
        XCTAssertEqual(track.name, "Lead")
        XCTAssertEqual(track.parameters.channel, 2)
        XCTAssertEqual(track.parameters.patch, 40)
        XCTAssertNil(track.parameters.pan)
        let events = work.events(inTrack: 0)
        XCTAssertEqual(events.map { $0.time }, [0, 120, 240]) // kept in time order
        XCTAssertEqual(events[1].data1, 62)

        let textIndex = try XCTUnwrap(work.insert(.text(60, "hello"), inTrack: 0))
        XCTAssertEqual(textIndex, 1)
        XCTAssertEqual(work.event(at: 1, inTrack: 0)?.text, "hello")
        XCTAssertTrue(work.removeEvent(at: 1, inTrack: 0))

        work.setTempo(at: 240, bpm100: 6000)
        XCTAssertEqual(work.tempoMap.count, 2)
        XCTAssertEqual(work.seconds(at: 360), 2.0, accuracy: 1e-9)
        XCTAssertEqual(work.mbt(at: 485), MBT(measure: 2, beat: 1, tick: 5))
        XCTAssertEqual(work.mbt(at: 485).description, "2:1:005")
        XCTAssertEqual(MBT(parsing: "12:3:045"), MBT(measure: 12, beat: 3, tick: 45))
        XCTAssertNil(MBT(parsing: "nonsense"))
        work.addMarker(Marker(time: 240, name: "Verse"))
        XCTAssertEqual(work.markers.first?.name, "Verse")
        work.set(.metronomeRecording, to: true)
        XCTAssertTrue(work.flag(.metronomeRecording))
        XCTAssertFalse(work.set(.thruOn, to: true)) // read only

        let wrk = try work.wrkData(normalize: true)
        XCTAssertEqual(String(decoding: wrk.prefix(8), as: UTF8.self), "CAKEWALK")
        let back = try Work(wrkData: wrk)
        XCTAssertEqual(back.trackCount, 1)
        XCTAssertEqual(back.events(inTrack: 0).count, 3)
        XCTAssertEqual(back.track(at: 0)?.name, "Lead")
        XCTAssertEqual(back.tempoMap.count, 2)

        let mid = try work.midData(portMeta: false)
        XCTAssertEqual(String(decoding: mid.prefix(4), as: UTF8.self), "MThd")
        let fromMID = try Work(midData: mid)
        XCTAssertEqual(fromMID.events(inTrack: 0).count, 3)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sequencerkit-test.wrk")
        try work.writeWRK(to: url)
        let fromFile = try Work(contentsOf: url)
        XCTAssertEqual(fromFile.endTick, 360)
        try? FileManager.default.removeItem(at: url)
        XCTAssertThrowsError(try Work(contentsOf: URL(fileURLWithPath: "/nonexistent/file.wrk")))
    }

    func testRenderAndTransport() throws {
        let work = makeWork()
        var options = PlaybackOptions()
        XCTAssertTrue(options.chase)
        XCTAssertTrue(options.stopAtEnd)
        options.sendTrackParameters = false
        let rendered = try render(work, options: options)
        XCTAssertEqual(rendered.count, 6)
        XCTAssertEqual(rendered[0].bytes, [0x92, 60, 100])
        XCTAssertEqual(rendered[5].time, 1.5, accuracy: 1e-9)

        work.insert(.text(60, "hello"), inTrack: 0) // tick 60 = 0.25 s into playback
        let clock = FakeClock()
        let output = RecordingOutput()
        options.lookAhead = 0.05
        let transport = try Transport(work: work, clock: clock, output: output, options: options)
        var strings = 0
        transport.stringEventHandler = { _, event, _ in
            if event.text == "hello" { strings += 1 }
        }
        XCTAssertEqual(transport.endTick, 360)
        clock.now = 1.0
        transport.play()
        XCTAssertTrue(transport.isPlaying)
        XCTAssertEqual(output.messages.count, 1)
        clock.now = 1.3
        XCTAssertTrue(transport.pump())
        XCTAssertEqual(transport.now, 72)
        XCTAssertEqual(strings, 1)
        XCTAssertEqual(transport.tick(at: 1.5), 120)
        XCTAssertNil(transport.tick(at: 0.5))
        clock.now = 1.5
        XCTAssertTrue(transport.pump())
        XCTAssertEqual(output.messages.count, 3)
        XCTAssertGreaterThanOrEqual(output.flushes, 2)
        transport.setMuted(true, trackNumber: 0)
        XCTAssertFalse(transport.isAudible(trackNumber: 0))
        transport.setMuted(false, trackNumber: 0)
        clock.now = 2.6
        XCTAssertFalse(transport.pump()) // ended
        XCTAssertFalse(transport.isPlaying)
        XCTAssertEqual(output.messages.count, 6)
        transport.rewind()
        XCTAssertEqual(transport.now, 0)

        // Recording: the transport runs past the end while recording.
        var recording = transport.options
        recording.stopAtEnd = false
        transport.options = recording
        let recorder = try Recorder(transport: transport)
        clock.now = 10.0
        transport.play()
        recorder.receive(MIDIMessage(time: 10.0, port: 0, bytes: [0x90, 67, 100]))
        recorder.receive(MIDIMessage(time: 10.5, port: 0, bytes: [0x90, 67, 0]))
        recorder.receive(MIDIMessage(time: 10.5, port: 0, bytes: [0x90, 69, 100]))
        clock.now = 11.0
        transport.pump()
        recorder.finish(at: 11.0)
        transport.stop()
        XCTAssertEqual(recorder.count, 2)
        XCTAssertEqual(recorder.events[0], .note(0, channel: 0, key: 67, velocity: 100, duration: 120))
        XCTAssertEqual(recorder.events[1].time, 120)
        XCTAssertTrue(recorder.commit(toTrack: 0, of: work))
        XCTAssertEqual(work.eventCount(inTrack: 0), 6)
        XCTAssertTrue(recorder.isEmpty)
    }
}

final class DisplayTextTests: XCTestCase {
    func testEventListText() {
        XCTAssertEqual(DisplayText.keyName(60), "C 5")
        XCTAssertEqual(DisplayText.keyName(56), "G#4")
        XCTAssertEqual(DisplayText.key(parsing: "G 10"), 127)
        XCTAssertNil(DisplayText.key(parsing: "H2"))
        XCTAssertEqual(DisplayText.durationText(200, ppq: 120), "1:080")
        XCTAssertEqual(DisplayText.duration(parsing: "1:080", ppq: 120), 200)
        XCTAssertEqual(DisplayText.generalMIDIProgramName(20), "Reed Organ")
        XCTAssertNil(DisplayText.generalMIDIProgramName(128))
        XCTAssertEqual(EventKind.pitchWheel.displayName, "Wheel")
        let note = Event.note(0, channel: 2, key: 60, velocity: 100, duration: 240)
        XCTAssertEqual(note.channelText, "3")
        XCTAssertEqual(note.valuesText(ppq: 120), "C 5  100  2:000")
        XCTAssertEqual(Event.text(0, "hello").valuesText(ppq: 120), "hello")
        XCTAssertEqual(Event.text(0, "hello").channelText, "n/a")
    }
}
