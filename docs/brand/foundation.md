# Asm brand foundation

This is the source of truth for Asm's belief, vision, story, and decision principles.
Use it with the [messaging guide](messaging.md) for every task.
[AGENTS.md](../../AGENTS.md) makes both documents required context for agents.

## The defining belief

Software should serve people exceptionally well and use resources with care.
AI gives us an opportunity to revisit the constraints of writing code by hand.
We should use that opportunity to improve the software people experience.

## The change we see

Programming languages and abstractions made computers practical for people to program.
They helped build the digital world and still provide useful structure, safety properties, and portability.
They also shaped which implementations were economical to create and maintain.

We expect AI to change those economics.
More implementations and more machine targets may become practical.
Code generation alone does not establish correctness, security, or value.
As generation becomes cheaper, dependable reuse and evidence become more valuable.
These are working assumptions that we will test and revise.

## The human tension

People experience software through its behavior: whether it works, responds quickly, protects them, and fits their needs.
They also bear its costs through waiting, hardware, energy, operation, and maintenance.
Builders need a practical way to deliver those outcomes without rebuilding every component or trusting unexplained claims.

Our challenge is the gap between generating an implementation and making it dependable enough for someone else to use.

## Vision

A world where people can focus on what software should make possible.
AI helps produce implementations suited to their machines.
A dependable ecosystem makes those implementations practical to inspect, share, verify, and reuse.
Human judgment sets the intent, evaluates the result, and decides what to trust.

This is a long-term direction, not a description of a complete service available today.

## Mission and role

Make machine-level software practical to build upon and distribute with inspectable evidence.
We start with assembly projects, a package registry, and a command-line tool.
Our broader goal is dependable software distribution at global scope.

Asm provides the shared foundation between producing code and putting it into use.
Package identity, explicit targets, repeatable workflows, and evidence give builders something they can assess and reuse.
Authenticated distribution, discovery, and recovery must grow together as the service develops.
The [architecture proposal](../architecture.md) and [acceptance gates](../architecture-gates.md) define those platform ambitions.

## Our technical conviction

Assembly gives direct control over instructions, layout, and machine features.
We believe AI can make that control useful in more situations.
The result must earn its place through correctness, user experience, security, and measured total cost.

Assembly is a language and an implementation choice.
It does not automatically outperform a compiler or make code safe.
Asm must remain useful when a compiler already produces the best implementation for a workload.
The [project purpose](../why-asm.md) develops the technical assumptions and their limits.

## The defining story

Software should serve the people who use it.

For decades, creating software has meant working within what people could reasonably write and maintain.
Languages and frameworks helped us build extraordinary things.
They also shaped the trade-offs between the work of creating software and the experience of using it.

AI gives us a chance to revisit those trade-offs.
If machines can help produce and revise code closer to the hardware, more approaches become worth exploring.
We can focus more attention on what matters to people: software that responds quickly, works reliably, protects them, and respects their resources.

We are starting with assembly.
It gives us a direct foundation for exploring that future.
But an implementation becomes more useful when others can build on it.
People need to know what it does, which machine it supports, where it came from, and what evidence accompanies it.

That is why we are building Asm.
We bring assembly projects, packages, targets, and release evidence into a shared workflow.
Our ambition is a foundation that helps people and AI create better software, and helps others make informed decisions about using it.

**Working expression: Made for machines. Built for people.**

This line is a candidate expression of the story.
It does not replace the current product description or approve a visual redesign.

## Who we serve first

| Person | Need | What Asm should help them do |
| --- | --- | --- |
| Assembly author, including a person working with AI | Turn an implementation into something others can use | Declare interfaces and targets, build, test, package, and prepare release evidence |
| Package consumer | Make an informed choice and integrate dependable components | Find a package, inspect its scope and evidence, and use an exact compatible artifact |
| Contributor or maintainer | Improve a shared foundation without weakening it | Follow explicit contracts, preserve evidence, and ship focused changes |

People who use the resulting applications are the ultimate beneficiaries.
The initial audience does not imply that Asm is already an autonomous application builder or a universal runtime.

## Principles that govern the work

| Principle | Consequence for a decision |
| --- | --- |
| Serve the person | Favor completed tasks, responsive behavior, clear errors, accessibility, and reliability. |
| Earn trust with evidence | State the check, scope, assumptions, target, and artifact. Keep missing and failed evidence visible. |
| Respect resources | Measure relevant time, compute, energy, and operating costs. Include development, verification, and maintenance in total-cost claims. |
| Make reuse dependable | Prefer clear identities, interfaces, explicit targets, immutable releases, and repeatable workflows. |
| Keep people in control | Make consequences understandable. Preserve files on failure and require deliberate execution. |
| Let results test the thesis | Compare credible alternatives. Keep regressions and negative results. Revise assumptions when evidence disagrees. |

These principles apply to engineering and operations as well as copy and design.
They do not require adding slogans to commands, errors, or technical specifications.

## What is true today

The [README status section](../../README.md#status) describes the current release and supported hosts.
The [security model](../specs/security.md) defines implemented checks, trust boundaries, and missing capabilities.
The [roadmap](../roadmap.md) describes work that remains.
Use those sources for current capability claims rather than maintaining a second feature table here.

Global distribution capacity, hosted verification, and the wider vision require their own implementation and qualification evidence.
A digest match, signed provenance, tests, formal proofs, and agent review establish different things.
None is a general declaration that a package is harmless.

## Evidence that strengthens the story

- Reproducible comparisons with credible baselines, defined workloads, hardware, raw results, and regressions.
- Security mechanisms tested against explicit threats and connected to the relevant released bytes.
- Real examples of publishing, finding, integrating, and maintaining reusable components.
- Observed completion of first-user tasks and understandable recovery from failures.
- Cost evidence that distinguishes runtime savings from the work of development, verification, and maintenance.

Link to existing evidence before making a claim.
If the evidence is absent, describe the goal or hypothesis explicitly.

## How we use and maintain this foundation

1. Read this foundation and the messaging guide before starting a task.
2. Identify the user outcome and relevant principles.
3. Check the current specifications, implementation, and evidence.
4. Make the smallest complete change consistent with those sources.
5. Record material trade-offs and validation in the pull request.
6. Update affected messaging when the underlying direction or facts change.

The repository maintainer owns changes to this foundation through the normal pull-request process.
Review it at major strategy changes and periodically as evidence accumulates.
Keep beliefs durable, technical assumptions testable, and product descriptions current.
A conflict should lead to an explicit decision and a coherent update, never an invented claim or a weaker check.
