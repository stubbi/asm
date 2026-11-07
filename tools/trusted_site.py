"""Attach a qualified installer and signed metadata to a staged site.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
import hashlib
from pathlib import Path
import subprocess
import tempfile

import bootstrap
import registry


def attach(stage: Path, source: Path, publication: Path, release: dict, reader, verifier: Path, inspector: Path):
    registry.require(release is not None, "trusted distribution requires checked release artifacts")
    page = stage / "index.html"
    region = bootstrap.insertion_point(page.read_text(encoding="utf-8"))
    base = release["bundle_url"].rsplit("/", 1)[0]
    manifest_bytes = reader(base + "/release.json", 1 << 20)
    manifest = registry.strict_json(manifest_bytes)
    registry.require(manifest.get("version") == release["version"] and
                     manifest.get("repository") == bootstrap.REPOSITORY and
                     manifest.get("source_commit") == release["source_commit"], "release identity differs")
    distribution = manifest.get("distribution", {})
    root = source / "verifier/trust/asm-root.json"
    registry.require(distribution.get("profile") == "asm-tuf-v1" and
                     distribution.get("root_sha256") == hashlib.sha256(root.read_bytes()).hexdigest(),
                     "release uses a different distribution root or profile")
    with tempfile.TemporaryDirectory(prefix=".asm-site-trust-", dir=stage.parent) as temporary:
        work = Path(temporary)
        (work / "release.json").write_bytes(manifest_bytes)
        (work / "bundle.json").write_bytes(reader(release["bundle_url"], 1 << 20))
        env = {"PATH":"/usr/bin:/bin", "HOME":str(work), "LC_ALL":"C"}
        subprocess.run([str(verifier.resolve()), "check-root", str(root.resolve())], env=env, check=True, timeout=15)
        subprocess.run([str(verifier.resolve()), "provenance", str(work / "release.json"), str(work / "bundle.json"),
                        release["source_commit"]], env=env, check=True, timeout=120, capture_output=True)
        assets = manifest.get("assets", [])
        matching = [asset for asset in assets if asset.get("file") == "install.sh"]
        registry.require(len(matching) == 1, "signed manifest requires one installer")
        entry = matching[0]
        registry.require(type(entry.get("bytes")) is int and 0 < entry["bytes"] <= 1 << 20, "invalid installer size")
        installer = reader(base + "/install.sh", entry["bytes"])
        registry.require(len(installer) == entry["bytes"] and hashlib.sha256(installer).hexdigest() == entry.get("sha256"),
                         "installer differs from signed release")
        targets = {name: str((stage / "registry/v1" / name).resolve()) for name in ("index.tsv", "index-macos.tsv")}
        for asset in release["artifacts"]:
            name = asset["url"].rsplit("/", 1)[1]
            data = reader(asset["url"], asset["bytes"])
            registry.require(len(data) == asset["bytes"] and hashlib.sha256(data).hexdigest() == asset["sha256"], "release artifact differs")
            (work / name).write_bytes(data)
            targets[name] = str(work / name)
        (work / "targets.json").write_bytes(registry.json_bytes(targets))
        subprocess.run([str(inspector.resolve()), "inspect", str(root.resolve()), str(publication.resolve()),
                        str(work / "targets.json")], env=env, check=True, timeout=120, capture_output=True)
    # collect_files rejects links and special files. Signature validation above
    # binds the current metadata and exact indexes before atomic site exposure.
    for name, (data, mode) in registry.collect_files(publication).items():
        registry.write_atomic(stage / "trust/v1" / name, data)
    registry.write_atomic(stage / "install.sh", installer)
    if region is not None:
        before, content, after = region
        # Alter only optional installer requirements for this profile.
        content = content.replace("Install GitHub CLI at /usr/bin/gh.", "")
        content = content.replace("Install GitHub CLI at /opt/homebrew/bin/gh. ", "")
        content = content.replace('Use <a href="https://cli.github.com/">GitHub CLI 2.93.0 or later</a> before you start.',
                                  "The installer downloads and checks its verifier.")
        page.write_text(before + bootstrap.START + content + bootstrap.END + after, encoding="utf-8")
