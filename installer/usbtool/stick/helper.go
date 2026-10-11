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
	return f.Sync()
}
