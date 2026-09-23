// IdentityVManifestPlanner validates DirectManifestDocument schema 1 and plans repairs.
package main

import (
	"context"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/cespare/xxhash/v2"
)

const schemaVersion = 1

type FileEntry struct {
	Path      string `json:"path"`
	ByteCount int64  `json:"byteCount"`
	XXH64     string `json:"xxh64"`
	Operation *int   `json:"operation"`
}
type DirectoryEntry struct {
	Path      string `json:"path"`
	Operation *int   `json:"operation"`
}
type Manifest struct {
	SchemaVersion    int              `json:"schemaVersion"`
	ProductID        string           `json:"productId"`
	Adapter          string           `json:"adapter"`
	DistributionID   int              `json:"distributionId"`
	GameID           string           `json:"gameId"`
	DisplayName      string           `json:"displayName"`
	StartupPath      string           `json:"startupPath"`
	StartupArguments string           `json:"startupArguments"`
	VersionCode      string           `json:"versionCode"`
	ContentID        int              `json:"contentId"`
	TotalByteCount   int64            `json:"totalByteCount"`
	Files            []FileEntry      `json:"files"`
	Directories      []DirectoryEntry `json:"directories"`
	FetchedAt        string           `json:"fetchedAt"`
}
type summary struct {
	SchemaVersion int   `json:"schemaVersion"`
	FilesTotal    int   `json:"filesTotal"`
	FilesScanned  int   `json:"filesScanned"`
	BytesScanned  int64 `json:"bytesScanned"`
	Repairs       int   `json:"repairs"`
	Valid         bool  `json:"valid"`
	PlanCompleted bool  `json:"planCompleted,omitempty"`
}
type progress struct {
	SchemaVersion int    `json:"schemaVersion"`
	Event         string `json:"event"`
	FilesScanned  int    `json:"filesScanned"`
	FilesTotal    int    `json:"filesTotal"`
	BytesScanned  int64  `json:"bytesScanned"`
}

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	if os.Args[1] == "self-test" {
		if xxhash.Sum64String("hello") != 0x26c7827d889f6da3 {
			fmt.Fprintln(os.Stderr, "self-test failed")
			os.Exit(1)
		}
		fmt.Println(`{"selfTest":"ok"}`)
		return
	}
	fs := flag.NewFlagSet(os.Args[1], flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	manifestPath := fs.String("manifest", "", "absolute manifest JSON path")
	root := fs.String("root", "", "absolute game root path")
	repair := fs.String("repair-list", "", "absolute repair list output path")
	if fs.Parse(os.Args[2:]) != nil || *manifestPath == "" || *root == "" || (os.Args[1] == "plan" && *repair == "") {
		usage()
		os.Exit(2)
	}
	if os.Args[1] != "plan" && os.Args[1] != "verify" {
		usage()
		os.Exit(2)
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	m, err := readManifest(*manifestPath)
	if err == nil {
		err = validateRoot(*root)
	}
	if err == nil && os.Args[1] == "plan" {
		err = validateRepairPath(*repair, *root)
	}
	if err == nil {
		var bad []string
		var s summary
		bad, s, err = scan(ctx, m, *root)
		if err == nil && os.Args[1] == "plan" {
			err = writeRepairList(*repair, bad)
			s.Repairs = len(bad)
			s.Valid = len(bad) == 0
			s.PlanCompleted = true
		} else if err == nil {
			s.Valid = len(bad) == 0
			if len(bad) > 0 {
				err = fmt.Errorf("verification failed: %d file(s) need repair", len(bad))
			}
		}
		if err == nil {
			_ = json.NewEncoder(os.Stdout).Encode(s)
		}
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}
func usage() {
	fmt.Fprintln(os.Stderr, "usage: IdentityVManifestPlanner plan --manifest ABS --root ABS --repair-list ABS | verify --manifest ABS --root ABS | self-test")
}
func mustAbsolute(p string) error {
	if !filepath.IsAbs(p) {
		return fmt.Errorf("path must be absolute")
	}
	return nil
}
func readManifest(p string) (Manifest, error) {
	var m Manifest
	if err := mustAbsolute(p); err != nil {
		return m, err
	}
	f, e := os.Open(p)
	if e != nil {
		return m, e
	}
	defer f.Close()
	d := json.NewDecoder(io.LimitReader(f, 64<<20))
	d.DisallowUnknownFields()
	if e = d.Decode(&m); e != nil {
		return m, e
	}
	if d.Decode(&struct{}{}) != io.EOF {
		return m, errors.New("manifest has trailing data")
	}
	return m, validateManifest(m)
}
func validRel(p string) error {
	if p == "" || len(p) > 4096 || strings.ContainsAny(p, "\\:\x00") {
		return fmt.Errorf("unsafe manifest path %q", p)
	}
	for _, s := range strings.Split(p, "/") {
		if s == "" || s == "." || s == ".." {
			return fmt.Errorf("unsafe manifest path %q", p)
		}
	}
	return nil
}
func validateManifest(m Manifest) error {
	if m.SchemaVersion != schemaVersion {
		return fmt.Errorf("unsupported schemaVersion %d", m.SchemaVersion)
	}
	for _, v := range []string{m.ProductID, m.Adapter, m.GameID, m.DisplayName, m.StartupPath, m.VersionCode, m.FetchedAt} {
		if strings.TrimSpace(v) == "" {
			return errors.New("missing manifest identity field")
		}
	}
	if m.ProductID != "mainland" || m.Adapter != "netease-loadingbay-v1" || m.DistributionID <= 0 || m.ContentID <= 0 {
		return errors.New("manifest identity values are invalid")
	}
	if !regexp.MustCompile(`^h[0-9]+$`).MatchString(m.GameID) {
		return errors.New("invalid gameId")
	}
	if !regexp.MustCompile(`^v[0-9]+_[0-9]+_[0-9a-fA-F]{32}$`).MatchString(m.VersionCode) {
		return errors.New("invalid versionCode")
	}
	if e := validRel(m.StartupPath); e != nil || !strings.HasSuffix(strings.ToLower(m.StartupPath), ".exe") {
		return errors.New("invalid startupPath")
	}
	if _, e := time.Parse(time.RFC3339, m.FetchedAt); e != nil {
		return fmt.Errorf("invalid fetchedAt: %w", e)
	}
	if len(m.Files) == 0 || len(m.Files) > 1000000 {
		return errors.New("invalid files count")
	}
	if m.TotalByteCount < 0 {
		return errors.New("negative totalByteCount")
	}
	// macOS game volumes are commonly case-insensitive. Treat paths that differ
	// only by case as the same target so concurrent hashing/downloading cannot
	// race on one filesystem entry.
	seen := map[string]string{}
	var total int64
	for _, f := range m.Files {
		if validRel(f.Path) != nil {
			return validRel(f.Path)
		}
		key := strings.ToLower(f.Path)
		if previous, exists := seen[key]; exists {
			return fmt.Errorf("duplicate path %q conflicts with %q", f.Path, previous)
		}
		seen[key] = f.Path
		if f.ByteCount < 0 {
			return fmt.Errorf("negative byteCount for %q", f.Path)
		}
		if f.Operation != nil && *f.Operation != 1 {
			return fmt.Errorf("invalid operation for %q", f.Path)
		}
		if len(f.XXH64) != 16 {
			return fmt.Errorf("invalid xxh64 for %q", f.Path)
		}
		if _, e := hex.DecodeString(f.XXH64); e != nil {
			return fmt.Errorf("invalid xxh64 for %q", f.Path)
		}
		if total > int64(^uint64(0)>>1)-f.ByteCount {
			return errors.New("total byte count overflow")
		}
		total += f.ByteCount
	}
	if total != m.TotalByteCount {
		return fmt.Errorf("totalByteCount mismatch: got %d expected %d", m.TotalByteCount, total)
	}
	for _, d := range m.Directories {
		if e := validRel(d.Path); e != nil {
			return e
		}
		key := strings.ToLower(d.Path)
		if previous, exists := seen[key]; exists {
			return fmt.Errorf("duplicate path %q conflicts with %q", d.Path, previous)
		}
		seen[key] = d.Path
		if d.Operation != nil && *d.Operation != 1 {
			return fmt.Errorf("invalid operation for %q", d.Path)
		}
	}
	return nil
}
func validateRoot(root string) error {
	if e := mustAbsolute(root); e != nil {
		return e
	}
	i, e := os.Lstat(root)
	if e != nil {
		return e
	}
	if i.Mode()&os.ModeSymlink != 0 || !i.IsDir() {
		return errors.New("root must be a real directory, not a symlink")
	}
	return nil
}
func validateRepairPath(out, root string) error {
	if e := mustAbsolute(out); e != nil {
		return e
	}
	rel, e := filepath.Rel(root, out)
	if e == nil && rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator)) && !filepath.IsAbs(rel) {
		return errors.New("repair list must be outside game root")
	}
	parent := filepath.Dir(out)
	i, e := os.Lstat(parent)
	if e != nil {
		return fmt.Errorf("repair-list parent: %w", e)
	}
	if !i.IsDir() || i.Mode()&os.ModeSymlink != 0 {
		return errors.New("repair-list parent must be a real directory")
	}
	return nil
}
func secureFile(root, rel string) (string, os.FileInfo, error) {
	cur := root
	var target os.FileInfo
	parts := strings.Split(rel, "/")
	for n, p := range parts {
		cur = filepath.Join(cur, p)
		i, e := os.Lstat(cur)
		if e != nil {
			if os.IsNotExist(e) {
				return cur, nil, nil
			}
			return "", nil, e
		}
		if i.Mode()&os.ModeSymlink != 0 {
			return "", nil, fmt.Errorf("symlink rejected at %q", rel)
		}
		if n < len(parts)-1 && !i.IsDir() {
			return "", nil, fmt.Errorf("non-directory ancestor at %q", rel)
		}
		if n == len(parts)-1 && !i.Mode().IsRegular() {
			return "", nil, fmt.Errorf("non-regular file rejected at %q", rel)
		}
		if n == len(parts)-1 {
			target = i
		}
	}
	return cur, target, nil
}
func scan(ctx context.Context, m Manifest, root string) ([]string, summary, error) {
	s := summary{SchemaVersion: schemaVersion, FilesTotal: len(m.Files)}
	bad := make([]bool, len(m.Files))
	jobs := make(chan int)
	var mu sync.Mutex
	var first error
	report := func(final bool) {
		mu.Lock()
		p := progress{SchemaVersion: schemaVersion, Event: "scan", FilesScanned: s.FilesScanned, FilesTotal: s.FilesTotal, BytesScanned: s.BytesScanned}
		mu.Unlock()
		if final || p.FilesScanned > 0 {
			_ = json.NewEncoder(os.Stderr).Encode(p)
		}
	}
	progressCtx, stopProgress := context.WithCancel(ctx)
	defer stopProgress()
	done := make(chan struct{})
	go func() {
		t := time.NewTicker(200 * time.Millisecond)
		defer t.Stop()
		defer close(done)
		for {
			select {
			case <-t.C:
				report(false)
			case <-progressCtx.Done():
				return
			}
		}
	}()
	workers := runtime.NumCPU()
	if workers > 4 {
		workers = 4
	}
	if workers < 1 {
		workers = 1
	}
	var wg sync.WaitGroup
	for w := 0; w < workers; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for n := range jobs {
				if ctx.Err() != nil {
					return
				}
				f := m.Files[n]
				path, info, e := secureFile(root, f.Path)
				needs := false
				if e != nil {
					mu.Lock()
					if first == nil {
						first = e
					}
					mu.Unlock()
					continue
				}
				if info == nil || info.Size() != f.ByteCount {
					needs = true
				} else {
					var count int64
					var got uint64
					count, got, e = hashFile(ctx, path)
					mu.Lock()
					s.BytesScanned += count
					mu.Unlock()
					if e != nil {
						mu.Lock()
						if first == nil {
							first = e
						}
						mu.Unlock()
						continue
					}
					want, _ := hex.DecodeString(f.XXH64)
					var wb [8]byte
					copy(wb[:], want)
					var gb [8]byte
					for i := 7; i >= 0; i-- {
						gb[i] = byte(got)
						got >>= 8
					}
					if subtle.ConstantTimeCompare(gb[:], wb[:]) != 1 {
						needs = true
					}
				}
				mu.Lock()
				bad[n] = needs
				s.FilesScanned++
				mu.Unlock()
			}
		}()
	}
	for i := range m.Files {
		select {
		case jobs <- i:
		case <-ctx.Done():
			break
		}
		if ctx.Err() != nil {
			break
		}
	}
	close(jobs)
	wg.Wait()
	if ctx.Err() != nil {
		first = ctx.Err()
	}
	stopProgress()
	<-done
	report(true)
	if first != nil {
		return nil, s, first
	}
	var result []string
	for i, b := range bad {
		if b {
			result = append(result, m.Files[i].Path)
		}
	}
	return result, s, nil
}
func hashFile(ctx context.Context, p string) (int64, uint64, error) {
	f, e := os.Open(p)
	if e != nil {
		return 0, 0, e
	}
	defer f.Close()
	h := xxhash.New()
	buf := make([]byte, 1<<20)
	var n int64
	for {
		if e = ctx.Err(); e != nil {
			return n, 0, e
		}
		r, re := f.Read(buf)
		if r > 0 {
			n += int64(r)
			_, _ = h.Write(buf[:r])
		}
		if re == io.EOF {
			return n, h.Sum64(), nil
		}
		if re != nil {
			return n, 0, re
		}
	}
}

var renameFile = os.Rename

func writeRepairList(p string, items []string) error {
	d := filepath.Dir(p)
	f, e := os.CreateTemp(d, ".IdentityVManifestPlanner-*")
	if e != nil {
		return e
	}
	tmp := f.Name()
	ok := false
	defer func() {
		if !ok {
			_ = os.Remove(tmp)
		}
	}()
	if e = f.Chmod(0600); e == nil {
		for _, v := range items {
			if _, e = f.WriteString(v + "\n"); e != nil {
				break
			}
		}
	}
	if e == nil {
		e = f.Sync()
	}
	if ce := f.Close(); e == nil {
		e = ce
	}
	if e != nil {
		return e
	}
	if e = renameFile(tmp, p); e != nil {
		return e
	}
	ok = true
	return nil
}
