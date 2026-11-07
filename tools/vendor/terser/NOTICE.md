# Terser 5.51.2

`bundle.min.js` and `LICENSE` are unmodified files from the official Terser 5.51.2 npm source package.
The bundle retains its upstream notices; the accompanying license is BSD-2-Clause.

- Upstream: <https://github.com/terser/terser/tree/v5.51.2>
- API: <https://terser.org/docs/api-reference/>
- Package: <https://registry.npmjs.org/terser/-/terser-5.51.2.tgz>
- Package SHA-512 SRI: `sha512-bWnjSNscmuI+GJze6ZupnHP8G/cTcsJF+bXCeQknk2SHQsgbNJnLrqiH9jZ2W4STPVXH2mDKKRX3iwPhc9Cn/Q==`
- Package SHA-256: `e861b3a42eef7477ba7df38483fd0b802b4954637d396ca04316f26e30996d89`
- Bundle SHA-256: `379f8758191b03c07745486e785cbf4bed6a7ae368aa40a5a819556743f3ad1c`
- License SHA-256: `901d0a7fcaccaae9917d165039c0473c354e5da2e0e94140dde67aad9ffb19da`

These files were retrieved and checked on 8 November 2026.
Asm uses the documented browser-global API in a Node.js context containing no module loader.
Source maps are disabled; no additional package, installation, or network request is needed during a build.
Compression and local identifier mangling are enabled; property names and public script filenames remain unchanged.
Readable source and its notices remain in `site/`.
The site gate runs the existing behavior tests against the actual minified scripts.

This is a build-only dependency and is not included in the published website.
It replaces the measured rJSmin candidate with a parser that supports modern JavaScript and reduces more browser bytes.
The larger vendored tool trades repository and source-archive size for smaller served assets without provisioning npm dependencies.
