package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"syscall"
)

func main() {
	if len(os.Args) > 1 && os.Args[1] == "self-test" {
		fmt.Println(`{"schemaVersion":1,"selfTest":"ok"}`)
		return
	}
	fs := flag.NewFlagSet("IdentityVDownloadSupervisor", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	taskPath := fs.String("task", "", "task JSON path")
	if len(os.Args) < 2 || os.Args[1] != "run" || fs.Parse(os.Args[2:]) != nil || *taskPath == "" {
		fmt.Fprintln(os.Stderr, "usage: IdentityVDownloadSupervisor run --task <task.json>")
		os.Exit(2)
	}
	t, err := loadTask(*taskPath)
	if err == nil {
		ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
		defer stop()
		err = NewSupervisor(t, os.Stdout).Run(ctx)
	}
	if err != nil {
		// Supervisor errors are deliberately normalized and contain no local
		// paths or untrusted core output, so the caller can distinguish a task
		// validation failure from a protocol/process failure.
		fmt.Fprintln(os.Stderr, "supervisor failed:", err)
		os.Exit(1)
	}
}
