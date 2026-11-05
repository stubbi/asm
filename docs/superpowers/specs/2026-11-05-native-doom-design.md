# Native Doom for Apple Silicon

## Authorized result

Build a native Doom-compatible game with handwritten AArch64 assembly engine code.
Bundle Freedoom Phase 1 game data.
Make the game installable through Asm on Apple Silicon macOS 15 or later.
The user explicitly rejected a compiler-generated assembly engine on 5 November 2026.

The user outcome is an installed game that starts without another data download.
The governing principles are completed tasks, dependable reuse, deliberate execution, and evidence tied to exact bytes.

## Implementation decisions

Use Apple arm64 calling conventions and Clang's assembler.
Keep all game rules, WAD parsing, world simulation, rendering, menus, input mapping, mixing, and save handling in handwritten assembly.
Use SDL3 for window, device input, framebuffer presentation, timing, and audio device output.
SDL is a platform library, not the game engine.
Link a pinned SDL static library into the executable.
Use the system zlib library to expand the embedded, compressed Freedoom data in memory.
Keep upstream licenses and origin records beside the package source.
Do not include proprietary Doom data.

Place the independent package in `packages/doom/`.
Use GPL-2.0-or-later for the Doom-derived engine, BSD-3-Clause for Freedoom data, and SDL's Zlib license.
These notices do not change Asm's platform license.
Build tools and tests can use Python and C test drivers.
No C game implementation or compiler-produced engine assembly is permitted.

## Required behavior

- Load the standard Doom WAD directory and map records with explicit bounds.
- Render actual map walls, height changes, floors, ceilings, textures, and world sprites.
- Preserve the original game coordinate and sector model.
- Support keyboard and mouse movement, turning, fire, use, weapon selection, pause, and quit.
- Implement solid-wall collision, steps, doors, lifts, switches, keys, exits, and sector damage.
- Implement monsters, combat, pickups, weapons, deaths, and restarts.
- Play data-driven sound effects and provide music playback.
- Save and restore game state without overwriting unrelated files on failure.
- Support episode and map selection and progression through bundled maps.
- Provide a deterministic headless mode and framebuffer export for tests.
- Install the complete game as one executable without executing it during installation.

Compatibility is measured behavior, not inferred from the language or a successful build.
Record missing or failed cases honestly.
Do not publish an incomplete implementation as a complete Doom port.
Do not claim demo compatibility until recorded commands and expected game states agree.
Network multiplayer and support for other hosts are outside this initial target.

## Boundaries and evidence

Treat external WADs, map indices, patch posts, and save files as untrusted.
Reject malformed input before replacing the active world.
Use bounded arrays and reject unsupported record counts.
Retain immutable input data; store moving-sector and actor state separately.
Use a 35 Hz fixed simulation step.
Render a 320 by 200 framebuffer and scale it with the correct display aspect ratio.
Pause on focus loss and release mouse capture on escape.

Test synthetic maps and corrupt files before using the bundled campaign.
Exercise all 36 map loads, render representative views, and check visible gameplay on native hardware.
Test save round trips, blocked movement, combat, doors, pickups, exits, unsupported arguments, and existing destinations.
Inspect the final Mach-O architecture, minimum OS, non-executable stack, system dependencies, and code signature.
Run registry validation and a real Asm install using the final artifact digest.
Publication uses the existing reviewed registry route and immutable artifacts.

## Trade-offs

The initial engine is specific to Apple Silicon.
Static SDL and embedded compressed data keep installation within Asm's existing single-executable contract.
This avoids changing general package installation before the game needs such a change.
The complete engine is handwritten; upstream Doom source is reference material only.
An independent game package has its own build because Asm's current project builder handles a narrower source contract.

## Shared implementation contract

`packages/doom/ABI.md` specifies module ownership, functions, globals, and memory layouts.
All agents must follow that contract and request changes before altering shared layouts.
