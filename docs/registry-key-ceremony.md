# Provision registry V2 trust

Status: operator procedure; production custody and recovery remain unqualified.

This procedure provisions the package registry root.
It does not provision CLI self-update trust.
Keep `verifier/trust/asm-root.json` unchanged.
Keep the release `trusted_distribution` flag disabled.

The registry needs three offline root keys and three separate online role keys.
The root requires signatures from two of its three keys.
Online keys authorize targets, snapshots, and short-lived timestamps separately.
The [V2 specification](specs/registry-v2.md) defines the client and publication contracts.

## Record custody first

1. Name the custodian for each offline key.
2. Select three separate offline devices or protected offline stores.
3. Select encrypted recovery locations.
4. Name the independent human security reviewer.
5. Record the access and recovery procedure privately.
6. Record the reviewed source commit and tool digests.

One person can hold multiple keys on separate stores.
That choice does not provide separation between people.
The security review must assess that trade-off explicitly.
Do not record private keys, passphrases, or recovery codes in Git or chat.

## Prepare the public inputs

The maintainer tools need the Go version in `verifier/go.mod` during their build.
OpenSSL supplies Ed25519 key generation and public-key export.
The tools use maintained cryptography; application decisions remain in assembly.

1. Build and test the tools from the recorded reviewed commit.

   ```sh
   make build/asm-trust verifier-test
   cd verifier
   go build -mod=readonly -trimpath -o ../build/asm-verify .
   cd ..
   ```

   Expected result: the verifier tests pass and `build/asm-trust` exists.

2. Transfer the qualified tools to each selected offline device.
3. Check their digests against the private reviewed record.
4. Disconnect the root-key devices before creating or using private keys.
5. On each device, create one root key in its protected store.

   ```sh
   umask 077
   openssl genpkey -algorithm ED25519 -out root.pem
   openssl pkey -in root.pem -pubout -out root.pub
   ```

   Expected result: one private key and its public key exist on that device.

6. Transfer only each `root.pub` to the offline preparation device.
7. Name the three public files `root1.pub`, `root2.pub`, and `root3.pub`.
8. Create each online key in its approved signing environment.
9. Export only `targets.pub`, `snapshot.pub`, and `timestamp.pub` for root preparation.

Online private files use PKCS8 Ed25519 and mode0600 or stricter.
Root private keys must never enter the online environment.
Kubernetes receives only the three online keys through approved scoped secret items.
Its projected files need the qualified private-snapshot preparation before signing.

## Create and sign version1

1. Generate one registry identity on the preparation device.

   ```sh
   openssl rand -hex 16
   ```

   Expected result: one lowercase 32-character hexadecimal identity.

2. Record that immutable identity privately.
3. Prepare the unsigned public root.

   ```sh
   build/asm-trust prepare-root unsigned.json root1.pub root2.pub root3.pub targets.pub snapshot.pub timestamp.pub
   ```

   Expected result: a new unsigned version1 root, valid for 365 days.

4. Inspect every public key, role, threshold, version, and expiry on the first signing device.
5. Sign the inspected document with the first offline key.

   ```sh
   build/asm-trust sign-root unsigned.json root.pem first-signature.json
   ```

   Expected result: a new public document with one signature.

6. Transfer that public document to the second signing device.
7. Inspect the same fields and public-key fingerprints again.
8. Sign that document with a different offline key.

   ```sh
   build/asm-trust sign-root first-signature.json root.pem registry-root-v1.json
   build/asm-verify check-root registry-root-v1.json
   openssl dgst -sha256 registry-root-v1.json
   ```

   Expected result: root validation succeeds and the command prints the public-root digest.

9. Record the digest, role key IDs, custodian, review, and recovery references privately.
10. Return only the public root, registry identity, digest, and audit references to deployment.
11. Publish independently authenticated instructions for the initial identity and root pin.

Artifact mirrors cannot establish their own initial authority.
A digest obtained from the same compromised source does not supply an independent pin.
The deployment must retain the exact initial root and complete subsequent root history.

## Rehearse renewal and recovery

Use isolated resources and synthetic keys for rehearsal.
Never publish rehearsal roots into the production registry identity.

1. Restore the sealed signing record into a separate recovery environment.
2. Replace a synthetic online timestamp key.
3. Export its new public key to the offline preparation device.
4. Prepare the next unsigned root from the authenticated previous root.

   ```sh
   build/asm-trust prepare-next-root registry-root-v1.json unsigned-v2.json root1.pub root2.pub root3.pub targets.pub snapshot.pub timestamp.pub
   ```

   Expected result: a new unsigned version2 root with the selected public keys.

5. Inspect the new keys, version, thresholds, and expiry.
6. Collect signatures that meet both previous and new root thresholds.
7. Check the signed root with `build/asm-verify check-root`.
8. Publish the sequential root through the isolated distribution procedure.
9. Refresh a client that retains the previous root and rollback state.
10. Confirm that the old online key cannot sign an accepted new checkpoint.
11. Repeat with changed offline keys and signatures from both root sets.
12. Test interrupted publication and a client that missed the intermediate root.
13. Retain exact documents, tool digests, client results, and elapsed recovery time privately.

The preparation command does not sign or authorize a new root.
It permits an expired, authenticated previous root for offline recovery.
Clients still require a current final root and the complete authenticated sequence.
When root keys change, signatures from only the new keys cannot authorize the transition.
Never reset metadata versions or delete retained client rollback state to complete recovery.

## Activate only after qualification

1. Obtain the independent human security review.
2. Complete the joint database, retained-object, signed-bundle, and root-history restore exercise.
3. Qualify the online key snapshot and rotation in the selected runtime.
4. Deliver a test alert for failed checkpoint renewal.
5. Qualify external clients with the independently supplied initial pin.
6. Record the exact source and deployment artifact digests.
7. Remove deployment holds through the reviewed GitOps procedure.

The five-minute registry checkpoint needs renewal every two minutes.
Routine renewal uses the timestamp key.
Package changes and full metadata renewal need the applicable other online keys.
Offline root custody does not replace these operational requirements.

Protocol source checked 8 November 2026:
[TUF specification 1.0.37](https://theupdateframework.github.io/specification/latest/#update-the-root-role).
The [trust provisioning guide](trusted-distribution.md) states the shared custody requirements.
