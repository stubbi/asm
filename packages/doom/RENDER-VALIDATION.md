# Native renderer validation

Date: 5 November 2026.
This record covers the unpublished handwritten renderer, not a qualified Doom release.

## Outcome and implementation

The renderer serves a player who needs visible map geometry and understandable game state.
The governing Asm principles are completed tasks, dependable interfaces, and claims supported by evidence.

`src/render.s` implements a column portal walk through original Doom linedefs and sectors.
It uses dynamic sector heights, perspective wall and flat sampling, episode skies, and masked world patches.
It draws weapon frames, status graphics, numbers, keys, damage feedback, and a readable menu with controls.
Actor views include eight rotations and paired-patch mirroring.
Material accessors expose switches, changed floor flats, and scrolling walls on the next rendered frame.

All renderer instructions were written by hand.
The renderer calls the resource and world interfaces in `ABI.md`.
System `sinf`, `cosf`, and `atan2f` provide primitive mathematical operations.
The renderer does not call SDL or use a C game backend.

The renderer reserves approximately 6.4 MiB of bounded static buffers.
This avoids allocation failures during frame drawing, at the cost of a fixed memory reservation.
Material queries run once per used sidedef or sector in each frame, rather than once per pixel.

## Native checks

Host: Apple M3, arm64, macOS 15.6.1, build 24G90.
Toolchain: Apple Clang 17.0.0, `clang-1700.0.13.5`.
Build options include `-arch arm64 -O2 -mmacosx-version-min=15.0`.

Run this command from the repository root:

```sh
python3 -m unittest discover -s packages/doom/tests -p test_render.py -v
```

Final result: both test cases passed.
The campaign case initializes and renders all 36 bundled Freedoom maps through the native world and resource modules.
It checks framebuffer guards, opaque output, and visible pixel variation for each starting view.

The synthetic case checks these observable results:

- Distinct wall, floor, and ceiling materials.
- Correct north-left orientation when the player looks east.
- Negative world-Y orientation for Doom flats.
- An open sector portal and a raised floor's lower wall.
- Changed dynamic heights and material names without rebuilding geometry.
- Updated horizontal scrolling offsets.
- Adjacent sky ceilings without a false upper wall.
- Lower-unpegged masked walls and visible geometry through their holes.
- Sprite transparency, wall occlusion, view rotations, and paired-patch mirroring.
- Explicit alpha that preserves opaque palette index 255 in walls, world sprites, and UI patches.
- Equipped and firing weapon frames, damage feedback, menu selection, and visible controls.
- Bounded fallback for invalid texture dimensions and an empty world.
- Preserved `x19`–`x28`, frame pointer, stack pointer, and the low 64 bits of `v8`–`v15`.

The ABI test calls both rendering exports with sentinel register values.
The frame tests check all 64,000 output pixels for opacity in their tested cases.
These tests do not establish memory safety for every possible input.
Map records must first pass the resource module's validation.

## Retained failures and corrections

The first native check failed because the absent renderer did not draw the center wall.
Later regressions exposed incorrect sprite projection, sky joins, flat orientation, firing frames, rotations, and cached material changes.
The final checks include each corrected behavior.

An early visual review recognized the campaign room but missed a horizontally mirrored camera basis.
An asymmetric sprite test then failed.
The corrected basis now passes separate sprite and wall-orientation checks.

A masked-wall test exposed an incorrect lower-unpegged texture anchor.
The corrected anchor and transparency checks pass.

The initial descriptor contract reserved palette index 255 for transparency.
A raw-data inspection found 34 opaque index-255 pixels among 1,900 candidate bundled wall and sprite patches.
An explicit alpha channel now preserves those colors.
The opaque-index-255 regression failed before this change and passes for wall, sprite, and UI paths.

An incorrect stack write during alpha integration caused a native fixture fault.
The write was moved into the UI routine's own stack frame.
The final guard and ABI checks pass with explicit alpha enabled.

Campaign compilation temporarily failed during concurrent world-module changes.
The errors included unsupported instruction operands and unfinished local labels.
The final campaign driver compiled and completed all 36 map checks after those changes were corrected.

## Visual inspection and exact artifacts

The final native campaign driver exported starting views for E1M1, E1M8, E2M1, E3M1, and E4M1.
E1M1, its controls menu, and E3M1 were visually inspected after the final geometry fixes.
The inspected frames show textured sectors, perspective surfaces, world details, the weapon overlay, and status graphics.
E3M1 shows the episode's red sky.

The retained local artifacts are in `/tmp/asm-doom-render-validation.YuH8UE/`.
They are test drivers and framebuffer exports, not release artifacts.
PNG previews were converted from PPM output without changing the renderer's pixels.
The `sources/` directory retains the exact source snapshots used to build the recorded native drivers.

| Artifact | SHA-256 |
| --- | --- |
| `src/render.s` | `f7a3b6ad633a57ea049ab8779f99a96eea4d1a2fb779a4a64c0a30fdbb84b1eb` |
| Synthetic native driver | `392426c5546500080261ba1afea290a990d9c70107867a12a0dc4139fb68c6da` |
| Campaign native driver | `77745411aa98456edc10b8326002cb370f1702d7bfc1e30b076724b5879c053f` |
| Bundled `freedoom1.wad.zlib` | `cba58ef4ce377700b48b6703547640220d8f061cbd332689659140c1ac66ed44` |
| `doom-E1M1.ppm` | `80c86440a1dd32829b9835efd663f86da93d72b272141920dce18a05f4d2e510` |
| `doom-E1M1-menu.ppm` | `597f5e2ef027cce0d3be22ecbe3bba34aa7e2b3c5ea7222a277f2fda86d999fd` |

The campaign driver used these supporting source digests:

| Source | SHA-256 |
| --- | --- |
| `src/world.s` | `f70b355eac4f7e06ca8f91ffa4c09434fe98062fd1df485339e504514b563165` |
| `src/wad.s` | `a501824e02092c9c58df9c6dc30712b02659befb9ee4576fe1f1f93f625636b7` |
| `src/textures.s` | `5b3b8307a40abde8ed921c52b65fd042708229a4c55cf139caabaa1889e9c617` |

These source files were unpublished changes above base commit `452a798e0a62c2a7c0c6c436e15db316fda76959`.
Further source changes require new evidence for their resulting artifacts.

## Scope and remaining limits

The campaign check covers starting views, not every location, orientation, encounter, or complete campaign playthrough.
Synthetic tests cover selected moving-sector and material states.
They do not establish demo compatibility or pixel-exact agreement with vanilla Doom.

Projection and lighting use floating-point calculations and a bounded distance-light approximation.
Weapon and status animations reproduce a subset of vanilla presentation states.
Animated flat and texture sequences require world-supplied material names.

Legacy fixtures can omit the alpha pointer and use palette index 255 for transparency.
Real resource descriptors supply explicit alpha and retain all 256 palette colors.

The renderer has no public release, performance qualification, or deterministic release-gate result in this record.
Gameplay, audio, save handling, application scheduling, packaging, and native-window input require their own checks.

## Reference behavior

Flat orientation and fullbright sky behavior were checked against id Software's `linuxdoom-1.10/r_plane.c` on 5 November 2026.
The primary source is [id Software's Doom repository](https://github.com/id-Software/DOOM/blob/master/linuxdoom-1.10/r_plane.c).
This reference does not imply pixel-exact compatibility.
