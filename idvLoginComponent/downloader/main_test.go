package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"regexp"
	"sync"
	"testing"
)

// Exercise the actual release manifest and its UI consumer together: a new
// manifest with an old downloader or old UI cache slot must fail the build.
func TestPinnedReleaseContract(t *testing.T) {
	b, err := os.ReadFile("../../idvLoginComponent.json")
	if err != nil {
		t.Fatal(err)
	}
	var m manifest
	if err = json.Unmarshal(b, &m); err != nil {
		t.Fatal(err)
	}
	if err = validatePinned(m); err != nil {
		t.Fatal(err)
	}
	ui, err := os.ReadFile("../../playerLauncherApp/Sources/ToolboxModels.swift")
	if err != nil {
		t.Fatal(err)
	}
	re := regexp.MustCompile(`(?s)enum IdvLoginRelease\s*\{\s*static let version = "([^"]+)"`)
	match := re.FindSubmatch(ui)
	if len(match) != 2 || string(match[1]) != m.Version {
		t.Fatal("UI and pinned component versions disagree")
	}
	bad := m
	bad.SHA256 = "0000000000000000000000000000000000000000000000000000000000000000"
	if validatePinned(bad) == nil {
		t.Fatal("substituted payload digest accepted")
	}
	bad = m
	bad.DownloadURL = "https://github.com/another-owner/another-repo/releases/download/v6.3.0/asset"
	if validatePinned(bad) == nil {
		t.Fatal("different GitHub release accepted")
	}
}

func payload() []byte {
	b := make([]byte, 4096)
	copy(b, []byte{0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0, 0, 0})
	for i := 8; i < len(b); i++ {
		b[i] = byte(i)
	}
	return b
}
func testManifest(url string, b []byte) manifest {
	h := sha256.Sum256(b)
	return manifest{AssetName: "idv-login-v6.2.3-stable-mac", DownloadURL: url, SHA256: hex.EncodeToString(h[:]), ByteSize: int64(len(b))}
}
func server(t *testing.T, body []byte, mode string) *httptest.Server {
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Range") != "" && mode == "range" {
			var start int
			_, e := fmt.Sscanf(r.Header.Get("Range"), "bytes=%d-", &start)
			if e != nil {
				t.Fatal(e)
			}
			w.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", start, len(body)-1, len(body)))
			w.Header().Set("Content-Length", fmt.Sprint(len(body)-start))
			w.WriteHeader(206)
			_, _ = w.Write(body[start:])
			return
		}
		if r.Header.Get("Range") != "" && mode == "bad" {
			w.Header().Set("Content-Range", "bytes 0-1/2")
			w.WriteHeader(206)
			return
		}
		w.Header().Set("Content-Length", fmt.Sprint(len(body)))
		_, _ = w.Write(body)
	}))
}

func TestFullCacheAndLegacy(t *testing.T) {
	b := payload()
	root := t.TempDir()
	cache := filepath.Join(root, "6.2.3")
	if err := os.Mkdir(cache, 0700); err != nil {
		t.Fatal(err)
	}
	m := testManifest("http://unused", b)
	if err := os.WriteFile(filepath.Join(cache, m.AssetName), b, 0600); err != nil {
		t.Fatal(err)
	}
	got, e := download(m, cache, &http.Client{})
	if e != nil || got == "" {
		t.Fatalf("%v %q", e, got)
	}
	root = t.TempDir()
	cache = filepath.Join(root, "6.2.3")
	old := filepath.Join(root, "123e4567-e89b-12d3-a456-426614174000")
	if err := os.Mkdir(old, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(old, m.AssetName), b, 0600); err != nil {
		t.Fatal(err)
	}
	got, e = download(m, cache, &http.Client{})
	if e != nil {
		t.Fatal(e)
	}
	if e = regularArm64(got, m); e != nil {
		t.Fatal(e)
	}
}

func TestCompletePartialPublishesWithoutNetwork(t *testing.T) {
	b := payload()
	cache := filepath.Join(t.TempDir(), "6.2.3")
	if err := os.Mkdir(cache, 0700); err != nil {
		t.Fatal(err)
	}
	m := testManifest("http://must-not-be-used.invalid", b)
	partial := filepath.Join(cache, m.AssetName+".partial")
	if err := os.WriteFile(partial, b, 0600); err != nil {
		t.Fatal(err)
	}
	client := &http.Client{Transport: roundTripFunc(func(*http.Request) (*http.Response, error) {
		t.Fatal("complete partial unexpectedly reached the network")
		return nil, nil
	})}
	got, err := download(m, cache, client)
	if err != nil {
		t.Fatal(err)
	}
	if err = regularArm64(got, m); err != nil {
		t.Fatal(err)
	}
	if _, err = os.Lstat(partial); !os.IsNotExist(err) {
		t.Fatalf("complete partial was not atomically published: %v", err)
	}
}

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }
func TestRangeAndFallback(t *testing.T) {
	b := payload()
	s := server(t, b, "range")
	defer s.Close()
	m := testManifest(s.URL, b)
	cache := t.TempDir()
	if err := os.WriteFile(filepath.Join(cache, m.AssetName+".partial"), b[:100], 0600); err != nil {
		t.Fatal(err)
	}
	if _, e := download(m, cache, s.Client()); e != nil {
		t.Fatal(e)
	}
	s = server(t, b, "full")
	defer s.Close()
	m = testManifest(s.URL, b)
	cache = t.TempDir()
	if err := os.WriteFile(filepath.Join(cache, m.AssetName+".partial"), b[:100], 0600); err != nil {
		t.Fatal(err)
	}
	if _, e := download(m, cache, s.Client()); e != nil {
		t.Fatal(e)
	}
}
func TestBadRangeHashAndLock(t *testing.T) {
	b := payload()
	s := server(t, b, "bad")
	defer s.Close()
	m := testManifest(s.URL, b)
	cache := t.TempDir()
	_ = os.WriteFile(filepath.Join(cache, m.AssetName+".partial"), b[:10], 0600)
	if _, e := download(m, cache, s.Client()); e == nil {
		t.Fatal("bad range accepted")
	}
	bad := append([]byte(nil), b...)
	bad[100] ^= 1
	s = server(t, bad, "full")
	defer s.Close()
	m = testManifest(s.URL, b)
	cache = t.TempDir()
	if _, e := download(m, cache, s.Client()); e == nil {
		t.Fatal("bad hash accepted")
	}
	if _, e := os.Stat(filepath.Join(cache, m.AssetName+".partial")); !os.IsNotExist(e) {
		t.Fatal("bad partial retained")
	}
	l, e := lockCache(cache)
	if e != nil {
		t.Fatal(e)
	}
	var wg sync.WaitGroup
	wg.Add(1)
	done := make(chan struct{})
	go func() {
		defer wg.Done()
		x, e := lockCache(cache)
		if e == nil {
			unlock(x)
			close(done)
		}
	}()
	select {
	case <-done:
		t.Fatal("lock not exclusive")
	default:
	}
	unlock(l)
	wg.Wait()
	select {
	case <-done:
	default:
		t.Fatal("lock not released")
	}
}
