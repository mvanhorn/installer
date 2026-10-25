package stick

import (
	"fmt"
	"os"
)

// BootCodeHelperFlag makes the app write the BIOS boot code and exit.  macOS
// uses it to run just this step as root.
const BootCodeHelperFlag = "--write-bootcode"

// RunBootCodeHelper handles "app --write-bootcode DEVICE BLOBFILE".
func RunBootCodeHelper(args []string) error {
	if len(args) != 2 {
		return fmt.Errorf("usage: %s DEVICE BLOBFILE", BootCodeHelperFlag)
	}
	blob, err := os.ReadFile(args[1])
	if err != nil {
		return err
	}
	f, err := os.OpenFile(args[0], os.O_RDWR, 0)
	if err != nil {
		return err
	}
	defer f.Close()
	if err := WriteBootCode(f, blob); err != nil {
		return err
	}
	// Do not return f.Sync() here: fsync(2) on a raw /dev/rdisk* device fails
	// with ENOTTY on macOS even when the write succeeded.  WriteBootCode has
	// just read the boot code back and verified it, so syncBootDevice flushes
	// with sync(2) (darwin) or fsync (other platforms) without failing the
	// step; the app unmounts and ejects the stick once this helper exits.
	return syncBootDevice(f)
}
