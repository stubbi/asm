# World validation record

Observed on 5 November 2026 on Apple Silicon macOS 15.6.1.
The assembler was Apple Clang 17.0.0, build `clang-1700.0.13.5`.
The target requires macOS 15 or later.

The user outcome is an installed game that can advance, fight, and preserve progress.
Asm's relevant principles are completed tasks, dependable reuse, and evidence with explicit limits.

## Scope and evidence

`world.s` contains handwritten engine instructions.
`monster-data.inc` contains extracted state data, without generated instructions.
The native C drivers contain fixtures and assertions, without a game implementation.

The state data uses Chocolate Doom commit `a2dfd51fcc00d272dc8a17a97ccd6683333ff4ea`.
`monster-data-reference.json` records source digests, action mappings, and transition indices.
The tables contain 11 actor definitions and 107 attack or death states.

The current world source SHA-256 is `0d2dcc2e846f0477e19d42c15fb4ee1f02ed22a535a62bb1f32fc7334171fae9`.
The state data SHA-256 is `11cc5a4537fafb2b73dd602be461d8833945d5ea32195704853e18156b2de212`.
The package build records the executable digest and each compiled source digest separately.

Run the documented package checks:

```sh
make -C packages/doom test
```

A historical native package checkpoint passed 109 tests.
That checkpoint used world source `227aa602ecef1e934a9c72b844c6f5a1adf16d3e52914ece84e010eb649926ab`.
Its executable SHA-256 was `953c0692f27f493eee552a5a0b9687f39c192edda4700f4edb0d07169b37baed`.
It predates the pickup-reach and active-mover fixes below.
It also predates the runtime license command and alpha version output.

Current focused checks pass 57 world cases, 15 hostile-save cases, and the 36-map campaign driver.
Twelve command-line cases pass, including embedded notices before engine initialization.
The integrated `make doom-test` run passed 119 tests after these corrections.
Its executable SHA-256 was `8640aa2d5bd8ae93962f2431aa3ea284021d71fdff5981a69473904c9b396080`.
Its build evidence records the current world and state data digests.
This is an integration checkpoint, not the clean-commit release build.

The world tests cover 57 synthetic cases.
They exercise player spawning, wall and actor collision, steps, strafing, pickups, weapons, doors, and exits.
They also exercise stair chains, donut movement, lifts, crushers, switch materials, lighting, teleports, and inventory transitions.

Monster cases cover distinct Cyberdemon, Cacodemon, Baron, shotgunner, and Lost Soul attacks.
They check weapon windup, portal-height autoaim, blocked melee, barrel explosions, BFG spray, and delayed boss exits.

The campaign driver loads all 36 bundled maps.
It checks the player sector and spawn height.
It then runs 15 simulation ticks per map.
It also checks cross-map save restoration against complete player and actor bytes.
This check does not establish complete campaign traversal.

The save suite includes 15 independent hostile-file cases.
It checks finite mover speeds, destinations, typed auxiliary fields, and file preservation.
The world suite also rejects an out-of-range saved actor-state index before replacement.

`world-coverage.json` records all 79 line-special IDs used by the bundled WAD.
Those IDs occur on 2,929 lines.
The record distinguishes dispatch coverage from behavior qualification.

## Retained negative results

The initial native ABI shell failed the six initial behavior cases.
Subsequent red tests exposed missing stairs, donut movement, lift timing, and crusher behavior.
New red cases also rejected direct displacement without acceleration or coasting.
The momentum cases check a 128-unit gap, air momentum, stopping, and exact save continuation.
Other red tests exposed gun-trigger misuse, player use of monster-only teleports, and missing monster teleport traversal.

A native pickup fixture initially included a live attacking monster.
That fixture mixed health pickup and combat behavior.
The corrected fixture isolates the pickup.

The independent save review reproduced accepted NaN crusher speeds and negative mover speeds.
All 11 malformed mover cases now reject the file before changing the world.
The four existing file-preservation cases also pass.

The strafe regression first reproduced east-facing right input moving north.
The corrected basis moves south when facing east.
It moves east when facing north.

The new state-index case first accepted a saved attack index outside its table.
The parser now rejects that file before changing the world.
The interpreter also checks an index before each table access.

The projectile capacity case fires 5,000 shots with forced short projectile lifetimes.
It retains at most two actor slots.
A separate temporary build disabled slot reuse.
That build failed the actor-count assertion.

Source data corrected two timing assumptions during development.
The Cyberdemon attack sequence lasts 66 ticks.
Its final death action follows 110 ticks of death states.
The barrel explosion action follows 15 ticks of death states.
Tests use those source transitions.

A material-accessor regression supplied nonzero upper register bits with a valid 32-bit index.
The accessor now extends its declared 32-bit input before pointer arithmetic.
A lighting regression also prevented a light-off action from increasing the current light.

Review added two confirmed gameplay findings.
A pickup above the player or more than eight units below could be collected.
The corrected reach retains the original inclusive range from minus eight through the player's height.
Four cases check both rejection ranges and the inclusive boundaries.

Reusing an active lift could overwrite its original return height.
Repeated use while lowering and while waiting now preserves that height.
The active-mover guard runs before speed, wait, or destination changes.
Manual door reversal has its separate policy.
Its regression also preserves the original closing wait.

Source review confirmed that vanilla Lost Soul contact precedes missile height checks.
The proposed Lost Soul height change was not applied.
That original contact ordering remains an explicit behavior choice.

## Save contract and trade-offs

Save version 2 includes moving planes, actor states, materials, lights, switches, powers, and weapon windup.
It also includes horizontal momentum and the player contact floor.
A fingerprint connects the save to the ten raw map lumps.
FNV detects corruption; it does not authenticate a file.

New saves use a private temporary file, file synchronization, and atomic publication.
Replacement requires a valid owned save and a repeated identity check.
Symlinks, nonregular destinations, hard-linked replacement files, and unrelated files are refused.
The final identity check and rename do not provide protection from same-user path races.
The application's default save directory restricts access to its owner.

## Compatibility limits

This evidence does not qualify vanilla demo compatibility.
The simulation uses floating-point geometry and an independent random sequence.
Player acceleration, floor friction, stop speed, and maximum momentum use the original units.
The implementation stores momentum as floating-point values rather than original fixed-point values.
Monster pursuit uses a direction and slide heuristic instead of vanilla eight-direction chase selection.

Monster infighting, Nightmare respawn behavior, and complete DeHackEd interpretation remain outside these qualified cases.
The bundled DeHackEd fullbright changes are not interpreted by the world module.
Monster sound selection and several visual effects do not reproduce every original state action.

The Doom II actor definitions do not have qualified state tables.
The bundled qualification target is Freedoom Phase 1 at the default skill.
A complete campaign playthrough and original-demo comparison remain unmeasured.
Do not describe these checks as full Doom conformance.
