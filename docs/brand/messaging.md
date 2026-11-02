# Asm messaging guide

Read the [brand foundation](foundation.md) before using this guide.
The foundation defines our intent.
This guide turns that intent into consistent explanations and decisions.
Current specifications and evidence determine which product claims we can make.

## Name and role

Use **Asm** for the project and service in prose, including at the start of a sentence.
Keep the wordmark lowercase: **asm**.
Use `asm` for the command and **asm.build** for the website address.
Keep literal identifiers, required legal notices, and recorded evidence unchanged.
Follow the terms in the [writing guide](../writing.md).

**Product description:** Asm is a package registry and command-line tool for assembly projects.

**Current descriptor:** A home for assembly.

**Vision statement:** We are building a foundation that helps people and AI create better software and makes the results practical to share and assess.

**Working brand expression:** Made for machines. Built for people.

The working expression is a candidate, not a new capability claim or an instruction to replace every existing heading.
Use a concrete product description wherever a reader first needs to understand what Asm does.

## Short introduction

Asm helps people build, share, and check assembly software.
We expect AI to make useful assembly cheaper to create and maintain.
That makes dependable reuse more valuable.
Asm brings projects, packages, targets, and release evidence into a shared workflow.
Our ambition is software that serves people well and uses resources with care.

## The story at different depths

| Context | Lead with | Then explain |
| --- | --- | --- |
| Homepage or README | What Asm does and who can use it today | A real first task, the larger purpose, and evidence with clear limits |
| Project introduction | Human outcomes and the change AI may enable | Assembly as the technical bet and distribution as Asm's role |
| Package page | Identity, version, target, and available evidence | Interface, source, artifact checks, and missing results |
| Contributor onboarding | The defining belief and decision principles | Current contracts, useful work, validation, and review requirements |
| Technical proposal | The user problem and measurable acceptance conditions | Relevant principles, alternatives, risks, and evidence |
| Release announcement | What users can now do | Exact release, host support, validation, and remaining limits |

Adapt the depth and examples to the audience.
Keep the underlying belief and factual boundary consistent.

## Message priorities

1. Software should serve people through reliable behavior, responsiveness, security, accessibility, and responsible resource use.
2. AI may change the cost of producing and maintaining machine-level implementations.
3. More generated code increases the value of dependable reuse and inspectable evidence.
4. Asm starts with packaging and distribution for assembly projects.
5. Current capabilities and measured results show progress toward the larger vision.

Do not turn that order into a mandatory page layout.
The [design guide](../../design.md) governs the interface and the user's next action.

## Claims and evidence

| Claim | How to express it responsibly |
| --- | --- |
| AI changes assembly development | State this as our expectation or research position. Measure development and verification effort. |
| Assembly improves performance | Name the workload, baseline, hardware, artifact, and results. Link the evidence and include regressions. |
| Lower running cost | State measured resource or operating costs. Include development and maintenance when claiming lower total cost. |
| Trusted distribution | Name the implemented identity, integrity, provenance, or policy checks and their limits. |
| Verified software | Name the exact property, model, assumptions, target, and artifact covered. |
| Global distribution | Describe the architectural goal and qualification gates until capacity and recovery are demonstrated. |

Avoid universal claims such as “programming languages are dead,” “assembly is always best,” or “AI makes software secure.”
Assembly is itself a programming language.
The stronger position is that AI lets us revisit historical implementation constraints and test the results.

A successful checksum check does not establish publisher identity or general safety.
Provenance, tests, proofs, and agent review answer different questions.
Use the [security model](../specs/security.md) and [evidence record](../evidence.md) for the relevant distinctions.

## Voice

Write with conviction about the purpose and precision about the facts.
Use short sentences, active verbs, and familiar words.
Give a concrete action or observable result.
Credit the useful role of existing tools and languages.
Treat uncertainty as information that helps the reader decide.

Keep the current [writing rules](../writing.md) and [design rules](../../design.md).
Do not add invented adoption metrics, fictional testimonials, or reassuring labels without evidence.
Do not promise effortless development, universal compatibility, or automatic safety.

## Put the foundation to work

| Decision | Derivation from the foundation |
| --- | --- |
| Add a faster path | Measure equal work and preserve correctness, security checks, and useful errors. |
| Support another target | Declare the machine requirements and qualify that target independently. |
| Add a trust badge | Show the actual check, scope, result, and missing evidence. |
| Simplify onboarding | Reduce unnecessary steps while keeping prerequisites and consequences visible. |
| Expand discovery | Preserve the ability to install a known package when search is unavailable. |
| Choose roadmap work | Favor a concrete user outcome or a necessary trust and distribution capability. |

For a meaningful change, answer these questions in the task brief or pull request:

- Which person and outcome does this serve?
- Which foundation principle guides the choice?
- What trade-off are we accepting?
- What evidence supports the resulting claim?

Use this brief with people and AI agents.
Read the actual documents after a handoff or context loss; a remembered slogan is insufficient context.
The foundation guides implementation choices without adding marketing language to every interface.

## Document responsibilities

| Source | Responsibility |
| --- | --- |
| [foundation.md](foundation.md) | Belief, vision, mission, defining story, audiences, and principles |
| This guide | Descriptions, voice, audience emphasis, claims discipline, and application examples |
| [why-asm.md](../why-asm.md) | Technical reasoning and testable working assumptions |
| [README](../../README.md) | Product entry point, installation, and current release scope |
| [design.md](../../design.md) and [writing.md](../writing.md) | Interface and editorial standards |
| [Architecture](../architecture.md), [roadmap](../roadmap.md), and specifications | Proposed contracts, delivery sequence, and technical requirements |

Keep the brand documents in this repository as the canonical source.
Derive websites, presentations, release copy, and other materials from them.
Review relevant downstream materials when the foundation changes.
Update facts at their authoritative source instead of creating conflicting feature lists.
