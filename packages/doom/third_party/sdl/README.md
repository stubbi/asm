# SDL source and build

The included archive is the unmodified SDL 3.4.18 source release.
Its license is in `LICENSE.txt` and inside the archive.
The source record gives its upstream commit, origin, size, and SHA-256 digest.
The digest checks bytes; it does not establish publisher identity.

`tools/build_sdl.py` verifies the archive before extraction.
It builds a static Apple arm64 library with a macOS 15 deployment target.
The build requires Python 3.12 or later, CMake, and Apple command-line development tools.
Build files stay in `build/sdl/`.
The corresponding source offer includes this archive and the build recipe.

The build enables Cocoa windows, Metal presentation, CoreAudio output, and software test devices.
It disables GPU rendering, camera, joystick, haptic, sensor, HIDAPI, tray, dialog, power, OpenGL, and Vulkan support.
The final executable links SDL statically and uses Apple's system frameworks.
It does not need a Homebrew SDL installation.

SDL supplies native device services.
The game engine and its input mapping, PCM mixing, music parsing, and synthesis use handwritten AArch64 assembly.
The synthesizer uses bounded pulse, triangle, saw, and noise voices.
It supports MUS and Standard MIDI format 0 or 1 with up to 32 tracks.
MIDI division values from 1 through 960 ticks per quarter note are supported.
The 41 bundled Freedoom scores fit these format bounds.
The synthesizer does not reproduce a General MIDI sound bank.
It supports sustain and volume changes.
It does not model expression or spatial controllers.
It clamps tempos above 600 beats per minute to bound scheduler work.

Platform checks use synthetic sound data, malformed input, SDL test devices, and bundled music.
The Cocoa, Metal, and CoreAudio lifecycle also requires a native hardware check.
An audio device failure permits muted play.
A window failure reports an error and stops initialization.

The MIDI format reference is the MIDI Association's Standard MIDI Files 1.0 specification.
Its official index is <https://midi.org/standard-midi-files>.
The format reference and SDL release record were checked on 5 November 2026.
