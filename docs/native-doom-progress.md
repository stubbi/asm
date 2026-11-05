# Native Doom work record

User direction: complete native Doom-compatible engine written directly in assembly, bundled Freedoom, Apple Silicon macOS, installable through Asm.
Compiler-generated engine assembly was explicitly rejected.
The task was paused and then resumed on 5 November 2026.

Workspace: isolated managed worktree `doom-apple-silicon/asm`, base `452a798e0a62c2a7c0c6c436e15db316fda76959`.
The worktree now includes public main through `7efb4b7b543018d68e5c5801e5f4b7eef74772b5`.
No public game release or catalog record exists at this checkpoint.

## Accepted implementation decisions

- Use handwritten Apple AArch64 game code, SDL platform services, primitive system math, and zlib data expansion.
- Embed the exact compressed Freedoom Phase 1 data and link pinned SDL statically.
- Keep installation inside Asm's existing single-executable contract.
- Keep the independent package's GPL, BSD, and Zlib notices and corresponding source.
- Claim compatibility only within measured scope.

## Completed checks before publication

- `make check` passed against the integrated main source on Apple Silicon macOS 15.6.1.
- The run contained 270 native CLI cases, 18 reference-package cases, 97 registry cases, 78 release cases, and 20 site cases.
- Four reference-package cases and 12 release cases reported their documented host or tool skips.
- The integrated game package passed 119 cases after the notice and pickup/lift corrections.
- Its checkpoint executable SHA-256 is `8640aa2d5bd8ae93962f2431aa3ea284021d71fdff5981a69473904c9b396080`.
- Resource cases cover all 36 bundled maps, every wall texture, malformed data, full COLORMAP bounds, and opaque palette 255.
- Campaign movement cases cover 288 fresh directions and 1,152 forward ticks across all 36 maps.
- World cases cover combat, momentum, running gaps, sector mechanisms, transitions, and saves.
- Fifteen hostile-save cases check malformed movers and file preservation.
- The main-loop cases cover exact 35 Hz timing, overload, menus, and focus recovery.
- Real Asm installation cases cover exact bytes, execution, target/hash/signature rejection, existing files, and symlinks.
- The native window check exercised movement, firing, save/load, fullscreen, menu navigation, and keyboard quit.
- Clean tool environments passed poisoned compiler-variable checks and a fresh native SDL build.
- The independent lifecycle review found pickup reach and lift-retrigger defects; native regressions now pass.

The package's subsystem records retain source and artifact digests for these earlier checks.
These results do not qualify a later release artifact automatically.
Complete campaign traversal, vanilla demos, and arbitrary external WADs remain unqualified.

## Retained defects found during development

- Incorrect REJECT byte-count limit rejected a real campaign map.
- A truncated COLORMAP could expose an out-of-bounds renderer read.
- Borrowed map pointers outlived a resource reset.
- Reserved palette 255 discarded real opaque pixels.
- The renderer's initial camera basis mirrored the scene.
- Initial sky joins, floor orientation, sprite rotations, and material caches were incorrect.
- Initial scheduling used 28 milliseconds instead of an exact 35 Hz timebase.
- Initial map transitions lost inventory and used the wrong secret return routes.
- Initial screenshots exposed partial final files after a failed write.
- Offline start markers became solid actors and blocked two actual map starts.
- Expired missiles exhausted actor slots.
- Gun switches, monster teleports, drops, and several sector mechanisms needed correct game semantics.
- Repeated lift activation lost the original return height.
- Pickups ignored the player's vertical reach.
- Inherited compiler variables could change the selected SDK or compiler behavior.

Regression checks and current source address these findings as implementation progresses.
The final evidence must state any remaining gaps explicitly.

## Outstanding publication gates

- Commit and review the source through the repository pull-request route.
- Build from a clean recorded main commit.
- Validate the exact source and executable artifacts and test real Asm installation.
- Publish immutable game bytes, checksums, corresponding source, target requirements, and known limits.
- Submit the catalog record through the registry pull-request route.
- Verify the deployed catalog, download bytes, and public Asm installation.

Do not mark the project complete while these gates remain open.
