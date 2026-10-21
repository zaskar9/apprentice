# Ensemble

A Cakewalk-style MIDI sequencer for Apple platforms, built on [libsseq](https://github.com/zaskar9/libsseq).
"Ensemble" is the working name.

The first milestone is a player in the spirit of the Windows 3.1 Media Player
(`Docs/concept-media-player.png`): open a `.WRK` or `.MID` file, map its ports to CoreMIDI
destinations, and play it with a time or measure scale.

## Layout

| Part | Where | What |
|---|---|---|
| SequencerKit | `Sources/SequencerKit` | Swift wrapper over the libsseq C API: `Work`, `Track`, `Event`, `Transport`, `Recorder`, maps and time conversions. Platform neutral. |
| CoreMIDIKit | `Sources/CoreMIDIKit` | `HostClock` (mach time), `MIDISystem` (client, output port, destinations) and `CoreMIDIOutput` (timestamped MIDI 1.0 event lists). |
| Ensemble (macOS) | `Apps/EnsembleMac` | The SwiftUI player. The Xcode project is generated from `project.yml`. |
| Tests | `Tests/SequencerKitTests` | XCTest for SequencerKit (`swift test`). |

Terminology: libsseq follows the Cakewalk engine (sequence, stream); the Swift layer follows the
Cakewalk user interface (work, track), as the original application did on top of its engine.

## Build

Requirements: macOS 13 or later, Xcode 15 or later, [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
xcodegen generate          # writes Ensemble.xcodeproj (not committed)
open Ensemble.xcodeproj    # scheme "Ensemble", then Run
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
- Device menu: one submenu per port the work uses; pick the CoreMIDI destination for each. The
  choice is remembered. Panic (⌘.) sends all-notes-off and a controller reset everywhere.
- Scale menu: Time (mm:ss) or Measures, like the Media Player's Scale menu.
- Space plays and pauses, S stops (and rewinds), W rewinds. The slider seeks.

Without a MIDI destination (no synthesizer or interface connected) nothing is heard. On a Mac
without hardware, enable the IAC Driver in Audio MIDI Setup and route it to a software synth, or use
a DAW's virtual input.

## Status

0.1 (in progress): player. Planned next: the views of Cakewalk Apprentice (Track/Measure, Event
list, Piano-roll, Controllers, Staff, Markers, Tempo, Meter) and the editing commands, each
analysed against the original before it is built.
