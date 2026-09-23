package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/cespare/xxhash/v2"
)

type roundTrip func(*http.Request) (*http.Response, error)

func (f roundTrip) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func fixtureFile(data []byte) GlobalFile {
	return GlobalFile{Path: "tiny.bin", ByteCount: int64(len(data)), MD5: "900150983cd24fb0d6963f7d28e17f72", XXH64: "44bc2cf5ad770999", URL: "https://h55na-h.gdl.easebar.com/unit/tiny.bin", Operation: 1}
}
func testClient(data []byte) *http.Client {
	return &http.Client{Transport: roundTrip(func(r *http.Request) (*http.Response, error) {
		return &http.Response{StatusCode: http.StatusOK, ContentLength: int64(len(data)), Body: io.NopCloser(bytes.NewReader(data)), Header: make(http.Header), Request: r}, nil
	})}
}
func testManifest(data []byte) GlobalManifest {
	return GlobalManifest{SchemaVersion: 1, ProductID: "global", Adapter: "netease-loadingbay-global-v1", AppID: 40, GameID: "h55naxx2gb", DisplayName: "Identity V", StartupPath: "dwrg.exe", VersionCode: "v3_1_0123456789abcdef0123456789abcdef", ContentID: 122, TotalByteCount: int64(len(data)), Oversea: true, Files: []GlobalFile{fixtureFile(data)}}
}

func TestFetchVerifiedAndHashFailureRetainsPartial(t *testing.T) {
	data := []byte("abc")
	f := fixtureFile(data)
	if xxhash.Sum64(data) != 0x44bc2cf5ad770999 {
		t.Fatal("test vector changed")
	}
	d := t.TempDir()
	out := filepath.Join(d, "out.bin")
	if err := fetchVerified(context.Background(), testClient(data), f, out); err != nil {
		t.Fatal(err)
	}
	if got, err := os.ReadFile(out); err != nil || !bytes.Equal(got, data) {
		t.Fatal("verified output missing")
	}
	f.MD5 = "00000000000000000000000000000000"
	bad := filepath.Join(d, "bad.bin")
	if err := fetchVerified(context.Background(), testClient(data), f, bad); err == nil {
		t.Fatal("bad hash accepted")
	}
	if _, err := os.Stat(bad + ".partial"); err != nil {
		t.Fatal("failed download partial was not retained")
	}
}

func TestFetchVerifiedRequestsIdentityEncoding(t *testing.T) {
	data := []byte("abc")
	f := fixtureFile(data)
	client := &http.Client{Transport: roundTrip(func(request *http.Request) (*http.Response, error) {
		if request.Header.Get("Accept-Encoding") != "identity" {
			t.Fatalf("Accept-Encoding = %q, want identity", request.Header.Get("Accept-Encoding"))
		}
		return &http.Response{
			StatusCode:    http.StatusOK,
			ContentLength: int64(len(data)),
			Body:          io.NopCloser(bytes.NewReader(data)),
			Header:        make(http.Header),
			Request:       request,
		}, nil
	})}
	out := filepath.Join(t.TempDir(), "identity.bin")
	if err := fetchVerified(context.Background(), client, f, out); err != nil {
		t.Fatal(err)
	}
}

func TestRepairStagesThenPublishesAndBlocksLiveHotUpdate(t *testing.T) {
	data := []byte("abc")
	m := testManifest(data)
	root := filepath.Join(t.TempDir(), "game")
	if err := os.Mkdir(root, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "tiny.bin"), []byte("bad"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := repairTree(context.Background(), m, root, testClient(data)); err != nil {
		t.Fatal(err)
	}
	if !verifiedExisting(filepath.Join(root, "tiny.bin"), m.Files[0]) {
		t.Fatal("repair did not publish verified file")
	}
	if matches, _ := filepath.Glob(filepath.Join(root, ".identityv-global-repair-stage-*")); len(matches) != 0 {
		t.Fatal("repair stage leaked")
	}
	// A syntactically valid live marker must block before any CDN operation.
	m.Files = append(m.Files, GlobalFile{Path: "engine_version", ByteCount: 1, MD5: "0cc175b9c0f1b6a831c399e269772661", XXH64: "d24ec4f1a98c6e5b", URL: "https://h55na-h.gdl.easebar.com/unit/engine_version", Operation: 1})
	m.TotalByteCount++
	if err := os.WriteFile(filepath.Join(root, "engine_version"), []byte("release_2026_0828:0123456789abcdef0123456789abcdef01234567\n"), 0600); err != nil {
		t.Fatal(err)
	}
	called := false
	client := &http.Client{Transport: roundTrip(func(*http.Request) (*http.Response, error) {
		called = true
		return nil, errors.New("must not download")
	})}
	if err := repairTree(context.Background(), m, root, client); err == nil {
		t.Fatal("hot update marker accepted")
	}
	if called {
		t.Fatal("hot update block downloaded")
	}
}

func TestRepairRejectsSymlinkTarget(t *testing.T) {
	data := []byte("abc")
	m := testManifest(data)
	root := filepath.Join(t.TempDir(), "game")
	if err := os.Mkdir(root, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(t.TempDir(), "outside"), filepath.Join(root, "tiny.bin")); err != nil {
		t.Fatal(err)
	}
	if err := repairTree(context.Background(), m, root, testClient(data)); err == nil {
		t.Fatal("symlink target accepted")
	}
}

func TestFetchVerifiedAllowsUnknownLengthButStillVerifiesBody(t *testing.T) {
	data := []byte("abc")
	f := fixtureFile(data)
	client := &http.Client{Transport: roundTrip(func(request *http.Request) (*http.Response, error) {
		return &http.Response{
			StatusCode:    http.StatusOK,
			ContentLength: -1,
			Body:          io.NopCloser(bytes.NewReader(data)),
			Header:        make(http.Header),
			Request:       request,
		}, nil
	})}
	out := filepath.Join(t.TempDir(), "chunked.bin")
	if err := fetchVerified(context.Background(), client, f, out); err != nil {
		t.Fatal(err)
	}
	bad := filepath.Join(t.TempDir(), "chunked-bad.bin")
	if err := fetchVerified(context.Background(), testClientWithLength([]byte("bad"), -1), f, bad); err == nil {
		t.Fatal("unknown-length bad body accepted")
	}
	if _, err := os.Stat(bad + ".partial"); err != nil {
		t.Fatal("unknown-length hash failure did not retain partial")
	}
}

func testClientWithLength(data []byte, length int64) *http.Client {
	return &http.Client{Transport: roundTrip(func(r *http.Request) (*http.Response, error) {
		return &http.Response{StatusCode: http.StatusOK, ContentLength: length, Body: io.NopCloser(bytes.NewReader(data)), Header: make(http.Header), Request: r}, nil
	})}
}

func TestSmokeAndFullPublishHaveNoPartialPublication(t *testing.T) {
	data := []byte("abc")
	m := testManifest(data)
	if _, err := validateResolvedManifest(m); err != nil {
		t.Fatal(err)
	}
	d := t.TempDir()
	smoke := filepath.Join(d, "smoke.bin")
	if err := smokeFileWithClient(context.Background(), m, "tiny.bin", smoke, testClient(data)); err != nil {
		t.Fatal(err)
	}
	final := filepath.Join(d, "published")
	if err := downloadAllWithClient(context.Background(), m, final, testClient(data)); err != nil {
		t.Fatal(err)
	}
	if got, err := os.ReadFile(filepath.Join(final, "tiny.bin")); err != nil || !bytes.Equal(got, data) {
		t.Fatal("full publish missing verified file")
	}
	bad := m
	bad.Files = append([]GlobalFile(nil), m.Files...)
	bad.Files[0].MD5 = "00000000000000000000000000000000"
	badRoot := filepath.Join(d, "must-not-publish")
	if err := downloadAllWithClient(context.Background(), bad, badRoot, testClient(data)); err == nil {
		t.Fatal("bad hash accepted")
	}
	if _, err := os.Stat(badRoot); !os.IsNotExist(err) {
		t.Fatal("failed full download was published")
	}
}

func TestGlobalValidationRejectsURLAndPathEscapes(t *testing.T) {
	m := testManifest([]byte("abc"))
	m.Files[0].URL = "https://gdl.easebar.com.example.org/tiny.bin"
	if _, err := validateResolvedManifest(m); err == nil {
		t.Fatal("foreign CDN accepted")
	}
	m = testManifest([]byte("abc"))
	m.Files[0].Path = "../tiny.bin"
	if _, err := validateResolvedManifest(m); err == nil {
		t.Fatal("path escape accepted")
	}
}

func TestDeterministicStageResumesVerifiedFiles(t *testing.T) {
	data := []byte("abc")
	m := testManifest(data)
	d := t.TempDir()
	final := filepath.Join(d, "published")
	stage := final + ".stage"
	if err := os.Mkdir(stage, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(stage, "global-direct-manifest.json"), stageManifestJSON(m), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(stage, "tiny.bin"), data, 0600); err != nil {
		t.Fatal(err)
	}
	if err := downloadAllWithClient(context.Background(), m, final, &http.Client{Transport: roundTrip(func(*http.Request) (*http.Response, error) {
		t.Fatal("verified file was downloaded again")
		return nil, nil
	})}); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(final, "tiny.bin")); err != nil {
		t.Fatal(err)
	}
}

func TestDeterministicStageResumesAcrossFetchedAtChange(t *testing.T) {
	data := []byte("abc")
	old := testManifest(data)
	old.FetchedAt = "2026-08-29T00:00:00Z"
	current := old
	current.FetchedAt = "2026-08-29T00:01:00Z"
	d := t.TempDir()
	final := filepath.Join(d, "published")
	stage := final + ".stage"
	if err := os.Mkdir(stage, 0700); err != nil {
		t.Fatal(err)
	}
	// This deliberately writes the old full marker shape, proving installed
	// pre-canonical stages remain resumable.
	legacy, _ := json.MarshalIndent(old, "", "  ")
	if err := os.WriteFile(filepath.Join(stage, "global-direct-manifest.json"), append(legacy, '\n'), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(stage, "tiny.bin"), data, 0600); err != nil {
		t.Fatal(err)
	}
	client := &http.Client{Transport: roundTrip(func(*http.Request) (*http.Response, error) {
		t.Fatal("verified file was downloaded again after fetchedAt-only change")
		return nil, nil
	})}
	if err := downloadAllWithClient(context.Background(), current, final, client); err != nil {
		t.Fatal(err)
	}
}

func TestStageMarkerWritesCanonicalContentIdentity(t *testing.T) {
	m := testManifest([]byte("abc"))
	m.FetchedAt = "2026-08-29T00:00:00Z"
	var persisted GlobalManifest
	if err := json.Unmarshal(stageManifestJSON(m), &persisted); err != nil {
		t.Fatal(err)
	}
	if persisted.FetchedAt != "" {
		t.Fatalf("stage marker retained volatile fetchedAt %q", persisted.FetchedAt)
	}
	if !sameContentIdentity(persisted, m) {
		t.Fatal("canonical marker did not preserve content identity")
	}
}

func TestDeterministicStageRejectsContentIdentityChange(t *testing.T) {
	data := []byte("abc")
	base := testManifest(data)
	for name, changed := range map[string]GlobalManifest{
		"version": func() GlobalManifest { m := base; m.VersionCode = "v4_1_0123456789abcdef0123456789abcdef"; return m }(),
		"hash": func() GlobalManifest {
			m := base
			m.Files = append([]GlobalFile(nil), base.Files...)
			m.Files[0].MD5 = "00000000000000000000000000000000"
			return m
		}(),
		"path": func() GlobalManifest {
			m := base
			m.Files = append([]GlobalFile(nil), base.Files...)
			m.Files[0].Path = "different.bin"
			return m
		}(),
	} {
		t.Run(name, func(t *testing.T) {
			d := t.TempDir()
			final := filepath.Join(d, "published")
			stage := final + ".stage"
			if err := os.Mkdir(stage, 0700); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(stage, "global-direct-manifest.json"), stageManifestJSON(base), 0600); err != nil {
				t.Fatal(err)
			}
			if err := downloadAllWithClient(context.Background(), changed, final, testClient(data)); err == nil {
				t.Fatal("different content identity was accepted for resume")
			}
		})
	}
}

func TestVerifyTreeRejectsTamperedFile(t *testing.T) {
	data := []byte("abc")
	m := testManifest(data)
	d := t.TempDir()
	if err := os.WriteFile(filepath.Join(d, "tiny.bin"), data, 0600); err != nil {
		t.Fatal(err)
	}
	if err := verifyTree(m, d); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(d, "tiny.bin"), []byte("bad"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := verifyTree(m, d); err == nil {
		t.Fatal("tampered tree accepted")
	}
}

func TestCancelKeepsDeterministicStageAndNeverPublishes(t *testing.T) {
	data := []byte("abc")
	m := testManifest(data)
	d := t.TempDir()
	final := filepath.Join(d, "published")
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	started := make(chan struct{})
	stopped := make(chan struct{})
	client := &http.Client{Transport: roundTrip(func(r *http.Request) (*http.Response, error) {
		close(started)
		<-r.Context().Done()
		close(stopped)
		return nil, r.Context().Err()
	})}
	done := make(chan error, 1)
	go func() { done <- downloadAllWithClient(ctx, m, final, client) }()
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("request did not start")
	}
	cancel()
	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("want cancellation, got %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("download did not return after cancellation")
	}
	select {
	case <-stopped:
	case <-time.After(time.Second):
		t.Fatal("HTTP request context was not cancelled")
	}
	if _, err := os.Stat(final); !os.IsNotExist(err) {
		t.Fatal("cancelled destination was published")
	}
	if info, err := os.Stat(final + ".stage"); err != nil || !info.IsDir() {
		t.Fatal("deterministic stage not retained")
	}
}

func TestControlCancelAndMissingParentAreNonMutating(t *testing.T) {
	d := t.TempDir()
	control := filepath.Join(d, "not-created", "control.json")
	if err := waitForControl(context.Background(), control); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Dir(control)); !os.IsNotExist(err) {
		t.Fatal("control read created a managed parent")
	}
	if err := os.WriteFile(filepath.Join(d, "cancel.json"), []byte(`{"schemaVersion":1,"action":"cancel"}`), 0600); err != nil {
		t.Fatal(err)
	}
	if err := waitForControl(context.Background(), filepath.Join(d, "cancel.json")); !errors.Is(err, context.Canceled) {
		t.Fatalf("want cancel, got %v", err)
	}
}
