package main

// Interior light control.
//
// The oven's interior light is driven by the CookManager app through the
// exported Android service com.junelife.device.cookmanager.service.AxonService.
// Its binder interface (descriptor com.junelife.device.cookmanager.AxonServiceInterface)
// has two relevant transactions:
//
//	12 enableLightingScene(LightingScene)   - parcel: iface-token, 1, string id,
//	                                            int left%, int right%, int priority
//	13 disableLightingScene(LightingScene)  - same parcel
//
// LightingScene priorities resolve by the LOWEST number winning, so we use a
// high priority (100) and brightness 100/100: our scene lights the oven only
// when no higher-precedence scene (door open, cooking) is active, and
// disabling it hands control straight back to them.
//
// The actual binder call is made by the small com.july.oven LightBridgeService
// APK (am startservice), because a Go process cannot speak Android binder.
// All failures are logged and ignored: a missing helper must never break the
// camera.

import (
	"log"
	"os/exec"
	"sync/atomic"
)

var (
	lightWasOn atomic.Bool
)

// A fixed scene id means a june-local restart can always clear the scene it
// left behind instead of stacking a new one.
const lightSceneID = "6a756e65-6c6f-6361-6c2d6c69676874"

func runLightHelper(action string) error {
	args := []string{
		"startservice", "-n", "com.july.oven/.LightBridgeService",
		"--es", "action", action, "--es", "scene_id", lightSceneID,
	}
	if action == "enable" {
		args = append(args, "--ei", "left", "100", "--ei", "right", "100", "--ei", "priority", "100")
	}
	return exec.Command("/system/bin/am", args...).Run()
}

// initInteriorLight clears any scene left by a previous june-local process.
func initInteriorLight() {
	lightWasOn.Store(false)
	if err := runLightHelper("disable"); err != nil {
		log.Printf("[light] startup clear failed: %v", err)
	}
}

// setInteriorLight enables or disables our live-view lighting scene.
func setInteriorLight(on bool) {
	if on {
		if lightWasOn.Swap(true) {
			return
		}
	} else {
		if !lightWasOn.Swap(false) {
			return
		}
	}
	action := "disable"
	if on {
		action = "enable"
	}
	if err := runLightHelper(action); err != nil {
		// Let the next poll retry the transition instead of suppressing it.
		lightWasOn.Store(!on)
		log.Printf("[light] helper call failed: %v", err)
	} else {
		log.Printf("[light] %v", on)
	}
}

// lightFollowCamera keeps our scene in lockstep with the effective camera
// state. setInteriorLight is transition-only, so polling this is cheap.
func lightFollowCamera(cameraOn bool) {
	setInteriorLight(cameraOn)
}
