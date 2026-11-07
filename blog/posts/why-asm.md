+++
title = "Why we are building Asm"
summary = "Assembly, dependable reuse, and software that serves people."
author = "Asm"
draft = true
+++

Software should serve the people who use it.
It should work reliably, respond quickly, protect them, and use resources with care.

## Why start with assembly?

Assembly gives builders direct control over instructions, layout, and machine features.
We expect AI to reduce the work needed to create and maintain useful assembly implementations.
That expectation needs testing.
Assembly does not automatically make software faster or safer.

The result must earn its place through correct behavior, a useful experience, and measured total cost.

## Make useful work reusable

An implementation becomes more valuable when other people can build on it.
They need to know its purpose, supported targets, source, and available evidence.

Asm brings assembly projects, packages, targets, and release evidence into a shared workflow.
We are starting with a package registry and a command-line tool.
Our wider ambition is dependable software distribution.
That ambition requires further implementation and qualification.

## Keep the evidence visible

A checksum, test result, provenance record, and formal proof answer different questions.
Each result needs a clear scope and a connection to the exact artifact.
Missing evidence must remain visible.

People set the intent and decide what to trust.
Asm should help them inspect, share, and reuse the work with that context.

Read the [project purpose](https://github.com/stubbi/asm/blob/main/docs/why-asm.md) and the [current guide](https://asm.build/guide.html).
