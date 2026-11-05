# Licensing

Asm is shared infrastructure for assembly software.
Changes to that infrastructure should remain available to its users.
We use copyleft to support that goal, including when a modified version runs as a network service.

This choice follows the reciprocal openness argument in [Vitalik Buterin's July 2025 essay][copyleft].
The license text defines the obligations.
This guide explains the scope within this repository.

## Scope

Copyright (c) 2026 ASM contributors.

Unless a file has a separate notice, Asm is licensed under **AGPL-3.0-or-later**.
You can use version 3 of the GNU Affero General Public License, or any later version published by the Free Software Foundation.
The unmodified version 3 text is in [LICENSE](LICENSE).
Asm is provided without warranty, as that license states.

| Material | License |
| --- | --- |
| Asm CLI, registry tools, website, tests, and project documentation | AGPL-3.0-or-later |
| `cli/templates.s`, `cli/aarch64/templates.s`, `cli/windows/x86_64/templates.s`, and their emitted starter text | MIT |
| Each package under `examples/` | Its included MIT license |
| Independently published packages | The license declared by that package version |
| Earlier published versions | The license included with that version |

The starter assembly files include the complete MIT notice.
The retained MIT text is also in [LICENSES/MIT.txt](LICENSES/MIT.txt).
This notice covers the identified MIT material and preserves the notice for material originally distributed in Asm 0.1.0.

## Use Asm

Running Asm to build or install a separate program does not assign Asm's license to that program.
The [AGPL's output rule][agpl] applies when output itself contains covered material.
Asm's generated starter text has the separate MIT grant stated above.
Copied or linked package code has its own license conditions.

Commercial use and paid services are permitted under the license.
When distributing a covered binary, provide the corresponding source as the AGPL requires.
Section 13 also requires a source offer to remote users of a modified version that supports network interaction.
An independent program does not become part of Asm merely because Asm manages its package record.
See [sections 2, 5, 6, and 13 of the license][agpl].

Asm publishes source archives beside its release binaries.
The website links to its source.
`asm license` shows the applicable identifier, source location, and warranty notice.

## Contribute

Contributions use the license that applies to the affected material.
New platform code uses AGPL-3.0-or-later unless an explicit, reviewed exception applies.
Do not add a different license to existing third-party material.
Keep required copyright and permission notices.
State the origin and license of any material that you import.

Package authors select a supported open-source license and must have the rights needed to publish their artifacts.
A registry declaration or automated check does not establish those rights.
Each version retains its own license record.

## Earlier release

Asm 0.1.0 was published under MIT before this policy was selected.
Asm 0.2.0 introduces the copyleft policy for the platform.
The earlier source, artifacts, and license record remain historical facts.
Changing the current repository license does not relabel an earlier release.

[copyleft]: https://vitalik.eth.limo/general/2025/07/07/copyleft.html
[agpl]: https://opensource.org/license/agpl-3-0
