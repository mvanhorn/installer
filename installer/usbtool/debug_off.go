//go:build !junedebug && (windows || darwin)

package main

import "github.com/wailsapp/wails/v2/pkg/logger"

// webviewDebug, debugLogger and debugf: see debug_on.go.
const webviewDebug = false

var debugLogger logger.Logger

func debugf(string, ...any) {}

func logLevel() logger.LogLevel { return logger.ERROR }
