package stick

import (
	"syscall"
	"unsafe"
)

var procIsWow64Process2 = syscall.NewLazyDLL("kernel32.dll").NewProc("IsWow64Process2")

const imageFileMachineARM64 = 0xAA64

// HostIsARM reports whether this computer has an ARM processor.  The app is
// an x64 build, which Windows on ARM runs under emulation, so it asks for the
// native machine rather than looking at its own architecture.
func HostIsARM() bool {
	if procIsWow64Process2.Find() != nil {
		return false // before Windows 10 1709, which never ran on ARM64 PCs
	}
	var process, native uint16
	h, _ := syscall.GetCurrentProcess()
	r, _, _ := procIsWow64Process2.Call(uintptr(h), uintptr(unsafe.Pointer(&process)), uintptr(unsafe.Pointer(&native)))
	return r != 0 && native == imageFileMachineARM64
}
