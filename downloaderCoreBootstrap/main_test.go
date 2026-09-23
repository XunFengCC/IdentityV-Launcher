package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type roundTripFunc func(*http.Request) (*http.Response, error)

func (function roundTripFunc) RoundTrip(request *http.Request) (*http.Response, error) {
	return function(request)
}

func fixtureManifest(payloads map[string][]byte) ComponentManifest {
	files := make([]ComponentFile, 0, 3)
	for _, name := range []string{"downloadIPC.exe", "OrbitSDK.dll", "aria2c.exe"} {
		hash := sha256.Sum256(payloads[name])
		files = append(files, ComponentFile{Filename: name, ByteCount: int64(len(payloads[name])), SHA256: hex.EncodeToString(hash[:])})
	}
	commit := strings.Repeat("a", 40)
	return ComponentManifest{
		SchemaVersion: 1,
		Component:     "netease-download-core",
		Acquisition: Acquisition{
			Mode:          "download-on-first-use",
			Repository:    "https://github.com/KKeygen/idv-login",
			Commit:        commit,
			SourceBaseURL: "https://raw.githubusercontent.com/KKeygen/idv-login/" + commit + "/binaries/",
		},
		RedistributionStatus: "not-bundled-download-on-first-use",
		Files:                files,
	}
}

func fixturePayloads() map[string][]byte {
	return map[string][]byte{
		"downloadIPC.exe": append([]byte("MZ"), bytes.Repeat([]byte{1}, 31)...),
		"OrbitSDK.dll":    append([]byte("MZ"), bytes.Repeat([]byte{2}, 19)...),
		"aria2c.exe":      append([]byte("MZ"), bytes.Repeat([]byte{3}, 23)...),
	}
}

func realTempDir(t *testing.T) string {
	t.Helper()
	directory, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	return directory
}

func clientFor(payloads map[string][]byte, truncate string) *http.Client {
	return &http.Client{Transport: roundTripFunc(func(request *http.Request) (*http.Response, error) {
		name := filepath.Base(request.URL.Path)
		payload := payloads[name]
		if name == truncate && len(payload) > 2 {
			payload = payload[:len(payload)-1]
		}
		return &http.Response{StatusCode: http.StatusOK, ContentLength: int64(len(payload)), Body: io.NopCloser(bytes.NewReader(payload)), Header: make(http.Header)}, nil
	})}
}

func TestInstallVerifyAndReuse(t *testing.T) {
	payloads := fixturePayloads()
	manifest := fixtureManifest(payloads)
	root := filepath.Join(realTempDir(t), "components", "netease-download-core")
	var events bytes.Buffer
	if err := install(context.Background(), manifest, root, clientFor(payloads, ""), &events); err != nil {
		t.Fatal(err)
	}
	version := filepath.Join(root, manifest.Acquisition.Commit)
	if err := verifyInstalled(version, manifest); err != nil {
		t.Fatal(err)
	}
	current, err := filepath.EvalSymlinks(filepath.Join(root, "current"))
	if err != nil || current != version {
		t.Fatal(current, err)
	}
	if !strings.Contains(events.String(), `"event":"completed"`) {
		t.Fatal(events.String())
	}
	if err = install(context.Background(), manifest, root, clientFor(nil, ""), io.Discard); err != nil {
		t.Fatal("verified install should be reused without network", err)
	}
}

func TestTruncatedDownloadLeavesNoVersionOrCurrent(t *testing.T) {
	payloads := fixturePayloads()
	manifest := fixtureManifest(payloads)
	root := filepath.Join(realTempDir(t), "components", "netease-download-core")
	if err := install(context.Background(), manifest, root, clientFor(payloads, "OrbitSDK.dll"), io.Discard); err == nil {
		t.Fatal("truncated download accepted")
	}
	if _, err := filepath.EvalSymlinks(filepath.Join(root, "current")); err == nil {
		t.Fatal("failed acquisition published current")
	}
	if _, err := filepath.EvalSymlinks(filepath.Join(root, manifest.Acquisition.Commit)); err == nil {
		t.Fatal("failed acquisition published version")
	}
}

func TestCorruptExistingVersionIsQuarantinedAndRecovered(t *testing.T) {
	payloads := fixturePayloads()
	manifest := fixtureManifest(payloads)
	root := filepath.Join(realTempDir(t), "components", "netease-download-core")
	if err := install(context.Background(), manifest, root, clientFor(payloads, ""), io.Discard); err != nil {
		t.Fatal(err)
	}
	version := filepath.Join(root, manifest.Acquisition.Commit)
	corrupt := bytes.Repeat([]byte{9}, len(payloads["OrbitSDK.dll"]))
	copy(corrupt[:2], []byte("MZ"))
	if err := os.WriteFile(filepath.Join(version, "OrbitSDK.dll"), corrupt, 0600); err != nil {
		t.Fatal(err)
	}
	var events bytes.Buffer
	if err := install(context.Background(), manifest, root, clientFor(payloads, ""), &events); err != nil {
		t.Fatal(err)
	}
	if err := verifyInstalled(version, manifest); err != nil {
		t.Fatal(err)
	}
	quarantined, err := filepath.Glob(filepath.Join(root, ".quarantine-"+manifest.Acquisition.Commit+"-*"))
	if err != nil || len(quarantined) != 1 {
		t.Fatal("corrupt version was not recoverably quarantined", quarantined, err)
	}
	if !strings.Contains(events.String(), `"event":"quarantined"`) {
		t.Fatal(events.String())
	}
}

func TestCurrentDirectoryIsQuarantined(t *testing.T) {
	payloads := fixturePayloads()
	manifest := fixtureManifest(payloads)
	root := filepath.Join(realTempDir(t), "components", "netease-download-core")
	if err := ensureRealDirectory(filepath.Join(root, "current")); err != nil {
		t.Fatal(err)
	}
	if err := install(context.Background(), manifest, root, clientFor(payloads, ""), io.Discard); err != nil {
		t.Fatal(err)
	}
	current, err := filepath.EvalSymlinks(filepath.Join(root, "current"))
	if err != nil || current != filepath.Join(root, manifest.Acquisition.Commit) {
		t.Fatal(current, err)
	}
	quarantined, err := filepath.Glob(filepath.Join(root, ".quarantine-current-*"))
	if err != nil || len(quarantined) != 1 {
		t.Fatal("invalid current directory was not quarantined", quarantined, err)
	}
}

func TestManifestAndDestinationSafety(t *testing.T) {
	payloads := fixturePayloads()
	manifest := fixtureManifest(payloads)
	manifest.Acquisition.SourceBaseURL = "https://example.com/binaries/"
	if validateManifest(manifest) == nil {
		t.Fatal("untrusted source accepted")
	}
	base := realTempDir(t)
	outside := realTempDir(t)
	link := filepath.Join(base, "linked")
	if err := os.Symlink(outside, link); err != nil {
		t.Fatal(err)
	}
	if err := ensureRealDirectory(filepath.Join(link, "component")); err == nil {
		t.Fatal("symlink destination accepted")
	}
}
