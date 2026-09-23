package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

const manifestSchema = 1

var commitPattern = regexp.MustCompile(`^[0-9a-f]{40}$`)
var hashPattern = regexp.MustCompile(`^[0-9a-f]{64}$`)

type Acquisition struct {
	Mode          string `json:"mode"`
	Repository    string `json:"repository"`
	Commit        string `json:"commit"`
	SourceBaseURL string `json:"sourceBaseURL"`
	Note          string `json:"note"`
}

type ComponentFile struct {
	Filename  string `json:"filename"`
	ByteCount int64  `json:"byteCount"`
	SHA256    string `json:"sha256"`
}

type ComponentManifest struct {
	SchemaVersion        int             `json:"schemaVersion"`
	Component            string          `json:"component"`
	Acquisition          Acquisition     `json:"acquisition"`
	AuthenticodeLeaf     string          `json:"observedAuthenticodeLeaf"`
	RedistributionStatus string          `json:"redistributionStatus"`
	Files                []ComponentFile `json:"files"`
}

type progressEvent struct {
	SchemaVersion int    `json:"schemaVersion"`
	Event         string `json:"event"`
	Filename      string `json:"filename,omitempty"`
	BytesWritten  int64  `json:"bytesWritten,omitempty"`
	TotalBytes    int64  `json:"totalBytes,omitempty"`
}

func main() {
	if len(os.Args) > 1 && os.Args[1] == "self-test" {
		fmt.Println(`{"schemaVersion":1,"selfTest":"ok"}`)
		return
	}
	fs := flag.NewFlagSet("install", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	manifestPath := fs.String("manifest", "", "absolute component manifest path")
	destinationRoot := fs.String("destination-root", "", "absolute component root")
	if len(os.Args) < 2 || os.Args[1] != "install" || fs.Parse(os.Args[2:]) != nil || *manifestPath == "" || *destinationRoot == "" {
		fmt.Fprintln(os.Stderr, "usage: IdentityVDownloaderCoreBootstrap install --manifest ABS --destination-root ABS")
		os.Exit(2)
	}
	manifest, err := readManifest(*manifestPath)
	if err == nil {
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Minute)
		defer cancel()
		err = install(ctx, manifest, *destinationRoot, defaultHTTPClient(), os.Stderr)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "downloader core acquisition failed")
		os.Exit(1)
	}
}

func readManifest(path string) (ComponentManifest, error) {
	var manifest ComponentManifest
	if !filepath.IsAbs(path) {
		return manifest, errors.New("manifest path must be absolute")
	}
	file, err := os.Open(path)
	if err != nil {
		return manifest, err
	}
	defer file.Close()
	decoder := json.NewDecoder(io.LimitReader(file, 1<<20))
	decoder.DisallowUnknownFields()
	if err = decoder.Decode(&manifest); err != nil {
		return manifest, err
	}
	if decoder.Decode(&struct{}{}) != io.EOF {
		return manifest, errors.New("manifest has trailing data")
	}
	return manifest, validateManifest(manifest)
}

func validateManifest(manifest ComponentManifest) error {
	if manifest.SchemaVersion != manifestSchema || manifest.Component != "netease-download-core" {
		return errors.New("unsupported component manifest")
	}
	if manifest.Acquisition.Mode != "download-on-first-use" ||
		manifest.Acquisition.Repository != "https://github.com/KKeygen/idv-login" ||
		!commitPattern.MatchString(manifest.Acquisition.Commit) ||
		manifest.RedistributionStatus != "not-bundled-download-on-first-use" {
		return errors.New("unsupported acquisition policy")
	}
	base, err := url.Parse(manifest.Acquisition.SourceBaseURL)
	if err != nil || base.Scheme != "https" || base.Host != "raw.githubusercontent.com" || base.RawQuery != "" || base.Fragment != "" {
		return errors.New("invalid source base URL")
	}
	wantPrefix := "/KKeygen/idv-login/" + manifest.Acquisition.Commit + "/binaries/"
	if base.Path != wantPrefix {
		return errors.New("source URL is not pinned to the declared commit")
	}
	expected := map[string]bool{"downloadIPC.exe": false, "OrbitSDK.dll": false, "aria2c.exe": false}
	if len(manifest.Files) != len(expected) {
		return errors.New("unexpected component file count")
	}
	for _, file := range manifest.Files {
		seen, allowed := expected[file.Filename]
		if !allowed || seen || filepath.Base(file.Filename) != file.Filename {
			return errors.New("invalid or duplicate component filename")
		}
		if file.ByteCount < 2 || file.ByteCount > 64<<20 || !hashPattern.MatchString(file.SHA256) {
			return errors.New("invalid component file metadata")
		}
		expected[file.Filename] = true
	}
	return nil
}

func defaultHTTPClient() *http.Client {
	return &http.Client{
		Timeout: 10 * time.Minute,
		CheckRedirect: func(request *http.Request, via []*http.Request) error {
			if len(via) >= 3 || request.URL.Scheme != "https" || request.URL.Host != "raw.githubusercontent.com" {
				return errors.New("download redirect left the pinned source host")
			}
			return nil
		},
	}
}

func emit(out io.Writer, event progressEvent) {
	_ = json.NewEncoder(out).Encode(event)
}

func install(ctx context.Context, manifest ComponentManifest, destinationRoot string, client *http.Client, out io.Writer) error {
	if err := validateManifest(manifest); err != nil {
		return err
	}
	if err := ensureRealDirectory(destinationRoot); err != nil {
		return err
	}
	version := manifest.Acquisition.Commit
	destination := filepath.Join(destinationRoot, version)
	if info, err := os.Lstat(destination); err == nil {
		if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 || verifyInstalled(destination, manifest) != nil {
			if _, err = quarantinePath(destinationRoot, destination, version); err != nil {
				return errors.New("cannot quarantine invalid component version")
			}
			emit(out, progressEvent{SchemaVersion: 1, Event: "quarantined"})
		} else {
			return updateCurrent(destinationRoot, version)
		}
	} else if !os.IsNotExist(err) {
		return err
	}
	staging, err := os.MkdirTemp(destinationRoot, ".netease-download-core-staging-")
	if err != nil {
		return err
	}
	if err = os.Chmod(staging, 0700); err != nil {
		return err
	}
	keep := false
	defer func() {
		if !keep {
			_ = os.RemoveAll(staging)
		}
	}()
	base, _ := url.Parse(manifest.Acquisition.SourceBaseURL)
	for _, component := range manifest.Files {
		source := *base
		source.Path += component.Filename
		target := filepath.Join(staging, component.Filename)
		emit(out, progressEvent{SchemaVersion: 1, Event: "downloading", Filename: component.Filename, TotalBytes: component.ByteCount})
		if err = downloadVerified(ctx, client, source.String(), target, component, out); err != nil {
			return err
		}
	}
	manifestCopy, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		return err
	}
	manifestCopy = append(manifestCopy, '\n')
	if err = writeFileSynced(filepath.Join(staging, "component.json"), manifestCopy, 0600); err != nil {
		return err
	}
	if err = verifyInstalled(staging, manifest); err != nil {
		return err
	}
	if err = os.Rename(staging, destination); err != nil {
		return err
	}
	keep = true
	if err = syncDirectory(destinationRoot); err != nil {
		return err
	}
	if err = updateCurrent(destinationRoot, version); err != nil {
		return err
	}
	emit(out, progressEvent{SchemaVersion: 1, Event: "completed"})
	return nil
}

func ensureRealDirectory(path string) error {
	if !filepath.IsAbs(path) || filepath.Clean(path) == string(filepath.Separator) {
		return errors.New("component root must be a narrow absolute path")
	}
	clean := filepath.Clean(path)
	volume := filepath.VolumeName(clean)
	current := volume + string(filepath.Separator)
	relative := strings.TrimPrefix(clean, current)
	for _, part := range strings.Split(relative, string(filepath.Separator)) {
		if part == "" {
			continue
		}
		current = filepath.Join(current, part)
		info, err := os.Lstat(current)
		if os.IsNotExist(err) {
			if err = os.Mkdir(current, 0700); err != nil {
				return err
			}
			info, err = os.Lstat(current)
		}
		if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
			return errors.New("component root contains a symlink or non-directory")
		}
	}
	return nil
}

func downloadVerified(ctx context.Context, client *http.Client, source, target string, component ComponentFile, out io.Writer) error {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, source, nil)
	if err != nil {
		return err
	}
	request.Header.Set("Accept", "application/octet-stream")
	response, err := client.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK || response.ContentLength > component.ByteCount {
		return errors.New("component download response rejected")
	}
	file, err := os.OpenFile(target, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return err
	}
	hash := sha256.New()
	limited := io.LimitReader(response.Body, component.ByteCount+1)
	written, copyErr := io.Copy(io.MultiWriter(file, hash), limited)
	if copyErr == nil {
		copyErr = file.Sync()
	}
	closeErr := file.Close()
	if copyErr != nil {
		return copyErr
	}
	if closeErr != nil {
		return closeErr
	}
	if written != component.ByteCount || hex.EncodeToString(hash.Sum(nil)) != component.SHA256 {
		return errors.New("component size or hash mismatch")
	}
	content, err := os.Open(target)
	if err != nil {
		return err
	}
	var magic [2]byte
	_, readErr := io.ReadFull(content, magic[:])
	_ = content.Close()
	if readErr != nil || string(magic[:]) != "MZ" {
		return errors.New("component is not a PE image")
	}
	emit(out, progressEvent{SchemaVersion: 1, Event: "verified", Filename: component.Filename, BytesWritten: written, TotalBytes: component.ByteCount})
	return nil
}

func verifyInstalled(directory string, manifest ComponentManifest) error {
	for _, component := range manifest.Files {
		path := filepath.Join(directory, component.Filename)
		info, err := os.Lstat(path)
		if err != nil || !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 || info.Size() != component.ByteCount {
			return errors.New("installed component file invalid")
		}
		file, err := os.Open(path)
		if err != nil {
			return err
		}
		hash := sha256.New()
		_, copyErr := io.Copy(hash, file)
		closeErr := file.Close()
		if copyErr != nil || closeErr != nil || hex.EncodeToString(hash.Sum(nil)) != component.SHA256 {
			return errors.New("installed component hash mismatch")
		}
	}
	return nil
}

func updateCurrent(root, version string) error {
	current := filepath.Join(root, "current")
	if info, err := os.Lstat(current); err == nil && info.IsDir() && info.Mode()&os.ModeSymlink == 0 {
		if _, err = quarantinePath(root, current, "current"); err != nil {
			return errors.New("cannot quarantine invalid current directory")
		}
	} else if err != nil && !os.IsNotExist(err) {
		return err
	}
	temporary := filepath.Join(root, ".current-"+fmt.Sprint(time.Now().UnixNano()))
	if err := os.Symlink(version, temporary); err != nil {
		return err
	}
	if err := os.Rename(temporary, current); err != nil {
		_ = os.Remove(temporary)
		return err
	}
	return syncDirectory(root)
}

func quarantinePath(root, source, label string) (string, error) {
	for attempt := 0; attempt < 16; attempt++ {
		name := fmt.Sprintf(".quarantine-%s-%d-%d", label, time.Now().UnixNano(), attempt)
		destination := filepath.Join(root, name)
		if _, err := os.Lstat(destination); !os.IsNotExist(err) {
			continue
		}
		if err := os.Rename(source, destination); err != nil {
			return "", err
		}
		if err := syncDirectory(root); err != nil {
			return "", err
		}
		return destination, nil
	}
	return "", errors.New("cannot allocate quarantine name")
}

func writeFileSynced(path string, data []byte, mode os.FileMode) error {
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, mode)
	if err != nil {
		return err
	}
	_, writeErr := file.Write(data)
	if writeErr == nil {
		writeErr = file.Sync()
	}
	closeErr := file.Close()
	if writeErr != nil {
		return writeErr
	}
	return closeErr
}

func syncDirectory(path string) error {
	directory, err := os.Open(path)
	if err != nil {
		return err
	}
	err = directory.Sync()
	closeErr := directory.Close()
	if err != nil {
		return err
	}
	return closeErr
}
