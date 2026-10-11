FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    live-build xorriso isolinux syslinux-utils \
    grub-pc-bin fdisk \
    cpio \
    curl ca-certificates git rsync \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
COPY assets /build/assets
COPY gui /build/gui
COPY vendor /build/vendor
COPY build.sh /build/build.sh
COPY make_bios_boot.sh /build/make_bios_boot.sh
RUN chmod +x /build/build.sh

CMD ["/build/build.sh"]
