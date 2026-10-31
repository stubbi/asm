# Writing guide

Use ASD-STE100 Issue 9 for technical instructions and descriptions.
The official standard contains writing rules and a controlled dictionary.
Read the [official guidance](https://www.asd-ste100.org/STE_faq.html) when a word or construction is uncertain.

## Apply the rules

Give one instruction in each sentence.
Use no more than 20 words in an instruction.
Use no more than 25 words in a description.
Put a required condition before the instruction.
Use active voice when you know the actor.
Keep one topic in each paragraph.

Use a technical term when it is necessary and defined.
Do not change a literal identifier to satisfy a prose rule.
Do not omit an article or a verb to shorten a sentence.
Use notes for information. Put required actions in steps.

## Project terms

| Term | Meaning |
| --- | --- |
| ASM | The project and service. |
| `asm` | The command that the user runs. |
| package | A named unit of software with one or more versions. |
| version | An immutable release of a package. |
| target | The declared machine and platform requirements for an artifact. |
| architecture | An instruction set, such as x86-64 or AArch64. |
| ABI | The rules for binary interfaces, calls, and data layout. |
| artifact | A specific file produced or supplied for a release. |
| digest | A cryptographic value that identifies file bytes. |
| manifest | A file that describes a project or release. |
| index | A generated list of available releases and artifacts. |
| lock file | A record of exact dependency versions and digests. |
| provenance | A record that connects an artifact to its source and build. |
| proof | Evidence for a stated mathematical claim within explicit assumptions. |
| yank | Exclude a release from new resolution while retaining its record. |
| revoke | Mark a release as unsafe under an explicit emergency policy. |

## Write useful errors

Use a short problem statement and a recovery action.
Name the affected path or target when it is safe to show it.
Do not expose tokens, credentials, or private source content.

Example:

```text
asm: asm.toml contains an unsupported target.
Run `asm targets` to see the supported targets.
```

## Review before publication

Check the meaning as well as the sentence length.
Run every procedural command in a clean temporary directory.
Compare the observed output with the documented output.
Ask whether a new user knows the next action after an error.

Automatic checks can find some writing defects.
They cannot certify full STE conformance or prove that an instruction is correct.
We use the standard as an editorial requirement and retain human review.

## References

- [ASD-STE100 official site](https://www.asd-ste100.org/)
- [Official FAQ](https://www.asd-ste100.org/STE_faq.html)
- [Official guidance on checking tools](https://www.asd-ste100.org/STEsoftware.html)
