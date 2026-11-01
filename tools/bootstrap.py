#!/usr/bin/env python3
"""Render the fixed ASM installer from a validated, canonical release record.

SPDX-License-Identifier: AGPL-3.0-or-later
"""

from __future__ import annotations

from collections.abc import Callable
from html import escape
from pathlib import Path
import re

import registry


REPOSITORY = "https://github.com/stubbi/asm"
REPOSITORY_ID = 1441332955
TARGET = "x86_64-linux"
MINIMUM_VERSION = (0, 2, 0)
MAX_BUNDLE_BYTES = 1024 * 1024
TEMPLATE = Path(__file__).with_name("install.sh.in")
START = "<!-- ASM_BOOTSTRAP_START -->"
END = "<!-- ASM_BOOTSTRAP_END -->"


def installer_release(records: list[dict], checked: set[tuple[str, str]]) -> dict | None:
    """Select the latest active compatible release; require its artifact checks."""
    candidates = [record for record in registry.check_records(records)
                  if record["name"] == "stubbi/asm" and not record["yanked"]]
    if not candidates:
        return None
    record = max(candidates, key=lambda item: tuple(int(part) for part in item["version"].split(".")))
    # Earlier releases have neither the named bundle nor `asm self update`.
    # Do not advertise an installation path that cannot fulfill its contract.
    if registry.version_tuple(record["version"]) < MINIMUM_VERSION:
        return None
    if (record["name"], record["version"]) not in checked:
        return None
    version = record["version"]
    registry.version_tuple(version)
    source = record["source"]
    registry.require(source["repository"] == REPOSITORY and source["path"] == ".",
                     "installer source must be the canonical ASM repository root")
    registry.require(re.fullmatch(r"[0-9a-f]{40}", source["commit"]) is not None,
                     "installer source needs a full Git commit")
    artifacts = [artifact for artifact in record["artifacts"]
                 if artifact["kind"] == "executable" and artifact["target"] == TARGET]
    registry.require(len(artifacts) == 1, "installer needs exactly one Linux x86_64 executable")
    artifact = artifacts[0]
    base = f"{REPOSITORY}/releases/download/v{version}"
    registry.require(artifact["url"] == f"{base}/asm-{version}-{TARGET}",
                     "installer executable URL must use the canonical release asset")
    registry.require(type(artifact["bytes"]) is int and 0 < artifact["bytes"] <= registry.MAX_ARTIFACT_BYTES,
                     "installer executable size is invalid")
    registry.require(re.fullmatch(r"[0-9a-f]{64}", artifact["sha256"]) is not None,
                     "installer needs a full lowercase SHA-256 digest")
    return {"version": version, "sha256": artifact["sha256"], "bytes": artifact["bytes"],
            "source_commit": source["commit"], "repository_id": REPOSITORY_ID,
            "artifact_url": artifact["url"], "bundle_url": f"{base}/release-attestation.sigstore.json"}


def render_installer(release: dict) -> bytes:
    """Only installer_release output is accepted; validate again before shell interpolation."""
    version = release.get("version")
    registry.require(registry.version_tuple(version) >= MINIMUM_VERSION,
                     "installer release predates signed bootstrap support")
    base = f"{REPOSITORY}/releases/download/v{version}"
    registry.require(release.get("artifact_url") == f"{base}/asm-{version}-{TARGET}" and
                     release.get("bundle_url") == f"{base}/release-attestation.sigstore.json",
                     "invalid installer asset URLs")
    registry.require(release.get("repository_id") == REPOSITORY_ID, "invalid installer repository identity")
    for key, length in (("sha256", 64), ("source_commit", 40)):
        registry.require(isinstance(release.get(key), str) and re.fullmatch(rf"[0-9a-f]{{{length}}}", release[key]) is not None,
                         f"invalid installer {key}")
    registry.require(release["source_commit"] != "0" * 40, "invalid installer source commit")
    registry.require(type(release.get("bytes")) is int and 0 < release["bytes"] <= registry.MAX_ARTIFACT_BYTES,
                     "invalid installer byte size")
    script = TEMPLATE.read_text(encoding="utf-8")
    for key in ("version", "sha256", "bytes", "source_commit", "artifact_url", "bundle_url"):
        script = script.replace(f"@@{key.upper()}@@", str(release[key]))
    registry.require("@@" not in script, "unexpanded installer template field")
    return script.encode("utf-8")


def installer_markup(release: dict) -> str:
    # Values have passed render_installer's strict validation before this runs.
    version = escape(release["version"])
    commands = "curl -qfsSL --proto '=https' --tlsv1.2 -m 120 https://asm.build/install.sh | sh"
    download_commands = '''asm_installer=$(mktemp) &&
curl -qfsSL --proto '=https' --tlsv1.2 -m 120 https://asm.build/install.sh -o "$asm_installer" &&
cat "$asm_installer"'''
    ci_commands = '''(
  installer=$(mktemp) || exit
  trap 'rm -f "$installer"' 0
  curl -q --proto '=https' --tlsv1.2 -fsSL --max-time 120 https://asm.build/install.sh -o "$installer" || exit
  sh "$installer"
)'''
    return f'''<div class="bootstrap-panel">
<p class="section-footnote">Requires Linux x86_64. The installer uses curl and GNU Coreutils in /usr/bin. Install <a href="https://cli.github.com/">GitHub CLI 2.93.0 or later</a> at /usr/bin/gh before you start.</p>
<div class="terminal">
<div class="terminal-header"><div class="terminal-label">INSTALL ASM {version}</div><button class="copy-button" type="button" data-copy="bootstrap-commands" aria-label="Copy ASM installation command">Copy</button></div>
<pre><code id="bootstrap-commands">{escape(commands)}</code></pre>
<div class="terminal-footer"><span>Linux x86_64</span><a href="install.sh">Read the installer ↗</a></div>
</div>
<p class="section-footnote">The ASM installer does not use sudo or a GitHub login. It checks the exact file and its signed release attestation. It installs to $HOME/.local/bin/asm and preserves a different existing asm file.</p>
<p class="section-footnote">Apply the PATH command shown by the installer. Then run <code>asm version</code>. For later updates, run <code>asm self update</code>.</p>
<details class="source-fallback">
<summary>Set PATH for this terminal</summary>
<p>Put the installation directory first in PATH for this terminal:</p>
<div class="terminal"><pre><code>export PATH="$HOME/.local/bin:$PATH"</code></pre></div>
<p>Add the same command to your shell configuration to keep this setting. Run <code>asm version</code> again.</p>
</details>
<details class="source-fallback">
<summary>Inspect the installer first</summary>
<p>Download the script to a temporary file:</p>
<div class="terminal">
<div class="terminal-header"><div class="terminal-label">DOWNLOAD FOR REVIEW</div><button class="copy-button" type="button" data-copy="bootstrap-download-commands" aria-label="Copy installer download commands">Copy</button></div>
<pre><code id="bootstrap-download-commands">{escape(download_commands)}</code></pre>
</div>
<p>If the download succeeds, review the displayed script. After your review, run this separate command in the same terminal:</p>
<div class="terminal"><pre><code>sh "$asm_installer"</code></pre></div>
<p>Remove the temporary file after installation:</p>
<div class="terminal"><pre><code>rm -f "$asm_installer"
unset asm_installer</code></pre></div>
</details>
<details class="source-fallback">
<summary>Use in scripts and CI</summary>
<p>For scripts and CI, use the complete-download commands below. The script runs only if the download succeeds.</p>
<div class="terminal">
<div class="terminal-header"><div class="terminal-label">INSTALL FROM FILE</div><button class="copy-button" type="button" data-copy="bootstrap-ci-commands" aria-label="Copy installation commands for scripts and CI">Copy</button></div>
<pre><code id="bootstrap-ci-commands">{escape(ci_commands)}</code></pre>
</div>
<p>Running it again accepts only the same release bytes with the required ownership and permissions. The installer does not change PATH or run the downloaded command.</p>
</details>
</div>'''


def write_bootstrap(stage: Path, records: list[dict], checked: set[tuple[str, str]], *,
                    bundle_reader: Callable[[str, int], bytes] | None = None) -> dict | None:
    # Only this generator can publish an installer. A copied, stale file is not
    # evidence that this build checked the current CLI artifact.
    (stage / "install.sh").unlink(missing_ok=True)
    release = installer_release(records, checked)
    page = stage / "index.html"
    content = page.read_text(encoding="utf-8")
    registry.require(content.count(START) == 1 and content.count(END) == 1,
                     "site needs exactly one bootstrap insertion point")
    before, rest = content.split(START, 1)
    original, after = rest.split(END, 1)
    if release is not None:
        registry.require(bundle_reader is not None, "installer needs a checked release bundle")
        bundle = bundle_reader(release["bundle_url"], MAX_BUNDLE_BYTES)
        registry.require(type(bundle) is bytes and 0 < len(bundle) <= MAX_BUNDLE_BYTES,
                         "installer release bundle exceeds the size limit or is empty")
        value = registry.strict_json(bundle)
        registry.require(isinstance(value, dict) and isinstance(value.get("dsseEnvelope"), dict),
                         "installer release bundle must be one Sigstore JSON object")
        # This is an availability and format check. The installer verifies the
        # signature, exact artifact, and identity with the independent verifier.
        registry.write_atomic(stage / "install.sh", render_installer(release))
        body = installer_markup(release)
        after = after.replace('<details class="source-fallback" open>', '<details class="source-fallback">', 1)
    else:
        body = original
    page.write_text(before + START + "\n" + body.strip() + "\n" + END + after, encoding="utf-8")
    return release
