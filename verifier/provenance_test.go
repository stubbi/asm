// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2026 ASM contributors
package main

import (
	"encoding/json"
	intoto "github.com/in-toto/attestation/go/v1"
	"os"
	"strings"
	"testing"

	"github.com/sigstore/sigstore-go/pkg/bundle"
	"github.com/sigstore/sigstore-go/pkg/root"
	"github.com/sigstore/sigstore-go/pkg/verify"
)

// These public fixtures are Asm 0.4.0's actual release manifest and attestation.
// The test root contains public Sigstore verification material, never Asm's
// production update root or private keys. See testdata/README.md for origin.
func TestPublishedProvenance(t *testing.T) {
	artifact, err := os.ReadFile("testdata/release.json")
	must(t, err)
	var manifest struct {
		SourceCommit string `json:"source_commit"`
	}
	must(t, json.Unmarshal(artifact, &manifest))
	encoded, err := os.ReadFile("testdata/release-attestation.sigstore.json")
	must(t, err)
	trusted, err := root.NewTrustedRootFromPath("testdata/sigstore-trusted-root.json")
	must(t, err)
	for _, attack := range []string{"none", "artifact", "source commit", "signature"} {
		t.Run(attack, func(t *testing.T) {
			data := append([]byte{}, artifact...)
			commit := manifest.SourceCommit
			input := append([]byte{}, encoded...)
			switch attack {
			case "artifact":
				data[0] ^= 1
			case "source commit":
				commit = strings.Repeat("a", 40)
			case "signature":
				var value map[string]any
				must(t, json.Unmarshal(input, &value))
				sig := value["dsseEnvelope"].(map[string]any)["signatures"].([]any)[0].(map[string]any)
				s := sig["sig"].(string)
				prefix := "A"
				if s[:1] == prefix {
					prefix = "B"
				}
				sig["sig"] = prefix + s[1:]
				input, err = json.Marshal(value)
				must(t, err)
			}
			var b bundle.Bundle
			must(t, json.Unmarshal(input, &b))
			err := verifyProvenance(&b, data, commit, trusted)
			if attack == "none" {
				must(t, err)
			} else if err == nil {
				t.Fatal("accepted altered provenance")
			}
		})
	}
}

func TestPublisherPolicyRejectsEachWrongBinding(t *testing.T) {
	// This tests the application policy separately from the real cryptographic
	// fixture above. No synthetic result is described as verified evidence.
	base := `{"statement":{"predicateType":"https://slsa.dev/provenance/v1"},"signature":{"certificate":{"sourceRepositoryURI":"https://github.com/stubbi/asm","sourceRepositoryIdentifier":"1441332955","sourceRepositoryRef":"refs/heads/main","runnerEnvironment":"github-hosted","buildSignerURI":"https://github.com/stubbi/asm/.github/workflows/release.yml@refs/heads/main","sourceRepositoryDigest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","buildSignerDigest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}}`
	for _, field := range []string{"sourceRepositoryURI", "sourceRepositoryIdentifier", "sourceRepositoryRef", "runnerEnvironment", "buildSignerURI", "sourceRepositoryDigest", "buildSignerDigest"} {
		t.Run(field, func(t *testing.T) {
			var fields map[string]any
			must(t, json.Unmarshal([]byte(base), &fields))
			fields["signature"].(map[string]any)["certificate"].(map[string]any)[field] = "wrong"
			data, err := json.Marshal(fields)
			must(t, err)
			var result verify.VerificationResult
			must(t, decodePolicyResult(data, &result))
			if checkProvenanceResult(&result, "-") == nil {
				t.Fatal("accepted incorrect publisher binding")
			}
		})
	}
	var valid verify.VerificationResult
	must(t, decodePolicyResult([]byte(base), &valid))
	must(t, checkProvenanceResult(&valid, "-"))
	valid.Statement.PredicateType = "https://example.com/predicate"
	if checkProvenanceResult(&valid, "-") == nil {
		t.Fatal("accepted wrong predicate")
	}
}

func decodePolicyResult(data []byte, result *verify.VerificationResult) error {
	var decoded struct {
		Signature *verify.SignatureVerificationResult
		Statement map[string]string
	}
	if err := json.Unmarshal(data, &decoded); err != nil {
		return err
	}
	result.Signature = decoded.Signature
	result.Statement = &intoto.Statement{PredicateType: decoded.Statement["predicateType"]}
	return nil
}
