# take

A recorder with a prompter. One window, black. The camera in the middle, the script over it, the settings beside it. Space records.

The camera does not record. It only sends its picture over HDMI. take writes HEVC straight to disk, with the audio from the capture card or any mic. The Mac's own camera, a Studio Display or an iPhone as Continuity Camera work too.

Format is 9:16, 4:5, 1:1 or 16:9, set in the sidebar and kept for next time. Each is the largest centred crop of the camera frame: 1920 x 1080 turns into 608 x 1080 at 9:16, a portrait 1080 x 1920 into 1080 x 608 at 16:9. It is locked while a take is recording.

## Voice

The teleprompter follows your voice. It listens on the Mac, offline, and scrolls to the line you are speaking. Improvise and it waits. Come back to the script, even a few sentences further, and it finds you. Switch to Fixed speed for the old behaviour.

Four spoken commands, each said on its own with a short pause before it. The same four are buttons in the sidebar.

    take start   count in 3, 2, 1, record
    take again   discard the take, back to where it started, count in, record
    take end     stop and keep, the command itself is trimmed off
    take reset   teleprompter from the top

Keep take end in the take, a switch under the commands, keeps the spoken take end and cuts right after it. The end tone never lands in the file.

Discarded takes are moved to `discarded/`, never deleted. While the teleprompter is shown and running, a command the script says where you are reading is a line, not an order. In Fixed speed take cannot tell where you are, so anywhere in the script counts. The script's last words are the exception, so a reel can end on a spoken take end. A near miss that is really script words ("give and take and") is not a command either.

Speech runs on the Mac only (`requiresOnDeviceRecognition`), in English or German, picked from the script. First launch opens a short script that shows it. Press E to write your own.

Voice log, off by default: `defaults write design.ante.take voiceLog -bool true` writes `~/Library/Logs/take-voice.log`. What was heard, what take decided, the camera and its frame count. Off, nothing is written.

## Keys

    space   record / stop
    p       teleprompter start / pause
    up down prompter speed
    t       teleprompter show / hide
    0       prompter back to the top
    - +     prompter text size
    e       write the script (esc closes)
    r       rotate 90 degrees
    s       frame rate: 30, 50, 60
    v       next camera
    a       next audio source
    o       choose the folder
    f       fullscreen

Files land in `take/` on the first external drive, otherwise in `~/Movies/take`. macOS asks once for access to the drive. Change it under Save to. Named `2026-09-26_take-01.mov`.

The teleprompter starts by itself when you record. In Fixed speed it first waits the delay set in the sidebar, 1.5 s by default. Start / Pause runs it without recording, for a rehearsal. The meter's brighter blocks mark -18 to -6 dB. Speak into them. Red means too loud.

## Icon

An LED panel. A 9:16 frame of lit dots, one red dot recording. `Icon/make-icon.swift` renders it.

## Build

    ./build.sh [output path]
    open build/take.app

Needs Xcode or the Command Line Tools. Builds for this Mac and signs with the Apple Development certificate if one exists, so camera access survives rebuilds.

## Release

    ./release.sh

Builds a universal take.app (Apple silicon and Intel, macOS 14 or later), ad-hoc signed with the hardened runtime, and packs `dist/take.dmg` with an Applications shortcut. Not notarized: the first launch needs Open Anyway under System Settings, Privacy & Security. Writes size and SHA-256 to `dist/release.json`. Every run produces different DMG bytes, so take both from that file, never by hand.

No account, no analytics, no network requests. Settings live in the user defaults under `design.ante.take`. Geist is under the SIL Open Font License, see `Resources/Fonts-OFL.txt`.

Made with Claude Code.
