"""Build a native task index for maintained Asm documentation.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
from html import escape
from pathlib import Path

import package_pages
import registry


REPOSITORY = "https://github.com/stubbi/asm/"
SOURCE = REPOSITORY + "blob/main/"
GROUPS = (
    ("start", "Start", (
        ("Install Asm", REPOSITORY + "#install-the-command",
         "Check prerequisites and install the CLI for your supported host."),
        ("Create your first project", REPOSITORY + "#run-your-first-project",
         "Create, run, and test a small assembly program."),
        ("Check current support", REPOSITORY + "#status",
         "Read supported hosts, published capabilities, and remaining limits."),
    )),
    ("packages", "Packages", (
        ("Inspect a package", "../guide.html",
         "Follow the package walkthrough and understand targets and evidence."),
        ("Use a source package", SOURCE + "docs/use-a-package.md",
         "Select an exact dependency and check the resulting program."),
        ("Prepare a package release", SOURCE + "docs/specs/registry.md#package-and-prepare-a-record",
         "Prepare source-bound artifacts and a local release record without uploading."),
    )),
    ("reference", "Reference", (
        ("CLI source", "../reference/",
         "Read the CLI files from the site build’s recorded commit."),
        ("Registry format", SOURCE + "docs/specs/registry.md#release-record",
         "Inspect release records, targets, indexes, and package contracts."),
        ("Target distribution", SOURCE + "docs/target-distribution.md",
         "Review platform selection, artifact formats, and target support limits."),
        ("Security model", SOURCE + "docs/specs/security.md",
         "Understand implemented checks, trust boundaries, and missing safeguards."),
        ("Build with an AI", SOURCE + "docs/agents.md",
         "Set up the maintained skill and source-checkout developer tools."),
        ("AI instructions", "../agents.md",
         "Read the machine-oriented package and development workflow."),
    )),
)


def write_docs(repo: Path, stage: Path) -> list[str]:
    """Write docs/ from shared chrome; source guides remain authoritative.

    The build's source checkout can omit documentation files. Fixed repository
    links still identify the maintained guides; tests verify their real anchors.
    """
    body = ('<header class="package-heading"><h1>Documentation</h1>'
            '<p>Install Asm, use packages, and inspect the formats and evidence behind each release.</p></header>'
            '<p class="package-note">Detailed guides open on GitHub.</p>')
    for identifier, heading, cards in GROUPS:
        body += '<section class="directory-section" aria-labelledby="docs-' + identifier + '"><h2 id="docs-' + identifier + '">' + heading + '</h2><div class="directory-grid">'
        for title, href, description in cards:
            body += ('<a class="directory-card" href="' + escape(href, quote=True) + '"><h3>'
                     + escape(title) + '</h3><p>' + escape(description) + '</p></a>')
        body += '</div></section>'
    content = package_pages._page("docs/", "Installation and package documentation",
                                  "Find installation, first-project, package, target, and security guides. Detailed instructions open in the maintained repository documentation.",
                                  body, package_pages._chrome(stage), active_nav="Docs", scripts=False)
    registry.write_atomic(stage / "docs/index.html", content.encode("utf-8"))
    return ["docs/"]
