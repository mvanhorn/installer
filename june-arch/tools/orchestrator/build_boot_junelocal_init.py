#!/usr/bin/env python3
"""Build boot_junelocal_init.img from boot_adb_debug.img.

Adds a dedicated Android init service `junelocal` to the boot ramdisk's
init.june.rc, replacing the prior shell-script backgrounding hack, and triggers
it at `sys.boot_completed=1`.

The kernel, second, dt, and every other ramdisk entry are preserved
byte-for-byte. Only init.june.rc is modified. The boot-v0 header `id` field is
recomputed as sha1(kernel + ramdisk + second), matching the existing
repack_boot.py behavior.

Usage:
  build_boot_junelocal_init.py [in.img] [out.img]
"""
import sys, struct, gzip, io, hashlib, os

SERVICE_BLOCK = """service junelocal /system/xbin/june-local --cert /system/etc/june_leaf.crt --key /system/etc/june_leaf.key --bind 0.0.0.0 --port 443 --http-port 80 --media-dir /data/june/media --log /data/june/logs/june-local.log --jsonl /data/june/logs/capture.jsonl --companion-state /data/june/companions_state.json --append
    user root
    group root
    seclabel u:r:init:s0
    class main
    disabled
"""

CAMERAD_SERVICE = """service camerad /system/xbin/june-camerad --dev /dev/video0 --out /data/june/media/prod/images/latest.jpg --relay http://127.0.0.1/internal/video --fps 10 --trigger-url http://127.0.0.1/internal/camera-enabled --config /data/june/camerad.conf --log /data/june/logs/camerad.log
    user root
    group root
    seclabel u:r:init:s0
    class main
    disabled
"""

JCM_APPLY_SERVICE = """service jcm_apply /sbin/jcm_apply.sh
    user root
    group root
    seclabel u:r:init:s0
    class main
    oneshot
    disabled
"""


def parse_header(data):
    if data[0:8] != b"ANDROID!":
        raise SystemExit("not an Android boot image")
    return dict(
        kernel_size=struct.unpack("<I", data[8:12])[0],
        kernel_addr=struct.unpack("<I", data[12:16])[0],
        ramdisk_size=struct.unpack("<I", data[16:20])[0],
        ramdisk_addr=struct.unpack("<I", data[20:24])[0],
        second_size=struct.unpack("<I", data[24:28])[0],
        second_addr=struct.unpack("<I", data[28:32])[0],
        tags_addr=struct.unpack("<I", data[32:36])[0],
        page_size=struct.unpack("<I", data[36:40])[0],
        dt_size=struct.unpack("<I", data[40:44])[0],
        unused=struct.unpack("<I", data[44:48])[0],
        name=data[48:64].rstrip(b"\x00"),
        cmdline=data[64:576].rstrip(b"\x00"),
        id=data[576:608],
        extra=data[608:1632],
    )


def build_header(h):
    out = bytearray(2048)
    out[0:8] = b"ANDROID!"
    struct.pack_into("<I", out, 8, h["kernel_size"])
    struct.pack_into("<I", out, 12, h["kernel_addr"])
    struct.pack_into("<I", out, 16, h["ramdisk_size"])
    struct.pack_into("<I", out, 20, h["ramdisk_addr"])
    struct.pack_into("<I", out, 24, h["second_size"])
    struct.pack_into("<I", out, 28, h["second_addr"])
    struct.pack_into("<I", out, 32, h["tags_addr"])
    struct.pack_into("<I", out, 36, h["page_size"])
    struct.pack_into("<I", out, 40, h["dt_size"])
    struct.pack_into("<I", out, 44, h["unused"])
    out[48:64] = h["name"].ljust(16, b"\x00")
    out[64:576] = h["cmdline"].ljust(512, b"\x00")
    out[576:608] = h["id"]
    out[608:1632] = h["extra"]
    return bytes(out)


def parse_newc(data):
    entries = []
    off = 0
    while off < len(data):
        hdr = data[off:off + 110]
        if len(hdr) < 110:
            raise SystemExit("truncated cpio header")
        if hdr[:6] not in (b"070701", b"070702"):
            raise SystemExit(f"bad cpio magic {hdr[:6]!r} at {off}")
        fields = hdr[6:110].decode("ascii")
        mode = fields[8:16].encode("ascii")
        uid = fields[16:24].encode("ascii")
        gid = fields[24:32].encode("ascii")
        mtime = fields[40:48].encode("ascii")
        fsize = int(fields[48:56], 16)
        namesz = int(fields[88:96], 16)
        off += 110
        name = data[off:off + namesz - 1]
        off += namesz
        off = (off + 3) & ~3
        content = data[off:off + fsize]
        off += fsize
        off = (off + 3) & ~3
        name = name.decode("utf-8", "replace")
        if name == "TRAILER!!!":
            break
        entries.append((name, content, mode, uid, gid, mtime))
    return entries


def build_newc(entries):
    out = bytearray()

    def entry(name, content, mode=b"0100644", uid=b"00000000", gid=b"00000000",
              mtime=b"00000000", nlink=b"00000001"):
        nonlocal out
        nameb = name.encode("utf-8") + b"\x00"
        namesz = len(nameb)
        fsize = len(content)
        hdr = b"070701"
        hdr += b"00000000"
        hdr += mode
        hdr += uid
        hdr += gid
        hdr += nlink
        hdr += mtime
        hdr += f"{fsize:08X}".encode("ascii")
        hdr += b"00000000" * 4
        hdr += f"{namesz:08X}".encode("ascii")
        hdr += b"00000000"
        out += hdr
        out += nameb
        while len(out) % 4:
            out += b"\x00"
        out += content
        while len(out) % 4:
            out += b"\x00"

    for name, content, mode, uid, gid, mtime in entries:
        entry(name, content, mode, uid, gid, mtime)
    entry("TRAILER!!!", b"", mode=b"00000000", nlink=b"00000001")
    while len(out) % 512:
        out += b"\x00"
    return bytes(out)


def pad(b, page):
    return b + b"\x00" * ((page - len(b) % page) % page)


def patch_init_june_rc(content: bytes) -> bytes:
    text = content.decode("utf-8", "replace")
    if "service junelocal " in text:
        print("[!] init.june.rc already has service junelocal; skipping patch")
        return content
    if "service jcm_apply " in text:
        print("[!] init.june.rc already has service jcm_apply; skipping patch")
        return content

    # 1) Create media/log dirs alongside the existing /data/june mkdir block.
    anchor = "    mkdir /data/june 0775 root system\n"
    if anchor in text and "    mkdir /data/june/media" not in text:
        insert = (
            "    mkdir /data/june/media 0775 root system\n"
            "    mkdir /data/june/logs 0775 root system\n"
        )
        text = text.replace(anchor, anchor + insert, 1)

    # 2) Add the service definition immediately before the `on boot` block
    #    (or before `on property:sys.boot_completed=1` if `on boot` is absent).
    boot_anchor = "\non boot\n"
    if boot_anchor in text:
        text = text.replace(
            boot_anchor,
            "\n" + JCM_APPLY_SERVICE + SERVICE_BLOCK + CAMERAD_SERVICE + boot_anchor,
            1,
        )
    else:
        text = text.rstrip("\n") + "\n\n" + JCM_APPLY_SERVICE + SERVICE_BLOCK + CAMERAD_SERVICE

    # 3) Start it at boot_completed.
    completed = "on property:sys.boot_completed=1\n"
    if completed in text:
        if "    start junelocal\n" not in text:
            # Append after the `start bootclearsvc` line if present, else right
            # after the trigger line.
            start_marker = "    start bootclearsvc\n"
            if start_marker in text:
                text = text.replace(
                    start_marker,
                    start_marker + "    start jcm_apply\n    start junelocal\n    start camerad\n",
                    1,
                )
            else:
                text = text.replace(
                    completed,
                    completed + "    start jcm_apply\n    start junelocal\n    start camerad\n",
                    1,
                )
    else:
        text += "\non property:sys.boot_completed=1\n    start jcm_apply\n    start junelocal\n    start camerad\n"

    return text.encode("utf-8")


def main():
    inp = sys.argv[1] if len(sys.argv) > 1 else (
        os.path.join(os.path.dirname(__file__), "boot_adb_debug.img")
    )
    outp = sys.argv[2] if len(sys.argv) > 2 else (
        os.path.join(os.path.dirname(__file__), "boot_junelocal_init.img")
    )

    raw = open(inp, "rb").read()
    h = parse_header(raw[:2048])
    page = h["page_size"]

    koff = page
    roff = koff + ((h["kernel_size"] + page - 1) // page) * page
    soff = roff + ((h["ramdisk_size"] + page - 1) // page) * page
    doff = soff + ((h["second_size"] + page - 1) // page) * page

    kernel = raw[koff:koff + h["kernel_size"]]
    ramdisk = raw[roff:roff + h["ramdisk_size"]]
    second = raw[soff:soff + h["second_size"]]
    dt = raw[doff:doff + h["dt_size"]]

    cpio = gzip.GzipFile(fileobj=io.BytesIO(ramdisk)).read()
    entries = parse_newc(cpio)

    patched = False
    for i, (name, content, mode, uid, gid, mtime) in enumerate(entries):
        if name == "init.june.rc":
            new_content = patch_init_june_rc(content)
            if new_content != content:
                entries[i] = (name, new_content, mode, uid, gid, mtime)
                patched = True
            break
    if not patched:
        print("[!] init.june.rc unchanged (was it already patched?)")

    jcm_script_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "jcm_apply.sh")
    if not os.path.isfile(jcm_script_path):
        raise SystemExit(f"missing JCM apply script: {jcm_script_path}")
    jcm_script = open(jcm_script_path, "rb").read()
    if any(name == "sbin/jcm_apply.sh" for name, *_ in entries):
        print("[!] sbin/jcm_apply.sh already present in ramdisk")
    else:
        entries.append(
            ("sbin/jcm_apply.sh", jcm_script, b"000081ED",
             b"00000000", b"00000000", b"00000000")
        )

    new_cpio = build_newc(entries)
    gzout = io.BytesIO()
    with gzip.GzipFile(fileobj=gzout, mode="wb", mtime=0) as g:
        g.write(new_cpio)
    new_ramdisk = gzout.getvalue()

    h["ramdisk_size"] = len(new_ramdisk)
    sha = hashlib.sha1()
    sha.update(kernel)
    sha.update(new_ramdisk)
    sha.update(second)
    h["id"] = sha.digest().ljust(32, b"\x00")

    header = build_header(h)
    buf = bytearray()
    buf += header
    buf += pad(kernel, page)
    buf += pad(new_ramdisk, page)
    buf += pad(second, page)
    buf += pad(dt, page)

    # Pad to the full source-image length (the 8 MiB LNX partition) so a
    # `dd bs=512 seek=76544` overwrites the entire partition and clears any
    # stale trailing bytes.
    if len(buf) < len(raw):
        buf += b"\x00" * (len(raw) - len(buf))
    elif len(buf) > len(raw):
        raise SystemExit(
            f"patched image ({len(buf)}) grew past source ({len(raw)}); "
            "trim ramdisk growth"
        )

    final = bytes(buf)
    open(outp, "wb").write(final)
    print(f"[+] wrote {outp} total={len(final)} ramdisk={len(new_ramdisk)}")

    digest = hashlib.sha256(final).hexdigest()
    with open(outp + ".sha256", "w") as f:
        f.write(digest + "  " + os.path.basename(outp) + "\n")
    print(f"[+] sha256 {digest}")


if __name__ == "__main__":
    main()
