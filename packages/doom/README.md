# Asm Doom

Native Doom-compatible game for **Apple Silicon with macOS 15 or later**.
The engine is written directly in AArch64 assembly.
It uses the Apple arm64 ABI, Mach-O format, and Clang assembler syntax.
It requires no optional CPU extensions beyond Apple Silicon support.
Freedoom Phase 1 supplies the bundled game data.

## Status

Version 0.1.0 is the first alpha of this engine.
Full campaign completion and vanilla demo compatibility remain unqualified.

The engine loads the 36 bundled maps and renders their original geometry and textures.
Native tests cover selected combat, movement, sector mechanisms, saves, sound, music, and installation paths.
The validation records state each check's scope and remaining limits.

- [Renderer evidence](RENDER-VALIDATION.md)
- [Platform and audio evidence](PLATFORM-VALIDATION.md)
- [World and save evidence](tests/world-validation.md)
- [Campaign movement evidence](CAMPAIGN-MOVEMENT-VALIDATION.md)
- [Module contracts](ABI.md)

## Install

Use Apple Silicon with macOS 15 or later.
Install [Asm](https://asm.build) 0.6.0 before installing the game.

```sh
asm install stubbi/doom@0.1.0
"$HOME/.local/bin/doom"
```

Installation checks the selected artifact and records the installed file.
It does not start the game.
The second command opens the controls menu over the first map.

The game needs no separate data download or Homebrew runtime.
Other processor architectures and operating systems are unsupported in this release.

## Build and run

Install Xcode Command Line Tools before building.
Install Python 3.12 or later, Make, and CMake.
Make CMake available at `/opt/homebrew/bin/cmake` or a system tool path.
The first build expands the included SDL source archive and builds its static library.
No dependency download is required.
Use this Makefile to build the source package.
Asm's current project builder cannot express this game's static framework link.

Run these commands from this directory:

```sh
make
./build/asm-doom
```

The game shows a controls menu over the first Freedoom map.
Press Enter to resume play.
Use Escape to open the menu and release the mouse.

| Control | Action |
| --- | --- |
| W/S or Up/Down | Move forward/backward. |
| A/D | Move sideways. |
| Mouse or Left/Right | Turn. |
| Left click or Ctrl | Fire. |
| E or Space | Use a door or switch. |
| Shift | Run. |
| 1–7 | Select an owned weapon. |
| Escape | Open or close the menu. |
| P | Pause. |
| F5/F9 | Save/load the default slot. |
| F11 | Toggle fullscreen. |

The default save is `$HOME/.asm-doom/save1.bin`.
The game creates a private save directory.
It refuses unrelated files and symlinks at the save destination.
An existing valid game save can be replaced atomically.
Checks on existing paths do not prevent every race with another process running as the same user.

Use a map name to start another level:

```sh
./build/asm-doom --map E2M1
```

Use `--iwad PATH` to select another Doom-format data file.
Compatibility with arbitrary external data is not qualified.
The game does not modify the selected WAD.
A WAD is a file containing maps, graphics, sounds, and other game data.

## Test

Run the native package checks:

```sh
make test
```

The platform tests use SDL's dummy devices by default.
Native-window checks require a logged-in macOS display session.
The platform evidence gives the separate native-device command.

The installation checks use `ASM_BIN` when that variable is set.
Otherwise, they use the Asm executable at the repository's `build/asm` path.
Build Asm before running this gate from its repository:

```sh
make -C ../..
ASM_BIN="$PWD/../../build/asm" make test
```

The source-only package can run its engine checks without an Asm checkout.
It reports the installation gate as skipped when Asm is unavailable.
A release must pass that gate with an explicit executable.

For a deterministic headless check:

```sh
./build/asm-doom --headless --ticks 35 --screenshot new-frame.ppm
```

The screenshot destination must be new.
The command reports final game state as JSON.
`--ticks N` advances fixed simulation steps without opening native devices.

`--input FILE` accepts a versioned headless input recording.
Its 16-byte header contains `ASMINP1` followed by NUL, a little-endian 32-bit record count, and a zero reserved field.
Each 32-byte record contains three little-endian float32 controls, buttons, weapon, and three zero fields.
The controls are forward movement, sideways movement, and turn angle.
Button bits are use 1, fire 2, run 4, and pause 8.
The weapon field is zero or a number from 1 to 7.
The parser bounds record counts and rejects non-finite controls.
These recordings are test inputs, not vanilla Doom demos.

## Runtime and source boundary

`src/*.s` contains all game rules, map parsing, rendering, menus, input mapping, saves, audio mixing, and music scheduling.
No compiler-produced engine assembly or C game backend is used.
SDL handles native windows, device events, presentation, and PCM audio output.
System math functions provide primitive trigonometry.
System zlib expands the embedded data in memory.

The engine uses floating-point coordinates and heuristic monster pursuit.
It does not reproduce vanilla fixed-point simulation or qualify original demos.
Infighting and Nightmare behavior need further qualification.
The evidence records list additional limits for each subsystem.

The executable links SDL statically and embeds compressed Freedoom data.
Its remaining dynamic dependencies are macOS system libraries and frameworks.
It does not need Homebrew at runtime.
Python build tools and C test drivers are separate from the shipped engine.

## Licenses and origin

Print the complete licenses and copyright notices from the installed executable:

```sh
doom --license
```

The command prints notices before opening game data or native devices.
Its output includes the corresponding source location for version 0.1.0.

The independent engine package uses GPL-2.0-or-later.
See [LICENSE](LICENSE).
The assembly source cites Doom or Chocolate Doom references where applicable.
Those references do not establish behavioral equivalence.

Freedoom 0.13.0 data uses BSD-3-Clause.
Its complete [copyright notice](third_party/COPYING.txt), [credits](third_party/CREDITS.txt), and [music credits](third_party/CREDITS-MUSIC.txt) are included.
[The data record](assets/freedoom.json) identifies the original archive and embedded bytes.
No proprietary Doom data is included.

SDL 3.4.18 uses the Zlib license.
Its exact [source archive](third_party/sdl/SDL3-3.4.18.tar.gz), [license](third_party/sdl/LICENSE.txt), and [origin record](third_party/sdl/source.json) are included.
This source offer includes the library used in the statically linked executable.

This project is independent of id Software and the Freedoom project.
Doom is a trademark of its respective owner.
Asm's platform license does not replace these package licenses.

Report defects at [the Asm issue tracker](https://github.com/stubbi/asm/issues).
Include the game version, map, macOS version, and steps that reproduce the problem.
