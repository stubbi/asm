# Guide package example

The guide follows the published `stubbi/math@0.4.0` package for `x86_64-linux`.
The instruction explorer is a browser model, separate from the recorded Linux execution.
It is not a native assembly runtime or a formal proof.

## Recorded execution

[recording.json](recording.json) records the commands, output, exit codes, source, and artifact digests.
The run used Asm 0.4.0 in an Alpine Linux 3.24.3 x86-64 guest.
QEMU TCG 9.2.0 ran the guest on Apple Silicon.
GNU binutils 2.45.1 assembled and linked the program.
This is functional validation, not a performance measurement.

The sequence creates a project, adds the exact published source package, replaces `src/main.s`, locks dependencies, and runs the program.
The replacement file is [minimum.s](minimum.s), with its complete MIT notice.
The recorded output is `min(12, 37) = 12`, with exit code 0 and empty standard error.
The consumer checks the returned value before it prints the fixed example message.
Changing its input values also requires changing its check and message.

The recording binds these artifacts:

| Artifact | SHA-256 |
| --- | --- |
| Published CLI | `7a618e4070a9b373d63554c7f144b40ad51729ff868fa091bd1d72de4b4fe586` |
| Published math source archive | `5276f2810d875b54c1dd579e3a6152cfd9d0e63a49decd1d411d0796d2bd0a08` |
| Consumer source | `33d0bb36359da4b7e244b6be6c300d159c737cf5beb729f5753a9519939e42ab` |
| Built consumer executable | `c3cd8a634cf34f9c685e60c7977ff63cf0fa3c3e4a049c88de0cb36544f05471` |

The package declares source commit `1dbe731fbe19d1e6201afd662699382e4983655a`.
The tested function and published tests match that commit.
The record includes their source hashes and the registry record.
A digest match does not establish publisher identity or general safety.

[package-tests.json](package-tests.json) records the separately executed published package tests.
Its eight encoded cases include zero, equal and reversed inputs, the unsigned maximum, and the signed boundary.
The generated consumer's starter tests are not the package tests.

## Failure checks and recording corrections

The final run rejected a changed dependency before assembly and preserved the prior executable.
It rejected an unsupported dependency target and preserved the lock file.
The recording retains each command's output and exit code.

[recording-attempt1.json](recording-attempt1.json) retains the first failed harness attempt.
The harness expected unsupported-target exit code 1; the CLI correctly returned argument-error exit code 2.
Only that expectation was corrected before a fresh run.
The final recording repeats the workflow with the complete consumer license notice.

[recording-annotation.json](recording-annotation.json) explains a misleading gzip compatibility-link log field.
The harness looked up the executable again after creating the link, so its message repeats the link path.
The corrected target is reconstructed from the retained harness and recorded pre-link path.
Guest `readlink` output was not captured.
The raw recording is unchanged.

## Maintenance

Keep the displayed source, download, and recording consistent.
Run the site checks after changing them.
Record a new supported-host run before changing the example's claimed behavior.
Do not silently edit a recorded result or relabel earlier released bytes.
