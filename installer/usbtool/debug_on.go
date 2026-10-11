//go:build junedebug && (windows || darwin)

package main

import (
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/wailsapp/wails/v2/pkg/logger"
)

// webviewDebug is set by "go build -tags junedebug".  It leaves WebView2's
// command line free of Wails' own flags.  Never used for release builds.
const webviewDebug = true

// debugLogger sends Wails' own log (and runtime.Log* from the page) to
// june-usb-wails.log in the temp folder.
var debugLogger = logger.NewFileLogger(filepath.Join(os.TempDir(), "june-usb-wails.log"))

// debugf appends to june-usb-debug.log in the temp folder, so a debug build
// shows which backend calls the UI really makes.
func debugf(format string, a ...any) {
	f, err := os.OpenFile(filepath.Join(os.TempDir(), "june-usb-debug.log"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return
	}
	defer f.Close()
	fmt.Fprintf(f, "%s "+format+"\n", append([]any{time.Now().Format("15:04:05.000")}, a...)...)
}

func logLevel() logger.LogLevel { return logger.TRACE }
