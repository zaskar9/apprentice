# Apprentice

A Cakewalk-style MIDI sequencer for Apple platforms, built on [libsseq](https://github.com/zaskar9/libsseq),
named after Cakewalk Apprentice, the program it follows.

The first milestone is a player in the spirit of the Windows 3.1 Media Player: open a `.WRK` or
`.MID` file, send its ports to the built-in synthesizer or to CoreMIDI destinations, and play it
with a time or measure scale.

## Layout

| Part | Where | What |
|---|---|---|
| SequencerKit | `Sources/SequencerKit` | Swift wrapper over the libsseq C API: `Work`, `Track`, `Event`, `Transport`, `Recorder`, maps and time conversions. Platform neutral. |
| CoreMIDIKit | `Sources/CoreMIDIKit` | `HostClock` (mach time), `MIDISystem` (client, output port, destinations) and `CoreMIDIOutput` (timestamped MIDI 1.0 event lists). |
| SynthKit | `Sources/SynthKit` | `BuiltInSynth`: a General MIDI synthesizer on Apple's AUMIDISynth unit, with the system bank or a loaded `.sf2`/`.dls`, fed by its own scheduler thread. |
| Apprentice (macOS) | `Apps/Apprentice` | The SwiftUI player. The Xcode project is generated from `project.yml`; the app icon is `Resources/Apprentice.icon` (Icon Composer), with the Illustrator master next to it. |
| Tests | `Tests/SequencerKitTests` | XCTest for SequencerKit (`swift test`). |

Terminology: libsseq follows the Cakewalk engine (sequence, stream); the Swift layer follows the
Cakewalk user interface (work, track), as the original application did on top of its engine.

## Build

Requirements: macOS 13 or later, Xcode 15 or later, [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
xcodegen generate          # writes Apprentice.xcodeproj (not committed)
open Apprentice.xcodeproj  # scheme "Apprentice", then Run
```

Xcode resolves the libsseq package from GitHub on the first build. To work against a local
checkout instead, drag the `libsseq` folder into the project navigator; Xcode then uses it in
place of the remote package.

The Swift package on its own builds and tests the two libraries:

```sh
swift build
swift test
```

## Using the player

- File > Open (⌘O), or drop a file on the window, or double-click a `.wrk` file in the Finder.
- Settings > MIDI Devices, after Cakewalk's dialog: the checked output devices (the built-in
  synthesizer, CoreMIDI destinations) become ports 1, 2, 3 in list order; drag to reorder, or
  "Move checked devices to top". The window shows which device each port of the open work goes
  to. A fresh install plays through the built-in synthesizer. Settings > Synthesizer switches
  between the system's General MIDI bank and a loaded soundfont (`.sf2` or `.dls`, for example
  FluidR3_GM); the soundfont is remembered too. Realtime > Panic (⌘.) sends all-notes-off and a
  controller reset everywhere.
- Scale menu: Time (mm:ss) or Measures, like the Media Player's Scale menu.
- Space plays and pauses, S stops (and rewinds), W rewinds. The slider seeks.
- Window > Event list > Track n opens Cakewalk's Event list for that track (read-only for now):
  Trk, Hr:Mn:Sc:Fr, Meas:Beat:Tick, Chn, Kind and Values, with the row at the Now time selected;
  selecting a row while stopped moves the Now time there.

The built-in synthesizer sounds without any setup. External destinations (a MIDI interface, a
DAW's virtual input, FluidSynth started with `-m coremidi`) appear in the Device menu as CoreMIDI
lists them.

## Status

0.1 (in progress): player. Planned next: the views of Cakewalk Apprentice (Track/Measure, Event
list, Piano-roll, Controllers, Staff, Markers, Tempo, Meter) and the editing commands, each
analysed against the original before it is built.
