package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/go-zeromq/zmq4"
)

const taskSchemaVersion = 1

var ErrCancelled = errors.New("download cancelled by control file")

type Task struct {
	SchemaVersion        int    `json:"schemaVersion"`
	ContentID            string `json:"contentId"`
	DistributionID       string `json:"distributionId"`
	CoreExecutable       string `json:"coreExecutable"`
	CoreWorkingDirectory string `json:"coreWorkingDirectory"`
	WineExecutable       string `json:"wineExecutable"`
	WinePrefix           string `json:"winePrefix"`
	DownloadRootWindows  string `json:"downloadRootWindows"`
	RepairListWindows    string `json:"repairListWindows"`
	TargetVersion        string `json:"targetVersion"`
	OriginVersion        string `json:"originVersion"`
	// Oversea selects the vendor core's global-service route.  It is explicit
	// rather than inferred from an ID: mainland remains the schema-1 default.
	Oversea     bool   `json:"oversea"`
	ControlFile string `json:"controlFile"`
}

type control struct {
	SchemaVersion int    `json:"schemaVersion"`
	Sequence      uint64 `json:"sequence"`
	Action        string `json:"action"`
}

func loadTask(path string) (Task, error) {
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 {
		return Task{}, errors.New("task must be a real regular file")
	}
	b, err := readBoundedFile(path, 64<<10)
	if err != nil {
		return Task{}, errors.New("cannot read task")
	}
	var t Task
	if decodeStrictJSON(b, &t) != nil {
		return Task{}, errors.New("invalid task JSON")
	}
	if err := validateTask(t); err != nil {
		return Task{}, err
	}
	return t, validateFilesystem(t)
}

func readBoundedFile(path string, maximum int64) ([]byte, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, maximum+1))
	if err != nil || int64(len(data)) > maximum {
		return nil, errors.New("file exceeds limit")
	}
	return data, nil
}

func decodeStrictJSON(data []byte, target any) error {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		return err
	}
	if decoder.Decode(&struct{}{}) != io.EOF {
		return errors.New("JSON has trailing data")
	}
	return nil
}

func validateTask(t Task) error {
	if t.SchemaVersion != taskSchemaVersion {
		return errors.New("unsupported task schema")
	}
	for _, n := range []string{t.ContentID, t.DistributionID} {
		if _, err := strconv.ParseUint(n, 10, 64); err != nil || n == "0" {
			return errors.New("identifier must be a positive decimal integer")
		}
	}
	for _, p := range []string{t.CoreExecutable, t.CoreWorkingDirectory, t.WineExecutable, t.WinePrefix, t.ControlFile} {
		if !filepath.IsAbs(p) {
			return errors.New("macOS paths must be absolute")
		}
	}
	if !windowsPathOK(t.DownloadRootWindows) || !windowsPathOK(t.RepairListWindows) {
		return errors.New("Windows paths are required")
	}
	if !versionOK(t.TargetVersion) || (t.OriginVersion != "" && !versionOK(t.OriginVersion)) {
		return errors.New("invalid version")
	}
	return nil
}
func versionOK(v string) bool {
	if len(v) < 4 || len(v) > 128 || v[0] != 'v' {
		return false
	}
	p := strings.Split(v[1:], "_")
	if len(p) != 2 && len(p) != 3 {
		return false
	}
	for _, n := range p[:2] {
		if n == "" {
			return false
		}
		for _, c := range n {
			if c < '0' || c > '9' {
				return false
			}
		}
	}
	if len(p) == 3 {
		if len(p[2]) != 32 {
			return false
		}
		for _, c := range p[2] {
			if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
				return false
			}
		}
	}
	return true
}
func windowsPathOK(v string) bool {
	if len(v) == 0 || len(v) > 4096 || strings.ContainsAny(v, "\x00\r\n") || strings.Contains(v, "..") {
		return false
	}
	return (len(v) >= 3 && ((v[0] >= 'A' && v[0] <= 'Z') || (v[0] >= 'a' && v[0] <= 'z')) && v[1] == ':' && (v[2] == '\\' || v[2] == '/')) || strings.HasPrefix(v, `\\`)
}
func validateFilesystem(t Task) error {
	for _, p := range []string{t.CoreWorkingDirectory, t.WinePrefix} {
		i, e := os.Lstat(p)
		if e != nil || !i.IsDir() || i.Mode()&os.ModeSymlink != 0 {
			return errors.New("required directory unavailable")
		}
	}
	// The Windows core is a PE file: it need only be a readable regular file.
	i, e := os.Lstat(t.CoreExecutable)
	if e != nil || !i.Mode().IsRegular() || i.Mode()&os.ModeSymlink != 0 || i.Mode().Perm()&0444 == 0 {
		return errors.New("required core unavailable")
	}
	// Wine itself is a native program and must be executable.
	for _, p := range []string{t.WineExecutable} {
		i, e := os.Lstat(p)
		if e != nil || !i.Mode().IsRegular() || i.Mode()&os.ModeSymlink != 0 || i.Mode()&0111 == 0 {
			return errors.New("required executable unavailable")
		}
	}
	rel, e := filepath.Rel(t.CoreWorkingDirectory, t.CoreExecutable)
	if e != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(os.PathSeparator)) {
		return errors.New("core must be inside working directory")
	}
	controlParent := filepath.Dir(t.ControlFile)
	if info, err := os.Lstat(controlParent); err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return errors.New("control directory unavailable")
	}
	if info, err := os.Lstat(t.ControlFile); err == nil {
		if !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 {
			return errors.New("control file is not regular")
		}
	} else if !os.IsNotExist(err) {
		return errors.New("control file unavailable")
	}
	return nil
}
func listenLocal(sock zmq4.Socket) (string, error) {
	if e := sock.Listen("tcp://127.0.0.1:0"); e != nil {
		return "", e
	}
	a := sock.Addr()
	if a == nil {
		return "", errors.New("ZMQ did not report listener address")
	}
	return "tcp://" + a.String(), nil
}

func coreArgs(t Task, controlEndpoint, progressEndpoint string) []string {
	b64 := func(s string) string { return base64.StdEncoding.EncodeToString([]byte(s)) }
	oversea := "--oversea:0"
	if t.Oversea {
		oversea = "--oversea:1"
	}
	// downloadIPC names these ports from the core's point of view: its SUB
	// socket receives UI control/heartbeat frames, while its PUB socket emits
	// progress frames.  The supervisor therefore passes the control PUB
	// endpoint as --subport and the progress SUB endpoint as --pubport.
	return []string{t.CoreExecutable, "--gameid:" + t.DistributionID, "--env:live", oversea, "--scene:3", "--rateLimit:0", "--channel:platform", "--locale:zh_Hans", "--isSSD:1", "--isRepairMode:1", "--contentid:" + t.ContentID, "--subport:" + strings.TrimPrefix(controlEndpoint, "tcp://127.0.0.1:"), "--pubport:" + strings.TrimPrefix(progressEndpoint, "tcp://127.0.0.1:"), "--path:" + b64(t.DownloadRootWindows), "--repairListPath:" + b64(t.RepairListWindows), "--targetVersion:" + t.TargetVersion, "--originVersion:" + t.OriginVersion}
}

type Supervisor struct {
	task           Task
	out            io.Writer
	pollInterval   time.Duration
	startupTimeout time.Duration
	idleTimeout    time.Duration
	command        func(string, ...string) *exec.Cmd
	environment    func(Task) []string
	started        func(int) // test-only observation hook; never set by production callers
}

func NewSupervisor(task Task, out io.Writer) *Supervisor {
	return &Supervisor{
		task: task, out: out,
		pollInterval:   100 * time.Millisecond,
		startupTimeout: 90 * time.Second,
		idleTimeout:    5 * time.Minute,
	}
}

type progressStage struct {
	Percent        float64 `json:"percent"`
	BytesPerSecond float64 `json:"bytesPerSecond"`
	TotalBytes     float64 `json:"totalBytes"`
}

type sanitizedProgress struct {
	StateFlags       int           `json:"stateFlags"`
	DownloadHead     progressStage `json:"downloadHead"`
	Download         progressStage `json:"download"`
	Build            progressStage `json:"build"`
	VerifyPercent    float64       `json:"verifyPercent"`
	PayloadByteCount int           `json:"payloadByteCount"`
	PayloadSHA256    string        `json:"payloadSha256"`
}

func numericField(data map[string]json.RawMessage, key string, maximum float64) (float64, error) {
	raw, present := data[key]
	if !present {
		return 0, nil
	}
	var number json.Number
	if err := json.Unmarshal(raw, &number); err != nil {
		return 0, errors.New("invalid progress number")
	}
	value, err := strconv.ParseFloat(string(number), 64)
	if err != nil || math.IsNaN(value) || math.IsInf(value, 0) || value < 0 || value > maximum {
		return 0, errors.New("progress number outside range")
	}
	return value, nil
}

func sanitizeProgress(state string, payload json.RawMessage) (sanitizedProgress, error) {
	var data map[string]json.RawMessage
	if err := json.Unmarshal(payload, &data); err != nil || data == nil {
		return sanitizedProgress{}, errors.New("invalid progress JSON for state " + state)
	}
	frameState, err := strconv.Atoi(state)
	if err != nil {
		return sanitizedProgress{}, errors.New("progress state is not numeric")
	}
	stateFlags := frameState
	if raw, present := data["StateFlags"]; present {
		if err = json.Unmarshal(raw, &stateFlags); err != nil || stateFlags != frameState {
			return sanitizedProgress{}, errors.New("progress payload state mismatch")
		}
	}
	stage := func(prefix string) (progressStage, error) {
		percent, stageErr := numericField(data, "Show"+prefix+"Percent", 100)
		if stageErr != nil {
			return progressStage{}, stageErr
		}
		rate, stageErr := numericField(data, "Show"+prefix+"Rate", 1e15)
		if stageErr != nil {
			return progressStage{}, stageErr
		}
		total, stageErr := numericField(data, "Show"+prefix+"Size", 1e15)
		if stageErr != nil {
			return progressStage{}, stageErr
		}
		return progressStage{Percent: percent, BytesPerSecond: rate, TotalBytes: total}, nil
	}
	downloadHead, err := stage("DownloadHead")
	if err != nil {
		return sanitizedProgress{}, err
	}
	download, err := stage("Download")
	if err != nil {
		return sanitizedProgress{}, err
	}
	build, err := stage("Build")
	if err != nil {
		return sanitizedProgress{}, err
	}
	verify, err := numericField(data, "ShowVerifyPercent", 100)
	if err != nil {
		return sanitizedProgress{}, err
	}
	digest := sha256.Sum256(payload)
	return sanitizedProgress{
		StateFlags:       stateFlags,
		DownloadHead:     downloadHead,
		Download:         download,
		Build:            build,
		VerifyPercent:    verify,
		PayloadByteCount: len(payload),
		PayloadSHA256:    fmt.Sprintf("%x", digest),
	}, nil
}

func (s *Supervisor) emit(state string, payload json.RawMessage) error {
	progress, err := sanitizeProgress(state, payload)
	if err != nil {
		return err
	}
	line, _ := json.Marshal(struct {
		SchemaVersion int               `json:"schemaVersion"`
		ContentID     string            `json:"contentId"`
		State         string            `json:"state"`
		Progress      sanitizedProgress `json:"progress"`
	}{1, s.task.ContentID, state, progress})
	_, err = s.out.Write(append(line, '\n'))
	return err
}

func (s *Supervisor) emitAuxiliary(state string, payload []byte) error {
	// Auxiliary frames are opaque vendor notifications. Preserve only bounded
	// metadata so diagnostics can correlate them without leaking a path or
	// vendor payload that has no public schema.
	digest := sha256.Sum256(payload)
	line, _ := json.Marshal(struct {
		SchemaVersion    int    `json:"schemaVersion"`
		ContentID        string `json:"contentId"`
		State            string `json:"state"`
		PayloadByteCount int    `json:"payloadByteCount"`
		PayloadSHA256    string `json:"payloadSha256"`
	}{1, s.task.ContentID, state, len(payload), fmt.Sprintf("%x", digest)})
	_, err := s.out.Write(append(line, '\n'))
	return err
}

func (s *Supervisor) Run(ctx context.Context) error {
	var err error
	if err := validateTask(s.task); err != nil {
		return err
	}
	progress := zmq4.NewSub(ctx)
	defer progress.Close()
	if err = progress.SetOption(zmq4.OptionSubscribe, s.task.ContentID); err != nil {
		return err
	}
	progressEndpoint, err := listenLocal(progress)
	if err != nil {
		return errors.New("cannot bind progress socket")
	}
	controlPub := zmq4.NewPub(ctx)
	defer controlPub.Close()
	controlEndpoint, err := listenLocal(controlPub)
	if err != nil {
		return errors.New("cannot bind control socket")
	}
	makeCmd := s.command
	if makeCmd == nil {
		makeCmd = func(name string, args ...string) *exec.Cmd {
			return exec.CommandContext(context.Background(), name, args...)
		}
	}
	cmd := makeCmd(s.task.WineExecutable, coreArgs(s.task, controlEndpoint, progressEndpoint)...)
	cmd.Dir = s.task.CoreWorkingDirectory
	makeEnvironment := s.environment
	if makeEnvironment == nil {
		makeEnvironment = controlledWineEnv
	}
	cmd.Env = makeEnvironment(s.task)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	// The core's stderr is intentionally discarded: it can contain untrusted paths
	// or tokens, while this helper's stderr is reserved for generic diagnostics.
	cmd.Stderr = nil
	if err = cmd.Start(); err != nil {
		return errors.New("cannot start core")
	}
	if s.started != nil {
		s.started(cmd.Process.Pid)
	}
	coreDone := make(chan error, 1)
	go func() { coreDone <- cmd.Wait() }()
	coreExited := false
	defer func() {
		if !coreExited {
			stopProcess(cmd, coreDone)
		}
	}()
	recv := make(chan zmq4.Msg, 1)
	recvErr := make(chan error, 1)
	go func() {
		for {
			m, e := progress.Recv()
			if e != nil {
				recvErr <- e
				return
			}
			select {
			case recv <- m:
			case <-ctx.Done():
				return
			}
		}
	}()
	tick := time.NewTicker(time.Second)
	defer tick.Stop()
	poll := time.NewTicker(s.pollInterval)
	defer poll.Stop()
	startupTimer := time.NewTimer(s.startupTimeout)
	defer startupTimer.Stop()
	startupDeadline := startupTimer.C
	var idleTimer *time.Timer
	var idleDeadline <-chan time.Time
	coreReady := false
	pausedState := false
	stopIdle := func() {
		if idleTimer != nil {
			if !idleTimer.Stop() {
				select {
				case <-idleTimer.C:
				default:
				}
			}
		}
		idleDeadline = nil
	}
	noteCoreFrame := func(active bool) {
		if !coreReady {
			coreReady = true
			if !startupTimer.Stop() {
				select {
				case <-startupTimer.C:
				default:
				}
			}
			startupDeadline = nil
		}
		if !active {
			stopIdle()
			return
		}
		if idleTimer == nil {
			idleTimer = time.NewTimer(s.idleTimeout)
		} else {
			if !idleTimer.Stop() {
				select {
				case <-idleTimer.C:
				default:
				}
			}
			idleTimer.Reset(s.idleTimeout)
		}
		idleDeadline = idleTimer.C
	}
	var lastSeq uint64
	var pending *control
	finished := false
	var finishDeadline <-chan time.Time
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-startupDeadline:
			return errors.New("core did not establish progress channel")
		case <-idleDeadline:
			return errors.New("core progress timed out")
		case exitErr := <-coreDone:
			coreExited = true
			if finished && exitErr == nil {
				return nil
			}
			return coreExitError(exitErr)
		case <-recvErr:
			if ctx.Err() != nil {
				return ctx.Err()
			}
			// downloadIPC may close its PUB socket after acknowledging state 8
			// and before the process itself exits. Once terminal success has been
			// observed, the process exit code is authoritative.
			if finished {
				recvErr = nil
				continue
			}
			return errors.New("progress channel failed")
		case <-finishDeadline:
			return errors.New("core did not exit after finishing")
		case <-tick.C:
			if e := controlPub.Send(zmq4.NewMsgFromString([]string{s.task.ContentID, "4"})); e != nil {
				return errors.New("heartbeat failed")
			}
		case <-poll.C:
			c, present, e := readControl(s.task.ControlFile)
			if e != nil {
				return e
			}
			if present && c.Sequence > lastSeq {
				if c.Action == "cancel" {
					return ErrCancelled
				}
				pending = &c
			}
			if coreReady && pending != nil {
				c := *pending
				lastSeq = c.Sequence
				code := "1"
				if c.Action == "resume" {
					code = "2"
				}
				if e := controlPub.Send(zmq4.NewMsgFromString([]string{s.task.ContentID, code})); e != nil {
					return errors.New("control send failed")
				}
				pending = nil
			}
		case msg := <-recv:
			if len(msg.Frames) != 3 || len(msg.Frames[2]) > 1<<20 || string(msg.Frames[0]) != s.task.ContentID {
				return errors.New("invalid progress frame")
			}
			state := string(msg.Frames[1])
			if auxiliaryState(state) {
				if err := s.emitAuxiliary(state, msg.Frames[2]); err != nil {
					return err
				}
				noteCoreFrame(!pausedState)
				continue
			}
			if state == "101" || state == "206" || state == "-1" {
				return errors.New("core reported terminal state " + state)
			}
			if !validState(state) {
				if len(state) <= 3 {
					numeric := state != ""
					for _, character := range state {
						if character < '0' || character > '9' {
							numeric = false
						}
					}
					if numeric {
						return errors.New("core reported unsupported state " + state)
					}
				}
				if len(msg.Frames[1]) <= 8 {
					return errors.New("invalid progress state 0x" + hex.EncodeToString(msg.Frames[1]))
				}
				return errors.New("invalid progress state")
			}
			if state == "9" {
				return errors.New("core reported download failure")
			}
			if err := s.emit(state, json.RawMessage(msg.Frames[2])); err != nil {
				return err
			}
			pausedState = state == "6" || state == "7"
			noteCoreFrame(!pausedState && state != "8")
			if state == "8" && !finished {
				if e := controlPub.Send(zmq4.NewMsgFromString([]string{s.task.ContentID, "3"})); e != nil {
					return errors.New("finish send failed")
				}
				finished = true
				stopIdle()
				finishDeadline = time.After(15 * time.Second)
			}
		}
	}
}
func controlledWineEnv(task Task) []string {
	// Never forward the launcher's complete environment to a downloaded
	// Windows helper. These are the only host/runtime fields Wine needs for the
	// supported CodeWeavers/Sikarugir profiles. In particular, credentials,
	// proxy variables, SSH agents and DYLD_INSERT_LIBRARIES are excluded.
	allowed := []string{
		"HOME", "USER", "LOGNAME", "TMPDIR",
		"LANG", "LC_ALL", "LC_CTYPE", "PATH",
		"CX_ROOT", "WINELOADER", "WINESERVER", "WINEDLLPATH",
		"DYLD_LIBRARY_PATH", "DYLD_FALLBACK_LIBRARY_PATH",
		"GST_PLUGIN_SYSTEM_PATH", "GST_REGISTRY", "SSL_CERT_FILE",
		"QMLSCENE_DEVICE", "DOTNET_EnableWriteXorExecute", "SIM_BACKEND_OVERRIDE",
		"ROSETTA_ADVERTISE_AVX", "WINEMSYNC", "WINEESYNC",
		"WINEDEBUG", "WINEDLLOVERRIDES", "MallocNanoZone",
	}
	out := make([]string, 0, len(allowed)+1)
	for _, key := range allowed {
		if value, present := os.LookupEnv(key); present && !strings.ContainsAny(value, "\x00\r\n") {
			out = append(out, key+"="+value)
		}
	}
	return append(out, "WINEPREFIX="+task.WinePrefix)
}

func validState(v string) bool {
	switch v {
	case "1", "2", "3", "4", "5", "6", "7", "8", "9", "11":
		return true
	}
	return false
}

func auxiliaryState(v string) bool {
	// The current NetEase core emits these opaque acknowledgements/informational
	// frames. idv-login 6.2.3 ignores them; retain only bounded metadata in our
	// JSONL stream without accepting arbitrary unknown codes.
	switch v {
	case "10", "2001", "2002", "2005", "2006":
		return true
	}
	return false
}
func readControl(path string) (control, bool, error) {
	info, e := os.Lstat(path)
	if os.IsNotExist(e) {
		return control{}, false, nil
	}
	if e != nil || !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 {
		return control{}, false, errors.New("cannot read control file")
	}
	b, e := readBoundedFile(path, 64<<10)
	if e != nil {
		return control{}, false, errors.New("cannot read control file")
	}
	var c control
	if decodeStrictJSON(b, &c) != nil || c.SchemaVersion != 1 || (c.Action != "pause" && c.Action != "resume" && c.Action != "cancel") {
		return control{}, false, errors.New("invalid control file")
	}
	return c, true, nil
}
func stopProcess(c *exec.Cmd, done <-chan error) {
	if c.Process == nil {
		return
	}
	_ = syscall.Kill(-c.Process.Pid, syscall.SIGTERM)
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		_ = syscall.Kill(-c.Process.Pid, syscall.SIGKILL)
		<-done
	}
}

// coreExitError exposes only the core process's stable termination category.
// In particular, it must never return exec.ExitError's text because that text
// can include the executable path or other untrusted launch context.
func coreExitError(waitErr error) error {
	if waitErr == nil {
		return errors.New("core exited before completion")
	}
	exitErr, ok := waitErr.(*exec.ExitError)
	if !ok {
		return errors.New("core execution failed")
	}
	status, ok := exitErr.Sys().(syscall.WaitStatus)
	if !ok {
		return errors.New("core exited unsuccessfully")
	}
	if status.Signaled() {
		return fmt.Errorf("core terminated by signal %d", status.Signal())
	}
	if status.Exited() {
		return fmt.Errorf("core exited with code %d", status.ExitStatus())
	}
	return errors.New("core exited unsuccessfully")
}
