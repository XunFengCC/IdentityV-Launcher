package main

import (
	"context"
	"crypto/md5"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"syscall"
	"time"

	"github.com/cespare/xxhash/v2"
)

func runDownloadCommand(command string, args []string) error {
	fs := flag.NewFlagSet(command, flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	manifestPath := fs.String("manifest", "", "absolute global manifest JSON")
	destination := fs.String("destination", "", "absolute destination directory")
	control := fs.String("control", "", "optional absolute control JSON")
	filePath := fs.String("path", "", "manifest-relative file path (smoke-file only)")
	if fs.Parse(args) != nil || *manifestPath == "" || *destination == "" || (command == "smoke-file" && *filePath == "") {
		return errors.New("usage: smoke-file/download/verify-tree/repair --manifest ABS --destination ABS")
	}
	m, err := readGlobalManifest(*manifestPath)
	if err != nil {
		return err
	}
	ctx, stop := signalContext()
	defer stop()
	if command == "smoke-file" {
		return smokeFile(ctx, m, *filePath, *destination)
	}
	if command == "verify-tree" {
		return verifyTree(m, *destination)
	}
	if command == "repair" {
		return repairTree(ctx, m, *destination, downloadClient())
	}
	return downloadAllWithControl(ctx, m, *destination, *control)
}

// repairTree intentionally never streams a replacement into the live game
// tree.  It first downloads every missing/corrupt manifest item into a private
// sibling stage, verifies both official hashes, then atomically renames each
// completed file over its existing counterpart.  An interruption therefore
// leaves either the old file or a fully verified new file, never a half file.
func repairTree(ctx context.Context, m GlobalManifest, root string, client *http.Client) error {
	if !filepath.IsAbs(root) {
		return errors.New("repair root must be absolute")
	}
	info, err := os.Lstat(root)
	if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return errors.New("repair root must be a real directory")
	}
	var repairs []GlobalFile
	for _, f := range m.Files {
		target, err := safeTreeTarget(root, f.Path)
		if err != nil {
			return err
		}
		if !verifiedExisting(target, f) {
			repairs = append(repairs, f)
		}
	}
	// A live engine_version marker means the running game has legitimately
	// patched itself past this base manifest.  Do this after scan but before
	// creating a stage, downloading, or replacing anything.
	if containsEngineVersion(repairs) && validEngineVersion(filepath.Join(root, "engine_version")) {
		return errors.New("game hot-update marker detected; use the game's own update/repair first")
	}
	if len(repairs) == 0 {
		fmt.Println("{\"schemaVersion\":1,\"repairs\":0,\"valid\":true}")
		return nil
	}
	stage := filepath.Join(root, ".identityv-global-repair-stage-"+fmt.Sprintf("%d", os.Getpid()))
	if err := os.Mkdir(stage, 0700); err != nil {
		return err
	}
	defer os.RemoveAll(stage) // private, never published; cleanup is best-effort only.
	for _, f := range repairs {
		if err := ctx.Err(); err != nil {
			return err
		}
		out, err := safeTreeTarget(stage, f.Path)
		if err != nil {
			return err
		}
		if err := fetchVerified(ctx, client, f, out); err != nil {
			return err
		}
	}
	// Recheck all staging files before the first publication.  This also makes
	// a future fetch implementation unable to weaken the publish boundary.
	for _, f := range repairs {
		candidate, _ := safeTreeTarget(stage, f.Path)
		if !verifiedExisting(candidate, f) {
			return fmt.Errorf("staged repair verification failed for %q", f.Path)
		}
	}
	// Cancellation remains effective through scanning and staging.  Once the
	// first rename happens, however, we deliberately finish this tiny local
	// publish critical section: stopping between two renames would leave a
	// mixed-version tree.  Preflight every live destination before that point.
	if err := ctx.Err(); err != nil {
		return err
	}
	for _, f := range repairs {
		target, err := safeTreeTarget(root, f.Path)
		if err != nil {
			return err
		}
		if err := os.MkdirAll(filepath.Dir(target), 0700); err != nil {
			return err
		}
		if err := rejectSymlinkParents(root, filepath.Dir(target)); err != nil {
			return err
		}
	}
	for _, f := range repairs {
		source, _ := safeTreeTarget(stage, f.Path)
		target, err := safeTreeTarget(root, f.Path)
		if err != nil {
			return err
		}
		if err := os.Rename(source, target); err != nil {
			return err
		}
	}
	if err := verifyTree(m, root); err != nil {
		return err
	}
	fmt.Printf("{\"schemaVersion\":1,\"repairs\":%d,\"valid\":true}\n", len(repairs))
	return nil
}

func safeTreeTarget(root, rel string) (string, error) {
	if !safePath(rel) {
		return "", errors.New("unsafe repair path")
	}
	target := filepath.Join(root, filepath.FromSlash(rel))
	cleanRoot, cleanTarget := filepath.Clean(root), filepath.Clean(target)
	if cleanTarget == cleanRoot || !strings.HasPrefix(cleanTarget, cleanRoot+string(os.PathSeparator)) {
		return "", errors.New("repair path escapes root")
	}
	if err := rejectSymlinkParents(cleanRoot, filepath.Dir(cleanTarget)); err != nil {
		return "", err
	}
	if i, err := os.Lstat(cleanTarget); err == nil && i.Mode()&os.ModeSymlink != 0 {
		return "", errors.New("repair target is a symbolic link")
	}
	return cleanTarget, nil
}
func rejectSymlinkParents(root, parent string) error {
	root, parent = filepath.Clean(root), filepath.Clean(parent)
	for p := parent; ; p = filepath.Dir(p) {
		i, err := os.Lstat(p)
		if err == nil && i.Mode()&os.ModeSymlink != 0 {
			return errors.New("repair parent is a symbolic link")
		}
		if p == root {
			break
		}
		if p == filepath.Dir(p) {
			return errors.New("repair parent escapes root")
		}
	}
	return nil
}
func containsEngineVersion(files []GlobalFile) bool {
	for _, f := range files {
		if f.Path == "engine_version" {
			return true
		}
	}
	return false
}
func validEngineVersion(marker string) bool {
	i, err := os.Lstat(marker)
	if err != nil || !i.Mode().IsRegular() || i.Mode()&os.ModeSymlink != 0 || i.Size() < 1 || i.Size() > 256 {
		return false
	}
	b, err := os.ReadFile(marker)
	if err != nil {
		return false
	}
	ok, _ := regexp.Match(`^release_[0-9]{4}_[0-9]{4}:[0-9A-Fa-f]{40}\r?\n?$`, b)
	return ok
}

func verifyTree(m GlobalManifest, root string) error {
	if !filepath.IsAbs(root) {
		return errors.New("tree path must be absolute")
	}
	info, err := os.Lstat(root)
	if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return errors.New("tree must be a real directory")
	}
	for _, f := range m.Files {
		candidate := filepath.Join(root, filepath.FromSlash(f.Path))
		if !verifiedExisting(candidate, f) {
			return fmt.Errorf("tree verification failed for %q", f.Path)
		}
	}
	return nil
}

func readGlobalManifest(p string) (GlobalManifest, error) {
	if !filepath.IsAbs(p) {
		return GlobalManifest{}, errors.New("manifest path must be absolute")
	}
	i, err := os.Lstat(p)
	if err != nil || !i.Mode().IsRegular() || i.Mode()&os.ModeSymlink != 0 || i.Size() > 32<<20 {
		return GlobalManifest{}, errors.New("manifest must be a bounded real regular file")
	}
	b, err := os.ReadFile(p)
	if err != nil {
		return GlobalManifest{}, err
	}
	var m GlobalManifest
	decoder := json.NewDecoder(strings.NewReader(string(b)))
	decoder.DisallowUnknownFields()
	if err = decoder.Decode(&m); err != nil {
		return GlobalManifest{}, errors.New("invalid global manifest JSON")
	}
	if decoder.Decode(&struct{}{}) != io.EOF {
		return GlobalManifest{}, errors.New("manifest has trailing data")
	}
	return validateResolvedManifest(m)
}

func validateResolvedManifest(m GlobalManifest) (GlobalManifest, error) {
	if m.SchemaVersion != 1 || m.ProductID != "global" || m.Adapter != "netease-loadingbay-global-v1" || m.AppID != globalAppID || m.GameID != globalGameID || m.DisplayName != "Identity V" || m.StartupPath != "dwrg.exe" || !m.Oversea || !versionPattern.MatchString(m.VersionCode) || m.ContentID <= 0 || len(m.Files) == 0 || len(m.Files) > 100000 || len(m.Directories) > 100000 {
		return GlobalManifest{}, errors.New("unsupported global manifest identity")
	}
	seen := map[string]struct{}{}
	var total int64
	for _, f := range m.Files {
		if !safePath(f.Path) || f.Operation != 1 || f.ByteCount < 0 || !md5Pattern(f.MD5) || !xxhPattern(f.XXH64) || !safeCDNFileURL(f.URL) {
			return GlobalManifest{}, fmt.Errorf("unsafe file %q", f.Path)
		}
		if _, ok := seen[strings.ToLower(f.Path)]; ok {
			return GlobalManifest{}, fmt.Errorf("duplicate file %q", f.Path)
		}
		seen[strings.ToLower(f.Path)] = struct{}{}
		n := total + f.ByteCount
		if n < total {
			return GlobalManifest{}, errors.New("manifest byte overflow")
		}
		total = n
	}
	if total != m.TotalByteCount {
		return GlobalManifest{}, errors.New("manifest total mismatch")
	}
	for _, d := range m.Directories {
		if !safePath(d.Path) || d.Operation != 1 {
			return GlobalManifest{}, fmt.Errorf("unsafe directory %q", d.Path)
		}
	}
	return m, nil
}

func md5Pattern(v string) bool {
	if len(v) != 32 {
		return false
	}
	_, e := hex.DecodeString(v)
	return e == nil && v == strings.ToLower(v)
}
func xxhPattern(v string) bool {
	if len(v) != 16 {
		return false
	}
	_, e := hex.DecodeString(v)
	return e == nil && v == strings.ToLower(v)
}

func downloadClient() *http.Client {
	return &http.Client{Timeout: 10 * time.Minute, CheckRedirect: func(_ *http.Request, _ []*http.Request) error { return http.ErrUseLastResponse }}
}

func fetchVerified(ctx context.Context, client *http.Client, f GlobalFile, out string) error {
	if err := os.MkdirAll(filepath.Dir(out), 0700); err != nil {
		return err
	}
	partial := out + ".partial"
	if _, err := os.Lstat(partial); err == nil {
		return errors.New("partial output already exists; retain it for inspection")
	} else if !os.IsNotExist(err) {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, f.URL, nil)
	if err != nil {
		return err
	}
	// Go's default Transport advertises gzip and transparently decodes textual
	// CDN objects. In that mode Response.ContentLength is the compressed size
	// (or -1 after decompression), while the official manifest describes the
	// identity bytes. Ask for identity explicitly so the early length gate and
	// the subsequent MD5/XXH64 checks all describe the same representation.
	req.Header.Set("Accept-Encoding", "identity")
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("official CDN returned HTTP %d", resp.StatusCode)
	}
	if resp.ContentLength >= 0 && resp.ContentLength != f.ByteCount {
		return fmt.Errorf("official CDN content length mismatch: got %d, want %d", resp.ContentLength, f.ByteCount)
	}
	h, err := os.OpenFile(partial, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return err
	}
	md := md5.New()
	xx := xxhash.New()
	n, copyErr := io.Copy(io.MultiWriter(h, md, xx), io.LimitReader(resp.Body, f.ByteCount+1))
	closeErr := h.Close()
	if copyErr != nil {
		return copyErr
	}
	if closeErr != nil {
		return closeErr
	}
	if n != f.ByteCount || hex.EncodeToString(md.Sum(nil)) != f.MD5 || fmt.Sprintf("%016x", xx.Sum64()) != f.XXH64 {
		return errors.New("download hash or size mismatch; partial retained")
	}
	return os.Rename(partial, out)
}

func smokeFile(ctx context.Context, m GlobalManifest, rel, destination string) error {
	return smokeFileWithClient(ctx, m, rel, destination, downloadClient())
}

func smokeFileWithClient(ctx context.Context, m GlobalManifest, rel, destination string, client *http.Client) error {
	if !filepath.IsAbs(destination) || !safePath(rel) {
		return errors.New("destination must be absolute and file path must be manifest-relative")
	}
	var selected *GlobalFile
	for i := range m.Files {
		if m.Files[i].Path == rel {
			selected = &m.Files[i]
			break
		}
	}
	if selected == nil {
		return errors.New("requested smoke file is absent from manifest")
	}
	if selected.ByteCount > 32<<20 {
		return errors.New("smoke file exceeds 32 MiB boundary")
	}
	parent := filepath.Dir(destination)
	i, err := os.Lstat(parent)
	if err != nil || !i.IsDir() || i.Mode()&os.ModeSymlink != 0 {
		return errors.New("smoke destination parent must be a real directory")
	}
	if _, err = os.Lstat(destination); err == nil {
		return errors.New("smoke destination already exists")
	} else if !os.IsNotExist(err) {
		return err
	}
	return fetchVerified(ctx, client, *selected, destination)
}

func downloadAll(ctx context.Context, m GlobalManifest, destination string) error {
	return downloadAllWithControl(ctx, m, destination, "")
}

func downloadAllWithControl(ctx context.Context, m GlobalManifest, destination, control string) error {
	return downloadAllWithClientControl(ctx, m, destination, control, downloadClient())
}

func downloadAllWithClient(ctx context.Context, m GlobalManifest, destination string, client *http.Client) error {
	return downloadAllWithClientControl(ctx, m, destination, "", client)
}

func downloadAllWithClientControl(ctx context.Context, m GlobalManifest, destination, control string, client *http.Client) error {
	if !filepath.IsAbs(destination) {
		return errors.New("destination must be absolute")
	}
	parent := filepath.Dir(destination)
	pi, err := os.Lstat(parent)
	if err != nil || !pi.IsDir() || pi.Mode()&os.ModeSymlink != 0 {
		return errors.New("destination parent must be a real directory")
	}
	if _, err = os.Lstat(destination); err == nil {
		return errors.New("destination already exists; no overwrite or in-place repair")
	} else if !os.IsNotExist(err) {
		return err
	}
	stage := destination + ".stage"
	if info, statErr := os.Lstat(stage); statErr == nil {
		if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
			return errors.New("resume stage is not a real directory")
		}
		stored, readErr := readStageManifest(filepath.Join(stage, "global-direct-manifest.json"))
		if readErr != nil || !sameContentIdentity(stored, m) {
			return errors.New("resume stage manifest identity differs; refusing to mix versions")
		}
	} else if os.IsNotExist(statErr) {
		if err = os.Mkdir(stage, 0700); err != nil {
			return err
		}
		if err = os.WriteFile(filepath.Join(stage, "global-direct-manifest.json"), stageManifestJSON(m), 0600); err != nil {
			return err
		}
	} else {
		return statErr
	}
	// A failed or cancelled stage is deliberately retained, never published.
	for _, d := range m.Directories {
		if err = os.MkdirAll(filepath.Join(stage, filepath.FromSlash(d.Path)), 0700); err != nil {
			return err
		}
	}
	files := append([]GlobalFile(nil), m.Files...)
	sort.Slice(files, func(i, j int) bool { return files[i].Path < files[j].Path })
	var completed int64
	for _, f := range files {
		if err := waitForControl(ctx, control); err != nil {
			return err
		}
		out := filepath.Join(stage, filepath.FromSlash(f.Path))
		if verifiedExisting(out, f) {
			completed += f.ByteCount
			fmt.Fprintf(os.Stderr, "{\"schemaVersion\":1,\"event\":\"progress\",\"bytesWritten\":%d}\n", completed)
			continue
		}
		_ = os.Remove(out + ".partial") // partial is never trusted; restart just this file.
		if err = fetchVerified(ctx, client, f, out); err != nil {
			return err
		}
		// Machine-readable progress is intentionally stderr-only: stdout stays
		// available for a future human summary, while the Swift manager forwards
		// this bounded event to its existing UI protocol.
		completed += f.ByteCount
		fmt.Fprintf(os.Stderr, "{\"schemaVersion\":1,\"event\":\"progress\",\"bytesWritten\":%d}\n", completed)
	}
	return os.Rename(stage, destination)
}

func waitForControl(ctx context.Context, control string) error {
	if control == "" {
		return nil
	}
	if !filepath.IsAbs(control) {
		return errors.New("control path must be absolute")
	}
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}
		b, err := os.ReadFile(control)
		if os.IsNotExist(err) {
			return nil
		}
		if err != nil || len(b) > 4096 {
			return errors.New("invalid download control")
		}
		var v struct {
			SchemaVersion int    `json:"schemaVersion"`
			Action        string `json:"action"`
		}
		if json.Unmarshal(b, &v) != nil || v.SchemaVersion != 1 {
			return errors.New("invalid download control")
		}
		switch v.Action {
		case "resume", "":
			return nil
		case "cancel":
			return context.Canceled
		case "pause":
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(250 * time.Millisecond):
			}
		default:
			return errors.New("unknown download control")
		}
	}
}

func verifiedExisting(path string, f GlobalFile) bool {
	i, err := os.Lstat(path)
	if err != nil || !i.Mode().IsRegular() || i.Mode()&os.ModeSymlink != 0 || i.Size() != f.ByteCount {
		return false
	}
	h, err := os.Open(path)
	if err != nil {
		return false
	}
	defer h.Close()
	md, xx := md5.New(), xxhash.New()
	n, err := io.Copy(io.MultiWriter(md, xx), h)
	return err == nil && n == f.ByteCount && hex.EncodeToString(md.Sum(nil)) == f.MD5 && fmt.Sprintf("%016x", xx.Sum64()) == f.XXH64
}

// contentIdentity removes the resolver observation timestamp and canonicalizes
// collection order.  A stage can therefore resume after a fresh resolve of the
// exact same official content, while every actual download-relevant field
// (including URL, sizes, hashes and operations) stays part of the identity.
//
// Old stages wrote FetchedAt too. readStageManifest accepts those markers and
// compares through this function, so an interrupted existing download remains
// resumable rather than being silently replaced.
func contentIdentity(m GlobalManifest) GlobalManifest {
	identity := m
	identity.FetchedAt = ""
	identity.Files = append([]GlobalFile(nil), m.Files...)
	identity.Directories = append([]GlobalDir(nil), m.Directories...)
	sort.Slice(identity.Files, func(i, j int) bool {
		if identity.Files[i].Path != identity.Files[j].Path {
			return identity.Files[i].Path < identity.Files[j].Path
		}
		return identity.Files[i].Operation < identity.Files[j].Operation
	})
	sort.Slice(identity.Directories, func(i, j int) bool {
		if identity.Directories[i].Path != identity.Directories[j].Path {
			return identity.Directories[i].Path < identity.Directories[j].Path
		}
		return identity.Directories[i].Operation < identity.Directories[j].Operation
	})
	return identity
}

func stageManifestJSON(m GlobalManifest) []byte {
	b, _ := json.MarshalIndent(contentIdentity(m), "", "  ")
	return append(b, '\n')
}

func sameContentIdentity(a, b GlobalManifest) bool {
	return string(stageManifestJSON(a)) == string(stageManifestJSON(b))
}

func readStageManifest(p string) (GlobalManifest, error) {
	i, err := os.Lstat(p)
	if err != nil || !i.Mode().IsRegular() || i.Mode()&os.ModeSymlink != 0 || i.Size() > 32<<20 {
		return GlobalManifest{}, errors.New("stage manifest must be a bounded real regular file")
	}
	b, err := os.ReadFile(p)
	if err != nil {
		return GlobalManifest{}, err
	}
	var m GlobalManifest
	decoder := json.NewDecoder(strings.NewReader(string(b)))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&m); err != nil {
		return GlobalManifest{}, errors.New("invalid stage manifest JSON")
	}
	if decoder.Decode(&struct{}{}) != io.EOF {
		return GlobalManifest{}, errors.New("stage manifest has trailing data")
	}
	return validateResolvedManifest(m)
}

func signalContext() (context.Context, context.CancelFunc) {
	ctx, cancel := context.WithCancel(context.Background())
	ch := make(chan os.Signal, 1)
	signal.Notify(ch, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		select {
		case <-ch:
			cancel()
		case <-ctx.Done():
		}
	}()
	return ctx, func() { signal.Stop(ch); cancel() }
}
