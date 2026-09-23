// IdentityVRuntimeBootstrap obtains a fixed runtime from its original release
// publisher and verifies it before making it available to the launcher.
package main

import (
	"context"
	"crypto/sha256"
	"debug/macho"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"syscall"
	"time"
)

const schemaVersion = 1

var hashRE = regexp.MustCompile(`^[0-9a-f]{64}$`)
var versionRE = regexp.MustCompile(`^[A-Za-z0-9._-]+$`)

type fileSpec struct {
	RelativePath     string `json:"relativePath"`
	SHA256           string `json:"sha256"`
	Executable       bool   `json:"executable,omitempty"`
	MachOMinOSAtMost string `json:"machOMinOSAtMost,omitempty"`
}
type patchSpec struct {
	PatchRelativePath  string `json:"patchRelativePath"`
	TargetRelativePath string `json:"targetRelativePath"`
	SHA256             string `json:"sha256"`
	MachOMinOSAtMost   string `json:"machOMinOSAtMost,omitempty"`
}
type sourceSpec struct {
	URL                  string   `json:"url"`
	AllowedRedirectHosts []string `json:"allowedRedirectHosts"`
	ByteCount            int64    `json:"byteCount"`
	SHA256               string   `json:"sha256"`
	RuntimeRoot          string   `json:"runtimeRoot"`
}
type manifest struct {
	SchemaVersion           int         `json:"schemaVersion"`
	Component               string      `json:"component"`
	Version                 string      `json:"version"`
	MinimumMacOS            string      `json:"minimumMacOS"`
	Source                  sourceSpec  `json:"source"`
	SourceVerificationFiles []fileSpec  `json:"sourceVerificationFiles"`
	Patches                 []patchSpec `json:"patches"`
	FinalVerificationFiles  []fileSpec  `json:"finalVerificationFiles"`
}

func main() {
	if runtime.GOOS != "darwin" || runtime.GOARCH != "arm64" {
		fail(errors.New("this helper is only supported on native arm64 macOS"))
	}
	if len(os.Args) < 2 {
		usage()
	}
	switch os.Args[1] {
	case "install":
		fs := flag.NewFlagSet("install", flag.ExitOnError)
		manifestPath := fs.String("manifest", "", "absolute manifest")
		destination := fs.String("destination-root", "", "component root")
		patches := fs.String("patch-root", "", "read-only patch root")
		fs.Parse(os.Args[2:])
		m, err := readManifest(*manifestPath)
		if err == nil {
			// The manager forwards cancellation only to this helper.  Keep the
			// signal context for the complete transaction so an interrupted
			// download, attach or copy cannot outlive its parent process.
			ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
			defer stop()
			err = install(ctx, m, *destination, *patches, os.Stderr)
		}
		fail(err)
	case "verify-tree":
		fs := flag.NewFlagSet("verify-tree", flag.ExitOnError)
		manifestPath := fs.String("manifest", "", "absolute manifest")
		tree := fs.String("tree", "", "runtime directory")
		fs.Parse(os.Args[2:])
		m, err := readManifest(*manifestPath)
		if err == nil {
			err = verifyTree(*tree, m.FinalVerificationFiles, true)
		}
		fail(err)
		fmt.Println("runtime verification passed")
	default:
		usage()
	}
}
func usage() {
	fmt.Fprintln(os.Stderr, "usage: IdentityVRuntimeBootstrap install --manifest ABS --destination-root ABS --patch-root ABS | verify-tree --manifest ABS --tree ABS")
	os.Exit(2)
}
func fail(err error) {
	if err != nil {
		fmt.Fprintln(os.Stderr, "runtime bootstrap failed:", err)
		os.Exit(1)
	}
}

func readManifest(path string) (manifest, error) {
	var m manifest
	if !filepath.IsAbs(path) {
		return m, errors.New("manifest path must be absolute")
	}
	f, err := os.Open(path)
	if err != nil {
		return m, err
	}
	defer f.Close()
	d := json.NewDecoder(io.LimitReader(f, 1<<20))
	d.DisallowUnknownFields()
	if err = d.Decode(&m); err != nil {
		return m, err
	}
	if d.Decode(&struct{}{}) != io.EOF {
		return m, errors.New("trailing manifest data")
	}
	return m, validateManifest(m)
}
func safeRelative(p string) bool {
	return p != "" && !filepath.IsAbs(p) && filepath.Clean(p) == p && p != "." && !strings.HasPrefix(p, ".."+string(os.PathSeparator)) && p != ".."
}
func validateFile(f fileSpec) error {
	if !safeRelative(f.RelativePath) || !hashRE.MatchString(f.SHA256) {
		return errors.New("invalid file specification")
	}
	if f.MachOMinOSAtMost != "" && parseVersion(f.MachOMinOSAtMost) < 0 {
		return errors.New("invalid Mach-O minimum OS")
	}
	return nil
}
func validateManifest(m manifest) error {
	if m.SchemaVersion != schemaVersion || m.Component != "wine-runtime" || !versionRE.MatchString(m.Version) || parseVersion(m.MinimumMacOS) < 0 {
		return errors.New("unsupported runtime manifest")
	}
	u, err := url.Parse(m.Source.URL)
	if err != nil || u.Scheme != "https" || u.RawQuery != "" || u.Fragment != "" || m.Source.ByteCount < 1 || !hashRE.MatchString(m.Source.SHA256) || !safeRelative(m.Source.RuntimeRoot) {
		return errors.New("invalid runtime source")
	}
	allowed := map[string]bool{}
	for _, h := range m.Source.AllowedRedirectHosts {
		if h == "" || strings.Contains(h, "/") {
			return errors.New("invalid redirect host")
		}
		allowed[strings.ToLower(h)] = true
	}
	if !allowed[strings.ToLower(u.Host)] {
		return errors.New("initial source host not allowed")
	}
	if len(m.SourceVerificationFiles) == 0 || len(m.Patches) != 4 || len(m.FinalVerificationFiles) == 0 {
		return errors.New("incomplete runtime manifest")
	}
	sourceSeen := map[string]bool{}
	for _, f := range m.SourceVerificationFiles {
		if err := validateFile(f); err != nil {
			return err
		}
		if sourceSeen[f.RelativePath] {
			return errors.New("duplicate source verification path")
		}
		sourceSeen[f.RelativePath] = true
	}
	finalSeen := map[string]bool{}
	for _, f := range m.FinalVerificationFiles {
		if err := validateFile(f); err != nil {
			return err
		}
		if finalSeen[f.RelativePath] {
			return errors.New("duplicate final verification path")
		}
		finalSeen[f.RelativePath] = true
	}
	patchTargets := map[string]bool{}
	for _, p := range m.Patches {
		if !safeRelative(p.PatchRelativePath) || !safeRelative(p.TargetRelativePath) || !hashRE.MatchString(p.SHA256) || parseVersion(p.MachOMinOSAtMost) < 0 || patchTargets[p.TargetRelativePath] {
			return errors.New("invalid patch specification")
		}
		patchTargets[p.TargetRelativePath] = true
	}
	return nil
}
func parseVersion(s string) int {
	parts := strings.Split(s, ".")
	if len(parts) == 0 || len(parts) > 3 {
		return -1
	}
	n := 0
	for _, p := range parts {
		if p == "" {
			return -1
		}
		var x int
		if _, err := fmt.Sscanf(p, "%d", &x); err != nil || x < 0 || x > 999 {
			return -1
		}
		n = n*1000 + x
	}
	for len(parts) < 3 {
		n *= 1000
		parts = append(parts, "0")
	}
	return n
}
func ensureDirectory(path string) error {
	if !filepath.IsAbs(path) {
		return errors.New("path must be absolute")
	}
	info, err := os.Lstat(path)
	if err == nil {
		if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
			return errors.New("path must be a real directory")
		}
		return nil
	}
	if !os.IsNotExist(err) {
		return err
	}
	return os.MkdirAll(path, 0700)
}
func secureJoin(root, relative string) (string, error) {
	if !safeRelative(relative) {
		return "", errors.New("unsafe relative path")
	}
	full := filepath.Join(root, relative)
	r, err := filepath.Rel(root, full)
	if err != nil || r == ".." || strings.HasPrefix(r, ".."+string(os.PathSeparator)) {
		return "", errors.New("path escapes root")
	}
	return full, nil
}
func regular(path string) (os.FileInfo, error) {
	i, e := os.Lstat(path)
	if e != nil {
		return nil, e
	}
	if !i.Mode().IsRegular() || i.Mode()&os.ModeSymlink != 0 {
		return nil, errors.New("expected regular non-symlink file")
	}
	return i, nil
}
func hashFile(path string) (string, error) {
	f, e := os.Open(path)
	if e != nil {
		return "", e
	}
	defer f.Close()
	h := sha256.New()
	if _, e = io.Copy(h, f); e != nil {
		return "", e
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}
func verifyTree(root string, files []fileSpec, checkMachO bool) error {
	i, e := os.Lstat(root)
	if e != nil || !i.IsDir() || i.Mode()&os.ModeSymlink != 0 {
		return errors.New("runtime root is not a real directory")
	}
	seen := map[string]bool{}
	for _, f := range files {
		if seen[f.RelativePath] {
			return errors.New("duplicate verification path")
		}
		seen[f.RelativePath] = true
		p, e := secureJoin(root, f.RelativePath)
		if e != nil {
			return e
		}
		info, e := regular(p)
		if e != nil {
			return fmt.Errorf("%s: %w", f.RelativePath, e)
		}
		got, e := hashFile(p)
		if e != nil || got != f.SHA256 {
			return fmt.Errorf("hash mismatch: %s", f.RelativePath)
		}
		if f.Executable && info.Mode()&0111 == 0 {
			return fmt.Errorf("not executable: %s", f.RelativePath)
		}
		if checkMachO && f.MachOMinOSAtMost != "" {
			if e = verifyMachOMinOS(p, f.MachOMinOSAtMost); e != nil {
				return e
			}
		}
	}
	return nil
}
func verifyMachOMinOS(path, limit string) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		return err
	}
	err = verifyMachOReader(f, info.Size(), limit)
	if err != nil {
		return fmt.Errorf("cannot inspect Mach-O %s: %w", filepath.Base(path), err)
	}
	return nil
}

// Inspect deployment targets without otool (a developer-tools shim on a clean Mac).
func verifyMachOReader(r io.ReaderAt, size int64, limit string) error {
	if parseVersion(limit) < 0 {
		return errors.New("invalid macOS version limit")
	}
	var magic [4]byte
	if _, err := r.ReadAt(magic[:], 0); err != nil {
		return err
	}
	if binary.BigEndian.Uint32(magic[:]) != macho.MagicFat {
		return verifyMachOSlice(r, size, limit)
	}
	ff, err := macho.NewFatFile(r)
	if err != nil {
		return err
	}
	end := uint64(8 + 20*len(ff.Arches))
	for i, arch := range ff.Arches {
		start, length := uint64(arch.Offset), uint64(arch.Size)
		if start < end || start+length > uint64(size) || arch.Cpu != arch.File.Cpu || arch.SubCpu != arch.File.SubCpu {
			return errors.New("invalid Mach-O slice extent or architecture")
		}
		for _, previous := range ff.Arches[:i] {
			if start < uint64(previous.Offset)+uint64(previous.Size) && uint64(previous.Offset) < start+length {
				return errors.New("overlapping Mach-O slices")
			}
		}
		if err := verifyMachOSlice(io.NewSectionReader(r, int64(start), int64(length)), int64(length), limit); err != nil {
			return fmt.Errorf("slice %d: %w", i, err)
		}
	}
	return nil
}

func verifyMachOSlice(r io.ReaderAt, size int64, limit string) error {
	f, err := macho.NewFile(r)
	if err != nil {
		return err
	}
	headerSize := uint64(28)
	if f.Magic == macho.Magic64 {
		headerSize = 32
	}
	if headerSize+uint64(f.Cmdsz) > uint64(size) {
		return errors.New("truncated Mach-O header or commands")
	}
	var consumed uint64
	found := false
	for _, load := range f.Loads {
		raw := load.Raw()
		consumed += uint64(len(raw))
		if len(raw) < 8 || len(raw)%4 != 0 {
			return errors.New("malformed Mach-O command")
		}
		var packed uint32
		switch f.ByteOrder.Uint32(raw[:4]) {
		case 0x32: // LC_BUILD_VERSION: platform, minos, sdk, ntools, tools...
			if len(raw) < 24 || uint64(len(raw)) != 24+8*uint64(f.ByteOrder.Uint32(raw[20:24])) {
				return errors.New("malformed LC_BUILD_VERSION")
			}
			if f.ByteOrder.Uint32(raw[8:12]) != 1 {
				return errors.New("non-macOS Mach-O build platform")
			}
			packed = f.ByteOrder.Uint32(raw[12:16])
		case 0x24: // LC_VERSION_MIN_MACOSX
			if len(raw) != 16 {
				return errors.New("malformed LC_VERSION_MIN_MACOSX")
			}
			packed = f.ByteOrder.Uint32(raw[8:12])
		case 0x25, 0x2f, 0x30: // iOS, tvOS, watchOS deployment targets
			return errors.New("non-macOS Mach-O deployment target")
		default:
			continue
		}
		found = true
		version := parseVersion(fmt.Sprintf("%d.%d.%d", packed>>16, (packed>>8)&255, packed&255))
		if version < 0 || version > parseVersion(limit) {
			return fmt.Errorf("Mach-O minimum macOS exceeds %s", limit)
		}
	}
	if consumed != uint64(f.Cmdsz) {
		return errors.New("Mach-O command size/count mismatch")
	}
	if !found {
		return errors.New("no Mach-O deployment target")
	}
	return nil
}
func httpClient(allowed map[string]bool) *http.Client {
	return &http.Client{Timeout: 20 * time.Minute, CheckRedirect: func(r *http.Request, via []*http.Request) error {
		if len(via) > 4 || r.URL.Scheme != "https" || !allowed[strings.ToLower(r.URL.Host)] {
			return errors.New("redirect left allowed source hosts")
		}
		return nil
	}}
}
func download(ctx context.Context, m manifest, target string, out io.Writer) error {
	allowed := map[string]bool{}
	for _, h := range m.Source.AllowedRedirectHosts {
		allowed[strings.ToLower(h)] = true
	}
	req, e := http.NewRequestWithContext(ctx, http.MethodGet, m.Source.URL, nil)
	if e != nil {
		return e
	}
	resp, e := httpClient(allowed).Do(req)
	if e != nil {
		return e
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return errors.New("runtime download did not return 200")
	}
	if resp.ContentLength >= 0 && resp.ContentLength != m.Source.ByteCount {
		return errors.New("runtime download size mismatch")
	}
	f, e := os.OpenFile(target, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if e != nil {
		return e
	}
	defer f.Close()
	fmt.Fprintf(out, "runtime-bootstrap stage=download status=started bytes=0 total=%d percent=0\n", m.Source.ByteCount)
	if e = writeVerifiedWithProgressContext(ctx, f, resp.Body, m.Source.ByteCount, m.Source.SHA256, out); e != nil {
		return e
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	return f.Sync()
}

func writeVerified(destination io.Writer, source io.Reader, byteCount int64, expectedHash string) error {
	return writeVerifiedWithProgress(destination, source, byteCount, expectedHash, nil)
}

// downloadProgress emits a small, machine-readable progress stream.  It reports
// only each newly crossed five-percent boundary (plus 0 and 100), irrespective
// of HTTP chunk size, so a slow 326 MB download remains observable without
// turning stderr into a log of every read.
type downloadProgress struct {
	out         io.Writer
	total       int64
	written     int64
	nextPercent int64
}

func (p *downloadProgress) Write(b []byte) (int, error) {
	p.written += int64(len(b))
	if p.out != nil && p.total > 0 {
		percent := p.written * 100 / p.total
		if percent >= p.nextPercent {
			fmt.Fprintf(p.out, "runtime-bootstrap stage=download bytes=%d total=%d percent=%d\n", p.written, p.total, percent)
			p.nextPercent = (percent/5 + 1) * 5
		}
	}
	return len(b), nil
}

func writeVerifiedWithProgress(destination io.Writer, source io.Reader, byteCount int64, expectedHash string, out io.Writer) error {
	return writeVerifiedWithProgressContext(context.Background(), destination, source, byteCount, expectedHash, out)
}

func writeVerifiedWithProgressContext(ctx context.Context, destination io.Writer, source io.Reader, byteCount int64, expectedHash string, out io.Writer) error {
	h := sha256.New()
	progress := &downloadProgress{out: out, total: byteCount, nextPercent: 5}
	writer := io.MultiWriter(destination, h, progress)
	limited := io.LimitReader(source, byteCount+1)
	buffer := make([]byte, 1024*1024)
	var n int64
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		read, readErr := limited.Read(buffer)
		if read > 0 {
			written, writeErr := writer.Write(buffer[:read])
			n += int64(written)
			if writeErr != nil {
				return writeErr
			}
			if written != read {
				return io.ErrShortWrite
			}
		}
		if readErr == io.EOF {
			break
		}
		if readErr != nil {
			if ctx.Err() != nil {
				return ctx.Err()
			}
			return readErr
		}
	}
	if n != byteCount || hex.EncodeToString(h.Sum(nil)) != expectedHash {
		return errors.New("runtime archive integrity mismatch")
	}
	if out != nil && progress.nextPercent <= 100 {
		fmt.Fprintf(out, "runtime-bootstrap stage=download bytes=%d total=%d percent=100\n", n, byteCount)
	}
	return nil
}
func copyFile(source, target string) error {
	return copyFileContext(context.Background(), source, target)
}

func copyFileContext(ctx context.Context, source, target string) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	info, e := regular(source)
	if e != nil {
		return e
	}
	if e = os.MkdirAll(filepath.Dir(target), 0700); e != nil {
		return e
	}
	in, e := os.Open(source)
	if e != nil {
		return e
	}
	defer in.Close()
	out, e := os.OpenFile(target, os.O_CREATE|os.O_EXCL|os.O_WRONLY, info.Mode()&0777)
	if e != nil {
		return e
	}
	if _, e = copyWithContext(ctx, out, in); e == nil {
		e = out.Sync()
	}
	closeErr := out.Close()
	if e != nil {
		return e
	}
	return closeErr
}
func copyWithContext(ctx context.Context, destination io.Writer, source io.Reader) (int64, error) {
	buffer := make([]byte, 1024*1024)
	var total int64
	for {
		if err := ctx.Err(); err != nil {
			return total, err
		}
		n, readErr := source.Read(buffer)
		if n > 0 {
			written, writeErr := destination.Write(buffer[:n])
			total += int64(written)
			if writeErr != nil {
				return total, writeErr
			}
			if written != n {
				return total, io.ErrShortWrite
			}
		}
		if readErr == io.EOF {
			return total, nil
		}
		if readErr != nil {
			return total, readErr
		}
	}
}
func copyTree(source, target string) error {
	return copyTreeContext(context.Background(), source, target)
}

func copyTreeContext(ctx context.Context, source, target string) error {
	return filepath.WalkDir(source, func(path string, d os.DirEntry, err error) error {
		if err := ctx.Err(); err != nil {
			return err
		}
		if err != nil {
			return err
		}
		rel, e := filepath.Rel(source, path)
		if e != nil {
			return e
		}
		if rel == "." {
			return os.MkdirAll(target, 0700)
		}
		dest, e := secureJoin(target, rel)
		if e != nil {
			return e
		}
		info, e := d.Info()
		if e != nil {
			return e
		}
		if d.Type()&os.ModeSymlink != 0 {
			return errors.New("runtime source contains a symlink; refusing ambiguous copy")
		}
		if d.IsDir() {
			return os.Mkdir(dest, 0700)
		}
		if !info.Mode().IsRegular() {
			return errors.New("runtime source contains non-regular file")
		}
		return copyFileContext(ctx, path, dest)
	})
}
func attachDMG(ctx context.Context, dmg, mount string) (string, error) {
	cmd := exec.CommandContext(ctx, "/usr/bin/hdiutil", "attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mount, dmg)
	out, e := cmd.CombinedOutput()
	if e != nil {
		return "", fmt.Errorf("cannot mount runtime image: %s", strings.TrimSpace(string(out)))
	}
	for _, line := range strings.Split(string(out), "\n") {
		f := strings.Fields(line)
		if len(f) > 0 && strings.HasPrefix(f[0], "/dev/disk") {
			return f[0], nil
		}
	}
	return "", errors.New("mounted image did not report a disk")
}
func detach(device string) {
	if device != "" {
		_ = exec.Command("/usr/bin/hdiutil", "detach", device).Run()
	}
}

// recoverPublishedRuntime closes the only crash window after the final runtime
// directory has been atomically renamed into place but before `current` could
// be created.  It never repoints an existing link: a versioned final directory
// is accepted only after the same complete verification used for a new install.
func recoverPublishedRuntime(m manifest, destinationRoot string, checkMachO bool) (bool, error) {
	current := filepath.Join(destinationRoot, "current")
	final := filepath.Join(destinationRoot, m.Version)

	currentInfo, currentErr := os.Lstat(current)
	if currentErr != nil && !os.IsNotExist(currentErr) {
		return false, currentErr
	}
	finalInfo, finalErr := os.Lstat(final)
	if finalErr != nil && !os.IsNotExist(finalErr) {
		return false, finalErr
	}
	currentExists := currentErr == nil
	finalExists := finalErr == nil

	if currentExists {
		if currentInfo.Mode()&os.ModeSymlink == 0 {
			return false, errors.New("current runtime path already exists and is not a symlink")
		}
		target, err := os.Readlink(current)
		if err != nil {
			return false, err
		}
		if target != m.Version {
			return false, errors.New("current runtime points at a different version; refusing to overwrite it")
		}
		if !finalExists || !finalInfo.IsDir() || finalInfo.Mode()&os.ModeSymlink != 0 {
			return false, errors.New("current runtime points at a missing or invalid final runtime")
		}
		if err := verifyTree(final, m.FinalVerificationFiles, checkMachO); err != nil {
			return false, fmt.Errorf("existing current runtime verification: %w", err)
		}
		return true, nil
	}

	if !finalExists {
		return false, nil
	}
	if !finalInfo.IsDir() || finalInfo.Mode()&os.ModeSymlink != 0 {
		return false, errors.New("runtime version path already exists and is not a real directory")
	}
	if err := verifyTree(final, m.FinalVerificationFiles, checkMachO); err != nil {
		return false, fmt.Errorf("existing final runtime verification: %w", err)
	}
	if err := os.Symlink(m.Version, current); err != nil {
		return false, fmt.Errorf("cannot restore current runtime link: %w", err)
	}
	return true, nil
}
func install(ctx context.Context, m manifest, destinationRoot, patchRoot string, out io.Writer) error {
	// Keep the internal API tolerant for deterministic unit fixtures that do
	// not exercise cancellation.  The command-line install path always passes
	// a SIGINT/SIGTERM-aware context.
	if ctx == nil {
		ctx = context.Background()
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	if err := validateManifest(m); err != nil {
		return err
	}
	if err := ensureDirectory(destinationRoot); err != nil {
		return err
	}
	if err := ensureDirectory(patchRoot); err != nil {
		return err
	}
	recovered, err := recoverPublishedRuntime(m, destinationRoot, true)
	if err != nil {
		return err
	}
	if recovered {
		fmt.Fprintln(out, "runtime bootstrap already completed")
		return nil
	}
	current := filepath.Join(destinationRoot, "current")
	final := filepath.Join(destinationRoot, m.Version)
	stage, e := os.MkdirTemp(destinationRoot, ".wine-runtime-staging-")
	if e != nil {
		return e
	}
	defer os.RemoveAll(stage)
	dmg := filepath.Join(stage, "source.dmg")
	fmt.Fprintln(out, "downloading runtime from original publisher")
	if e = download(ctx, m, dmg, out); e != nil {
		return e
	}
	mount := filepath.Join(stage, "mount")
	if e = os.Mkdir(mount, 0700); e != nil {
		return e
	}
	device, e := attachDMG(ctx, dmg, mount)
	if e != nil {
		return e
	}
	defer detach(device)
	source, e := secureJoin(mount, m.Source.RuntimeRoot)
	if e != nil {
		return e
	}
	if i, x := os.Lstat(source); x != nil || !i.IsDir() || i.Mode()&os.ModeSymlink != 0 {
		return errors.New("expected runtime root was not found in image")
	}
	if e = verifyTree(source, m.SourceVerificationFiles, false); e != nil {
		return fmt.Errorf("source runtime verification: %w", e)
	}
	runtimeStage := filepath.Join(stage, "runtime")
	if e = copyTreeContext(ctx, source, runtimeStage); e != nil {
		return e
	}
	for _, p := range m.Patches {
		if e = ctx.Err(); e != nil {
			return e
		}
		from, e := secureJoin(patchRoot, p.PatchRelativePath)
		if e != nil {
			return e
		}
		if _, e = regular(from); e != nil {
			return fmt.Errorf("patch %s: %w", p.PatchRelativePath, e)
		}
		if got, e := hashFile(from); e != nil || got != p.SHA256 {
			return fmt.Errorf("patch hash mismatch: %s", p.PatchRelativePath)
		}
		to, e := secureJoin(runtimeStage, p.TargetRelativePath)
		if e != nil {
			return e
		}
		if _, e = os.Lstat(to); e == nil {
			if e = os.Remove(to); e != nil {
				return e
			}
		} else {
			return fmt.Errorf("missing patch target: %s", p.TargetRelativePath)
		}
		if e = copyFileContext(ctx, from, to); e != nil {
			return e
		}
		if e = verifyMachOMinOS(to, p.MachOMinOSAtMost); e != nil {
			return e
		}
	}
	if e = verifyTree(runtimeStage, m.FinalVerificationFiles, true); e != nil {
		return fmt.Errorf("final runtime verification: %w", e)
	}
	if e = ctx.Err(); e != nil {
		return e
	}
	if e = os.Rename(runtimeStage, final); e != nil {
		return e
	}
	if e = os.Symlink(m.Version, current); e != nil {
		return e
	}
	fmt.Fprintln(out, "runtime bootstrap completed")
	return nil
}
