package stick

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unicode/utf16"
	"unsafe"
)

// The Windows backend uses PowerShell's Storage cmdlets to list and find
// disks and diskpart to partition and format them; both ship with Windows
// 10 and 11.  The app runs elevated (requireAdministrator manifest).

const createNoWindow = 0x08000000

func hidden(cmd *exec.Cmd) *exec.Cmd {
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: createNoWindow}
	return cmd
}

// powershell runs script and returns its stdout.
func powershell(ctx context.Context, script string) ([]byte, error) {
	// -EncodedCommand (UTF-16LE, base64) runs the script as a whole; piping
	// it to "-Command -" runs it line by line and breaks multi-line blocks.
	full := "$ProgressPreference = 'SilentlyContinue'\n$ErrorActionPreference = 'Stop'\n" +
		"[Console]::OutputEncoding = [Text.Encoding]::UTF8\n" + script
	u := utf16.Encode([]rune(full))
	raw := make([]byte, 2*len(u))
	for i, c := range u {
		binary.LittleEndian.PutUint16(raw[2*i:], c)
	}
	cmd := hidden(exec.CommandContext(ctx, "powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
		"-EncodedCommand", base64.StdEncoding.EncodeToString(raw)))
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		msg := strings.TrimSpace(stderr.String())
		if i := strings.Index(msg, "\n"); i > 0 {
			msg = msg[:i]
		}
		return nil, fmt.Errorf("%s", strings.TrimSpace(msg+" ("+err.Error()+")"))
	}
	return out, nil
}

// allowVirtual lets tests use attached VHDs ("File Backed Virtual").
func allowVirtual() bool { return os.Getenv("JUNE_USB_ALLOW_VHD") == "1" }

const listScript = `
$list = @(Get-Disk | Where-Object { -not $_.IsBoot -and -not $_.IsSystem } | ForEach-Object {
  $d = $_
  $vols = @(Get-Partition -DiskNumber $d.Number -ErrorAction SilentlyContinue | ForEach-Object {
    $p = $_
    $v = $p | Get-Volume -ErrorAction SilentlyContinue
    $letter = ''
    if ([int][char]$p.DriveLetter -ne 0) { $letter = "$($p.DriveLetter):\" }
    [pscustomobject]@{ label = [string]$v.FileSystemLabel; fs = [string]$v.FileSystem; mount = $letter; size = [int64]$p.Size }
  })
  [pscustomobject]@{ number = [int]$d.Number; name = [string]$d.FriendlyName; size = [int64]$d.Size; bus = [string]$d.BusType;
    serial = ([string]$d.SerialNumber).Trim(); sector = [int]$d.LogicalSectorSize; volumes = $vols }
})
ConvertTo-Json -InputObject $list -Depth 4 -Compress
`

type psDisk struct {
	Number  int      `json:"number"`
	Name    string   `json:"name"`
	Size    int64    `json:"size"`
	Bus     string   `json:"bus"`
	Serial  string   `json:"serial"`
	Sector  int      `json:"sector"`
	Volumes []Volume `json:"volumes"`
}

func listDrives() ([]Drive, error) {
	out, err := powershell(context.Background(), listScript)
	if err != nil {
		return nil, fmt.Errorf("listing drives: %w", err)
	}
	var disks []psDisk
	if err := json.Unmarshal(bytes.TrimSpace(out), &disks); err != nil {
		return nil, fmt.Errorf("listing drives: %w", err)
	}
	var drives []Drive
	for _, d := range disks {
		bus := d.Bus
		if bus == "File Backed Virtual" {
			if !allowVirtual() {
				continue
			}
			bus = "USB"
		}
		drives = append(drives, Drive{
			ID: strconv.Itoa(d.Number), Device: fmt.Sprintf(`\\.\PhysicalDrive%d`, d.Number),
			Name: strings.TrimSpace(d.Name), Size: d.Size, Bus: bus, Serial: d.Serial,
			Removable: true, SectorSize: d.Sector, Volumes: d.Volumes,
		})
	}
	return drives, nil
}

func lookupDrive(id string) (Drive, error) {
	drives, err := listDrives()
	if err != nil {
		return Drive{}, err
	}
	for _, d := range drives {
		if d.ID == id {
			return d, nil
		}
	}
	return Drive{}, fmt.Errorf("the selected drive is no longer connected")
}

func diskNumber(d Drive) (int, error) {
	n, err := strconv.Atoi(d.ID)
	if err != nil || n < 0 {
		return 0, fmt.Errorf("invalid disk number %q", d.ID)
	}
	return n, nil
}

func partition(ctx context.Context, d Drive, logf func(string, ...any)) (*mounts, error) {
	n, err := diskNumber(d)
	if err != nil {
		return nil, err
	}
	script := fmt.Sprintf(`select disk %d
attributes disk clear readonly noerr
online disk noerr
clean
create partition primary size=%d align=1024 id=0c
format fs=fat32 quick label=%s
active
assign
create partition primary align=1024 id=07
format fs=exfat quick label=%s
assign
exit
`, n, BootPartSize>>20, BootLabel, DataLabel)
	f, err := os.CreateTemp("", "june-diskpart-*.txt")
	if err != nil {
		return nil, err
	}
	defer os.Remove(f.Name())
	if _, err := f.WriteString(strings.ReplaceAll(script, "\n", "\r\n")); err != nil {
		f.Close()
		return nil, err
	}
	f.Close()
	out, err := hidden(exec.CommandContext(ctx, "diskpart.exe", "/s", f.Name())).CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf("diskpart could not prepare disk %d: %s", n, lastLines(string(out), 4))
	}
	logf("diskpart: %s", lastLines(string(out), 1))
	return juneLetters(ctx, n)
}

func locate(ctx context.Context, d Drive, logf func(string, ...any)) (*mounts, error) {
	n, err := diskNumber(d)
	if err != nil {
		return nil, err
	}
	return juneLetters(ctx, n)
}

// juneLetters finds the JUNEBOOT and JUNE volumes of disk n, assigning
// drive letters if they have none, and checks partition 1 starts at 1 MiB.
func juneLetters(ctx context.Context, n int) (*mounts, error) {
	script := fmt.Sprintf(`
$n = %d
for ($i = 0; $i -lt 40; $i++) {
  $boot = $null; $data = $null
  foreach ($p in @(Get-Partition -DiskNumber $n)) {
    $v = $p | Get-Volume -ErrorAction SilentlyContinue
    if (-not $v) { continue }
    if ($v.FileSystemLabel -eq '%s' -and $v.FileSystem -eq 'FAT32') { $boot = $p }
    elseif ($v.FileSystemLabel -eq '%s') { $data = $p }
  }
  if ($boot -and $data) {
    foreach ($p in @($boot, $data)) {
      if ([int][char]$p.DriveLetter -eq 0) {
        Add-PartitionAccessPath -DiskNumber $n -PartitionNumber $p.PartitionNumber -AssignDriveLetter
      }
    }
    $boot = Get-Partition -DiskNumber $n -PartitionNumber $boot.PartitionNumber
    $data = Get-Partition -DiskNumber $n -PartitionNumber $data.PartitionNumber
    if ([int][char]$boot.DriveLetter -ne 0 -and [int][char]$data.DriveLetter -ne 0) {
      ConvertTo-Json -Compress @{ boot = "$($boot.DriveLetter):\"; data = "$($data.DriveLetter):\"; offset = [int64]$boot.Offset; number = [int]$boot.PartitionNumber }
      exit 0
    }
  }
  Start-Sleep -Milliseconds 500
}
throw 'The JUNEBOOT and JUNE partitions did not get drive letters'
`, n, BootLabel, DataLabel)
	out, err := powershell(ctx, script)
	if err != nil {
		return nil, err
	}
	var r struct {
		Boot, Data string
		Offset     int64
		Number     int
	}
	if err := json.Unmarshal(bytes.TrimSpace(out), &r); err != nil {
		return nil, fmt.Errorf("finding the stick's partitions: %w", err)
	}
	if r.Number != 1 || r.Offset != BootPartStart*sectorSize {
		return nil, fmt.Errorf("unexpected layout: %s is partition %d at offset %d", BootLabel, r.Number, r.Offset)
	}
	return &mounts{Boot: r.Boot, Data: r.Data}, nil
}

func flush(ctx context.Context, d Drive, m *mounts, logf func(string, ...any)) error {
	var letters []string
	for _, p := range []string{m.Boot, m.Data} {
		letters = append(letters, "'"+strings.TrimSuffix(filepath.VolumeName(p), ":")+"'")
	}
	_, err := powershell(ctx, "Write-VolumeCache -DriveLetter "+strings.Join(letters, ","))
	if err != nil {
		return fmt.Errorf("flushing the stick: %w", err)
	}
	return nil
}

// openUncached opens p bypassing the file cache, so verification reads what
// is really on the stick.  Reads must be sector multiples; copyWithProgress
// reads 1 MiB chunks into page-aligned buffers.
func openUncached(p string) (*os.File, error) {
	name, err := syscall.UTF16PtrFromString(p)
	if err != nil {
		return nil, err
	}
	const fileFlagNoBuffering, fileFlagSequentialScan = 0x20000000, 0x08000000
	h, err := syscall.CreateFile(name, syscall.GENERIC_READ, syscall.FILE_SHARE_READ|syscall.FILE_SHARE_WRITE, nil,
		syscall.OPEN_EXISTING, fileFlagNoBuffering|fileFlagSequentialScan, 0)
	if err != nil {
		return nil, &os.PathError{Op: "open", Path: p, Err: err}
	}
	return os.NewFile(uintptr(h), p), nil
}

func writeBootCode(ctx context.Context, d Drive, blob []byte, logf func(string, ...any)) error {
	f, err := os.OpenFile(d.Device, os.O_RDWR, 0)
	if err != nil {
		return fmt.Errorf("opening %s: %w", d.Device, err)
	}
	defer f.Close()
	if err := WriteBootCode(f, blob); err != nil {
		return err
	}
	return f.Sync()
}

// finish writes out every volume on the stick once more and ejects it the
// way "Safely Remove Hardware" does.  That also works for USB sticks that
// report themselves as fixed disks, which Explorer's "Eject" verb skips.
func finish(ctx context.Context, d Drive, logf func(string, ...any)) error {
	n, err := diskNumber(d)
	if err != nil {
		return err
	}
	out, err := powershell(ctx, fmt.Sprintf(`
$n = %d
foreach ($p in @(Get-Partition -DiskNumber $n | Where-Object { [int][char]$_.DriveLetter -ne 0 })) {
  Write-VolumeCache -DriveLetter $p.DriveLetter
}
(Get-CimInstance Win32_DiskDrive -Filter "Index=$n").PNPDeviceID`, n))
	if err != nil {
		return fmt.Errorf("writing out the stick: %w", err)
	}
	id := lastLines(string(out), 1)
	if id == "" {
		return errors.New("could not find the stick's device to eject it")
	}
	logf("Ejecting %s", id)
	return ejectDevice(ctx, id)
}

var (
	cfgmgr32               = syscall.NewLazyDLL("cfgmgr32.dll")
	procLocateDevNode      = cfgmgr32.NewProc("CM_Locate_DevNodeW")
	procGetParent          = cfgmgr32.NewProc("CM_Get_Parent")
	procRequestDeviceEject = cfgmgr32.NewProc("CM_Request_Device_EjectW")
)

// Why Windows refused to eject (PNP_VETO_TYPE).
var vetoReasons = map[uint32]string{
	1: "a legacy device is in the way", 2: "a close is still pending", 3: "a program is using it",
	4: "a Windows service is using it", 5: "a file on it is still open", 6: "another device depends on it",
	7: "its driver refused", 9: "of insufficient power", 12: "of missing rights",
}

// ejectDevice ejects the disk with this device instance ID, or its USB
// parent when the disk node itself cannot be ejected.  Explorer windows or
// virus scanners can hold the stick briefly, so it retries a few times.
func ejectDevice(ctx context.Context, id string) error {
	name, err := syscall.UTF16PtrFromString(id)
	if err != nil {
		return err
	}
	var inst uint32
	if cr, _, _ := procLocateDevNode.Call(uintptr(unsafe.Pointer(&inst)), uintptr(unsafe.Pointer(name)), 0); cr != 0 {
		return fmt.Errorf("could not find device %s (CONFIGRET %d)", id, cr)
	}
	nodes := []uint32{inst}
	var parent uint32
	if cr, _, _ := procGetParent.Call(uintptr(unsafe.Pointer(&parent)), uintptr(inst), 0); cr == 0 {
		nodes = append(nodes, parent)
	}
	var last error
	for attempt := 0; attempt < 5; attempt++ {
		if attempt > 0 {
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(time.Second):
			}
		}
		for _, node := range nodes {
			var veto uint32
			buf := make([]uint16, 512)
			// Passing a veto buffer keeps Windows from showing its own dialog.
			cr, _, _ := procRequestDeviceEject.Call(uintptr(node), uintptr(unsafe.Pointer(&veto)),
				uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf)), 0)
			if cr == 0 && veto == 0 {
				return nil
			}
			reason := vetoReasons[veto]
			if reason == "" {
				reason = fmt.Sprintf("CONFIGRET %d, veto %d", cr, veto)
			}
			if who := syscall.UTF16ToString(buf); who != "" {
				reason += " (" + who + ")"
			}
			last = errors.New("Windows could not eject it because " + reason)
		}
	}
	return last
}

func lastLines(s string, n int) string {
	lines := strings.Split(strings.TrimSpace(strings.ReplaceAll(s, "\r", "")), "\n")
	var keep []string
	for i := len(lines) - 1; i >= 0 && len(keep) < n; i-- {
		if l := strings.TrimSpace(lines[i]); l != "" {
			keep = append([]string{l}, keep...)
		}
	}
	return strings.Join(keep, " ")
}
