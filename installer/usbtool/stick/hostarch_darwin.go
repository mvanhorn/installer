package stick

import "syscall"

// HostIsARM reports whether this Mac has an Apple chip, also when the app
// runs under Rosetta.
func HostIsARM() bool {
	v, err := syscall.Sysctl("hw.optional.arm64")
	return err == nil && len(v) > 0 && v[0] == 1
}
