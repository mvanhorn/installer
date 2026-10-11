//go:build windows || darwin

// June USB prepares a June Local USB stick on Windows and macOS.  The UI is
// plain HTML/CSS/JS in frontend/ (styled like the installer itself), shown
// in the system webview by Wails; the work is done by package stick.
package main

import (
	"embed"
	"fmt"
	"io/fs"
	"os"

	"github.com/wailsapp/wails/v2"
	"github.com/wailsapp/wails/v2/pkg/options"
	"github.com/wailsapp/wails/v2/pkg/options/assetserver"
	"github.com/wailsapp/wails/v2/pkg/options/mac"
	"github.com/wailsapp/wails/v2/pkg/options/windows"

	"june-usb/stick"
)

//go:embed all:frontend
var frontend embed.FS

func main() {
	// macOS re-runs the app as root for this one step (see platform_darwin.go).
	if len(os.Args) > 1 && os.Args[1] == stick.BootCodeHelperFlag {
		if err := stick.RunBootCodeHelper(os.Args[2:]); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		return
	}

	assets, err := fs.Sub(frontend, "frontend")
	if err != nil {
		panic(err)
	}
	app := NewApp()
	err = wails.Run(&options.App{
		Title:            "June USB",
		Width:            1040,
		Height:           760,
		MinWidth:         720,
		MinHeight:        600,
		AssetServer:      &assetserver.Options{Assets: assets},
		BackgroundColour: &options.RGBA{R: 8, G: 9, B: 11, A: 255},
		OnStartup:        app.startup,
		OnBeforeClose:    app.beforeClose,
		Bind:             []interface{}{app},
		// Debug builds only (debug_on.go): no extra WebView2 flags, log to a file.
		EnableFraudulentWebsiteDetection: webviewDebug,
		Logger:                           debugLogger,
		LogLevelProduction:               logLevel(),
		Windows:                          &windows.Options{Theme: windows.SystemDefault},
		Mac:                              &mac.Options{About: &mac.AboutInfo{Title: "June USB", Message: "Prepares June Local USB sticks.\nProject July"}},
	})
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
