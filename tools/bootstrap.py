#!/usr/bin/env python3
"""Render the fixed Asm installer from a validated, canonical release record.

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
TARGETS = {
    "x86_64-linux": ("Linux:x86_64|Linux:amd64", "Linux x86_64"),
    "aarch64-linux": ("Linux:aarch64|Linux:arm64", "Linux ARM64"),
    "aarch64-macos": ("Darwin:arm64", "macOS 15 or later on ARM64"),
}
INSTALL_COMMAND = "curl -qfsS -m120 https://asm.build/install.sh | sh"
MINIMUM_VERSION = (0, 2, 0)
MAX_BUNDLE_BYTES = 1024 * 1024
TEMPLATE = Path(__file__).with_name("install.sh.in")
START = "<!-- ASM_BOOTSTRAP_START -->"
END = "<!-- ASM_BOOTSTRAP_END -->"


def insertion_point(content: str) -> tuple[str, str, str] | None:
    """Accept no installer UI, or one ordered pair of optional markers."""
    counts = (content.count(START), content.count(END))
    if counts == (0, 0):
        return None
    registry.require(counts == (1, 1) and content.index(START) < content.index(END),
                     "site needs no bootstrap markers or one ordered insertion point")
    before, rest = content.split(START, 1)
    original, after = rest.split(END, 1)
    return before, original, after


def installer_release(records: list[dict], checked: set[tuple[str, str]]) -> dict | None:
    """Select the latest POSIX-installer release; require its artifact checks.

    Catalog targets outside this installer profile remain in package records.
    They cannot add a shell-install route or suppress an older compatible one.
    """
    candidates = [record for record in registry.check_records(records)
                  if record["name"] == "stubbi/asm" and not record["yanked"]
                  and any(artifact["kind"] == "executable" and artifact["target"] in TARGETS
                          for artifact in record["artifacts"])]
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
                     "installer source must be the canonical Asm repository root")
    registry.require(re.fullmatch(r"[0-9a-f]{40}", source["commit"]) is not None,
                     "installer source needs a full Git commit")
    artifacts = [{key: artifact[key] for key in ("target", "sha256", "bytes", "url")}
                 for artifact in record["artifacts"]
                 if artifact["kind"] == "executable" and artifact["target"] in TARGETS]
    release = {"version": version, "artifacts": sorted(artifacts, key=lambda item: item["target"]),
               "source_commit": source["commit"], "repository_id": REPOSITORY_ID,
               "bundle_url": f"{REPOSITORY}/releases/download/v{version}/release-attestation.sigstore.json"}
    validate_release(release)
    return release


def validate_release(release: dict) -> None:
    """Check every field used in the shell, including each architecture's identity."""
    registry.require(set(release) == {"version", "artifacts", "source_commit", "repository_id", "bundle_url"},
                     "invalid installer release fields")
    version = release.get("version")
    registry.require(registry.version_tuple(version) >= MINIMUM_VERSION,
                     "installer release predates signed bootstrap support")
    base = f"{REPOSITORY}/releases/download/v{version}"
    registry.require(release.get("bundle_url") == f"{base}/release-attestation.sigstore.json",
                     "invalid installer bundle URL")
    registry.require(release.get("repository_id") == REPOSITORY_ID, "invalid installer repository identity")
    registry.require(isinstance(release.get("source_commit"), str) and
                     re.fullmatch(r"[0-9a-f]{40}", release["source_commit"]) is not None,
                     "invalid installer source commit")
    registry.require(release["source_commit"] != "0" * 40, "invalid installer source commit")
    artifacts = release.get("artifacts")
    registry.require(isinstance(artifacts, list) and 0 < len(artifacts) <= len(TARGETS),
                     "installer needs supported executable artifacts")
    seen = set()
    for artifact in artifacts:
        registry.require(isinstance(artifact, dict) and set(artifact) == {"target", "sha256", "bytes", "url"},
                         "invalid installer artifact fields")
        target = artifact["target"]
        registry.require(isinstance(target, str) and target in TARGETS and target not in seen,
                         "unsupported or duplicate installer target")
        seen.add(target)
        registry.require(artifact["url"] == f"{base}/asm-{version}-{target}",
                         "installer executable URL must use its canonical target asset")
        registry.require(type(artifact["bytes"]) is int and 0 < artifact["bytes"] <= registry.MAX_ARTIFACT_BYTES,
                         "invalid installer byte size")
        registry.require(isinstance(artifact["sha256"], str) and
                         re.fullmatch(r"[0-9a-f]{64}", artifact["sha256"]) is not None,
                         "invalid installer digest")


def render_installer(release: dict) -> bytes:
    """Bind each checked artifact to its local operating system and ISA."""
    validate_release(release)
    cases = []
    for artifact in release["artifacts"]:
        target = artifact["target"]
        cases.append(f"        {TARGETS[target][0]})\n"
                     f"            asm_target='{target}'\n"
                     f"            asm_sha256='{artifact['sha256']}'\n"
                     f"            asm_bytes='{artifact['bytes']}'\n"
                     f"            asm_url='{artifact['url']}'\n"
                     "            ;;")
    script = TEMPLATE.read_text(encoding="utf-8")
    for key in ("version", "source_commit", "bundle_url"):
        script = script.replace(f"@@{key.upper()}@@", str(release[key]))
    script = script.replace("@@TARGET_CASES@@", "\n".join(cases))
    registry.require("@@" not in script, "unexpanded installer template field")
    return script.encode("utf-8")


def installer_markup(release: dict) -> str:
    validate_release(release)
    version = escape(release["version"])
    hosts = " and ".join(TARGETS[artifact["target"]][1] for artifact in release["artifacts"])
    targets = {artifact["target"] for artifact in release["artifacts"]}
    requirements = []
    if targets & {"x86_64-linux", "aarch64-linux"}:
        requirements.append("On Linux, it uses curl and GNU Coreutils in /usr/bin. "
                            "Install GitHub CLI at /usr/bin/gh.")
    if "aarch64-macos" in targets:
        requirements.append("On macOS, it uses system tools, including Perl and /usr/bin/shasum. "
                            "Install GitHub CLI at /opt/homebrew/bin/gh. "
                            "The installation requires a local APFS volume with ownership enabled.")
    tools = " ".join(requirements)
    commands = INSTALL_COMMAND
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
<p class="section-footnote">The installer supports {hosts}. It selects the matching build on your machine. {tools} Use <a href="https://cli.github.com/">GitHub CLI 2.93.0 or later</a> before you start.</p>
<div class="terminal">
<div class="terminal-header"><div class="terminal-label">INSTALL Asm {version}</div><button class="copy-button" type="button" data-copy="bootstrap-commands" aria-label="Copy Asm installation command">Copy</button></div>
<pre tabindex="0"><code id="bootstrap-commands">{escape(commands)}</code></pre>
<div class="terminal-footer"><span>{hosts}</span><a href="install.sh">Read the installer ↗</a></div>
</div>
<p class="section-footnote">The Asm installer does not use sudo or a GitHub login. It checks the exact file and its signed release attestation. It installs to $HOME/.local/bin/asm and preserves a different existing asm file.</p>
<p class="section-footnote">Apply the PATH command shown by the installer. Then run <code>asm version</code>. For later updates, run <code>asm self update</code>.</p>
<details class="source-fallback">
<summary>Set PATH for this terminal</summary>
<p>Put the installation directory first in PATH for this terminal:</p>
<div class="terminal"><pre tabindex="0"><code>export PATH="$HOME/.local/bin:$PATH"</code></pre></div>
<p>Add the same command to your shell configuration to keep this setting. Run <code>asm version</code> again.</p>
</details>
<details class="source-fallback">
<summary>Inspect the installer first</summary>
<p>Download the script to a temporary file:</p>
<div class="terminal">
<div class="terminal-header"><div class="terminal-label">DOWNLOAD FOR REVIEW</div><button class="copy-button" type="button" data-copy="bootstrap-download-commands" aria-label="Copy installer download commands">Copy</button></div>
<pre tabindex="0"><code id="bootstrap-download-commands">{escape(download_commands)}</code></pre>
</div>
<p>If the download succeeds, review the displayed script. After your review, run this separate command in the same terminal:</p>
<div class="terminal"><pre tabindex="0"><code>sh "$asm_installer"</code></pre></div>
<p>Remove the temporary file after installation:</p>
<div class="terminal"><pre tabindex="0"><code>rm -f "$asm_installer"
unset asm_installer</code></pre></div>
</details>
<details class="source-fallback">
<summary>Use in scripts and CI</summary>
<p>For scripts and CI, use the complete-download commands below. The script runs only if the download succeeds.</p>
<div class="terminal">
<div class="terminal-header"><div class="terminal-label">INSTALL FROM FILE</div><button class="copy-button" type="button" data-copy="bootstrap-ci-commands" aria-label="Copy installation commands for scripts and CI">Copy</button></div>
<pre tabindex="0"><code id="bootstrap-ci-commands">{escape(ci_commands)}</code></pre>
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
    region = insertion_point(content)
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
    if region is not None:
        before, original, after = region
        body = installer_markup(release) if release is not None else original
        if release is not None:
            after = after.replace('<details class="source-fallback" open>', '<details class="source-fallback">', 1)
        page.write_text(before + START + "\n" + body.strip() + "\n" + END + after, encoding="utf-8")
    return release
