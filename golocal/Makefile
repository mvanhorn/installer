# Build the June local server as a static binary for the on-oven target (ARMv7,
# Tegra K1 / Jetson TK1) and for Docker/NAS (amd64).
#
#   make oven    -> golocal/bin/june-local-linux-armv7  (static, runs on Android 5 bionic)
#   make docker  -> golocal/bin/june-local-linux-amd64  (static)
#
# Override GO if your toolchain lives elsewhere: make GO=/usr/local/go/bin/go

GO ?= go
GOENV = CGO_ENABLED=0

.PHONY: oven camerad docker test clean

oven:
	mkdir -p bin
	GOOS=linux GOARCH=arm GOARM=7 $(GOENV) $(GO) build -trimpath -ldflags "-s -w" -o bin/june-local-linux-armv7 .

camerad:
	mkdir -p bin
	GOOS=linux GOARCH=arm GOARM=7 $(GOENV) $(GO) build -trimpath -ldflags "-s -w" -o bin/june-camerad-linux-armv7 ./camerad

docker:
	mkdir -p bin
	GOOS=linux GOARCH=amd64 $(GOENV) $(GO) build -trimpath -ldflags "-s -w" -o bin/june-local-linux-amd64 .

test:
	$(GO) test ./...

clean:
	rm -rf bin
