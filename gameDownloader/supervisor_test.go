package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/go-zeromq/zmq4"
)

func TestHelperProcess(t *testing.T) {
	if os.Getenv("GO_WANT_IDV_HELPER") != "1" {
		return
	}
	var subPort, pubPort string
	for _, a := range os.Args {
		if strings.HasPrefix(a, "--subport:") {
			subPort = "tcp://127.0.0.1:" + strings.TrimPrefix(a, "--subport:")
		}
		if strings.HasPrefix(a, "--pubport:") {
			pubPort = "tcp://127.0.0.1:" + strings.TrimPrefix(a, "--pubport:")
		}
	}
	ctx := context.Background()
	// Mirror downloadIPC's actual socket roles: core SUB receives control on
	// --subport, core PUB emits progress on --pubport.
	s := zmq4.NewSub(ctx)
	defer s.Close()
	_ = s.SetOption(zmq4.OptionSubscribe, "42")
	_ = s.Dial(subPort)
	p := zmq4.NewPub(ctx)
	defer p.Close()
	_ = p.Dial(pubPort)
	recv := make(chan zmq4.Msg, 16)
	go func() {
		for {
			m, e := s.Recv()
			if e != nil {
				return
			}
			recv <- m
		}
	}()
	type mark struct {
		PreProgressPause bool `json:"preProgressPause"`
		PauseCount       int  `json:"pauseCount"`
		FinishCount      int  `json:"finishCount"`
	}
	m := mark{}
	write := func() {
		if q := os.Getenv("IDV_HELPER_MARKER"); q != "" {
			b, _ := json.Marshal(m)
			tmp := q + ".tmp"
			_ = os.WriteFile(tmp, b, 0600)
			_ = os.Rename(tmp, q)
		}
	}
	mode := os.Getenv("IDV_HELPER_MODE")
	if mode == "bad" {
		for i := 0; i < 10; i++ {
			_ = p.Send(zmq4.NewMsgFromString([]string{"42", "1", "not-json"}))
			time.Sleep(30 * time.Millisecond)
		}
		time.Sleep(5 * time.Second)
		os.Exit(0)
	}
	if mode == "cancel" || mode == "hang" {
		time.Sleep(5 * time.Second)
		os.Exit(0)
	}
	// No progress is sent until a heartbeat arrives; pause here would be a protocol failure.
	gotHB := false
	until := time.After(4 * time.Second)
	for !gotHB {
		select {
		case x := <-recv:
			if len(x.Frames) == 2 {
				if string(x.Frames[1]) == "4" {
					gotHB = true
				}
				if string(x.Frames[1]) == "1" {
					m.PreProgressPause = true
				}
			}
		case <-until:
			write()
			os.Exit(5)
		}
	}
	for i := 0; i < 10; i++ {
		_ = p.Send(zmq4.NewMsgFromString([]string{"42", "1", "{}"}))
		time.Sleep(25 * time.Millisecond)
	}
	if mode == "idle" {
		time.Sleep(5 * time.Second)
		os.Exit(0)
	}
	until = time.After(3 * time.Second)
	for m.PauseCount == 0 {
		select {
		case x := <-recv:
			if len(x.Frames) == 2 && string(x.Frames[1]) == "1" {
				m.PauseCount++
			}
		case <-until:
			write()
			os.Exit(6)
		}
	}
	for i := 0; i < 80 && m.FinishCount == 0; i++ {
		_ = p.Send(zmq4.NewMsgFromString([]string{"42", "8", "{}"}))
		select {
		case x := <-recv:
			if len(x.Frames) == 2 {
				if string(x.Frames[1]) == "1" {
					m.PauseCount++
				}
				if string(x.Frames[1]) == "3" {
					m.FinishCount++
				}
			}
		default:
		}
		time.Sleep(30 * time.Millisecond)
	}
	// Duplicate terminal frames are possible while the core drains.  They must
	// not result in duplicate synchronous finish commands.
	for i := 0; i < 4; i++ {
		_ = p.Send(zmq4.NewMsgFromString([]string{"42", "8", "{}"}))
		time.Sleep(30 * time.Millisecond)
		select {
		case x := <-recv:
			if len(x.Frames) == 2 && string(x.Frames[1]) == "3" {
				m.FinishCount++
			}
		default:
		}
	}
	write()
	if m.FinishCount != 1 {
		os.Exit(7)
	}
	if mode == "nonzero" {
		os.Exit(3)
	}
	os.Exit(0)
}

func TestTaskValidationAndArgs(t *testing.T) {
	task := testTask(t)
	task.TargetVersion = "v3_4220_229300afaa11f1da1aa4af7379c2a648"
	if err := validateTask(task); err != nil {
		t.Fatal(err)
	}
	args := coreArgs(task, "tcp://127.0.0.1:1212", "tcp://127.0.0.1:3434")
	if !hasPrefix(args, "--path:") || !hasPrefix(args, "--repairListPath:") || contains(args, task.DownloadRootWindows) {
		t.Fatal("Windows paths must be base64 argv values")
	}
	if !contains(args, "--subport:1212") || !contains(args, "--pubport:3434") {
		t.Fatal("downloadIPC control/progress port roles are reversed")
	}
	task.Oversea = true
	if !contains(coreArgs(task, "tcp://127.0.0.1:1212", "tcp://127.0.0.1:3434"), "--oversea:1") {
		t.Fatal("global core route was not explicit")
	}
	task.ContentID = "-1"
	if validateTask(task) == nil {
		t.Fatal("negative content ID accepted")
	}
}

func TestReadControlDeduplicatableAndInvalid(t *testing.T) {
	d := t.TempDir()
	p := filepath.Join(d, "control.json")
	if _, ok, e := readControl(p); e != nil || ok {
		t.Fatal("missing control should be idle")
	}
	if err := os.WriteFile(p, []byte(`{"schemaVersion":1,"sequence":2,"action":"pause"}`), 0600); err != nil {
		t.Fatal(err)
	}
	c, ok, e := readControl(p)
	if e != nil || !ok || c.Sequence != 2 || c.Action != "pause" {
		t.Fatal("valid control rejected")
	}
	if err := os.WriteFile(p, []byte(`{"schemaVersion":1,"sequence":3,"action":"cancel"}`), 0600); err != nil {
		t.Fatal(err)
	}
	if c, ok, e := readControl(p); e != nil || !ok || c.Action != "cancel" {
		t.Fatal("cancel control rejected")
	}
	if err := os.WriteFile(p, []byte(`{"schemaVersion":1,"sequence":4,"action":"stop"}`), 0600); err != nil {
		t.Fatal(err)
	}
	if _, _, e := readControl(p); e == nil {
		t.Fatal("invalid action accepted")
	}
	if err := os.WriteFile(p, []byte(`{"schemaVersion":1,"sequence":5,"action":"pause","extra":true}`), 0600); err != nil {
		t.Fatal(err)
	}
	if _, _, e := readControl(p); e == nil {
		t.Fatal("unknown control field accepted")
	}
}

func TestCancelControlStopsExactCoreGroup(t *testing.T) {
	task := runTask(t)
	old := os.Getenv("GO_WANT_IDV_HELPER")
	defer os.Setenv("GO_WANT_IDV_HELPER", old)
	oldMode := os.Getenv("IDV_HELPER_MODE")
	defer os.Setenv("IDV_HELPER_MODE", oldMode)
	os.Setenv("GO_WANT_IDV_HELPER", "1")
	os.Setenv("IDV_HELPER_MODE", "cancel")
	started := make(chan int, 1)
	sup := NewSupervisor(task, io.Discard)
	sup.command = func(_ string, args ...string) *exec.Cmd {
		return exec.Command(os.Args[0], append([]string{"-test.run=TestHelperProcess", "--"}, args...)...)
	}
	sup.environment = func(task Task) []string {
		return append(controlledWineEnv(task), "GO_WANT_IDV_HELPER=1", "IDV_HELPER_MODE=cancel")
	}
	sup.started = func(pid int) { started <- pid }
	done := make(chan error, 1)
	go func() { done <- sup.Run(context.Background()) }()
	pid := <-started
	if err := os.WriteFile(task.ControlFile, []byte(`{"schemaVersion":1,"sequence":1,"action":"cancel"}`), 0600); err != nil {
		t.Fatal(err)
	}
	if err := <-done; !errors.Is(err, ErrCancelled) {
		t.Fatalf("want cancel, got %v", err)
	}
	for i := 0; i < 20; i++ {
		if err := syscall.Kill(pid, 0); err == syscall.ESRCH {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("cancelled core PID %d remained alive", pid)
}

func TestProgressOutputIsAllowlisted(t *testing.T) {
	var output bytes.Buffer
	supervisor := NewSupervisor(testTask(t), &output)
	payload := json.RawMessage(`{"StateFlags":4,"ShowDownloadPercent":0.5,"ShowDownloadRate":1024,"ShowDownloadSize":4096,"token":"secret","path":"C:\\Users\\name"}`)
	if err := supervisor.emit("4", payload); err != nil {
		t.Fatal(err)
	}
	text := output.String()
	if strings.Contains(text, "secret") || strings.Contains(text, "Users") || strings.Contains(text, `"token"`) || strings.Contains(text, `"path"`) {
		t.Fatal("untrusted vendor payload crossed diagnostic boundary")
	}
	if !strings.Contains(text, `"bytesPerSecond":1024`) || !strings.Contains(text, `"payloadSha256"`) {
		t.Fatal("allowlisted progress metrics missing")
	}
	if _, err := sanitizeProgress("4", json.RawMessage(`{"StateFlags":3}`)); err == nil {
		t.Fatal("mismatched state accepted")
	}
}

func TestProgressProtocolRejectsMalformed(t *testing.T) {
	if validState("101") || validState("206") || validState("-1") || validState("12") {
		t.Fatal("failure or unknown state accepted")
	}
	if !auxiliaryState("10") || validState("10") {
		t.Fatal("opaque control acknowledgement is not isolated")
	}
	if !auxiliaryState("2001") || !auxiliaryState("2002") || !auxiliaryState("2005") || !auxiliaryState("2006") || auxiliaryState("2003") {
		t.Fatal("auxiliary state allowlist is not exact")
	}
	if !validState("8") {
		t.Fatal("completion state rejected")
	}
}

// This peer uses the same package's public ZeroMQ API, never Wine or the network.
func TestMockPeerNormalSequenceAndFinish(t *testing.T) {
	var err error
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	sub := zmq4.NewSub(ctx)
	defer sub.Close()
	if err = sub.SetOption(zmq4.OptionSubscribe, "42"); err != nil {
		t.Fatal(err)
	}
	progressEndpoint, err := listenLocal(sub)
	if err != nil {
		t.Fatal(err)
	}
	pub := zmq4.NewPub(ctx)
	defer pub.Close()
	controlEndpoint, err := listenLocal(pub)
	if err != nil {
		t.Fatal(err)
	}
	peerPub := zmq4.NewPub(ctx)
	defer peerPub.Close()
	if err = peerPub.Dial(progressEndpoint); err != nil {
		t.Fatal(err)
	}
	peerSub := zmq4.NewSub(ctx)
	defer peerSub.Close()
	if err = peerSub.SetOption(zmq4.OptionSubscribe, "42"); err != nil {
		t.Fatal(err)
	}
	if err = peerSub.Dial(controlEndpoint); err != nil {
		t.Fatal(err)
	}
	// PUB/SUB subscriptions propagate asynchronously; retry a harmless state frame.
	for i := 0; i < 8; i++ {
		_ = peerPub.Send(zmq4.NewMsgFromString([]string{"42", "8", `{"progress":100}`}))
		time.Sleep(50 * time.Millisecond)
	}
	m, err := sub.Recv()
	if err != nil {
		t.Fatal(err)
	}
	if len(m.Frames) != 3 || string(m.Frames[1]) != "8" {
		t.Fatal("normal state frame not received")
	}
	if err = pub.Send(zmq4.NewMsgFromString([]string{"42", "3"})); err != nil {
		t.Fatal(err)
	}
	m, err = peerSub.Recv()
	if err != nil {
		t.Fatal(err)
	}
	if len(m.Frames) != 2 || string(m.Frames[1]) != "3" {
		t.Fatal("finish control not received")
	}
	var payload map[string]int
	if json.Unmarshal(mustFrame(t, zmq4.NewMsgFromString([]string{`{"progress":100}`})), &payload) != nil || payload["progress"] != 100 {
		t.Fatal("payload fixture invalid")
	}
}

func TestSignalShutdownHelper(t *testing.T) {
	// stopProcess is idempotent before a process has been started, which is the
	// fail-safe used after context cancellation during launch races.
	stopProcess(&exec.Cmd{}, make(chan error))
}

func TestCoreExitErrorIsStableAndDoesNotLeakLaunchContext(t *testing.T) {
	t.Run("normal exit before completion", func(t *testing.T) {
		if got := coreExitError(nil).Error(); got != "core exited before completion" {
			t.Fatalf("got %q", got)
		}
	})
	t.Run("nonzero exit", func(t *testing.T) {
		cmd := exec.Command("/bin/sh", "-c", "exit 23")
		err := cmd.Run()
		if got := coreExitError(err).Error(); got != "core exited with code 23" {
			t.Fatalf("got %q (run error %v)", got, err)
		}
	})
	t.Run("signal termination", func(t *testing.T) {
		cmd := exec.Command("/bin/sh", "-c", "kill -TERM $$")
		err := cmd.Run()
		if got := coreExitError(err).Error(); got != "core terminated by signal 15" {
			t.Fatalf("got %q (run error %v)", got, err)
		}
	})
	t.Run("unknown error is redacted", func(t *testing.T) {
		got := coreExitError(errors.New("/private/vendor/path token=secret")).Error()
		if got != "core execution failed" || strings.Contains(got, "secret") || strings.Contains(got, "path") {
			t.Fatalf("unsafe diagnostic %q", got)
		}
	})
}

func TestRunLifecycle(t *testing.T) {
	for _, tc := range []struct {
		name, mode string
		wantErr    bool
	}{{"success", "", false}, {"nonzero", "nonzero", true}, {"bad-json", "bad", true}, {"cancel", "cancel", true}, {"startup-timeout", "hang", true}, {"idle-timeout", "idle", true}} {
		t.Run(tc.name, func(t *testing.T) {
			task := runTask(t)
			marker := filepath.Join(filepath.Dir(task.ControlFile), "marker")
			if tc.name == "success" || tc.name == "nonzero" {
				_ = os.WriteFile(task.ControlFile, []byte(`{"schemaVersion":1,"sequence":9,"action":"pause"}`), 0600)
			}
			old1, old2 := os.Getenv("GO_WANT_IDV_HELPER"), os.Getenv("IDV_HELPER_MODE")
			defer os.Setenv("GO_WANT_IDV_HELPER", old1)
			defer os.Setenv("IDV_HELPER_MODE", old2)
			defer os.Unsetenv("IDV_HELPER_MARKER")
			os.Setenv("GO_WANT_IDV_HELPER", "1")
			os.Setenv("IDV_HELPER_MODE", tc.mode)
			os.Setenv("IDV_HELPER_MARKER", marker)
			r, w, e := os.Pipe()
			if e != nil {
				t.Fatal(e)
			}
			defer r.Close()
			ctx := context.Background()
			var cancel context.CancelFunc
			if tc.mode == "cancel" {
				ctx, cancel = context.WithTimeout(ctx, 300*time.Millisecond)
				defer cancel()
			}
			sup := NewSupervisor(task, w)
			if tc.mode == "hang" {
				sup.startupTimeout = 150 * time.Millisecond
			}
			if tc.mode == "idle" {
				sup.idleTimeout = 150 * time.Millisecond
			}
			sup.command = func(_ string, args ...string) *exec.Cmd {
				return exec.Command(os.Args[0], append([]string{"-test.run=TestHelperProcess", "--"}, args...)...)
			}
			sup.environment = func(task Task) []string {
				result := controlledWineEnv(task)
				for _, key := range []string{"GO_WANT_IDV_HELPER", "IDV_HELPER_MODE", "IDV_HELPER_MARKER"} {
					if value, present := os.LookupEnv(key); present {
						result = append(result, key+"="+value)
					}
				}
				return result
			}
			err := sup.Run(ctx)
			_ = w.Close()
			if (err != nil) != tc.wantErr {
				t.Fatalf("err=%v", err)
			}
			if tc.name == "success" || tc.name == "nonzero" {
				var m struct {
					PreProgressPause bool `json:"preProgressPause"`
					PauseCount       int  `json:"pauseCount"`
					FinishCount      int  `json:"finishCount"`
				}
				b, e := os.ReadFile(marker)
				if e != nil || json.Unmarshal(b, &m) != nil || m.PreProgressPause || m.PauseCount != 1 || m.FinishCount != 1 {
					t.Fatalf("marker=%q parsed=%+v", b, m)
				}
			}
		})
	}
}

func TestControlledWineEnvironmentExcludesCallerSecrets(t *testing.T) {
	t.Setenv("PATH", "/usr/bin:/bin")
	t.Setenv("OPENAI_API_KEY", "must-not-cross-boundary")
	t.Setenv("SSH_AUTH_SOCK", "/private/tmp/agent.sock")
	t.Setenv("HTTPS_PROXY", "http://127.0.0.1:9999")
	t.Setenv("DYLD_INSERT_LIBRARIES", "/private/tmp/inject.dylib")
	task := testTask(t)
	environment := controlledWineEnv(task)
	if !contains(environment, "PATH=/usr/bin:/bin") || !contains(environment, "WINEPREFIX="+task.WinePrefix) {
		t.Fatal("required Wine environment was not preserved")
	}
	for _, entry := range environment {
		for _, forbidden := range []string{"OPENAI_API_KEY=", "SSH_AUTH_SOCK=", "HTTPS_PROXY=", "DYLD_INSERT_LIBRARIES="} {
			if strings.HasPrefix(entry, forbidden) {
				t.Fatalf("caller secret crossed boundary: %s", forbidden)
			}
		}
	}
}

func TestTaskAndFilesystemRejectUnknownOrSymlink(t *testing.T) {
	task := runTask(t)
	encoded, err := json.Marshal(task)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(filepath.Dir(task.CoreExecutable), "task.json")
	if err = os.WriteFile(path, encoded, 0600); err != nil {
		t.Fatal(err)
	}
	if _, err = loadTask(path); err != nil {
		t.Fatal(err)
	}
	unknown := append(encoded[:len(encoded)-1], []byte(`,"extra":true}`)...)
	if err = os.WriteFile(path, unknown, 0600); err != nil {
		t.Fatal(err)
	}
	if _, err = loadTask(path); err == nil {
		t.Fatal("unknown task field accepted")
	}
	if err = os.WriteFile(path, encoded, 0600); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(filepath.Dir(path), "task-link.json")
	if err = os.Symlink(path, link); err != nil {
		t.Fatal(err)
	}
	if _, err = loadTask(link); err == nil {
		t.Fatal("symlink task accepted")
	}
	coreLink := filepath.Join(filepath.Dir(task.CoreExecutable), "core-link.exe")
	if err = os.Symlink(task.CoreExecutable, coreLink); err != nil {
		t.Fatal(err)
	}
	task.CoreExecutable = coreLink
	if validateFilesystem(task) == nil {
		t.Fatal("symlink core accepted")
	}
}
func runTask(t *testing.T) Task {
	d := t.TempDir()
	core := filepath.Join(d, "core.exe")
	if err := os.WriteFile(core, []byte("PE"), 0644); err != nil {
		t.Fatal(err)
	}
	return Task{SchemaVersion: 1, ContentID: "42", DistributionID: "7", CoreExecutable: core, CoreWorkingDirectory: d, WineExecutable: os.Args[0], WinePrefix: d, DownloadRootWindows: `C:\\Game`, RepairListWindows: `C:\\repair.json`, TargetVersion: "v1_2", ControlFile: filepath.Join(d, "control.json")}
}

func testTask(t *testing.T) Task {
	d := t.TempDir()
	return Task{SchemaVersion: 1, ContentID: "42", DistributionID: "7", CoreExecutable: "/bin/true", CoreWorkingDirectory: d, WineExecutable: "/bin/true", WinePrefix: d, DownloadRootWindows: `C:\\Game`, RepairListWindows: `C:\\repair.json`, TargetVersion: "v1_2", OriginVersion: "", ControlFile: filepath.Join(d, "control.json")}
}
func contains(a []string, v string) bool {
	for _, x := range a {
		if x == v {
			return true
		}
	}
	return false
}
func hasPrefix(a []string, v string) bool {
	for _, x := range a {
		if strings.HasPrefix(x, v) {
			return true
		}
	}
	return false
}
func mustFrame(t *testing.T, m zmq4.Msg) []byte {
	t.Helper()
	if len(m.Frames) != 1 {
		t.Fatal("fixture")
	}
	return m.Frames[0]
}
