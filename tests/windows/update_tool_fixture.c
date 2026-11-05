/* Test-only transport/verifier fixture. Never linked into the Asm CLI.
 * This fixture checks child arguments and supplies deterministic test bytes.
 * It does not perform HTTPS or Sigstore cryptography.
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
typedef unsigned short W;
typedef unsigned long D;
typedef void *H;
#define API __declspec(dllimport)
API W *GetCommandLineW(void);
API W **CommandLineToArgvW(const W *, int *);
API D GetModuleFileNameW(H, W *, D);
API H CreateFileW(const W *, D, D, void *, D, D, H);
API int ReadFile(H, void *, D, D *, void *);
API int WriteFile(H, const void *, D, D *, void *);
API int CloseHandle(H);
API D GetFileAttributesW(const W *);
API D GetEnvironmentVariableW(const W *, W *, D);
API H GetStdHandle(D);
API void ExitProcess(D);

static W base[4096], path[4096], env[4096];
static char bytes[1024 * 1024];
static char subject_bytes[32768], reference_bytes[32768];
static int argc;
static W **argv;

static int equal(const W *a, const W *b) {
    while (*a && *a == *b) { ++a; ++b; }
    return *a == *b;
}

static int contains(const W *a, const W *b) {
    for (; *a; ++a) {
        const W *x = a, *y = b;
        while (*x && *x == *y) { ++x; ++y; }
        if (!*y) return 1;
    }
    return 0;
}

static W *file(const W *name) {
    D i = 0, j = 0;
    while (base[i]) { path[i] = base[i]; ++i; }
    while (name[j] && i < 4095) path[i++] = name[j++];
    path[i] = 0;
    return path;
}

static int exists(const W *name) { return GetFileAttributesW(file(name)) != (D)-1; }

static W *option(const W *name) {
    int i;
    for (i = 1; i + 1 < argc; ++i) if (equal(argv[i], name)) return argv[i + 1];
    ExitProcess(91);
    return (W *)0;
}

static int present(const W *name) {
    int i;
    for (i = 1; i < argc; ++i) if (equal(argv[i], name)) return 1;
    return 0;
}

static void require(int condition) { if (!condition) ExitProcess(92); }

static void output(const char *text, D size) {
    D written = 0;
    require(WriteFile(GetStdHandle((D)-11), text, size, &written, 0) && written == size);
}

static void log_call(const char *text, D size) {
    H handle = CreateFileW(file(L"calls.tsv"), 4, 3, 0, 4, 128, 0);
    D written = 0;
    require(handle != (H)-1);
    require(WriteFile(handle, text, size, &written, 0) && written == size);
    require(CloseHandle(handle));
}

static void no_credentials(void) {
    require(!GetEnvironmentVariableW(L"GH_TOKEN", env, 4096));
    require(!GetEnvironmentVariableW(L"GITHUB_TOKEN", env, 4096));
    require(!GetEnvironmentVariableW(L"GH_HOST", env, 4096) || equal(env, L"github.com"));
    require(!GetEnvironmentVariableW(L"CURL_CA_BUNDLE", env, 4096));
    require(!GetEnvironmentVariableW(L"SSL_CERT_FILE", env, 4096));
}

static int same_bytes(const W *subject, const W *reference) {
    H left = CreateFileW(subject, 0x80000000, 1, 0, 3, 128, 0);
    H right;
    int matches = 1;
    D left_size, right_size, i;
    if (left == (H)-1) return 0;
    right = CreateFileW(file(reference), 0x80000000, 1, 0, 3, 128, 0);
    if (right == (H)-1) { CloseHandle(left); return 0; }
    for (;;) {
        if (!ReadFile(left, subject_bytes, sizeof(subject_bytes), &left_size, 0) ||
            !ReadFile(right, reference_bytes, sizeof(reference_bytes), &right_size, 0)) {
            matches = 0;
            break;
        }
        if (left_size != right_size) { matches = 0; break; }
        for (i = 0; i < left_size; ++i) {
            if (subject_bytes[i] != reference_bytes[i]) { matches = 0; break; }
        }
        if (!matches || !left_size) break;
    }
    if (!CloseHandle(left)) matches = 0;
    if (!CloseHandle(right)) matches = 0;
    return matches;
}

static void download(void) {
    const W *source;
    W *out;
    H handle;
    D length = 0, limit = 0;
    W *bound = option(L"--max-filesize");
    require(argc > 4 && equal(argv[1], L"--disable"));
    require(equal(option(L"--proto"), L"=https"));
    require(equal(option(L"--proto-redir"), L"=https"));
    require(equal(argv[argc - 2], L"--"));
    no_credentials();
    while (*bound >= '0' && *bound <= '9') limit = limit * 10 + (*bound++ - '0');
    require(limit > 0 && limit <= 67108864);
    log_call("curl\n", 5);
    if (exists(L"network-failure")) ExitProcess(22);
    if (contains(argv[argc - 1], L"/registry/v1/index")) source = L"index.tsv";
    else if (contains(argv[argc - 1], L"/release.json")) source = L"release.json";
    else if (contains(argv[argc - 1], L"/release-attestation.sigstore.json")) source = L"bundle";
    else source = L"artifact";
    handle = CreateFileW(file(source), 0x80000000, 1, 0, 3, 128, 0);
    require(handle != (H)-1);
    require(ReadFile(handle, bytes, sizeof(bytes), &length, 0));
    require(length > 0 && length <= limit);
    require(CloseHandle(handle));
    out = option(L"--output");
    require(equal(out, L"-"));
    output(bytes, length);
    ExitProcess(0);
}

static void verify(void) {
    int exact, manifest, candidate;
    no_credentials();
    if (argc == 2 && equal(argv[1], L"--version")) {
        output("gh version 2.93.0 (test fixture)\n", 33);
        ExitProcess(0);
    }
    require(argc > 3 && equal(argv[1], L"attestation") && equal(argv[2], L"verify"));
    require(equal(option(L"--repo"), L"stubbi/asm"));
    require(equal(option(L"--cert-identity"),
                  L"https://github.com/stubbi/asm/.github/workflows/release.yml@refs/heads/main"));
    require(equal(option(L"--cert-oidc-issuer"), L"https://token.actions.githubusercontent.com"));
    require(equal(option(L"--source-ref"), L"refs/heads/main"));
    require(equal(option(L"--predicate-type"), L"https://slsa.dev/provenance/v1"));
    require(equal(option(L"--hostname"), L"github.com"));
    require(equal(option(L"--format"), L"json"));
    require(equal(option(L"--jq"), L".[].verificationResult.signature.certificate.sourceRepositoryIdentifier"));
    require(present(L"--deny-self-hosted-runners"));
    require(!present(L"--custom-trusted-root"));
    require(same_bytes(option(L"--bundle"), L"bundle"));
    manifest = same_bytes(argv[3], L"release.json");
    candidate = same_bytes(argv[3], L"artifact");
    require(manifest != candidate);
    exact = present(L"--source-digest");
    if (exact) {
        require(equal(option(L"--source-digest"), L"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"));
        require(equal(option(L"--signer-digest"), L"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"));
        if (manifest) log_call("manifest-exact\n", 15);
        else log_call("candidate-exact\n", 16);
    } else {
        require(manifest);
        log_call("manifest-identity\n", 18);
    }
    if (exists(L"reject-signature") || (exact && exists(L"reject-source"))) ExitProcess(1);
    if (exists(L"wrong-repository")) output("1441332956\n", 11);
    else output("1441332955\n", 11);
    ExitProcess(0);
}

void fixture_entry(void) {
    D length = GetModuleFileNameW(0, base, 4096), i;
    require(length > 0 && length < 4096);
    for (i = length; i && base[i - 1] != '\\' && base[i - 1] != '/'; --i) {}
    require(i > 0);
    base[i] = 0;
    argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    require(argv && argc > 0);
    if (contains(argv[0], L"gh.exe")) verify();
    else download();
    ExitProcess(93);
}
