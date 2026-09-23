package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"testing"

	"github.com/cespare/xxhash/v2"
)

func testManifest(path string, b []byte) Manifest {
	return Manifest{SchemaVersion: 1, ProductID: "mainland", Adapter: "netease-loadingbay-v1", DistributionID: 1, GameID: "h123", DisplayName: "Identity V", StartupPath: "bin/game.exe", VersionCode: "v1_2_0123456789abcdef0123456789abcdef", ContentID: 1, TotalByteCount: int64(len(b)), Files: []FileEntry{{Path: path, ByteCount: int64(len(b)), XXH64: fmtHash(b)}}, FetchedAt: "2026-08-28T12:00:00Z"}
}
func fmtHash(b []byte) string { return fmt.Sprintf("%016x", xxhash.Sum64(b)) }
func ptr(v int) *int          { return &v }
func TestXXH64Vector(t *testing.T) {
	if xxhash.Sum64String("hello") != 0x26c7827d889f6da3 {
		t.Fatal("bad known vector")
	}
}
func TestSwiftShapeFixtureAndPlan(t *testing.T) {
	root, outDir := t.TempDir(), t.TempDir()
	b := []byte("contents")
	m := testManifest("z.bin", b)
	m.Files = append(m.Files, FileEntry{Path: "a.bin", ByteCount: 1, XXH64: fmtHash([]byte("a"))})
	m.TotalByteCount++
	if e := validateManifest(m); e != nil {
		t.Fatal(e)
	}
	bad, s, e := scan(context.Background(), m, root)
	if e != nil || len(bad) != 2 || bad[0] != "z.bin" || bad[1] != "a.bin" {
		t.Fatal(e, bad)
	}
	out := filepath.Join(outDir, "repair")
	if e = writeRepairList(out, bad); e != nil {
		t.Fatal(e)
	}
	got, e := os.ReadFile(out)
	if e != nil || string(got) != "z.bin\na.bin\n" {
		t.Fatal(e, string(got))
	}
	i, e := os.Stat(out)
	if e != nil || i.Mode().Perm() != 0600 {
		t.Fatal(e, i.Mode())
	}
	if s.FilesScanned != 2 {
		t.Fatal(s)
	}
	if e = os.WriteFile(filepath.Join(root, "z.bin"), b, 0600); e != nil {
		t.Fatal(e)
	}
	if e = os.WriteFile(filepath.Join(root, "a.bin"), []byte("a"), 0600); e != nil {
		t.Fatal(e)
	}
	bad, _, e = scan(context.Background(), m, root)
	if e != nil || len(bad) != 0 {
		t.Fatal(e, bad)
	}
	if e = os.WriteFile(filepath.Join(root, "a.bin"), []byte("x"), 0600); e != nil {
		t.Fatal(e)
	}
	bad, _, e = scan(context.Background(), m, root)
	if e != nil || len(bad) != 1 {
		t.Fatal(e, bad)
	}
}
func TestSchemaAndDangerousPaths(t *testing.T) {
	m := testManifest("a", []byte("x"))
	for _, p := range []string{"../x", "a//b", "a\\b", "a:b", "."} {
		m.Files[0].Path = p
		if validateManifest(m) == nil {
			t.Fatal(p)
		}
	}
	m = testManifest("a", []byte("x"))
	m.ProductID = "other"
	if validateManifest(m) == nil {
		t.Fatal("identity")
	}
	m = testManifest("a", []byte("x"))
	m.Files[0].Operation = ptr(-1)
	if validateManifest(m) == nil {
		t.Fatal("op")
	}
	m = testManifest("a", []byte("x"))
	m.Files[0].Operation = ptr(2)
	if validateManifest(m) == nil {
		t.Fatal("unsupported non-install operation")
	}
	m = testManifest("a", []byte("x"))
	m.Directories = []DirectoryEntry{{Path: "a"}}
	if validateManifest(m) == nil {
		t.Fatal("duplicate")
	}
	m = testManifest("Data/File.bin", []byte("x"))
	m.Files = append(m.Files, FileEntry{Path: "data/file.BIN", ByteCount: 1, XXH64: fmtHash([]byte("x"))})
	m.TotalByteCount++
	if validateManifest(m) == nil {
		t.Fatal("case-insensitive duplicate")
	}
}
func TestMissingAncestorsAndSymlinkRejection(t *testing.T) {
	root := t.TempDir()
	m := testManifest("new/deep/file", []byte("x"))
	bad, _, e := scan(context.Background(), m, root)
	if e != nil || len(bad) != 1 {
		t.Fatal(e, bad)
	}
	outside := t.TempDir()
	if e = os.Symlink(outside, filepath.Join(root, "link")); e != nil {
		t.Fatal(e)
	}
	m = testManifest("link/x", []byte("x"))
	if _, _, e = scan(context.Background(), m, root); e == nil {
		t.Fatal("symlink accepted")
	}
}
func TestAtomicFailureAndCancellation(t *testing.T) {
	d := t.TempDir()
	out := filepath.Join(d, "repairs")
	if e := os.WriteFile(out, []byte("old\n"), 0600); e != nil {
		t.Fatal(e)
	}
	old := renameFile
	renameFile = func(string, string) error { return errors.New("rename failure") }
	defer func() { renameFile = old }()
	if writeRepairList(out, []string{"new"}) == nil {
		t.Fatal("expected failure")
	}
	b, e := os.ReadFile(out)
	if e != nil || string(b) != "old\n" {
		t.Fatal(e, string(b))
	}
	m := testManifest("a", []byte("x"))
	for n := 0; n < 100; n++ {
		m.Files = append(m.Files, FileEntry{Path: fmt.Sprintf("missing/%d", n), ByteCount: 1, XXH64: fmtHash([]byte("x"))})
		m.TotalByteCount++
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, _, e = scan(ctx, m, d); !errors.Is(e, context.Canceled) {
		t.Fatal(e)
	}
}

func TestCLIPlanVerifyAndStrictJSON(t *testing.T) {
	root, outDir := t.TempDir(), t.TempDir()
	m := testManifest("one.bin", []byte("x"))
	manifest := filepath.Join(outDir, "manifest.json")
	b, _ := json.Marshal(m)
	if e := os.WriteFile(manifest, b, 0600); e != nil {
		t.Fatal(e)
	}
	bin := filepath.Join(outDir, "planner")
	if out, e := exec.Command("go", "build", "-o", bin, ".").CombinedOutput(); e != nil {
		t.Fatal(e, string(out))
	}
	repair := filepath.Join(outDir, "repair")
	if out, e := exec.Command(bin, "plan", "--manifest", manifest, "--root", root, "--repair-list", repair).CombinedOutput(); e != nil {
		t.Fatal(e, string(out))
	}
	if got, _ := os.ReadFile(repair); string(got) != "one.bin\n" {
		t.Fatal(string(got))
	}
	if e := os.WriteFile(filepath.Join(root, "one.bin"), []byte("x"), 0600); e != nil {
		t.Fatal(e)
	}
	if out, e := exec.Command(bin, "verify", "--manifest", manifest, "--root", root).CombinedOutput(); e != nil {
		t.Fatal(e, string(out))
	}
	if e := os.WriteFile(filepath.Join(root, "one.bin"), []byte("bad"), 0600); e != nil {
		t.Fatal(e)
	}
	if e := exec.Command(bin, "verify", "--manifest", manifest, "--root", root).Run(); e == nil {
		t.Fatal("bad file verified")
	}
	if e := os.WriteFile(manifest, []byte(`{"schemaVersion":"wrong"}`), 0600); e != nil {
		t.Fatal(e)
	}
	if _, e := readManifest(manifest); e == nil {
		t.Fatal("wrong numeric type accepted")
	}
	if e := os.WriteFile(manifest, append(b[:len(b)-1], []byte(`,"unknown":true}`)...), 0600); e != nil {
		t.Fatal(e)
	}
	if _, e := readManifest(manifest); e == nil {
		t.Fatal("unknown field accepted")
	}
}
