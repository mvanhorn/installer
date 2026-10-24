package stick

import "runtime"

// HostIsARM reports whether this computer has an ARM processor.
func HostIsARM() bool {
	return runtime.GOARCH == "arm64" || runtime.GOARCH == "arm"
}
