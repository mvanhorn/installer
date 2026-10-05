package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"image"
	"image/jpeg"
	"io"
	"log"
	"math"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"
	"unsafe"
)

var httpClient = &http.Client{Timeout: 5 * time.Second}

// V4L2 constants for linux/arm (Linux 3.10-era camera device).
const (
	v4l2BufTypeVideoCapture = 1
	v4l2FieldNone           = 1
	v4l2PixFmtYUYV          = 0x56595559 // 'Y','U','Y','V'
	v4l2MemoryMMAP          = 1

	vidiocS_FMT     = 0xc0cc5605
	vidiocS_PARM    = 0xc0cc5616
	vidiocReqbufs   = 0xc0145608
	vidiocQuerybuf  = 0xc0445609
	vidiocQbuf      = 0xc044560f
	vidiocDqbuf     = 0xc0445611
	vidiocStreamon  = 0x40045612
	vidiocStreamoff = 0x40045613
)

type v4l2PixFormat struct {
	Width        uint32
	Height       uint32
	Pixelformat  uint32
	Field        uint32
	Bytesperline uint32
	Sizeimage    uint32
	Colorspace   uint32
	Priv         uint32
	Flags        uint32
}

type v4l2Format struct {
	Type uint32
	Pix  v4l2PixFormat
	_    [168]byte
}

type v4l2Fract struct {
	Numerator   uint32
	Denominator uint32
}

type v4l2CaptureParm struct {
	Capability   uint32
	Capturemode  uint32
	Timeperframe v4l2Fract
	Extendedmode uint32
	Readbuffers  uint32
	_            [4]uint32
}

type v4l2StreamParm struct {
	Type uint32
	Parm v4l2CaptureParm
	_    [192]byte
}

type v4l2Requestbuffers struct {
	Count    uint32
	Type     uint32
	Memory   uint32
	Reserved [2]uint32
}

type v4l2Timeval struct {
	Sec  int32
	Usec int32
}

type v4l2Timecode struct {
	Type     uint32
	Flags    uint32
	Frames   uint8
	Seconds  uint8
	Minutes  uint8
	Hours    uint8
	Userbits [4]uint8
}

type v4l2Buffer struct {
	Index     uint32
	Type      uint32
	BytesUsed uint32
	Flags     uint32
	Field     uint32
	Timestamp v4l2Timeval
	Timecode  v4l2Timecode
	Sequence  uint32
	Memory    uint32
	Offset    uint32
	Length    uint32
	Reserved2 uint32
	RequestFd int32
}

func ioctl(fd uintptr, req uintptr, arg unsafe.Pointer) error {
	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, fd, req, uintptr(arg))
	if errno != 0 {
		return errno
	}
	return nil
}

type calib struct {
	Fx        float64 `json:"fx"`
	Fy        float64 `json:"fy"`
	Cx        float64 `json:"cx"`
	Cy        float64 `json:"cy"`
	K1        float64 `json:"k1"`
	K2        float64 `json:"k2"`
	K3        float64 `json:"k3"`
	K4        float64 `json:"k4"`
	Fps       int     `json:"fps"`
	Undistort bool    `json:"undistort"`
	Quality   int     `json:"quality"`
}

func loadCalib(path string, cur *calib) bool {
	b, err := os.ReadFile(path)
	if err != nil {
		return false
	}
	var c calib
	if json.Unmarshal(b, &c) != nil {
		return false
	}
	changed := *cur != c
	*cur = c
	return changed
}

func yuyvToYCbCrInto(pix []byte, dst *image.YCbCr) {
	w := dst.Rect.Dx()
	h := dst.Rect.Dy()
	for p := 0; p < w*h; p += 2 {
		off := p * 2
		dst.Y[p] = pix[off]
		dst.Y[p+1] = pix[off+2]
		dst.Cb[p/2] = pix[off+1]
		dst.Cr[p/2] = pix[off+3]
	}
}

func buildUndistortMaps(w, h int, fx, fy, cx, cy, k1, k2, k3, k4 float64) ([]int, []int) {
	mapYIdx := make([]int, w*h)
	mapCIdx := make([]int, (w/2)*h)
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			xn := (float64(x) - cx) / fx
			yn := (float64(y) - cy) / fy
			r := math.Sqrt(xn*xn + yn*yn)
			theta := math.Atan(r)
			thetaD := theta * (1 + k1*theta*theta + k2*math.Pow(theta, 4) + k3*math.Pow(theta, 6) + k4*math.Pow(theta, 8))
			scale := 1.0
			if r > 1e-6 {
				scale = thetaD / r
			}
			sx := int(fx*xn*scale + cx)
			sy := int(fy*yn*scale + cy)
			if sx < 0 {
				sx = 0
			} else if sx >= w {
				sx = w - 1
			}
			if sy < 0 {
				sy = 0
			} else if sy >= h {
				sy = h - 1
			}
			i := y*w + x
			mapYIdx[i] = sy*w + sx
		}
	}
	for y := 0; y < h; y++ {
		for cxCol := 0; cxCol < w/2; cxCol++ {
			x := cxCol * 2
			xn := (float64(x) - cx) / fx
			yn := (float64(y) - cy) / fy
			r := math.Sqrt(xn*xn + yn*yn)
			theta := math.Atan(r)
			thetaD := theta * (1 + k1*theta*theta + k2*math.Pow(theta, 4) + k3*math.Pow(theta, 6) + k4*math.Pow(theta, 8))
			scale := 1.0
			if r > 1e-6 {
				scale = thetaD / r
			}
			sx := int(fx*xn*scale + cx)
			sy := int(fy*yn*scale + cy)
			if sx < 0 {
				sx = 0
			} else if sx >= w {
				sx = w - 1
			}
			if sy < 0 {
				sy = 0
			} else if sy >= h {
				sy = h - 1
			}
			ci := y*(w/2) + cxCol
			mapCIdx[ci] = sy*(w/2) + sx/2
		}
	}
	return mapYIdx, mapCIdx
}

func undistortYCbCrMappedInto(src, dst *image.YCbCr, mapYIdx, mapCIdx []int) {
	w := src.Rect.Dx()
	h := src.Rect.Dy()
	for i := 0; i < w*h; i++ {
		dst.Y[i] = src.Y[mapYIdx[i]]
	}
	for i := 0; i < (w/2)*h; i++ {
		dst.Cb[i] = src.Cb[mapCIdx[i]]
		dst.Cr[i] = src.Cr[mapCIdx[i]]
	}
}

func main() {
	dev := flag.String("dev", "/dev/video0", "V4L2 capture device")
	out := flag.String("out", "/data/june/media/prod/images/latest.jpg", "output JPEG path")
	relay := flag.String("relay", "http://127.0.0.1/internal/video", "relay upload endpoint")
	source := flag.String("source", "auto", "camera source: auto, stock (cameracapturerd socket), or v4l2")
	stockSocket := flag.String("stock-socket", "/juneOS2/cameracapturerd-capture.sock", "cameracapturerd capture socket")
	format := flag.Int("format", 6, "cameracapturerd frame format (6 = rectified JPEG)")
	fps := flag.Int("fps", 1, "capture cadence (frames per second)")
	width := flag.Int("width", 640, "capture width")
	height := flag.Int("height", 480, "capture height")
	logPath := flag.String("log", "", "log file (empty = stderr)")
	triggerURL := flag.String("trigger-url", "http://127.0.0.1/internal/camera-bridge-enabled", "URL returning 1/0 to gate capture")
	undistort := flag.Bool("undistort", true, "apply fisheye correction")
	fx := flag.Float64("fx", 268.995852, "camera matrix fx")
	fy := flag.Float64("fy", 268.816095, "camera matrix fy")
	cx := flag.Float64("cx", 320.41667, "camera matrix cx")
	cy := flag.Float64("cy", 241.396493, "camera matrix cy")
	k1 := flag.Float64("k1", -0.053871, "fisheye k1")
	k2 := flag.Float64("k2", -0.027886, "fisheye k2")
	k3 := flag.Float64("k3", 0.028242, "fisheye k3")
	k4 := flag.Float64("k4", -0.011131, "fisheye k4")
	quality := flag.Int("quality", 80, "JPEG quality")
	configPath := flag.String("config", "", "JSON calibration config path (optional, reloaded live)")
	flag.Parse()

	if *logPath != "" {
		if err := os.MkdirAll(filepath.Dir(*logPath), 0o755); err == nil {
			rw := &rotatingWriter{path: *logPath, max: 32 << 20}
			_ = rw.open()
			log.SetOutput(rw)
		}
	}

	src := strings.ToLower(*source)
	if src == "auto" {
		// On a stock oven cameracapturerd owns /dev/video0. Always prefer the
		// stock socket there, even if the daemon has not created it yet: the
		// bridge waits for it instead of stealing the device.
		if fileExists("/system/bin/cameracapturerd") || fileExists(*stockSocket) {
			src = "stock"
		} else {
			src = "v4l2"
		}
	}
	switch src {
	case "stock":
		log.Printf("camerad: stock bridge (socket=%s fps=%d format=%d)", *stockSocket, *fps, *format)
		runStockBridge(*stockSocket, *relay, *triggerURL, *fps, *format)
		return
	case "v4l2":
	default:
		log.Fatalf("unknown --source %q (want auto, stock, or v4l2)", *source)
	}

	cur := calib{Fx: *fx, Fy: *fy, Cx: *cx, Cy: *cy, K1: *k1, K2: *k2, K3: *k3, K4: *k4, Fps: *fps, Undistort: *undistort, Quality: *quality}
	if *configPath != "" {
		_ = loadCalib(*configPath, &cur)
	}

	var undistortX, undistortY []int
	if cur.Undistort {
		undistortX, undistortY = buildUndistortMaps(*width, *height, cur.Fx, cur.Fy, cur.Cx, cur.Cy, cur.K1, cur.K2, cur.K3, cur.K4)
	}
	srcImg := image.NewYCbCr(image.Rect(0, 0, *width, *height), image.YCbCrSubsampleRatio422)
	var dstImg *image.YCbCr
	if cur.Undistort {
		dstImg = image.NewYCbCr(image.Rect(0, 0, *width, *height), image.YCbCrSubsampleRatio422)
	}
	var jpg bytes.Buffer
	lastTriggerCheck := time.Now().Add(-time.Second)
	triggerOn := true

	fd, err := syscall.Open(*dev, syscall.O_RDWR|syscall.O_NONBLOCK, 0)
	if err != nil {
		log.Fatalf("open %s: %v", *dev, err)
	}
	defer syscall.Close(fd)

	// clear O_NONBLOCK for blocking reads
	if err := syscall.SetNonblock(fd, false); err != nil {
		log.Fatalf("clear nonblock: %v", err)
	}

	fmtp := v4l2Format{
		Type: v4l2BufTypeVideoCapture,
		Pix: v4l2PixFormat{
			Width:       uint32(*width),
			Height:      uint32(*height),
			Pixelformat: v4l2PixFmtYUYV,
			Field:       v4l2FieldNone,
		},
	}
	if err := ioctl(uintptr(fd), vidiocS_FMT, unsafe.Pointer(&fmtp)); err != nil {
		log.Fatalf("VIDIOC_S_FMT: %v", err)
	}

	parm := v4l2StreamParm{Type: v4l2BufTypeVideoCapture}
	parm.Parm.Timeperframe = v4l2Fract{Numerator: 1, Denominator: 30}
	if err := ioctl(uintptr(fd), vidiocS_PARM, unsafe.Pointer(&parm)); err != nil {
		log.Fatalf("VIDIOC_S_PARM: %v", err)
	}

	reqbufs := v4l2Requestbuffers{Count: 4, Type: v4l2BufTypeVideoCapture, Memory: v4l2MemoryMMAP}
	if err := ioctl(uintptr(fd), vidiocReqbufs, unsafe.Pointer(&reqbufs)); err != nil {
		log.Fatalf("VIDIOC_REQBUFS: %v", err)
	}

	buffers := make([][]byte, int(reqbufs.Count))
	for i := 0; i < int(reqbufs.Count); i++ {
		b := v4l2Buffer{Index: uint32(i), Type: v4l2BufTypeVideoCapture, Memory: v4l2MemoryMMAP}
		if err := ioctl(uintptr(fd), vidiocQuerybuf, unsafe.Pointer(&b)); err != nil {
			log.Fatalf("VIDIOC_QUERYBUF %d: %v", i, err)
		}
		mm, err := syscall.Mmap(fd, int64(b.Offset), int(b.Length), syscall.PROT_READ|syscall.PROT_WRITE, syscall.MAP_SHARED)
		if err != nil {
			log.Fatalf("mmap %d: %v", i, err)
		}
		buffers[i] = mm
		if err := ioctl(uintptr(fd), vidiocQbuf, unsafe.Pointer(&b)); err != nil {
			log.Fatalf("VIDIOC_QBUF %d: %v", i, err)
		}
	}

	on := uint32(v4l2BufTypeVideoCapture)
	if err := ioctl(uintptr(fd), vidiocStreamon, unsafe.Pointer(&on)); err != nil {
		log.Fatalf("VIDIOC_STREAMON: %v", err)
	}
	defer func() {
		off := uint32(v4l2BufTypeVideoCapture)
		_ = ioctl(uintptr(fd), vidiocStreamoff, unsafe.Pointer(&off))
	}()

	log.Printf("camerad streaming %dx%d YUYV at %d fps -> %s", *width, *height, cur.Fps, *out)
	for {
		if cur.Fps <= 0 {
			cur.Fps = 10
		}
		start := time.Now()
		if *configPath != "" {
			if loadCalib(*configPath, &cur) {
				if cur.Undistort {
					undistortX, undistortY = buildUndistortMaps(*width, *height, cur.Fx, cur.Fy, cur.Cx, cur.Cy, cur.K1, cur.K2, cur.K3, cur.K4)
				}
				log.Printf("reloaded calibration (fps=%d undistort=%v)", cur.Fps, cur.Undistort)
			}
		}
		if *triggerURL != "" {
			if time.Since(lastTriggerCheck) >= 500*time.Millisecond {
				triggerOn = cameraEnabled(*triggerURL)
				lastTriggerCheck = time.Now()
			}
			if !triggerOn {
				time.Sleep(200 * time.Millisecond)
				continue
			}
		}
		b := v4l2Buffer{Type: v4l2BufTypeVideoCapture, Memory: v4l2MemoryMMAP}
		if err := ioctl(uintptr(fd), vidiocDqbuf, unsafe.Pointer(&b)); err != nil {
			if err == syscall.EAGAIN {
				continue
			}
			log.Printf("VIDIOC_DQBUF: %v", err)
			continue
		}
		pix := buffers[b.Index][:b.BytesUsed]
		yuyvToYCbCrInto(pix, srcImg)
		img := srcImg
		if cur.Undistort {
			undistortYCbCrMappedInto(srcImg, dstImg, undistortX, undistortY)
			img = dstImg
		}
		jpg.Reset()
		if err := jpeg.Encode(&jpg, img, &jpeg.Options{Quality: cur.Quality}); err != nil {
			log.Printf("jpeg: %v", err)
			_ = ioctl(uintptr(fd), vidiocQbuf, unsafe.Pointer(&b))
			continue
		}
		if err := os.MkdirAll(filepath.Dir(*out), 0o755); err != nil {
			log.Printf("mkdir: %v", err)
		} else {
			tmp := *out + ".tmp"
			if err := os.WriteFile(tmp, jpg.Bytes(), 0o644); err != nil {
				log.Printf("write: %v", err)
			} else if err := os.Rename(tmp, *out); err != nil {
				log.Printf("rename: %v", err)
			}
		}
		_ = postJPEG(*relay, jpg.Bytes())
		_ = ioctl(uintptr(fd), vidiocQbuf, unsafe.Pointer(&b))
		elapsed := time.Since(start)
		frameDur := time.Second / time.Duration(cur.Fps)
		if elapsed < frameDur {
			time.Sleep(frameDur - elapsed)
		}
	}
}

type rotatingWriter struct {
	mu   sync.Mutex
	path string
	max  int64
	f    *os.File
}

func (w *rotatingWriter) open() error {
	f, err := os.OpenFile(w.path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err == nil {
		w.f = f
	}
	return err
}

func (w *rotatingWriter) Write(p []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.f == nil {
		if err := w.open(); err != nil {
			return 0, err
		}
	}
	if st, err := w.f.Stat(); err == nil && st.Size() > w.max {
		_ = w.f.Close()
		_ = os.Rename(w.path, w.path+".1")
		if err := w.open(); err != nil {
			return 0, err
		}
	}
	return w.f.Write(p)
}

func cameraEnabled(url string) bool {
	resp, err := http.Get(url)
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(io.LimitReader(resp.Body, 8))
	if err != nil {
		return false
	}
	return string(b) != "0"
}

func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

func postJPEG(url string, b []byte) error {
	req, err := http.NewRequest(http.MethodPost, url, bytes.NewReader(b))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "image/jpeg")
	resp, err := httpClient.Do(req)
	if err != nil {
		return err
	}
	io.Copy(io.Discard, resp.Body)
	resp.Body.Close()
	return nil
}
