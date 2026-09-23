package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestAllowedHostUsesDNSBoundary(t *testing.T) {
	for host, want := range map[string]bool{
		"a50.gdl.easebar.com":         true,
		"gdl.easebar.com":             true,
		"gdl.easebar.com.example.org": false,
		"notgdl.easebar.com":          false,
		"a50.gdl.easebar.com.":        true,
	} {
		if got := allowedHost(host, allowedCDNSuffix); got != want {
			t.Fatalf("allowedHost(%q) = %t, want %t", host, got, want)
		}
	}
}

func TestResolveAcceptsOnlyApprovedRedirect(t *testing.T) {
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Location", "https://a50.gdl.easebar.com/123/Identity_V_setup.exe")
		w.WriteHeader(http.StatusFound)
	}))
	defer s.Close()

	// The production resolver URL has a fixed host.  Here we exercise the
	// redirect parser after supplying a request to a local test server.
	client := s.Client()
	client.CheckRedirect = func(_ *http.Request, _ []*http.Request) error { return http.ErrUseLastResponse }
	resp, err := client.Get(s.URL)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if err := validateFinalURL(resp.Header.Get("Location")); err != nil {
		t.Fatal(err)
	}
}

func TestRejectsUnsafeURLs(t *testing.T) {
	for _, raw := range []string{
		"http://api.loadingbay.com/app/v1/download_client/windows/mkt-h55-official/url",
		"https://api.loadingbay.com.example.org/app/v1/download_client/windows/mkt-h55-official/url",
		"https://api.loadingbay.com/app/v1/download_client/windows/mkt-h55-official/url?next=x",
	} {
		if err := validateResolver(raw); err == nil {
			t.Fatalf("accepted resolver %q", raw)
		}
	}
	for _, raw := range []string{
		"https://gdl.easebar.com.example.org/123/Identity_V_setup.exe",
		"http://a50.gdl.easebar.com/123/Identity_V_setup.exe",
		"https://a50.gdl.easebar.com/123/other.exe",
		"https://a50.gdl.easebar.com/123/Identity_V_setup.exe?token=x",
	} {
		if err := validateFinalURL(raw); err == nil {
			t.Fatalf("accepted CDN URL %q", raw)
		}
	}
}

func TestCapturedGlobalManifestFixture(t *testing.T) {
	read := func(name string, out any) {
		t.Helper()
		b, err := os.ReadFile(filepath.Join("fixtures", name))
		if err != nil {
			t.Fatal(err)
		}
		if err := json.Unmarshal(b, out); err != nil {
			t.Fatal(err)
		}
	}
	var appResponse envelope[appData]
	var contentResponse envelope[contentEnvelope]
	read("global-app-40.json", &appResponse)
	read("global-content-40.json", &contentResponse)
	if appResponse.Code != 200 || contentResponse.Code != 200 {
		t.Fatal("fixture is not an official success response")
	}
	m, err := buildManifest(appResponse.Data, contentResponse.Data.MainContent, time.Unix(0, 0))
	if err != nil {
		t.Fatal(err)
	}
	if m.AppID != 40 || m.GameID != "h55naxx2gb" || m.ContentID != 122 || !m.Oversea || m.StartupPath != "dwrg.exe" || len(m.Files) != 444 || len(m.Directories) != 18 {
		t.Fatalf("unexpected normalized fixture identity: %#v", m)
	}
	if m.TotalByteCount != 17602266736 || m.Files[0].URL == "" || !safeCDNFileURL(m.Files[0].URL) {
		t.Fatal("fixture did not preserve a safe official file contract")
	}
}
