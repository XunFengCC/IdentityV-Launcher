package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"debug/macho"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func machoFixture(order binary.ByteOrder, wide bool, command, platform, version uint32) []byte {
	header, magic := 28, uint32(macho.Magic32)
	if wide {
		header, magic = 32, macho.Magic64
	}
	length := 16
	if command == 0x32 {
		length = 24
	}
	b := make([]byte, header+length)
	for i, v := range []uint32{magic, uint32(macho.CpuArm64), 0, 6, 1, uint32(length), 0} {
		order.PutUint32(b[i*4:], v)
	}
	order.PutUint32(b[header:], command)
	order.PutUint32(b[header+4:], uint32(length))
	if command == 0x32 {
		order.PutUint32(b[header+8:], platform)
		order.PutUint32(b[header+12:], version)
	} else {
		order.PutUint32(b[header+8:], version)
	}
	return b
}

func fatMachOFixture(slices ...[]byte) []byte {
	b := make([]byte, 8+20*len(slices))
	binary.BigEndian.PutUint32(b, macho.MagicFat)
	binary.BigEndian.PutUint32(b[4:], uint32(len(slices)))
	for i, slice := range slices {
		copySlice := append([]byte(nil), slice...)
		binary.LittleEndian.PutUint32(copySlice[8:], uint32(i))
		for j, v := range []uint32{uint32(macho.CpuArm64), uint32(i), uint32(len(b)), uint32(len(slice)), 0} {
			binary.BigEndian.PutUint32(b[8+i*20+j*4:], v)
		}
		b = append(b, copySlice...)
	}
	return b
}

func TestMachODeploymentTargetsWithoutDeveloperTools(t *testing.T) {
	// An empty PATH ensures the fixtures need no compiler or inspection tool.
	t.Setenv("PATH", t.TempDir())
	thin := func(cmd, platform, version uint32) []byte {
		return machoFixture(binary.LittleEndian, true, cmd, platform, version)
	}
	good := thin(0x32, 1, 15<<16)
	mutate := func(input []byte, offset int, value uint32) []byte {
		b := append([]byte(nil), input...)
		binary.LittleEndian.PutUint32(b[offset:], value)
		return b
	}
	withTool := append(mutate(good, 52, 1), make([]byte, 8)...)
	withTool = mutate(mutate(withTool, 20, 32), 36, 32)
	cases := []struct {
		name  string
		data  []byte
		limit string
		ok    bool
	}{
		{"build equal", good, "15.0", true},
		{"build tools", withTool, "15", true},
		{"legacy", thin(0x24, 0, 14<<16|6<<8|1), "15", true},
		{"big endian 32", machoFixture(binary.BigEndian, false, 0x24, 0, 15<<16), "15", true},
		{"fat", fatMachOFixture(good, thin(0x24, 0, 14<<16)), "15", true},
		{"high major", thin(0x32, 1, 16<<16), "15", false},
		{"high minor", thin(0x24, 0, 15<<16|1<<8), "15.0.9", false},
		{"high patch", thin(0x32, 1, 15<<16|2), "15.0.1", false},
		{"ios", thin(0x32, 2, 14<<16), "15", false},
		{"legacy ios", thin(0x25, 0, 14<<16), "15", false},
		{"missing", thin(0x777, 0, 0), "15", false},
		{"fat high second", fatMachOFixture(good, thin(0x24, 0, 16<<16)), "15", false},
		{"fat missing second", fatMachOFixture(good, thin(0x777, 0, 0)), "15", false},
		{"fat truncated", fatMachOFixture(good)[:40], "15", false},
		{"header truncated", good[:27], "15", false},
		{"command truncated", good[:len(good)-1], "15", false},
		{"short build", mutate(thin(0x24, 0, 15<<16), 32, 0x32), "15", false},
		{"short legacy", mutate(good, 32, 0x24), "15", false},
		{"bad command size", mutate(good, 36, 7), "15", false},
		{"bad tool count", mutate(good, 52, 1), "15", false},
		{"bad command count", mutate(good, 16, 0), "15", false},
		{"too many commands", mutate(good, 16, 2), "15", false},
		{"invalid magic", []byte("bad magic"), "15", false},
		{"empty fat", fatMachOFixture(), "15", false},
		{"invalid limit", good, "", false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "fixture.dylib")
			if err := os.WriteFile(path, tc.data, 0600); err != nil {
				t.Fatal(err)
			}
			err := verifyMachOMinOS(path, tc.limit)
			if (err == nil) != tc.ok {
				t.Fatalf("accepted=%v, want %v: %v", err == nil, tc.ok, err)
			}
		})
	}
}

func fixtureHash(b []byte) string { s := sha256.Sum256(b); return hex.EncodeToString(s[:]) }
func fixtureManifest() manifest {
	b := []byte("runtime")
	h := fixtureHash(b)
	return manifest{SchemaVersion: 1, Component: "wine-runtime", Version: "fixture-r1", MinimumMacOS: "15.0", Source: sourceSpec{URL: "https://github.com/example/release.dmg", AllowedRedirectHosts: []string{"github.com"}, ByteCount: 2, SHA256: stringsRepeat("a", 64), RuntimeRoot: "App.app/Contents/Resources/runtime"}, SourceVerificationFiles: []fileSpec{{RelativePath: "bin/wine", SHA256: h, Executable: true}}, Patches: []patchSpec{{PatchRelativePath: "winemac.so", TargetRelativePath: "lib/winemac.so", SHA256: h, MachOMinOSAtMost: "15.0"}, {PatchRelativePath: "gmp", TargetRelativePath: "lib/gmp", SHA256: h, MachOMinOSAtMost: "15.0"}, {PatchRelativePath: "pcre", TargetRelativePath: "lib/pcre", SHA256: h, MachOMinOSAtMost: "15.0"}, {PatchRelativePath: "zstd", TargetRelativePath: "lib/zstd", SHA256: h, MachOMinOSAtMost: "15.0"}}, FinalVerificationFiles: []fileSpec{{RelativePath: "bin/wine", SHA256: h, Executable: true}}}
}
func stringsRepeat(s string, n int) string {
	var b bytes.Buffer
	for i := 0; i < n; i++ {
		b.WriteString(s)
	}
	return b.String()
}
func TestManifestRejectsBadURLHashAndPaths(t *testing.T) {
	m := fixtureManifest()
	if err := validateManifest(m); err != nil {
		t.Fatal(err)
	}
	m.Source.URL = "http://github.com/x"
	if validateManifest(m) == nil {
		t.Fatal("accepted insecure URL")
	}
	m = fixtureManifest()
	m.Source.SHA256 = "bad"
	if validateManifest(m) == nil {
		t.Fatal("accepted bad source hash")
	}
	m = fixtureManifest()
	m.Patches[0].TargetRelativePath = "../escape"
	if validateManifest(m) == nil {
		t.Fatal("accepted escaping patch")
	}
	m = fixtureManifest()
	m.Source.AllowedRedirectHosts = []string{"evil.example"}
	if validateManifest(m) == nil {
		t.Fatal("accepted source host outside allowlist")
	}
}
func TestVerifyTreeRejectsSymlinkAndHashMismatch(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "bin"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "bin/wine"), []byte("runtime"), 0700); err != nil {
		t.Fatal(err)
	}
	m := fixtureManifest()
	if err := verifyTree(root, m.FinalVerificationFiles, false); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(filepath.Join(root, "bin/wine")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("elsewhere", filepath.Join(root, "bin/wine")); err != nil {
		t.Fatal(err)
	}
	if err := verifyTree(root, m.FinalVerificationFiles, false); err == nil {
		t.Fatal("accepted symlink")
	}
}
func TestExistingCurrentRefusesOverwrite(t *testing.T) {
	root := t.TempDir()
	if err := os.Symlink("old", filepath.Join(root, "current")); err != nil {
		t.Fatal(err)
	}
	m := fixtureManifest()
	if err := install(nil, m, root, t.TempDir(), os.Stderr); err == nil {
		t.Fatal("accepted overwriting current")
	}
}

func writeFinalFixture(t *testing.T, root string, m manifest) string {
	t.Helper()
	final := filepath.Join(root, m.Version)
	if err := os.MkdirAll(filepath.Join(final, "bin"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(final, "bin", "wine"), []byte("runtime"), 0700); err != nil {
		t.Fatal(err)
	}
	return final
}

func TestRecoverPublishedRuntimeRestoresCurrentAfterCrashWindow(t *testing.T) {
	root := t.TempDir()
	m := fixtureManifest()
	writeFinalFixture(t, root, m) // Simulates crash immediately after os.Rename(runtimeStage, final).
	recovered, err := recoverPublishedRuntime(m, root, false)
	if err != nil || !recovered {
		t.Fatalf("did not recover published runtime: recovered=%v err=%v", recovered, err)
	}
	target, err := os.Readlink(filepath.Join(root, "current"))
	if err != nil || target != m.Version {
		t.Fatalf("unexpected restored current link: target=%q err=%v", target, err)
	}
}

func TestRecoverPublishedRuntimeIsIdempotent(t *testing.T) {
	root := t.TempDir()
	m := fixtureManifest()
	writeFinalFixture(t, root, m)
	if err := os.Symlink(m.Version, filepath.Join(root, "current")); err != nil {
		t.Fatal(err)
	}
	recovered, err := recoverPublishedRuntime(m, root, false)
	if err != nil || !recovered {
		t.Fatalf("did not accept already-complete runtime: recovered=%v err=%v", recovered, err)
	}
}

func TestRecoverPublishedRuntimeFailsClosedOnConflictingCurrent(t *testing.T) {
	root := t.TempDir()
	m := fixtureManifest()
	writeFinalFixture(t, root, m)
	if err := os.Symlink("another-version", filepath.Join(root, "current")); err != nil {
		t.Fatal(err)
	}
	if _, err := recoverPublishedRuntime(m, root, false); err == nil {
		t.Fatal("accepted conflicting current link")
	}
}

func TestRecoverPublishedRuntimeRejectsInvalidFinalBeforeLinking(t *testing.T) {
	root := t.TempDir()
	m := fixtureManifest()
	final := filepath.Join(root, m.Version)
	if err := os.MkdirAll(final, 0700); err != nil {
		t.Fatal(err)
	}
	if _, err := recoverPublishedRuntime(m, root, false); err == nil {
		t.Fatal("accepted unverified final runtime")
	}
	if _, err := os.Lstat(filepath.Join(root, "current")); !os.IsNotExist(err) {
		t.Fatalf("created current despite invalid final: %v", err)
	}
}

func TestDownloadProgressIsBoundedAndMachineReadable(t *testing.T) {
	payload := bytes.Repeat([]byte("x"), 100)
	var destination, progress bytes.Buffer
	if err := writeVerifiedWithProgress(&destination, bytes.NewReader(payload), int64(len(payload)), fixtureHash(payload), &progress); err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSpace(progress.String()), "\n")
	if len(lines) != 1 { // A single large source read still produces one meaningful update.
		t.Fatalf("unexpected progress line count %d: %q", len(lines), progress.String())
	}
	if !strings.Contains(lines[0], "stage=download bytes=100 total=100 percent=100") {
		t.Fatalf("progress was not machine-readable: %q", progress.String())
	}
}

func TestPartialDownloadFixtureIsRejected(t *testing.T) {
	payload := []byte("full runtime fixture")
	if err := writeVerified(io.Discard, bytes.NewReader(payload[:len(payload)-1]), int64(len(payload)), fixtureHash(payload)); err == nil {
		t.Fatal("accepted partial runtime download")
	}
}

func TestDownloadCancellationStopsHTTPStream(t *testing.T) {
	started := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Length", "4194304")
		w.WriteHeader(http.StatusOK)
		if _, err := w.Write(bytes.Repeat([]byte("x"), 1024)); err != nil {
			return
		}
		if f, ok := w.(http.Flusher); ok {
			f.Flush()
		}
		close(started)
		<-r.Context().Done()
	}))
	defer server.Close()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	url := server.URL
	m := fixtureManifest()
	m.Source.URL = url
	m.Source.AllowedRedirectHosts = []string{strings.TrimPrefix(url, "http://")}
	m.Source.ByteCount = 4 * 1024 * 1024
	target := filepath.Join(t.TempDir(), "runtime.dmg")
	result := make(chan error, 1)
	go func() { result <- download(ctx, m, target, io.Discard) }()
	select {
	case <-started:
		cancel()
	case <-time.After(3 * time.Second):
		t.Fatal("test server did not begin streaming")
	}
	select {
	case err := <-result:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("expected cancellation, got %v", err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("download did not return after context cancellation")
	}
}
