# Native Doom Implementation Plan

> **For agentic workers:** Implement independent modules in parallel. Keep engine code handwritten and verify behavior before publication.

**Goal:** Deliver an installable native Apple Silicon game with bundled Freedoom and handwritten assembly engine code.

**Architecture:** Embed compressed data and link SDL statically. Separate resource loading, world simulation, rendering, and platform services behind an explicit assembly ABI.

**Tech Stack:** Apple AArch64 assembly, SDL3, system zlib, Python build and test tools.

**Spec:** `docs/superpowers/specs/2026-11-05-native-doom-design.md`

## Global constraints

- All engine code is handwritten AArch64 assembly.
- Apple Silicon macOS 15 or later is the sole initial target.
- Keep the existing checkout's unrelated changes separate.
- Retain licenses, exact dependency digests, failed checks, and current limitations.
- Never publish an unfinished engine as a complete port.

## Review focus

- Malformed WAD and patch offsets must not escape the input buffer.
- Doors and height changes must affect collision as well as rendering.
- Audio or focus failures must leave a usable quit and recovery path.
- Save failure must preserve existing files.
- Installed bytes and source must identify the same recorded release.

### Task 1: Resource loading and reference data

Files: `packages/doom/src/wad.s`, `textures.s`, assets, dependency manifest, resource tests.

Interfaces: bounded WAD lookup, map record globals, texture descriptors in `packages/doom/ABI.md`.

- [x] Add failing native tests for minimal WAD, missing lumps, corrupt directory, patch posts, and texture composition.
- [x] Implement handwritten resource parsing and decoding.
- [x] Pin and fetch Freedoom data and retain its full notices.
- [x] Run synthetic cases and all bundled map-load cases.

### Task 2: World and game simulation

Files: `packages/doom/src/world.s`, game data tables, world tests.

Interfaces: player/actor state, fixed-tick input, sector lookup, game events, save/load.

- [x] Add failing world tests for spawn, collision, steps, door use, combat, pickups, exits, and saves.
- [x] Implement world and gameplay directly in assembly.
- [x] Test success, malformed state, and file-preservation paths.

### Task 3: Renderer

Files: `packages/doom/src/render.s`, render tests.

Interfaces: immutable map records, dynamic world state, indexed textures, RGBA framebuffer.

- [x] Add failing reference-view tests using synthetic geometry.
- [x] Implement perspective-correct map rendering, planes, sprites, HUD, and menus.
- [x] Inspect representative Freedoom views and bounds behavior.

### Task 4: Native platform and sound

Files: `packages/doom/src/platform.s`, SDL dependency build support, platform tests.

Interfaces: window lifecycle, input structure, 35 Hz timing, PCM audio, framebuffer presentation.

- [x] Add failing checks for initialization, key mapping, headless behavior, audio, and quit.
- [x] Implement SDL calls, input, effects mixing, and music in assembly.
- [x] Build pinned static SDL and inspect native dependencies.

### Task 5: Integration and installation

Files: main assembly, Makefile, package manifest, documentation, acceptance tests, release evidence.

- [x] Add failing command and integration tests.
- [x] Connect the modules, embedded data, menus, and deterministic headless runner.
- [x] Check native gameplay, campaign progression, sound, focus, keyboard use, and saves.
- [x] Review the complete diff and licenses with an independent reviewer.
- [ ] Build the final artifact from a recorded clean commit.
- [ ] Validate source and executable records and test real Asm installation.
- [ ] Publish only after the full game and release gates pass.
