package stick

import (
	"fmt"
	"sort"
	"strings"
)

const (
	// MinSize fits the 4 GiB boot partition plus one ~8 GB oven backup.
	// Sticks sold as "16 GB" hold 15-16 billion bytes.
	MinSize int64 = 14_000_000_000
	// maxDefaultSize hides large drives (usually external hard disks) unless
	// the user asks to see all drives.
	maxDefaultSize int64 = 300_000_000_000
	// maxMBRSize is the most an MBR partition table can address.
	maxMBRSize int64 = 2 << 40
)

// Drive is a whole disk the stick can be prepared on.
type Drive struct {
	ID         string   `json:"id"`     // Windows disk number, macOS diskN, Linux /dev path
	Device     string   `json:"device"` // raw device path
	Name       string   `json:"name"`
	Size       int64    `json:"size"`
	Bus        string   `json:"bus"`
	Serial     string   `json:"serial"`
	Removable  bool     `json:"removable"`
	SectorSize int      `json:"sectorSize"`
	Volumes    []Volume `json:"volumes"`
	JuneStick  bool     `json:"juneStick"`
	Eligible   bool     `json:"eligible"`
	Reason     string   `json:"reason"` // why it cannot be used, when not eligible
}

// Volume is a partition of a drive, for display and June stick detection.
type Volume struct {
	Label string `json:"label"`
	FS    string `json:"fs"`
	Mount string `json:"mount"`
	Size  int64  `json:"size"`
}

// ListDrives returns the drives the user may pick.  System and boot disks
// are never listed.  Unless showAll is set, only USB drives up to 300 GB
// are listed.
func ListDrives(showAll bool) ([]Drive, error) {
	all, err := listDrives()
	if err != nil {
		return nil, err
	}
	var out []Drive
	for _, d := range all {
		if internalBus(d.Bus) {
			continue
		}
		usb := strings.EqualFold(d.Bus, "usb")
		if !showAll && (!usb || d.Size > maxDefaultSize) {
			continue
		}
		judge(&d)
		out = append(out, d)
	}
	sort.SliceStable(out, func(a, b int) bool { return out[a].ID < out[b].ID })
	return out, nil
}

// internalBus reports buses that only carry built-in disks.  Those are never
// offered, even with "show all drives"; external SATA docks report USB.
func internalBus(bus string) bool {
	switch strings.ToUpper(bus) {
	case "NVME", "SATA", "ATA", "SAS", "RAID", "SPACES", "PCIE", "PCI-EXPRESS", "PCI EXPRESS":
		return true
	}
	return false
}

func judge(d *Drive) {
	d.JuneStick = hasLabel(d.Volumes, BootLabel) && hasLabel(d.Volumes, DataLabel)
	switch {
	case d.Size < MinSize:
		d.Reason = fmt.Sprintf("Too small: at least 16 GB is needed (this drive has %s)", HumanSize(d.Size))
	case d.Size > maxMBRSize:
		d.Reason = "Too large: drives over 2 TB are not supported"
	case d.SectorSize != 0 && d.SectorSize != sectorSize:
		d.Reason = fmt.Sprintf("Unsupported sector size %d", d.SectorSize)
	default:
		d.Eligible = true
	}
}

func hasLabel(vs []Volume, label string) bool {
	for _, v := range vs {
		if strings.EqualFold(v.Label, label) {
			return true
		}
	}
	return false
}

// sameDrive guards against the stick being swapped between choosing and
// erasing it.
func sameDrive(chosen, now Drive) error {
	if chosen.Size != now.Size || chosen.Serial != now.Serial || chosen.Name != now.Name {
		return fmt.Errorf("the selected drive changed (was %s %s, now %s %s); please choose it again",
			chosen.Name, HumanSize(chosen.Size), now.Name, HumanSize(now.Size))
	}
	return nil
}

// HumanSize formats bytes the way drive vendors do (decimal).
func HumanSize(n int64) string {
	switch {
	case n >= 1e12:
		return fmt.Sprintf("%.1f TB", float64(n)/1e12)
	case n >= 1e9:
		return fmt.Sprintf("%.1f GB", float64(n)/1e9)
	case n >= 1e6:
		return fmt.Sprintf("%.0f MB", float64(n)/1e6)
	default:
		return fmt.Sprintf("%d bytes", n)
	}
}
