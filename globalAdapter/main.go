// IdentityVGlobalAdapter resolves both the official global-PC bootstrap installer
// and the separately validated direct game-content manifest. The latter uses
// LoadingBay's international product identity and must never be replaced with
// the mainland distribution/download-core protocol.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path"
	"regexp"
	"strings"
	"time"
)

const (
	resolverURL      = "https://api.loadingbay.com/app/v1/download_client/windows/mkt-h55-official/url"
	metadataOrigin   = "https://api.loadingbay.com"
	allowedCDNSuffix = "gdl.easebar.com"
	expectedFilename = "Identity_V_setup.exe"
	globalAppID      = 40
	globalGameID     = "h55naxx2gb"
	globalChannel    = "mkt-h55-official"
)

var versionPattern = regexp.MustCompile(`^v[0-9]+_[0-9]+_[0-9a-f]{32}$`)

type InstallerManifest struct {
	SchemaVersion       int    `json:"schemaVersion"`
	ProductID           string `json:"productId"`
	Adapter             string `json:"adapter"`
	Artifact            string `json:"artifact"`
	OfficialLandingPage string `json:"officialLandingPage"`
	ResolverURL         string `json:"resolverUrl"`
	FinalURL            string `json:"finalUrl"`
	Filename            string `json:"filename"`
	ResolvedAt          string `json:"resolvedAt"`
}

// GlobalManifest is the direct-download contract obtained from the global
// LoadingBay API.  Each file URL is already the official final CDN URL and is
// therefore validated independently of the API host.
type GlobalManifest struct {
	SchemaVersion  int          `json:"schemaVersion"`
	ProductID      string       `json:"productId"`
	Adapter        string       `json:"adapter"`
	AppID          int          `json:"appId"`
	GameID         string       `json:"gameId"`
	DisplayName    string       `json:"displayName"`
	StartupPath    string       `json:"startupPath"`
	VersionCode    string       `json:"versionCode"`
	ContentID      int          `json:"contentId"`
	TotalByteCount int64        `json:"totalByteCount"`
	Oversea        bool         `json:"oversea"`
	Files          []GlobalFile `json:"files"`
	Directories    []GlobalDir  `json:"directories"`
	FetchedAt      string       `json:"fetchedAt"`
}

type GlobalFile struct {
	Path      string `json:"path"`
	ByteCount int64  `json:"byteCount"`
	MD5       string `json:"md5"`
	XXH64     string `json:"xxh64"`
	URL       string `json:"url"`
	Operation int    `json:"operation"`
}

type GlobalDir struct {
	Path      string `json:"path"`
	Operation int    `json:"operation"`
}

type envelope[T any] struct {
	Code int `json:"code"`
	Data T   `json:"data"`
}
type appData struct {
	AppID       int    `json:"app_id"`
	AppName     string `json:"app_name"`
	ContentID   int    `json:"app_content_id"`
	DisplayName string `json:"display_name"`
	VersionCode string `json:"version_code"`
	StartupPath string `json:"startup_path"`
	GameID      string `json:"game_id"`
}
type contentEnvelope struct {
	MainContent contentData `json:"main_content"`
}
type contentData struct {
	VersionCode string        `json:"version_code"`
	ContentID   int           `json:"app_content_id"`
	Size        int64         `json:"size"`
	StartupPath string        `json:"startup_path"`
	Files       []contentFile `json:"files"`
	Directories []contentDir  `json:"directories"`
}
type contentFile struct {
	Path      string `json:"path"`
	MD5       string `json:"md5"`
	XXH       string `json:"xxh"`
	Size      int64  `json:"size"`
	URL       string `json:"url"`
	Operation int    `json:"op"`
}
type contentDir struct {
	Path      string `json:"path"`
	Operation int    `json:"op"`
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: IdentityVGlobalAdapter resolve-installer | resolve-manifest | smoke-file | download | verify-tree | repair")
		os.Exit(64)
	}
	if os.Args[1] == "smoke-file" || os.Args[1] == "download" || os.Args[1] == "verify-tree" || os.Args[1] == "repair" {
		if err := runDownloadCommand(os.Args[1], os.Args[2:]); err != nil {
			fmt.Fprintln(os.Stderr, "global downloader:", err)
			os.Exit(1)
		}
		return
	}
	if len(os.Args) != 2 || (os.Args[1] != "resolve-installer" && os.Args[1] != "resolve-manifest") {
		fmt.Fprintln(os.Stderr, "usage: IdentityVGlobalAdapter resolve-installer | resolve-manifest | smoke-file | download | verify-tree | repair")
		os.Exit(64)
	}
	var value any
	var err error
	if os.Args[1] == "resolve-installer" {
		value, err = resolve(context.Background(), newClient(), resolverURL, time.Now().UTC())
	} else {
		value, err = resolveManifest(context.Background(), newClient(), time.Now().UTC())
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "global adapter:", err)
		os.Exit(1)
	}
	if err := json.NewEncoder(os.Stdout).Encode(value); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func resolveManifest(ctx context.Context, client *http.Client, now time.Time) (GlobalManifest, error) {
	appURL := metadataOrigin + "/app/v1/game_library/app?force=1&app_id=40"
	contentURL := metadataOrigin + "/app/v1/file_distribution/download_app?app_id=40"
	var app envelope[appData]
	var content envelope[contentEnvelope]
	if err := fetchOfficialJSON(ctx, client, appURL, &app); err != nil {
		return GlobalManifest{}, err
	}
	if err := fetchOfficialJSON(ctx, client, contentURL, &content); err != nil {
		return GlobalManifest{}, err
	}
	if app.Code != http.StatusOK || content.Code != http.StatusOK {
		return GlobalManifest{}, errors.New("global LoadingBay API returned a non-success code")
	}
	return buildManifest(app.Data, content.Data.MainContent, now)
}

func fetchOfficialJSON(ctx context.Context, client *http.Client, raw string, out any) error {
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "https" || u.User != nil || u.Port() != "" || !strings.EqualFold(u.Hostname(), "api.loadingbay.com") {
		return errors.New("metadata URL is outside api.loadingbay.com")
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, raw, nil)
	if err != nil {
		return err
	}
	req.Header.Set("channel", globalChannel)
	req.Header.Set("Accept", "application/json")
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("metadata endpoint returned HTTP %d", resp.StatusCode)
	}
	limited := io.LimitReader(resp.Body, 32*1024*1024)
	decoder := json.NewDecoder(limited)
	if err := decoder.Decode(out); err != nil {
		return err
	}
	if decoder.Decode(&struct{}{}) != io.EOF {
		return errors.New("metadata response has trailing data")
	}
	return nil
}

func buildManifest(app appData, content contentData, now time.Time) (GlobalManifest, error) {
	if app.AppID != globalAppID || app.GameID != globalGameID || app.AppName != "Identity V" || app.DisplayName != "Identity V" || app.ContentID <= 0 || content.ContentID != app.ContentID || content.VersionCode != app.VersionCode || !versionPattern.MatchString(content.VersionCode) || !safePath(app.StartupPath) || app.StartupPath != "dwrg.exe" || content.StartupPath != app.StartupPath || content.Size < 0 || len(content.Files) == 0 || len(content.Files) > 100000 || len(content.Directories) > 100000 {
		return GlobalManifest{}, errors.New("global metadata identity or basic fields failed validation")
	}
	files := make([]GlobalFile, 0, len(content.Files))
	seen := make(map[string]struct{}, len(content.Files))
	var total int64
	for _, f := range content.Files {
		if !safePath(f.Path) || f.Size < 0 || f.Operation != 1 || !regexp.MustCompile(`^[0-9a-f]{32}$`).MatchString(f.MD5) || !regexp.MustCompile(`^[0-9a-f]{16}$`).MatchString(f.XXH) || !safeCDNFileURL(f.URL) {
			return GlobalManifest{}, fmt.Errorf("unsafe global file metadata for %q", f.Path)
		}
		key := strings.ToLower(f.Path)
		if _, ok := seen[key]; ok {
			return GlobalManifest{}, fmt.Errorf("duplicate global file path %q", f.Path)
		}
		seen[key] = struct{}{}
		next := total + f.Size
		if next < total {
			return GlobalManifest{}, errors.New("global manifest byte count overflow")
		}
		total = next
		files = append(files, GlobalFile{Path: f.Path, ByteCount: f.Size, MD5: f.MD5, XXH64: f.XXH, URL: f.URL, Operation: f.Operation})
	}
	if total != content.Size {
		return GlobalManifest{}, errors.New("global manifest declared size does not match files")
	}
	dirs := make([]GlobalDir, 0, len(content.Directories))
	for _, d := range content.Directories {
		if !safePath(d.Path) || d.Operation != 1 {
			return GlobalManifest{}, fmt.Errorf("unsafe global directory metadata for %q", d.Path)
		}
		dirs = append(dirs, GlobalDir{Path: d.Path, Operation: d.Operation})
	}
	return GlobalManifest{SchemaVersion: 1, ProductID: "global", Adapter: "netease-loadingbay-global-v1", AppID: globalAppID, GameID: globalGameID, DisplayName: app.DisplayName, StartupPath: app.StartupPath, VersionCode: content.VersionCode, ContentID: content.ContentID, TotalByteCount: total, Oversea: true, Files: files, Directories: dirs, FetchedAt: now.UTC().Format(time.RFC3339)}, nil
}

func safePath(p string) bool {
	if p == "" || len(p) > 4096 || strings.HasPrefix(p, "/") || strings.ContainsAny(p, "\\\\:\x00") {
		return false
	}
	for _, s := range strings.Split(p, "/") {
		if s == "" || s == "." || s == ".." {
			return false
		}
	}
	return true
}
func safeCDNFileURL(raw string) bool {
	u, err := url.Parse(raw)
	return err == nil && u.Scheme == "https" && u.User == nil && u.Port() == "" && u.RawQuery == "" && u.Fragment == "" && allowedHost(u.Hostname(), allowedCDNSuffix) && safePath(strings.TrimPrefix(u.EscapedPath(), "/"))
}

func newClient() *http.Client {
	return &http.Client{
		Timeout: 30 * time.Second,
		CheckRedirect: func(_ *http.Request, _ []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
}

func resolve(ctx context.Context, client *http.Client, rawResolver string, now time.Time) (InstallerManifest, error) {
	if err := validateResolver(rawResolver); err != nil {
		return InstallerManifest{}, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, rawResolver, nil)
	if err != nil {
		return InstallerManifest{}, err
	}
	resp, err := client.Do(req)
	if err != nil {
		return InstallerManifest{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusFound && resp.StatusCode != http.StatusTemporaryRedirect && resp.StatusCode != http.StatusSeeOther {
		return InstallerManifest{}, fmt.Errorf("expected official resolver redirect, got HTTP %d", resp.StatusCode)
	}
	location := resp.Header.Get("Location")
	if err := validateFinalURL(location); err != nil {
		return InstallerManifest{}, err
	}
	return InstallerManifest{
		SchemaVersion:       1,
		ProductID:           "global",
		Adapter:             "netease-loadingbay-global-installer-v1",
		Artifact:            "official-bootstrap-installer-only",
		OfficialLandingPage: "https://www.identityvgame.com/",
		ResolverURL:         rawResolver,
		FinalURL:            location,
		Filename:            expectedFilename,
		ResolvedAt:          now.UTC().Format(time.RFC3339),
	}, nil
}

func validateResolver(raw string) error {
	u, err := url.Parse(raw)
	if err != nil {
		return err
	}
	if u.Scheme != "https" || u.User != nil || u.Port() != "" || !strings.EqualFold(u.Hostname(), "api.loadingbay.com") || u.Path != "/app/v1/download_client/windows/mkt-h55-official/url" || u.RawQuery != "" || u.Fragment != "" {
		return errors.New("resolver is outside the approved global official endpoint")
	}
	return nil
}

func validateFinalURL(raw string) error {
	u, err := url.Parse(raw)
	if err != nil {
		return err
	}
	if u.Scheme != "https" || u.User != nil || u.Port() != "" || !allowedHost(u.Hostname(), allowedCDNSuffix) || u.RawQuery != "" || u.Fragment != "" || path.Base(u.Path) != expectedFilename {
		return errors.New("resolver returned an unapproved global installer URL")
	}
	return nil
}

func allowedHost(host, suffix string) bool {
	host = strings.TrimSuffix(strings.ToLower(host), ".")
	suffix = strings.TrimSuffix(strings.ToLower(suffix), ".")
	return host == suffix || strings.HasSuffix(host, "."+suffix)
}
