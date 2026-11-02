#!/usr/bin/env python3
"""Render the provisioned installer while retaining the current installer gates.

The legacy generator remains the live path until a new release and offline root
are qualified. This generator requires explicit, pinned verifier release assets.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
from __future__ import annotations

import re
import bootstrap
import registry


def replace_once(text: str, old: str, new: str) -> str:
    registry.require(text.count(old) == 1, "installer template changed; review the trusted adapter")
    return text.replace(old, new, 1)


def render_installer(release: dict, verifiers: list[dict]) -> bytes:
    """Pin one verifier per supported host before any downloaded code executes."""
    bootstrap.validate_release(release)
    registry.require(isinstance(verifiers, list), "verifiers must be a list")
    targets = {asset["target"] for asset in release["artifacts"]}
    seen = set()
    script = bootstrap.render_installer(release).decode()
    for asset in verifiers:
        registry.require(isinstance(asset, dict) and set(asset) == {"target", "url", "sha256", "bytes"},
                         "invalid verifier fields")
        target = asset["target"]
        registry.require(isinstance(target, str) and target in targets and target not in seen,
                         "unsupported or duplicate verifier target")
        seen.add(target)
        url = f"{bootstrap.REPOSITORY}/releases/download/v{release['version']}/asm-verify-{release['version']}-{target}"
        registry.require(asset["url"] == url, "verifier must use its fixed release URL")
        registry.require(type(asset["bytes"]) is int and 0 < asset["bytes"] <= registry.MAX_ARTIFACT_BYTES,
                         "invalid verifier size")
        registry.require(isinstance(asset["sha256"], str) and re.fullmatch("[0-9a-f]{64}", asset["sha256"]) is not None,
                         "invalid verifier digest")
        marker = f"            asm_target='{target}'\n"
        script = replace_once(script, marker, marker +
                              f"            asm_verifier_url='{url}'\n" +
                              f"            asm_verifier_bytes='{asset['bytes']}'\n" +
                              f"            asm_verifier_sha256='{asset['sha256']}'\n")
    registry.require(seen == targets, "each host requires its pinned verifier")
    script = replace_once(script, "for asm_tool in curl gh stat", "for asm_tool in curl stat")
    script = replace_once(script, "/usr/bin/curl /opt/homebrew/bin/gh /usr/bin/stat", "/usr/bin/curl /usr/bin/stat")
    script = replace_once(script, "            asm_gh=/usr/bin/gh\n", "")
    script = replace_once(script, "            asm_gh=/opt/homebrew/bin/gh\n", "")
    script = replace_once(script, "asm_link asm_rm asm_gh \\", "asm_link asm_rm \\")
    # Delete only the external-tool version probe. All installation ancestry,
    # ownership, existing-file, private-stage and finalization checks remain.
    start = script.index("    # gh reads configuration before it handles --version.")
    end = script.index("    asm_check_ancestors\n", start)
    script = script[:start] + script[end:]
    start = script.index("    printf 'Downloading Asm")
    helper = '''    asm_fetch "$asm_verifier_url" "$asm_verifier_bytes" "$asm_stage/asm-verify" || asm_fail 'The verifier download failed.'
    [ "$(asm_stat "$asm_stat_bytes" "$asm_stage/asm-verify")" = "$asm_verifier_bytes" ] || asm_fail 'The verifier size does not match.'
    if [ "$asm_system" = Darwin ]; then
        asm_verifier_digest=$(asm_clean_env /usr/bin/shasum -a 256 -- "$asm_stage/asm-verify") || asm_fail 'Cannot check the verifier digest.'
        [ "${asm_verifier_digest%% *}" = "$asm_verifier_sha256" ] || asm_fail 'The verifier checksum does not match.'
        "$asm_chmod" 700 "$asm_stage/asm-verify" || asm_fail 'Cannot prepare the verifier.'
    else
        printf '%s  %s\\n' "$asm_verifier_sha256" "$asm_stage/asm-verify" | /usr/bin/sha256sum --check --status || asm_fail 'The verifier checksum does not match.'
        "$asm_chmod" 700 -- "$asm_stage/asm-verify" || asm_fail 'Cannot prepare the verifier.'
    fi
    readonly asm_verifier="$asm_stage/asm-verify"
    asm_check_location
    if [ -e .asm-trust ] || [ -L .asm-trust ]; then
        asm_check_directory .asm-trust
    fi

'''
    script = script[:start] + helper + script[start:]
    start = script.index('        "$@" "$asm_gh" attestation verify')
    end = script.index('\n    ) >"$asm_stage/verified-repository"', start)
    script = script[:start] + '''        "$@" "$asm_verifier" authorize "$asm_bin_path/.asm-trust" "asm-$asm_version-$asm_target" "$asm_stage/asm" || exit 1
        "$@" "$asm_verifier" provenance "$asm_stage/asm" "$asm_stage/release-attestation.sigstore.json" "$asm_commit"''' + script[end:]
    script = replace_once(script, "Checking the signed GitHub release attestation. No login is required.",
                          "Checking release authorization and provenance.")
    registry.require("$asm_gh" not in script and "/usr/bin/gh" not in script and "/opt/homebrew/bin/gh" not in script,
                     "external verifier remains in generated installer")
    return script.encode()
