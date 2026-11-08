"""Generate factual project, contact, and privacy pages from shared chrome.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
from pathlib import Path

import package_pages
import registry


REPOSITORY = "https://github.com/stubbi/asm"
SOURCE = REPOSITORY + "/blob/main/"
GITHUB_PAGES = "https://docs.github.com/en/pages/getting-started-with-github-pages/what-is-github-pages#data-collection"
GITHUB_PRIVACY = "https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement"


def _link(label: str, href: str) -> str:
    return package_pages._anchor(label, href)


def _section(identifier: str, heading: str, content: str) -> str:
    return ('<section class="package-section package-readme-content" aria-labelledby="' + identifier
            + '"><h2 id="' + identifier + '">' + heading + '</h2>' + content + '</section>')


def _about() -> str:
    return (
        _section("about-reuse", "Build on recorded releases",
            '<p>Each release records a source repository, a Git commit, explicit targets, artifact digests, and its own license.</p>'
            '<p>Package targets do not establish native CLI host support. '
            + _link("Check current support", REPOSITORY + "#status") + ' before choosing a host binary.</p>'
            '<p>' + _link("Browse assembly packages", "../packages/") + ', '
            + _link("explore package categories", "../explore/") + ', or read the '
            + _link("installation and package documentation", "../docs/") + '.</p>')
        + _section("about-purpose", "Why assembly",
            '<p>Software should serve people well and use resources with care.</p>'
            '<p>We expect AI to reduce the work of producing and maintaining assembly software. This is a working assumption.</p>'
            '<p>Code still needs clear interfaces, tests, and evidence for its stated behavior.</p>'
            '<p>Assembly does not automatically outperform a compiler or make software safe.</p>'
            '<p>People decide what to build and what evidence they need before using a package.</p>'
            '<p>Read ' + _link("why Asm exists", SOURCE + "docs/why-asm.md") + ' and the '
            + _link("Asm guide and project story", "../guide.html#why") + '.</p>')
        + _section("about-project", "Project and contribution",
            '<p>Asm is an open-source project maintained through its '
            + _link("public source repository", REPOSITORY) + '.</p>'
            '<p>Platform code and documentation use AGPL-3.0-or-later unless a file has a separate notice.</p>'
            '<p>Starter text and independent packages have their own stated licenses. Read the '
            + _link("license scope", REPOSITORY + "#license") + '.</p>'
            '<p>Inspect ' + _link("registry statistics", "../stats/") + ' and '
            + _link("project articles and release notes", "../blog/") + ' for their stated scope and source.</p>'
            '<p>Use the ' + _link("contribution guide", SOURCE + "CONTRIBUTING.md") + ' to propose a change. '
            + _link("Contact Asm", "../contact/") + ' with a project question.</p>'))


def _contact() -> str:
    return (
        _section("contact-bugs", "Report a problem",
            '<p>Use ' + _link("GitHub Issues", REPOSITORY + "/issues") + ' for ordinary bugs and documentation problems.</p>'
            '<p>Include the affected version, target, command, expected result, and a small reproduction.</p>'
            '<p>Do not post credentials or private data in a public issue.</p>')
        + _section("contact-security", "Report a security defect",
            '<p>Use ' + _link("GitHub private vulnerability reporting", REPOSITORY + "/security/advisories/new") + ' for security defects.</p>'
            '<p>If the private form is unavailable, open an issue that asks for a private reporting route.</p>'
            '<p>Do not include vulnerability details in that public issue.</p>'
            '<p>Read the ' + _link("security reporting policy", SOURCE + "SECURITY.md") + ' for support scope and report details.</p>'
            '<p>Asm has no guaranteed security response time or support period yet.</p>')
        + _section("contact-email", "Project and sponsorship enquiries",
            '<p>Email ' + _link("jannes.stubbemann@gmail.com", "mailto:jannes.stubbemann@gmail.com")
            + ' for project or sponsorship enquiries.</p>'
            '<p>Use the ' + _link("Sponsorship page", "../sponsors.html") + ' for current tiers and agreement steps.</p>'
            '<p>Email links open your email application. They do not send a message automatically.</p>'
            '<p>Do not send credentials, financial details, or other sensitive information.</p>'
            '<p>Read ' + _link("how the website handles data", "../privacy/") + ' before sharing information.</p>'))


def _privacy(registry_version: int) -> str:
    hosting = (
        '<p>This static website uses the hosting service selected by its operator.</p>'
        '<p>That service can observe network requests. Read its privacy policy before using the site.</p>'
    ) if registry_version == 2 else (
        '<p>GitHub Pages hosts asm.build.</p>'
        '<p>GitHub states that Pages visits log and store visitors’ IP addresses for security purposes, whether visitors sign in or not.</p>'
        '<p>Read ' + _link("GitHub Pages data collection", GITHUB_PAGES) + ' and the '
        + _link("GitHub Privacy Statement", GITHUB_PRIVACY) + ' for GitHub’s handling of data.</p>'
    )
    downloads = (
        '<p>V2 download counts come from private server observations for declared public files.</p>'
        '<p>Counts show reporting cutoffs and gaps. Unreported mirrors and cache hits remain outside their coverage.</p>'
        '<p>The reference log format excludes IP addresses, cookies, user-agent strings, referrers, and raw queries.</p>'
    ) if registry_version == 2 else (
        '<p>Asm’s local delivery tooling records artifact-bound completed transfers for aggregate download counts.</p>'
        '<p>Its ledger stores no visitor identifiers, IP addresses, cookies, fingerprints, user-agent strings, or search terms.</p>'
        '<p>This deployed static site does not operate the local delivery event service.</p>'
        '<p>Direct downloads from other hosts are outside this event coverage.</p>'
    )
    return (
        _section("privacy-search", "Package search",
            '<p>Package search runs in your browser. Search terms and filters stay in the URL fragment after <code>#</code>.</p>'
            '<p>The website does not add them to request URLs or send them to analytics or an external search service.</p>'
            '<p>Sharing the full address shares its fragment with the recipient.</p>')
        + _section("privacy-hosting", "Hosting and network requests",
            hosting + '<p>Opening repository links, downloading release assets, or sending email uses the selected provider’s services.</p>')
        + _section("privacy-stars", "GitHub star count",
            '<p>The optional star counter first reads a public observation from asm.build.</p>'
            '<p>If cached data is unavailable or expired, it can request GitHub’s fixed public API for <code>stubbi/asm</code>.</p>'
            '<p>This request sends no credentials, cookies, referrer, search terms, page paths, or application-added visitor identifier.</p>'
            '<p>GitHub receives your network address and standard browser metadata, including the site origin.</p>'
            '<p>Session storage holds public repository metadata and a retry deadline. This storage does not contain a visitor identifier.</p>'
            '<p>Displayed observations expire after five minutes.</p>')
        + _section("privacy-downloads", "Download measurements",
            downloads + '<p>Read the ' + _link("Discovery data and coverage", "../discovery/") + ' and '
            + _link("implemented security boundaries", SOURCE + "docs/specs/security.md") + '.</p>')
        + _section("privacy-review", "Questions and review",
            '<p>Use ' + _link("Contact Asm", "../contact/") + ' for a project or privacy question.</p>'
            '<p>This page describes the implementation reviewed on <time datetime="2026-11-08">8 November 2026</time>.</p>'))


def write_info(repo: Path, stage: Path, *, registry_version: int = 1) -> list[str]:
    """Write three native information routes without copying private source files.

    The source checkout can omit documentation. Fixed repository links identify
    maintained facts; this module makes no network requests or legal assurances.
    """
    registry.require(type(registry_version) is int and registry_version in (1, 2), "unsupported information registry version")
    chrome = package_pages._chrome(stage)
    privacy_description = (
        "Read how this V2 website handles private search fragments, operator-selected hosting, public star observations, session storage, and download measurements."
        if registry_version == 2 else
        "Read how asm.build handles private search fragments, GitHub Pages hosting, public star observations, session storage, and download measurements.")
    pages = (
        ("about/", "About Asm", "About the assembly package project", "AboutPage",
         "Learn what Asm does, why it starts with assembly, and how exact releases and inspectable evidence support package reuse.",
         "Asm is a package registry and command-line tool for assembly projects.", _about()),
        ("contact/", "Contact Asm", "Project contact and issue reporting", "ContactPage",
         "Find Asm bug reports, private security reporting, and the public project email. Choose a route before sharing information.",
         "Choose a contact route for a bug, security defect, project question, or sponsorship enquiry.", _contact()),
        ("privacy/", "Privacy at Asm", "Website privacy and data handling", "WebPage",
         privacy_description,
         "How this website handles queries, public repository data, and network requests.", _privacy(registry_version)),
    )
    for route, heading, title, kind, description, introduction, content in pages:
        canonical = package_pages.SITE + route.rstrip("/")
        data = {"@context": "https://schema.org", "@type": kind, "@id": canonical + "#webpage",
                "url": canonical, "name": heading, "description": description, "inLanguage": "en"}
        body = ('<div class="discovery-explanation"><header class="package-heading"><h1>' + heading
                + '</h1><p>' + introduction + '</p></header>' + content + '</div>')
        page = package_pages._page(route, title, description, body, chrome, active_nav=False,
                                   scripts=False, structured_data=data)
        registry.write_atomic(stage / route / "index.html", page.encode("utf-8"))
    return [page[0] for page in pages]
