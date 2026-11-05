# Campaign start movement check

Date: 5 November 2026.
This unpublished acceptance check covers movement from bundled campaign starts.
It does not establish campaign completion or general Doom compatibility.

The player outcome is a start position from which ordinary movement works.
This check follows Asm's principles of completed tasks and evidence with an explicit scope.

## Procedure and result

Run this command from the repository root:

```sh
python3 -m unittest discover -s packages/doom/tests -p test_campaign_movement.py -v
```

Result: one test passed.
The driver uses the actual bundled Freedoom WAD and native world and resource modules.
It initializes every map separately for each of eight headings, separated by 45 degrees.
It changes only the camera angle before each attempt.
It submits four normal input records with `forward=4` to the assembly world tick.

The driver does not directly change collision flags, actor records, player position, health, or inventory.
It checks the fresh starting pose before each attempt.
It checks player and actor floating-point fields and dynamic sector heights after every tick.

All 36 maps passed at skill 3.
The check made 288 fresh attempts and ran 1,152 forward ticks.
Every map changed player position in at least one heading.
E1M4 and E3M7 each permitted movement in all eight headings.
E2M9 permitted movement in seven headings; the required result is at least one.
No tested state contained a non-finite floating-point value.

The maximum displacement in each map was approximately 16 world units after four ticks.
This observation is a movement result, not a performance measurement.

## Negative control

A separate test-driver copy changed `forward=4` to `forward=0`.
The engine source remained unchanged.
The negative control returned exit code 1 and reported all 36 maps as stationary.
Each report contained `moved=0/8` and `max_distance=0.000000`.
This confirms that successful initialization alone cannot satisfy the displacement assertion.

A retained earlier world snapshot also passed this gate.
It therefore provides no evidence of the earlier marker defect's failure before its fix.
The current passing result must not be described as a reproduced failure of that historical defect.

## Environment and exact artifacts

Host: Apple M3, arm64, macOS 15.6.1, build 24G90.
Toolchain: Apple Clang 17.0.0, `clang-1700.0.13.5`.
Options: `-arch arm64 -O2 -mmacosx-version-min=15.0 -Wall -Wextra -Werror`.

The local directory `/tmp/asm-doom-campaign-movement.EVmMrB/` retains both native drivers and their source snapshots.
These test executables are not release artifacts.

| Artifact | SHA-256 |
| --- | --- |
| `tests/campaign_movement.c` | `60f30747543c35d2bd41dfee34164449938324f93863dd234346931047a53b3e` |
| `tests/test_campaign_movement.py` | `8d6c924bebe7200208ef862b407787edddcdc3e486e5615f8a439e58b7567274` |
| Native positive driver | `df41662c4f1aad4f1c4eeab051c3f6fd038e0392f5304efc151b0549f1707cb2` |
| Native zero-input driver | `b336d830e39d6110d9d61615e6f2a8001b238831aab776197b7319b9b6ab34d5` |
| World source snapshot | `ecbde35066a42045cc58307e3331af2452e75284fd5ff5489652b7976e5af6b0` |
| WAD source snapshot | `a501824e02092c9c58df9c6dc30712b02659befb9ee4576fe1f1f93f625636b7` |
| Texture source snapshot | `5b3b8307a40abde8ed921c52b65fd042708229a4c55cf139caabaa1889e9c617` |
| Bundled compressed WAD | `cba58ef4ce377700b48b6703547640220d8f061cbd332689659140c1ac66ed44` |

## Limits

Four forward ticks test initial movement over a short distance.
They do not test exits, keys, doors, complete routes, long encounters, or all collision boundaries.
Selecting initial camera headings does not test native keyboard or mouse turning.
Other checks must cover those behaviors.
