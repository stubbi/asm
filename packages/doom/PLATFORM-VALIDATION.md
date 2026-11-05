# Platform validation

These checks ran on 5 November 2026.
They cover the platform module and its test driver at the hashes below.
This is working-tree evidence, not release qualification.
No release was published by these checks.
The lifecycle results below precede the later build-environment hardening.
The final section records that hardening separately.

The user outcome is native window, input, and audio support without another runtime installation.
The relevant Asm principles are reliable behavior, explicit dependencies, and evidence with clear limits.
SDL supplies platform primitives; handwritten AArch64 assembly supplies input mapping, mixing, parsing, scheduling, and synthesis.

## Environment

| Component | Observed value |
| --- | --- |
| Hardware | Apple M3, arm64 |
| Operating system | macOS 15.6.1, build 24G90 |
| Compiler | Apple Clang 17.0.0, clang-1700.0.13.5 |
| Apple SDK | macOS 15.5 |
| CMake | 4.1.0 |
| Python | 3.14.6 |
| Deployment target | macOS 15.0 |
| SDL | 3.4.18, static arm64 library |

## Commands and results

Run these commands from the repository root:

```sh
python3 packages/doom/tests/test_platform.py
ASM_DOOM_NATIVE_PLATFORM_TEST=1 python3 packages/doom/tests/test_platform.py
```

Both commands passed all three unittest cases.
The native run used Cocoa, CoreAudio, and Metal.
The test-device run used SDL dummy video, dummy audio, and software presentation.
The final native run took 2.584 seconds.
The final test-device run took 1.761 seconds.
These durations are check observations, not performance comparisons.

Both runs built the same test executable bytes:

```text
SHA-256 f680099c939cb69fa2d7b51699e01d752fa7087b3227cf3845c3b8af00bde4c7
```

The driver checked these observable results:

- Initialization, framebuffer presentation, timing, quit, and repeated shutdown succeeded.
- No-init sound, music, mouse capture, and shutdown calls were harmless.
- Injected keyboard events mapped movement, running, weapons, menus, saving, and restoring.
- Injected mouse events mapped turning and firing.
- Focus loss produced an inactive input state and set the pause state.
- Synthetic DS sound and MUS music produced nonzero signed 16-bit stereo samples.
- Standard MIDI format 1 track merging and tempo events produced nonzero samples.
- Bundled E1M1 MIDI produced a PCM absolute-sample sum of 111933236 over 102400 frames.
- Repeated polling during active MIDI returned zero until an explicit quit event.
- Register probes preserved x19–x28, x29, and the lower 64 bits of d8–d15.
- Corrupt, truncated, and missing sound data returned without a crash in the exercised cases.
- A fixed-seed corpus exercised 1024 bounded, hostile MUS scores.
- An unsupported output frame count left the output sentinel unchanged.
- An unavailable video driver returned an initialization failure and a nonempty error.
- An unavailable audio driver permitted muted play and preserved a nonempty error.
- An unsupported build host and corrupt SDL archive were rejected.
- A corrupt replacement archive preserved the existing cached archive.

## Exact inputs

| File | SHA-256 |
| --- | --- |
| `src/platform.s` | `2758f0eca3e9baff679a2547acd3221c2ccbb8394982892247700d7951ce9044` |
| `tests/platform_driver.c` | `cabab0989faab4ef343d94207d5e700e05d11e0844322ef3a33bf9c4b5ab88d0` |
| `tests/platform_abi.s` | `5d58236980316f4e0dfa15f7d545913d9338af109760c960eb3f3b8100c3712d` |
| `tests/test_platform.py` | `06751a153ea754abccfd073c07a71fea603fe6597782a5cb5f2e5c4fdca9b6da` |
| `tools/build_sdl.py` | `e13c77e719a73fa7bd4913ad0187d5c0ffa2e79679bb3f3480624d8dd9ce6647` |
| SDL source archive | `9c75cf16330322c217dedd2e0609f1124f1b54b8633e763467b4684d0f4334a3` |
| Linked `libSDL3.a` | `34b2befe814fadf26cce60e3362280a3c19ed70b71952304165ed8ba87e56df5` |
| Embedded Freedoom data | `cba58ef4ce377700b48b6703547640220d8f061cbd332689659140c1ac66ed44` |

The source offer retains the unmodified 15651004-byte SDL archive and its full license.
The build recipe verifies the archive and extracted source files.
It records the linked library digest, build options, compiler, CMake version, and recipe digest.
It rebuilds a mismatched library cache from fresh objects.
The source record is in `third_party/sdl/source.json`.

## Earlier negative results

The first behavioral test could not compile because `src/platform.s` did not exist.
The first complete link failed because the framework list omitted Carbon.
The framework list was corrected against SDL's generated `sdl3.pc` file.

The first final native test passed normal lifecycle and MIDI checks, then failed its muted-audio branch.
That branch selected dummy video while retaining the Metal renderer.
The harness now selects software presentation for that branch.
The final native and test-device runs passed after this correction.

## Limits

The tests inject input events; they do not establish the quality of physical keyboard or mouse interaction.
They opened native windows and audio streams, but did not include a human listening assessment.
They do not establish full-screen behavior, resize usability, or a visual assessment of display scaling.
The implementation presents the 320×200 framebuffer in a 320×240 logical area with letterboxing.
Interactive game assessment remains a separate integration check.

The synthesizer uses 32 bounded pulse, triangle, saw, or noise voices.
Its timbres do not reproduce a General MIDI sound bank.
It models volume, pitch, sustain, note release, program families, and MIDI tempo.
It does not model expression or spatial controllers.
Pitch bending uses an approximation over a two-semitone range.
MIDI supports format 0 or 1, at most 32 tracks, and division values from 1 through 960.
It clamps tempos above 600 beats per minute.
MUS uses a 140 Hz event clock.
Effects use eight bounded voices and fixed-point source resampling.
The output queue retains at most approximately 86 milliseconds of previously mixed samples.

All 41 bundled music lumps have supported MIDI header bounds.
Only E1M1 received the recorded music-content playback check.
The checks do not establish complete campaign playback or Doom demo compatibility.
Bit-for-bit reproducibility across different hosts, SDKs, or checkout paths was not tested.
Source digests identify bytes; they do not establish publisher identity or general safety.

## Build-environment hardening

These additional checks ran on 5 November 2026 in the environment stated above.
They address earlier failures caused by an inherited `SDKROOT` value.
The user outcome is a build that selects its recorded toolchain without ambient compiler configuration or credentials.

`build_environment(directory)` exports only these values:

```text
PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
LC_ALL=C
LANG=C
HOME=<private stage>/home
TMPDIR=<private stage>/tmp
SDKROOT=<SDK selected by /usr/bin/xcrun under this clean environment>
```

The container, home, and temporary directories must be builder-owned directories with permissions 0700.
Final-component symbolic links and public existing directories are rejected.
The checks preserve existing unrelated directory contents and permissions on failure.
The build helper creates and removes its own private environment when the caller supplies none.
A caller can pass a separately owned stage environment to `build`.
Extra environment variables and a substituted SDK are rejected.

Run the focused checks from the repository root:

```sh
python3 packages/doom/tests/test_build_environment.py
```

All four final tests passed in 0.211 seconds.
The initial three tests failed because the environment API did not yet exist.
The final tests include an actual Clang compile and execution under poisoned ambient variables.
The probe was an arm64 Mach-O executable and printed `native probe` with exit status zero.

The poison included `SDKROOT`, `DEVELOPER_DIR`, `CC`, `CFLAGS`, `CPATH`, `C_INCLUDE_PATH`, `LIBRARY_PATH`, and `CCC_OVERRIDE_OPTIONS`.
It also included `CMAKE_TOOLCHAIN_FILE`, `DYLD_INSERT_LIBRARIES`, a false deployment target, false tool paths, and test-only credential values.
None of those values entered the returned build environment.

A separate fresh SDL build ran under poisoned ambient variables in an isolated temporary directory.
Its configure, compilation, and static-library link succeeded.
The static archive contained arm64 objects.
A linked native test called `SDL_GetVersion()` and confirmed version 3.4.18 with exit status zero.
That test did not initialize video or open a window.
The temporary library SHA-256 was `7947861c3293f168ccf66ecb211710aa7dd45cb88b0692cc8cffcaab466a4976`.
This digest identifies the temporary check artifact, not a release library.

| Input | Recorded value |
| --- | --- |
| `tools/build_sdl.py` SHA-256 | `97dae5ffee71ad79e83fe071bb461e4a820f3acd7af94c07fe78f2ddef824b04` |
| `tests/test_build_environment.py` SHA-256 | `4394c40dc8e9e049743aaa0ed518ba6254b3d07d42eb6596b4b7cab64ee75237` |
| `tests/test_platform.py` SHA-256 | `54a39dbb5d0959550198279e2dbb27ef027271fb2f4da26fbc922bddf10e56be` |
| Selected Clang path | `/Library/Developer/CommandLineTools/usr/bin/clang` |
| Selected Clang SHA-256 | `4c458256bcdf913774de1bb4a37768244d3b41f32ad55afb2dfec3432f46f4fe` |
| Selected CMake path | `/opt/homebrew/Cellar/cmake/4.1.0/bin/cmake` |
| Selected CMake SHA-256 | `7957bf58840c1525964d22c8a99a84e18b93552fb19229f4dea16207992cd281` |
| SDK path | `/Library/Developer/CommandLineTools/SDKs/MacOSX15.5.sdk` |
| SDK version | `15.5` |
| SDKSettings.json SHA-256 | `58a133735f0a55a624a1703067059f6e78925e51725ec6e1f966072e142c9c42` |

Clang and CMake identity checks, configuration, and compilation use the clean environment.
The CMake options include the explicit SDK path and deployment target.
Build metadata records actual tool paths, versions, binary digests, and SDK settings.
The platform test driver's compilation also uses a private build environment.
The SDL source archive and its source offer did not change.
No game implementation moved into a compiled language.

These checks do not qualify the final game executable or its installer.
The complete package gates must run after the final source change.
