#!/usr/bin/env python3
# Copyright (C) 2026 Antonio Marogna — EVRApps
# SPDX-License-Identifier: GPL-3.0-only

"""
verify_offload_app.py — does an offload application's verification read the
destination back from the storage device, or from the page cache?

    engine/verify_offload_app.py SOURCE DEST_PARENT [--app NAME] [--app-path BUNDLE]

SOURCE is a file or a folder to offload. DEST_PARENT is where a fresh test
folder is created; point the application's destination at that folder.

With --guided, SOURCE is instead a folder on the source disk: the tool
generates the test data in a new folder there, checks the destination with a
first calibration, and removes the test data from both disks at the end.

The application is a black box: nothing is hooked or injected. The tool reads
the per-device byte counters of IOBlockStorageDriver around the job, separately
for the source disk and the destination disk, and compares them with the size
of the data.

Interactive by default (you drive the application, the tool waits). For CLI
copiers and for self-testing, --run-cmd runs a command instead:

    --run-cmd 'cp {src} {dst}/ && xxhsum {dst}/clip.mov'

Incremental offloads (several runs on the same destination): --runs N. The
expected destination read is then about N x the data; the verdict is unchanged.

Exit codes: 0 destination re-read from the device, 1 destination not re-read
from the device, 2 inconclusive, 3 not evaluable (copy missing, instrument not
validated, unsupported topology).

For a graphical front end there are two machine modes, which change only how
the measurement is driven, never what it measures or how it is judged:

    --check   print the pre-flight checks as one JSON object, create nothing
    --steps   JSON lines on stdout (events, live counters ~4 times a second);
              one command per line on stdin ("ok", "no", "retry", "abort") at each
              {"ev": "await"}. Report and exit code as in the terminal.
"""

import argparse
import datetime
import json
import os
import plistlib
import random
import re
import shlex
import subprocess
import sys
import threading
import time

ENGINE_VERSION = "1.0"
HERE = os.path.dirname(os.path.abspath(__file__))
EVR_COPYHASH = os.path.normpath(os.path.join(HERE, "..", "evr_copyhash"))
NETWORK_FS = ("smbfs", "afpfs", "nfs", "webdav")
CHUNK = 4 * 1024 * 1024
MB = 1024 * 1024

# Verdict thresholds, as a fraction of the data size. Wide on purpose: the
# question is "about all of it" or "about none of it"; anything in between is
# reported as inconclusive rather than rounded to an answer.
MEDIUM_READ = 0.8
NOT_READ = 0.1

# --guided: size of the generated test data. The ceiling is the size_check rule
# (data x 2 <= reusable RAM); the data takes GUIDED_MARGIN of it. The maximum
# is not about RAM: on an ExFAT card destination (FSKit, 16 GB Mac, 5 GB
# reusable) reference A held at 0.00 x up to 448 MB and failed from 480 MB.
# The minimum is not about background reads either: on quiet external disks
# they stayed under 0.02 MB per 30 s, and even 16 MB calibrated cleanly.
GUIDED_MARGIN = 0.2
GUIDED_MIN = 128 * MB
GUIDED_MAX = 256 * MB
GUIDED_FILES = (5, 8)
GUIDED_RAM_REFUSAL = ("not enough free memory for the test data: "
                      "quit some apps and try again")


# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------

def sh(args):
    return subprocess.run(args, capture_output=True, text=True).stdout


def sh_plist(args):
    out = subprocess.run(args, capture_output=True).stdout
    return plistlib.loads(out) if out else None


def ask(prompt, default=""):
    try:
        ans = input(prompt).strip()
    except EOFError:
        ans = ""
    return ans or default


def fmt_mb(n):
    return f"{n / MB:,.0f} MB"


def refuse(msg, *cleanup):
    """Not evaluable. Exit 3, never 1: 1 is a verdict about the application,
    and a refusal must not be mistaken for one by whoever reads only $?."""
    for p in cleanup:
        if p:
            subprocess.run(["rm", "-rf", p])
    print(f"NOT EVALUABLE: {msg}", file=sys.stderr)
    sys.exit(3)


# --------------------------------------------------------------------------
# storage topology: path -> the physical disk whose counter must be read
# --------------------------------------------------------------------------

def mount_of(path):
    """Return (device, mountpoint, fstype) for the mount holding path."""
    real = os.path.realpath(path)
    best = None
    for line in sh(["mount"]).splitlines():
        m = re.match(r"^(.+?) on (.+?) \(([^,)]+)", line)
        if not m:
            continue
        dev, mnt, fstype = m.groups()
        if real == mnt or real.startswith(mnt.rstrip("/") + "/"):
            if best is None or len(mnt) > len(best[1]):
                best = (dev, mnt, fstype)
    return best


def image_path_for(whole):
    info = sh_plist(["hdiutil", "info", "-plist"]) or {}
    for img in info.get("images", []):
        for ent in img.get("system-entities", []):
            if ent.get("dev-entry") == "/dev/" + whole:
                return img.get("image-path", "")
    return ""


def physical_of_device(dev):
    """Follow APFS containers to the physical store. Returns (disk, info)."""
    info = sh_plist(["diskutil", "info", "-plist", dev]) or {}
    stores = info.get("APFSPhysicalStores") or []
    if stores:
        store = stores[0].get("APFSPhysicalStore")
        if store:
            return physical_of_device("/dev/" + store)
    return info.get("ParentWholeDisk"), info


def classify(path):
    """Describe where path lives and which counter observes it."""
    m = mount_of(path)
    if not m:
        refuse(f"cannot tell which volume holds {path}")
    dev, mnt, fstype = m
    c = {"path": path, "mount": mnt, "device": dev, "fstype": fstype,
         "kind": None, "disk": None, "backing_disk": None, "detail": ""}
    if fstype in NETWORK_FS:
        c["kind"] = "network"
        host = re.sub(r"^//(?:[^@]+@)?", "", dev).split("/")[0]
        c["detail"] = host
        if host.split(".")[0] in ("localhost", "127") or host.startswith("127."):
            c["kind"] = "loopback"
        else:
            c["out_ifaces"] = net_out_ifaces(host)
        return c
    disk, info = physical_of_device(dev)
    c["disk"] = disk
    c["detail"] = info.get("MediaName") or info.get("IORegistryEntryName") or ""
    if info.get("BusProtocol") == "Disk Image":
        img = image_path_for(disk)
        if img.startswith("ram://"):
            c["kind"], c["detail"] = "ram", img
        else:
            # A file-backed image: its reads also land on the disk holding the
            # image file, which may be the other side of the test.
            c["kind"], c["detail"] = "image", img
            bm = mount_of(img)
            if bm:
                c["backing_disk"] = physical_of_device(bm[0])[0]
    else:
        c["kind"] = "local"
    return c


def physical_disks(c):
    """Every physical disk whose counter this location can move."""
    if c["kind"] in ("network", "loopback"):
        return set()
    return {d for d in (c["disk"], c["backing_disk"]) if d}


# --------------------------------------------------------------------------
# counters
# --------------------------------------------------------------------------

def block_counters():
    """{whole_disk: (bytes_read, bytes_written)} for every block device."""
    out = {}
    for drv in sh_plist(["ioreg", "-a", "-l", "-r", "-c",
                         "IOBlockStorageDriver", "-d", "2"]) or []:
        st = drv.get("Statistics", {})
        for child in drv.get("IORegistryEntryChildren", []):
            name = child.get("BSD Name")
            if name:
                out[name] = (st.get("Bytes (Read)", 0),
                             st.get("Bytes (Write)", 0))
    return out


def counters_for(disks, tries):
    """block_counters() with every disk in disks present, retried up to tries
    times: a snapshot can come back without a disk (or empty, if ioreg fails),
    and a missing disk read as 0 turns the next delta into its lifetime total."""
    disks = [d for d in disks if d]
    for i in range(tries):
        blk = block_counters()
        if all(d in blk for d in disks):
            return blk
        time.sleep(0.05)
    return blk


def net_if_bytes():
    """{interface: (inbound, outbound) bytes} for every non-loopback interface.

    Columns are taken from the end of each Link row. Rows for interfaces
    without a hardware address have one field fewer, so counting from the left
    silently reads the error columns instead of the byte columns.
    """
    out = {}
    for line in sh(["netstat", "-ib"]).splitlines()[1:]:
        tok = line.split()
        if len(tok) < 8 or "<Link#" not in line or tok[0].startswith("lo"):
            continue
        try:
            out[tok[0].rstrip("*")] = (int(tok[-5]), int(tok[-2]))     # Ibytes, Obytes
        except ValueError:
            pass
    return out


def net_io_bytes(ifs=None):
    """(inbound, outbound) bytes summed over all non-loopback interfaces."""
    v = (ifs if ifs is not None else net_if_bytes()).values()
    return sum(i for i, _ in v), sum(o for _, o in v)


def net_out_ifaces(host):
    """The physical interfaces that traffic to host leaves on.

    Outbound bytes cannot be summed over all interfaces: over a bridge each
    byte is counted more than once. Measured on Thunderbolt Bridge (macOS 15.7,
    Intel): bridge0 counts every outbound byte twice and the member carrying it
    once more, so an SMB copy of 120 MB showed 363 MB written. The members
    count it once. Inbound bytes appear on the bridge only, once, so the
    inbound sum the verdict uses is not affected."""
    m = re.search(r"interface:\s*(\S+)", sh(["route", "get", host]))
    if not m:
        return []
    iface = m.group(1)
    if iface.startswith("bridge"):
        return re.findall(r"member:\s*(\S+)", sh(["ifconfig", iface])) or [iface]
    return [iface]


def net_out_bytes(ifs, out_ifaces):
    """Outbound bytes on the physical path; all interfaces if it is unknown."""
    if not out_ifaces:
        return net_io_bytes(ifs)[1]
    return sum(ifs.get(i, (0, 0))[1] for i in out_ifaces)


def net_in_bytes():
    return net_io_bytes()[0]


class Observer:
    """Reads source reads, destination reads and destination writes."""

    def __init__(self, src, dst):
        self.src, self.dst = src, dst
        self.ifs = {}                       # per-interface counters at the last snap

    def snap(self):
        disks = [self.src["disk"] if self.src["kind"] not in ("network", "loopback") else None,
                 self.dst["disk"] if self.dst["kind"] != "network" else None]
        blk = counters_for(disks, 40)
        for d in disks:
            if d and d not in blk:
                raise RuntimeError(f"the block counters of {d} could not be read")
        s = {"src_r": 0, "dst_r": 0, "dst_w": 0}
        if self.src["kind"] not in ("network", "loopback"):
            s["src_r"] = blk.get(self.src["disk"], (0, 0))[0]
        if self.dst["kind"] == "network":
            self.ifs = net_if_bytes()
            s["dst_r"] = net_io_bytes(self.ifs)[0]     # data coming back from the server
            s["dst_w"] = net_out_bytes(self.ifs, self.dst.get("out_ifaces"))
        else:
            r, w = blk.get(self.dst["disk"], (0, 0))
            s["dst_r"], s["dst_w"] = r, w
        s["t"] = time.monotonic()
        return s

    @staticmethod
    def delta(a, b):
        return {k: b[k] - a[k] for k in a}


# --------------------------------------------------------------------------
# environment
# --------------------------------------------------------------------------

def reusable_ram():
    page, free, inactive = 4096, 0, 0
    for line in sh(["vm_stat"]).splitlines():
        m = re.search(r"page size of (\d+)", line)
        if m:
            page = int(m.group(1))
        if line.startswith("Pages free:"):
            free = int(line.split()[-1].rstrip("."))
        if line.startswith("Pages inactive:"):
            inactive = int(line.split()[-1].rstrip("."))
    return (free + inactive) * page


def source_files(src):
    if os.path.isfile(src):
        return [src]
    out = []
    for root, _, names in os.walk(src):
        for n in names:
            if not n.startswith("."):
                out.append(os.path.join(root, n))
    return out


def backup_running():
    """The status of the Time Machine backup running now, or None. `tmutil
    status` needs no Full Disk Access; if it cannot be run, the answer is None."""
    try:
        st = sh_plist(["tmutil", "status", "-X"])
    except (OSError, plistlib.InvalidFileException):
        return None
    return st if st and st.get("Running") in (1, True) else None


def tm_excluded(path):
    """True if Time Machine leaves path out of its backups, False if it backs it
    up, None if tmutil cannot tell (some paths need Full Disk Access)."""
    try:
        r = subprocess.run(["tmutil", "isexcluded", path], capture_output=True, text=True)
    except OSError:
        return None
    if r.returncode != 0:
        return None
    if "[Excluded]" in r.stdout:
        return True
    if "[Included]" in r.stdout:
        return False
    return None


def backup_conflict(src, dst):
    """Why a running Time Machine backup stops the test, or None.

    A backup reads the disks it backs up in bursts (376 MB in 30 s on the
    system disk), more than the test data, and no subtraction of the
    background removes bursts like that. During a backup, external disks
    left out of it showed no background reads at all. So a backup stops the
    test only where it can reach a counter the verdict reads: a disk it backs
    up, the disk it writes to, or any network destination, whose reads are
    counted on every interface. The system disk is refused with --guided
    anyway: tmutil reports "/" as excluded, since what it backs up is the data
    volume."""
    st = backup_running()
    if not st:
        return None
    if dst["kind"] in ("network", "loopback"):
        return ("a Time Machine backup is running and the destination is a network share: "
                "the test counts all network traffic, the backup's too. "
                "Try again when the backup has finished")
    target = st.get("DestinationMountPoint")
    target_disks = set()
    if target and os.path.exists(target):
        tc = classify(target)
        target_disks = physical_disks(tc) | ({tc["mount"]} if tc["kind"] == "network" else set())
    for side, c in (("source", src), ("destination", dst)):
        if physical_disks(c) & target_disks:
            return (f"a Time Machine backup is running onto the {side} disk: it writes "
                    "and reads there and skews the measurement. "
                    "Try again when the backup has finished")
        excluded = tm_excluded(c["mount"])
        if excluded is False:
            return (f"a Time Machine backup is running and it includes the {side} disk: "
                    "it reads the disk and skews the measurement. Try again when the "
                    "backup has finished, or exclude the disk from Time Machine")
        if excluded is None:
            return (f"a Time Machine backup is running and it can't be told whether it "
                    f"includes the {side} disk. Try again when the backup has finished")
    return None


def guided_size(ram, requested=None):
    """Bytes of test data for --guided, or None if RAM is too short for the minimum."""
    if requested:
        return requested if 2 * requested <= ram else None
    total = min(GUIDED_MAX, int(ram / 2 * GUIDED_MARGIN))
    return total if total >= GUIDED_MIN else None


def guided_name(parents, suffix="", prefix="ReadbackCheck_Test"):
    """A <prefix>_<YYYYMMDD-hhmmss> name free under every parent (source and
    destination). Always with seconds: a test started in the same minute as the
    one before, whose folders are gone by then, must not get the same name, or
    an offload app can take the new test folder for one it has already seen."""
    now = datetime.datetime.now()
    base = f"{prefix}_{now:%Y%m%d-%H%M%S}"
    for n in range(1, 100):
        name = base if n == 1 else f"{base}-{n}"
        if not any(os.path.exists(os.path.join(p, name + suffix)) for p in parents):
            return name
    return f"{base}-{os.getpid()}"


def make_test_files(folder, total):
    """Random .bin files, all of a different size, adding up to about total.

    Different sizes let copies_found match an app that renames on ingest. The
    sizes are deliberately not multiples of a page. Each file is fsynced, so the
    data is on the source disk before anything reads it."""
    rnd = random.SystemRandom()
    n = rnd.randint(*GUIDED_FILES)
    while True:
        w = [rnd.uniform(0.5, 1.5) for _ in range(n)]
        sizes = [int(total * x / sum(w)) + rnd.randint(1, 4095) for x in w]
        if len(set(sizes)) == n:
            break
    paths = []
    for i, sz in enumerate(sizes, 1):
        p = os.path.join(folder, f"ReadbackCheck_{i:02d}.bin")
        fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
        try:
            left = sz
            while left:
                k = min(CHUNK, left)
                os.write(fd, os.urandom(k))
                left -= k
            os.fsync(fd)
        finally:
            os.close(fd)
        paths.append(p)
    return paths


def app_version(app_path):
    """(version, bundle name) read from the bundle's Info.plist, or (None, None)."""
    plist = os.path.join(app_path, "Contents", "Info.plist")
    try:
        with open(plist, "rb") as f:
            p = plistlib.load(f)
    except (OSError, plistlib.InvalidFileException):
        return None, None
    name = p.get("CFBundleName") or p.get("CFBundleDisplayName")
    return f"{p.get('CFBundleShortVersionString', '?')} ({p.get('CFBundleVersion', '?')})", name


def app_identity(name, app_path):
    """Version of the measured app and where it was read from, for the report.

    The version is only as good as the bundle it comes from, so the report names
    that bundle. Two ways it went wrong in practice: a bundle path left over from
    an earlier measurement of another app, read while the name field was empty;
    and the default /Applications/<name>.app holding an older copy than the one
    actually launched. Returns (version, read_from, notes)."""
    notes = []
    if not name:
        notes.append("app name not given: the report does not say which app was measured")
    if app_path:
        read_from = os.path.realpath(app_path)
    elif name:
        read_from = f"/Applications/{name}.app"
    else:
        return "not read", "no bundle (app name and path not given)", notes
    version, bundle_name = app_version(read_from)
    if version is None:
        return "not read", f"{read_from} (Info.plist missing or unreadable)", notes
    if name and bundle_name and bundle_name.lower() != name.lower():
        notes.append(f"the version was read from the bundle '{bundle_name}', not '{name}': "
                     "the version in this report may not be the measured app's")
    if not app_path:
        notes.append(f"version read from {read_from} because no bundle was given: "
                     "if the measured app was launched from somewhere else, it may not be its version")
    return version, read_from, notes


def seen_label(x):
    return f"{x['name']} {x['version']}".strip() if x.get("version") else x["name"]


def seen_lines(seen, app_name, app_path, out, notes, report):
    """The apps seen copying, from the interface. With no app chosen and one
    seen, it stands in for the name; one chosen but not seen is pointed out."""
    if not seen:
        out("  seen copying   : no app was seen with files open in the test folders")
    for x in seen:
        sides = " and ".join(s for s in ("source", "destination") if s in (x.get("sides") or [])) or "the test folders"
        out(f"  seen copying   : {seen_label(x)} — {x.get('path', '')}  (files open in {sides})")
    if not app_name and len(seen) == 1:
        label = seen_label(seen[0])
        notes[:] = [n for n in notes if not n.startswith("app name not given")]
        notes.append(f"app not chosen: {label} was identified during the copy, "
                     "from the files it had open in the test folders")
        for i, line in enumerate(report):
            if line.startswith(" Readback Check engine") and line.endswith("(name not given)"):
                report[i] = line.replace("(name not given)", f"{label} (identified during the copy)")
            elif line.startswith("  app            : (name not given)"):
                report[i] = f"  app            : {label}  (not chosen: identified during the copy)"
            elif line.startswith("                   version read from: no bundle"):
                report[i] = f"                   version read from: {seen[0].get('path', '')}"
        report[:] = [l for l in report if l != "  WARNING        : app name not given"]
    elif app_name and seen:
        chosen = os.path.realpath(app_path) if app_path else None
        if not any(x.get("path") == chosen or x["name"].lower() == app_name.lower() for x in seen):
            notes.append(f"{app_name} was chosen, but it was not seen with files open in the test "
                         f"folders; seen instead: {', '.join(seen_label(x) for x in seen)}")


def verdict_words(copy_ok, rc, calib):
    """The outcome in the interface's words, for the report's file name; the
    same rule as the interface's Verdict."""
    if not copy_ok:
        return "run again"
    if rc == 0:
        return "read back"
    if rc == 1 and isinstance(calib, dict) and calib.get("B", 0) >= MEDIUM_READ:
        return "not read back"
    return "undetermined"


def report_path(folder, when, app, verdict):
    """'2026-10-31 07.33 – YourOffloadApp 1.0 – not read back.txt': sorted by name,
    the reports are in date order. Seconds are added only on a clash, then a
    number: a report is never overwritten."""
    app = re.sub(r"[/:\\]+", "-", app or "app not given").strip() or "app not given"
    stamps = [f"{when:%Y-%m-%d %H.%M}", f"{when:%Y-%m-%d %H.%M.%S}"]
    stamps += [f"{stamps[1]}-{n}" for n in range(2, 100)]
    for stamp in stamps:
        path = os.path.join(folder, f"{stamp} – {app} – {verdict}.txt")
        if not os.path.exists(path):
            return path
    return os.path.join(folder, f"{stamps[1]}-{os.getpid()} – {app} – {verdict}.txt")


def can_remount(c):
    return c["kind"] in ("local", "ram") and c["mount"] not in ("/", "/System/Volumes/Data")


def settle(disk, quiet=2.0, limit=15.0):
    """Wait until disk reads nothing for quiet seconds, or limit seconds pass.

    Right after mounting, APFS reads the volume's own metadata: 39, 22 and
    6 MB in the first three seconds on a USB SSD, then nothing. The background
    window that follows would take that burst for steady activity and subtract
    it over the whole job (667 MB from a 256 MB source read). ExFAT cards
    showed no burst."""
    def reads():
        return counters_for([disk], 2).get(disk, (None, None))[0]
    last, still, t0 = reads(), 0.0, time.monotonic()
    if last is None:
        return
    while still < quiet and time.monotonic() - t0 < limit:
        time.sleep(0.5)
        now = reads()
        if now is None:
            return
        still = still + 0.5 if now - last < 64 * 1024 else 0.0
        last = now


def remount(c, why=None):
    """Make the source cold by unmounting and remounting its volume.

    Measured on ExFAT and APFS to drop that volume's cached pages, without
    root. Returns True only if both steps succeeded and the path is back,
    and the disk has settled.
    If why is a dict, a failure fills it with "code" (not_remountable,
    unmount_failed, mount_failed) and "detail" (diskutil's own words).
    """
    why = why if why is not None else {}
    if not can_remount(c):
        why.update(code="not_remountable", detail=f"{c['kind']} · {c['mount']}")
        return False
    u = subprocess.run(["diskutil", "unmount", c["mount"]], capture_output=True, text=True)
    if u.returncode != 0:
        why.update(code="unmount_failed", detail=(u.stderr or u.stdout).strip())
        return False
    m = subprocess.run(["diskutil", "mount", c["device"]], capture_output=True, text=True)
    for _ in range(40):
        if os.path.exists(c["path"]):
            settle(c["disk"])
            return True
        time.sleep(0.25)
    why.update(code="mount_failed", detail=(m.stderr or m.stdout).strip())
    return False


def read_fully(path):
    """An ordinary read, through the file cache."""
    fd = os.open(path, os.O_RDONLY)
    try:
        while os.read(fd, CHUNK):
            pass
    finally:
        os.close(fd)


def bytes_in(run_dir):
    """Bytes of visible files under run_dir. Hidden files are left out: an app
    may write its own bookkeeping when a job is set up, before any copy."""
    total = 0
    for root, dirs, names in os.walk(run_dir):
        dirs[:] = [d for d in dirs if not d.startswith(".")]
        for n in names:
            if not n.startswith("."):
                try:
                    total += os.path.getsize(os.path.join(root, n))
                except OSError:
                    pass
    return total


EARLY_COPY_REFUSAL = ("the copy started before the test was watching the disks, so it was "
                      "not measured: run the test again and start the copy only once the "
                      "folders to copy are shown")


def copies_found(files, run_dir):
    """Bytes of source files found in run_dir, and how they were matched.

    First by name and size. Applications that rename on ingest (roll names,
    clip prefixes) defeat that, so if it falls short each source size is then
    matched to a distinct file of the same size. A false match would need an
    unrelated file of exactly the same byte count in a folder created empty
    for this test.
    """
    by_name_sizes, pool = {}, {}
    for root, dirs, names in os.walk(run_dir):
        dirs[:] = [d for d in dirs if not d.startswith("calibration_")]
        for n in names:
            try:
                sz = os.path.getsize(os.path.join(root, n))
            except OSError:
                continue
            by_name_sizes.setdefault(n, set()).add(sz)
            pool[sz] = pool.get(sz, 0) + 1
    sizes = [(f, os.path.getsize(f)) for f in files]
    total = sum(s for _, s in sizes)
    by_name = sum(s for f, s in sizes if s in by_name_sizes.get(os.path.basename(f), ()))
    if by_name >= 0.95 * total:
        return by_name, "name and size"
    by_size = 0
    for _, s in sizes:
        if pool.get(s, 0) > 0:
            pool[s] -= 1
            by_size += s
    if by_size > by_name:
        return by_size, "size only — the app renamed the files"
    return by_name, "name and size"


# --------------------------------------------------------------------------
# calibration: two copiers whose answer is known
# --------------------------------------------------------------------------

def calibrate(obs, files, run_dir, size, noise, on_phase=None):
    """Reference A must read ~0 back, reference B ~all of it. Otherwise the
    instrument is not trustworthy on this destination, whatever it says about
    the app. Background noise is subtracted exactly as for the job, or a busy
    system disk can push reference A over the threshold on its own.
    on_phase(label) is called as each reference starts (live display only)."""
    if not os.access(EVR_COPYHASH, os.X_OK):
        return None, f"evr_copyhash not found at {EVR_COPYHASH}"
    res = {}
    for label, flags in (("A", ["--cached-write"]), ("B", [])):
        if on_phase:
            on_phase(label)
        cdir = os.path.join(run_dir, "calibration_" + label)
        os.makedirs(cdir, exist_ok=True)
        copies = []
        for f in files:
            d = os.path.join(cdir, os.path.basename(f))
            subprocess.run([EVR_COPYHASH, f, d] + flags, capture_output=True)
            copies.append(d)
        subprocess.run(["sync"])
        time.sleep(1)
        a = obs.snap()
        for d in copies:
            read_fully(d)
        b = obs.snap()
        dd = Observer.delta(a, b)
        res[label] = max(0, dd["dst_r"] - noise["dst_r"] * dd["t"]) / size
    ok = res["A"] <= NOT_READ and res["B"] >= MEDIUM_READ
    return ok, res


def destination_verdict(copy_ok, calib, size_ok, r_dst, network=False, calib_pre=None):
    """(text, exit code) for the destination question.

    The two calibration references fail in different ways that mean different
    things. If B, whose readback must reach the disk, is not seen, the counter
    does not work on this destination and nothing can be said. If A, whose
    readback should be answered from cache, is read from disk, the counter works
    but the cache does not hold the data here: an application readback from disk
    can no longer be attributed to a choice. A zero, however, survives that — if
    the application read nothing from the disk, a leaky cache does not change it.
    On a network destination A crosses the network whatever the data size, so
    there the verdict gives that reason instead of advising less data. A share's
    client cache can also hold A at one check and not at the other (SMB 1: 1.05 x
    before the job, 0.00 x after it), so there A must pass both checks.

    When calibration ran, it replaces the RAM-size estimate: free + inactive
    pages overstates how much freshly written data stays cached, because the
    kernel reclaims from the same inactive queue the new pages land in.
    """
    if not copy_ok:
        return ("NOT EVALUABLE — the copy is not (all) in the test folder. "
                "Check the destination set in the app."), 3
    attributable = size_ok
    if isinstance(calib, dict):
        ca, cb = calib["A"], calib["B"]
        if cb < MEDIUM_READ:
            return (f"INSTRUMENT NOT VALIDATED — reference B, whose readback must reach "
                    f"the disk, was seen for only {cb:.2f} x: on this destination the "
                    "counter does not measure re-reads."), 3
        pre = calib_pre["A"] if network and isinstance(calib_pre, dict) else 0.0
        attributable = ca <= NOT_READ and pre <= NOT_READ
        if not attributable and r_dst > NOT_READ:
            if network:
                when = ("" if ca > NOT_READ and pre > NOT_READ
                        else " after the copy" if ca > NOT_READ else " before the copy")
                return (f"INCONCLUSIVE — on this network destination the Mac's cache does not "
                        f"hold the copy reliably: even reference A, whose readback should come "
                        f"from RAM, was read back over the network for {max(ca, pre):.0%}{when}. "
                        "Every read can cross the network whatever the app chooses, so a read "
                        "back can't be attributed to the app."), 2
            return (f"INCONCLUSIVE — the cache does not hold the data: even reference A, "
                    f"whose readback should come from RAM, was read back from the disk for "
                    f"{ca:.0%}. A re-read from the disk by the app therefore cannot be "
                    "attributed to a choice. Repeat with less data or more free memory."), 2
    if r_dst >= MEDIUM_READ:
        if attributable:
            return ("DESTINATION READ BACK FROM THE DEVICE — during the job the destination "
                    "disk read the whole amount of data, and the cache could have held it: "
                    "reading back from the device is the app's choice."), 0
        return ("READ BACK FROM THE DEVICE, NOT ATTRIBUTABLE — the data exceeds the "
                "available cache: it would have been read from the disk anyway."), 2
    if r_dst <= NOT_READ:
        return ("DESTINATION NOT READ BACK FROM THE DEVICE — whatever verification took "
                "place did not read the data from the disk."), 1
    return (f"INCONCLUSIVE — {r_dst:.0%} of the data was read back: partial eviction or "
            "partial reads. Repeat with less data or with a quieter disk."), 2


# --------------------------------------------------------------------------
# pre-flight: the same checks for the measurement and for --check
# --------------------------------------------------------------------------

def paths_problem(source, dest_parent, guided=False):
    """Why the two paths cannot be used, or None. With --guided the source is
    the folder the test data is generated in."""
    if not os.path.exists(source):
        return f"source not found: {source}"
    if guided and not (os.path.isdir(source) and os.access(source, os.W_OK)):
        return f"source not writable: {source}"
    # The destination parent must already exist. Never create it: a missing
    # "/Volumes/<name>" means the disk is not mounted (or is named differently),
    # and creating that folder would put the test on the system disk instead.
    if not os.path.isdir(dest_parent):
        mounted = ", ".join(sorted(n for n in os.listdir("/Volumes") if not n.startswith(".")))
        return (f"destination not found: {dest_parent}\n"
                f"  volumes mounted in /Volumes: {mounted}\n"
                "  (if the name contains spaces, put it in quotes)")
    if not os.access(dest_parent, os.W_OK):
        return f"destination not writable: {dest_parent}"
    return None


def topology_check(src, dst, boot, guided=False):
    """(refusal or None, notes) for a source and a destination location.

    --guided refuses the system disk on either side: its background reads
    (Spotlight, Time Machine, the system itself) reached 376 MB in 30 s, more
    than the test data, and no amount of data outweighs them."""
    notes = []
    if guided:
        for side, c in (("source", src), ("destination", dst)):
            if boot["disk"] in physical_disks(c):
                return (f"the {side} is on the system disk, which reads in the background "
                        "all the time: use a card or an external disk"), notes
    if dst["kind"] == "loopback":
        return ("SMB/AFP destination over loopback: reads and writes both arrive as "
                "inbound traffic on lo0 and cannot be told apart"), notes
    shared = physical_disks(src) & physical_disks(dst)
    if shared:
        return (f"source and destination share the physical disk {', '.join(shared)}: "
                "the counters cannot tell the two apart (and on the same APFS volume the "
                "copy can be a clone, with no data written). Use different disks."), notes
    if dst["kind"] == "image":
        notes.append("the destination is a file-backed disk image: "
                     "the image's cache and the cache of the file holding it add up")
    if dst["disk"] and dst["disk"] == boot["disk"]:
        notes.append("the destination is on the system disk, which reads in the background "
                     "all the time: for clean measurements use a dedicated external disk")
    if dst["kind"] == "network":
        notes.append("network destination: inbound bytes are counted on all interfaces, "
                     "shared with all other traffic; and a read reaches the server, "
                     "not necessarily its disk")
    return None, notes


def size_check(size):
    """(reusable RAM, size_ok, note or None)."""
    ram = reusable_ram()
    size_ok = 2 * size <= ram
    note = None
    if not size_ok:
        note = (f"the data ({fmt_mb(size)}) is too large for the reusable RAM "
                f"({fmt_mb(ram)}): a read back from the device will not be "
                "attributable to the app (it would be evicted anyway)")
    return ram, size_ok, note


def preflight(source, dest_parent, guided=False, test_size=None):
    """--check: everything the measurement checks before it starts, without
    creating the test folder. The destination parent stands in for the test
    folder, which will live on the same mount. With --guided, size is what
    would be generated and files is 0."""
    r = {"refusal": paths_problem(source, dest_parent, guided), "notes": []}
    if r["refusal"]:
        return r
    if guided:
        files, size = [], guided_size(reusable_ram(), test_size)
        if size is None:
            r["refusal"] = GUIDED_RAM_REFUSAL
            return r
    else:
        files = source_files(source)
        if not files:
            r["refusal"] = "no files in the source"
            return r
        size = sum(os.path.getsize(f) for f in files)
    src, dst = classify(source), classify(os.path.realpath(dest_parent))
    boot = classify("/")
    r["refusal"], r["notes"] = topology_check(src, dst, boot, guided)
    if guided and not r["refusal"]:
        r["refusal"] = backup_conflict(src, dst)
    ram, size_ok, note = size_check(size)
    if note:
        r["notes"].append(note)
    r.update(source=src, dest=dst, files=len(files), size=size, ram=ram,
             size_ok=size_ok, remountable=can_remount(src), boot_disk=boot["disk"])
    return r


# --------------------------------------------------------------------------
# who drives the measurement: an operator at a terminal, or an interface
# --------------------------------------------------------------------------

class Aborted(Exception):
    pass


class TerminalUI:
    """The prompts for an operator at a terminal."""

    steps = False

    def line(self, s=""):
        print(s)

    def say(self, s=""):
        print(s)

    def attach(self, src, dst):
        pass

    def phase(self, name, scale=None):
        pass

    def settings(self, args):
        """(verify mode, extras confirmed off)."""
        print()
        verify_mode = args.verify_mode or ask(
            "  Verification setting used in the app (e.g. 'xxHash64, source+destination'): ",
            "not given")
        if args.extras_off:
            return verify_mode, True
        extras = ask("  Are transcodes, proxies, previews and thumbnail reports OFF? [y/n]: ", "n")
        return verify_mode, extras.lower() in ("y", "yes")

    def confirm_large(self, size, ram):
        print(f"\n  WARNING: {fmt_mb(size)} of data with {fmt_mb(ram)} of reusable RAM.")
        print("  The cache will not hold it: the destination verdict will be inconclusive")
        print(f"  and the calibration will fail. Reduce the source below {fmt_mb(ram // 2)}.")
        return ask("  Continue anyway? [y/N]: ", "n").lower().startswith("y")

    def before_remount(self):
        ask("\n  Make sure the app does not have the source open in a job.\n"
            "  Press Return to unmount and remount the source (cold cache)... ")

    def remount_result(self, ok, why):
        """True to try again. The terminal never does: it reports in the notes."""
        return False

    def job_setup(self, app, source, run_dir):
        print()
        print(f"  Set up the job in {app}:")
        print(f"    source       -> {source}")
        print(f"    destination  -> {run_dir}")
        print("  Do NOT start it yet.")
        ask("\n  Press Return when the job is set up (not started)... ")

    def before_noise(self):
        print("  Measuring 5 seconds of background activity: don't touch anything...")

    def start_job(self, app, runs):
        pass

    def job_done(self, app, runs):
        more = f" ({runs} runs on the same destination)" if runs > 1 else ""
        ask(f"  START the job in {app} NOW{more}. Press Return only when the app says the "
            "VERIFICATION is complete... ")
        return []

    def result(self, **kw):
        pass

    def delete_folder(self):
        return ask("  Delete the test folder with the copies? [Y/n]: ", "y").lower().startswith("y")


def live_snap(src, dst):
    """All four counters, for display. Observer.snap stays the one the verdict
    uses; this adds source writes and, on a network destination, outbound bytes.
    A counter that could not be read is None."""
    local_src = src["kind"] not in ("network", "loopback")
    blk = counters_for([src["disk"] if local_src else None,
                        dst["disk"] if dst["kind"] != "network" else None], 2)
    s = {"src_r": 0, "src_w": 0, "dst_r": 0, "dst_w": 0}
    if local_src:
        s["src_r"], s["src_w"] = blk.get(src["disk"], (None, None))
    if dst["kind"] == "network":
        ifs = net_if_bytes()
        s["dst_r"] = net_io_bytes(ifs)[0]
        s["dst_w"] = net_out_bytes(ifs, dst.get("out_ifaces"))
    else:
        s["dst_r"], s["dst_w"] = blk.get(dst["disk"], (None, None))
    s["t"] = time.monotonic()
    return s


class Sampler(threading.Thread):
    """Emits the counters a few times a second, as bytes since the start of the
    current phase and as instantaneous rates. For the eyes only: nothing it
    reads reaches the verdict."""

    INTERVAL = 0.25

    def __init__(self, ui, src, dst):
        super().__init__(daemon=True)
        self.ui, self.src, self.dst = ui, src, dst
        self.lock = threading.Lock()
        self.name_, self.scale, self.base, self.shown = "idle", None, None, {}
        self.stop = threading.Event()

    def set_phase(self, name, scale=None):
        """Switch phase. The phase that ends gets a closing sample, so bytes that
        arrived after its last periodic sample are still shown."""
        cur = live_snap(self.src, self.dst)
        with self.lock:
            self._emit(cur, None, final=True)
            self.name_, self.scale, self.base, self.shown = name, scale, dict(cur), {}

    def _emit(self, cur, prev, final=False):
        ev = {"phase": self.name_}
        keys = [k for k in cur if k != "t" and cur[k] is not None]
        if self.base is not None:
            for k in keys:
                # A counter missing from the phase's first snapshot starts from
                # here; one that went backwards (the disk was re-attached) goes
                # on from what was already shown.
                if self.base[k] is None:
                    self.base[k] = cur[k]
                elif cur[k] < self.base[k] + self.shown.get(k, 0):
                    self.base[k] = cur[k] - self.shown.get(k, 0)
        if prev is not None:
            dt = max(cur["t"] - prev["t"], 1e-3)
            ev["rate"] = {k: max(0, cur[k] - prev[k]) / dt for k in keys if prev[k] is not None}
        if self.base is not None and self.name_ != "idle":
            ev["t"] = cur["t"] - self.base["t"]
            ev["bytes"] = {k: cur[k] - self.base[k] for k in keys}
            self.shown.update(ev["bytes"])
            ev["scale"] = self.scale
        elif final:
            return
        if final:
            ev["final"] = True
        self.ui.emit("sample", **ev)

    def run(self):
        prev = live_snap(self.src, self.dst)
        while not self.stop.wait(self.INTERVAL):
            cur = live_snap(self.src, self.dst)
            with self.lock:
                self._emit(cur, prev)
            prev = cur


class StepUI:
    """An interface on the other end of stdin/stdout. Settings come from the
    command line; each wait is an {"ev": "await"} answered by one stdin line."""

    steps = True

    def __init__(self, args):
        self.args = args
        self.out_lock = threading.Lock()
        self.sampler = None

    def emit(self, ev, **kw):
        with self.out_lock:
            sys.stdout.write(json.dumps({"ev": ev, **kw}) + "\n")
            sys.stdout.flush()

    def wait(self, step, **kw):
        self.emit("await", step=step, **kw)
        cmd = sys.stdin.readline()
        if not cmd:                        # the interface went away
            raise Aborted()
        cmd = cmd.strip()
        if cmd == "abort":
            raise Aborted()
        return cmd

    def line(self, s=""):
        self.emit("line", text=s)

    def say(self, s=""):
        self.emit("say", text=s)

    def attach(self, src, dst):
        self.sampler = Sampler(self, src, dst)
        self.sampler.start()

    def phase(self, name, scale=None):
        self.emit("phase", name=name, scale=scale)
        if self.sampler:
            self.sampler.set_phase(name, scale)

    def settings(self, args):
        return args.verify_mode or "not given", args.extras_off

    def confirm_large(self, size, ram):
        return self.wait("confirm_large", size=size, ram=ram, limit=ram // 2) == "ok"

    def before_remount(self):
        self.wait("remount")

    def remount_result(self, ok, why):
        """Say at once whether the source is cold; on failure the interface
        chooses between "retry" and going on with the source warm."""
        self.emit("cold", ok=ok, **why)
        if ok:
            return False
        return self.wait("remount_failed", retryable=why.get("code") != "not_remountable",
                         **why) == "retry"

    def job_setup(self, app, source, run_dir):
        self.wait("configure", app=app, source=source, run_dir=run_dir)

    def before_noise(self):
        pass

    def start_job(self, app, runs):
        self.wait("start", app=app, runs=runs)

    def job_done(self, app, runs):
        """The reply may carry the apps the interface saw with files open in the
        test folders: 'ok {"seen": [{"path", "name", "version", "sides"}]}'."""
        reply = self.wait("done", app=app, runs=runs)
        try:
            seen = json.loads(reply[2:]).get("seen", []) if reply.startswith("ok ") else []
        except ValueError:
            seen = []
        return [x for x in seen if isinstance(x, dict) and x.get("name")]

    def result(self, **kw):
        self.emit("result", **kw)

    def delete_folder(self):
        return self.wait("cleanup") == "ok"


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("source")
    ap.add_argument("dest_parent")
    ap.add_argument("--app", default="",
                    help="name of the app measured (a warning goes in the report if empty)")
    ap.add_argument("--app-path", default=None,
                    help="bundle of the app measured, for its version "
                         "(default /Applications/<app>.app)")
    ap.add_argument("--verify-mode", default=None,
                    help="verification setting used in the app (asked if omitted)")
    ap.add_argument("--extras-off", action="store_true",
                    help="transcodes, proxies, previews and thumbnail reports are off (asked if omitted)")
    ap.add_argument("--runs", type=int, default=1,
                    help="incremental: runs of the job on the same destination (default 1)")
    ap.add_argument("--run-cmd", default=None,
                    help="run this instead of waiting for the operator; {src} {dst}")
    ap.add_argument("--no-calibrate", action="store_true")
    ap.add_argument("--no-remount", action="store_true")
    ap.add_argument("--keep", action="store_true", help="keep the test folder")
    ap.add_argument("--report-dir", default=os.getcwd())
    ap.add_argument("--check", action="store_true",
                    help="print the pre-flight checks as JSON and exit")
    ap.add_argument("--steps", action="store_true",
                    help="driven by an interface: JSON lines out, commands in")
    ap.add_argument("--guided", action="store_true",
                    help="generate the test data in a new folder inside SOURCE, "
                         "calibrate before the job, remove the data at the end")
    ap.add_argument("--test-size", type=int, default=None, metavar="MB",
                    help="with --guided: MB of test data instead of the size from RAM")
    args = ap.parse_args()
    if args.runs < 1:
        ap.error("--runs must be at least 1")
    if args.test_size is not None and not args.guided:
        ap.error("--test-size only works with --guided")
    test_size = args.test_size * MB if args.test_size else None

    if args.check:
        print(json.dumps(preflight(args.source, args.dest_parent, args.guided, test_size)))
        return 0

    ui = StepUI(args) if args.steps else TerminalUI()
    ui.temp = []                       # test folders to remove if the run is cut short
    try:
        return run(args, ui, test_size)
    except (Aborted, KeyboardInterrupt):
        # ctrl-C too: it is not an Exception, and would leave the test folders behind
        refuse("stopped by the operator", *ui.temp)
    except Exception:
        # an internal error must not leave the test folders on the operator's disks
        for p in ui.temp:
            subprocess.run(["rm", "-rf", p])
        raise


def run(args, ui, test_size=None):
    interactive = args.run_cmd is None
    guided = args.guided

    problem = paths_problem(args.source, args.dest_parent, guided)
    if problem:
        refuse(problem)

    started_at = datetime.datetime.now()
    dest_parent = os.path.realpath(args.dest_parent)
    if guided:
        conflict = backup_conflict(classify(os.path.realpath(args.source)), classify(dest_parent))
        if conflict:
            refuse(conflict)
        size = guided_size(reusable_ram(), test_size)
        if size is None:
            refuse(GUIDED_RAM_REFUSAL)
        name = guided_name([dest_parent, os.path.realpath(args.source)], ".noindex")
        # .noindex on both sides: Spotlight indexing the card would add reads to the source.
        source = os.path.join(os.path.realpath(args.source), name + ".noindex")
        files = []
    else:
        source = args.source
        files = source_files(source)
        if not files:
            refuse("no files in the source")
        size = sum(os.path.getsize(f) for f in files)
        name = guided_name([dest_parent], ".noindex", "ReadbackCheck_probe")
    run_dir = os.path.join(dest_parent, name + ".noindex")   # Spotlight skips *.noindex
    os.mkdir(run_dir)                  # not makedirs: the parent is checked above
    ui.temp.append(run_dir)            # removed if the interface aborts
    if guided:
        os.mkdir(source)
        ui.temp.append(source)

    src, dst = classify(source), classify(run_dir)
    boot = classify("/")
    report = []

    def out(line=""):
        ui.line(line)
        report.append(line)

    # ---- topology checks
    refusal, notes = topology_check(src, dst, boot, guided)
    if refusal:
        refuse(refusal, *ui.temp)
    # The live counters start here, so an interface can show the test data
    # being written and the first calibration too. Display only.
    ui.attach(src, dst)

    # ---- --guided: test data, and a first calibration while it is still in cache
    calib_pre = None
    if guided:
        ui.phase("generate", size)
        files = make_test_files(source, size)
        size = sum(os.path.getsize(f) for f in files)
        ui.phase("idle")
        if ui.steps:
            ui.emit("generated", folder=source, size=size,
                    files=[{"name": os.path.basename(f), "size": os.path.getsize(f)} for f in files])
        if not args.no_calibrate:
            # One full read before the first calibration. Without it, with the
            # data just written to an ExFAT card (FSKit, macOS 15), reference A
            # was read back from the destination for 0.37-0.79 x in the first
            # round and 0.00 x in every later one. The source is remounted
            # before the job, so this read does not warm it for the app.
            for f in files:
                read_fully(f)
            obs0 = Observer(src, dst)
            ui.phase("noise_pre", size)
            a0 = obs0.snap()
            time.sleep(3)
            b0 = obs0.snap()
            noise0 = {k: v / (b0["t"] - a0["t"])
                      for k, v in Observer.delta(a0, b0).items() if k != "t"}
            _, calib_pre = calibrate(obs0, files, run_dir, size, noise0,
                                     on_phase=lambda label: ui.phase("precal_" + label, size))
            ui.phase("idle")
            for label in ("A", "B"):
                subprocess.run(["rm", "-rf", os.path.join(run_dir, "calibration_" + label)])
            if ui.steps:
                ui.emit("precal", calib=calib_pre if isinstance(calib_pre, dict) else None,
                        noise=noise0)
            # Only B can stop the test here. A failed B means the counter does
            # not see re-reads on this destination, which no retry changes. A is
            # reported only: before the job it failed now and then on an ExFAT
            # card (0.47 x at 256 MB) while every calibration after the job was
            # clean, and the verdict uses the one after the job.
            if isinstance(calib_pre, str):
                refuse(f"calibration not run: {calib_pre}", *ui.temp)
            if calib_pre["B"] < MEDIUM_READ:
                refuse(f"on this destination the counter does not see re-reads: "
                       f"reference B was seen for only {calib_pre['B']:.2f} x",
                       *ui.temp)

    ram, size_ok, note = size_check(size)
    if note:
        notes.append(note)

    app_name = args.app.strip()
    shown = app_name or "(name not given)"
    file_app = app_name
    if interactive:
        version, version_from, id_notes = app_identity(app_name, args.app_path)
        notes.extend(id_notes)
        if app_name and version != "not read":
            file_app = f"{app_name} {version}"
    else:
        version, version_from = "n/a", "no bundle (copier from --run-cmd)"
    runs = args.runs

    if ui.steps:
        ui.emit("header", app=app_name, version=version, version_from=version_from,
                source=source, run_dir=run_dir,
                files=len(files), size=size, ram=ram, size_ok=size_ok, runs=runs,
                src=src, dst=dst, report_dir=args.report_dir)
    out("=" * 72)
    out(f" Readback Check engine {ENGINE_VERSION} — {shown}")
    out("=" * 72)
    out(f"  app            : {shown}  version {version}")
    out(f"                   version read from: {version_from}")
    if not app_name:
        out("  WARNING        : app name not given")
    out(f"  source         : {source}  ({len(files)} files, {fmt_mb(size)})")
    out(f"                   {src['kind']} · disk {src['disk'] or src['detail']} · {src['fstype']}")
    out(f"  destination    : {run_dir}")
    out(f"                   {dst['kind']} · disk {dst['disk'] or dst['detail']} · {dst['fstype']}")
    out(f"  reusable RAM   : {fmt_mb(ram)}")

    # ---- what was configured in the app
    if interactive:
        verify_mode, extras_off = ui.settings(args)
        if not extras_off:
            notes.append("the app's extra features were not confirmed off: "
                         "they can read the files again and skew the counts")
    else:
        verify_mode = args.verify_mode or f"command: {args.run_cmd}"
    out(f"  verification   : {verify_mode}")
    if runs > 1:
        out(f"  runs           : {runs} on the same destination (incremental): "
            f"expected dest. read ~{runs:.2f} x")

    if interactive and not size_ok:
        if not ui.confirm_large(size, ram):
            refuse("the data is too large for the reusable RAM", *ui.temp)

    # ---- cold source
    cold = False
    if not args.no_remount:
        if interactive:
            ui.before_remount()
        while True:
            ui.phase("remount")
            why = {}
            cold = remount(src, why)
            if not ui.remount_result(cold, why):
                break
        if not cold:
            notes.append("the source was not made cold (system, network or busy volume): "
                         "the source reads row cannot be evaluated")
    out(f"  source cold    : {'yes' if cold else 'NO'}")

    obs = Observer(src, dst)

    # ---- the job
    if interactive:
        ui.job_setup(shown, source, run_dir)

    # --guided: a copy started before the start reply falls outside the window the
    # verdict reads, and would only show up as a window with nothing in it.
    # It happened in three of four first tries with a real app. A small amount
    # is tolerated for files an app may write when the job is set up.
    def early_copy():
        if guided and bytes_in(run_dir) > 0.01 * size:
            refuse(EARLY_COPY_REFUSAL, *ui.temp)

    early_copy()
    if interactive:
        ui.before_noise()
    ui.phase("noise", size * runs)
    base_a = obs.snap()
    time.sleep(5)
    base_b = obs.snap()
    noise = {k: v / (base_b["t"] - base_a["t"])
             for k, v in Observer.delta(base_a, base_b).items() if k != "t"}
    ui.phase("idle")
    if ui.steps:
        ui.emit("noise", rate=noise)
        ui.start_job(shown, runs)
    # A backup can start at any time (hourly by default), so --guided asks
    # again around the job, the only window the verdict reads.
    conflict = guided and backup_conflict(src, dst)
    if conflict:
        refuse(conflict, *ui.temp)
    early_copy()

    a = obs.snap()
    ifs_a = obs.ifs
    ui.phase("job", size * runs)
    seen = []
    if interactive:
        seen = ui.job_done(shown, runs)
    else:
        subprocess.run(args.run_cmd.format(src=shlex.quote(source),
                                           dst=shlex.quote(run_dir)), shell=True)
    subprocess.run(["sync"])           # completes write-back; creates no reads
    b = obs.snap()
    ifs_b = obs.ifs
    ui.phase("idle")
    conflict = guided and backup_conflict(src, dst)
    if conflict:
        refuse(conflict, *ui.temp)
    # The background again, after the job, and the lower rate of the two per
    # counter. A steady background shows in both windows. A one-off burst
    # shows in one: an offload app scanning the card it saw remounted read
    # 15 MB in the window before the job, and 110 MB were subtracted from a
    # source the app had read exactly twice.
    ui.phase("noise_after", size * runs)
    post_a = obs.snap()
    time.sleep(5)
    post_b = obs.snap()
    noise_after = {k: v / (post_b["t"] - post_a["t"])
                   for k, v in Observer.delta(post_a, post_b).items() if k != "t"}
    ui.phase("idle")
    noise_before = noise
    noise = {k: min(noise_before[k], noise_after[k]) for k in noise_before}
    d = Observer.delta(a, b)
    secs = d.pop("t")
    adj = {k: max(0, d[k] - noise[k] * secs) for k in d}

    # ---- did the copy happen where we are looking?
    found, matched_by = copies_found(files, run_dir)
    copy_ok = found >= 0.95 * size

    # ---- calibration, after the job so the job saw a cold source
    calib_ok, calib = (None, None)
    if not args.no_calibrate and copy_ok:
        calib_ok, calib = calibrate(
            obs, files, run_dir, size, noise,
            on_phase=lambda label: ui.phase("calib_" + label, size))
        ui.phase("idle")

    # ---- results
    r_dst = adj["dst_r"] / size
    out()
    out("-" * 72)
    out(f"  window         : {secs:.1f} s   background subtracted: "
        f"{fmt_mb(noise['dst_r'] * secs)} dest. / {fmt_mb(noise['src_r'] * secs)} source")
    out(f"  background     : before {noise_before['dst_r'] / MB:.1f} MB/s dest. / "
        f"{noise_before['src_r'] / MB:.1f} MB/s source, after {noise_after['dst_r'] / MB:.1f} / "
        f"{noise_after['src_r'] / MB:.1f} MB/s: the lower one is subtracted")
    out(f"  copy found     : {fmt_mb(found)} of {fmt_mb(size)}  (by {matched_by})"
        + ("" if copy_ok else "   <- INCOMPLETE"))
    if dst["kind"] != "network":
        out(f"  dest. written  : {fmt_mb(adj['dst_w'])}  ({adj['dst_w'] / size:.2f} x)")
    else:
        path = ", ".join(dst.get("out_ifaces") or []) or "all interfaces"
        out(f"  dest. written  : {fmt_mb(adj['dst_w'])}  ({adj['dst_w'] / size:.2f} x)"
            f"  outbound on {path}")
    out(f"  dest. read     : {fmt_mb(adj['dst_r'])}  ({r_dst:.2f} x)")
    if ui.steps:
        seen_lines(seen, app_name, args.app_path, out, notes, report)
        if not app_name and len(seen) == 1:
            app_name = seen[0]["name"]
            file_app = seen_label(seen[0])
    if dst["kind"] == "network":
        # Per interface, so a count that looks wrong can be checked by eye.
        moved = []
        for name in sorted(ifs_b):
            i0, o0 = ifs_a.get(name, (0, 0))
            di, do = ifs_b[name][0] - i0, ifs_b[name][1] - o0
            if di >= MB or do >= MB:
                moved.append(f"{name} {di / MB:,.0f}/{do / MB:,.0f}")
        out(f"  network MB in/out: {' · '.join(moved) or '-'}   (read = inbound sum)")
    if src["kind"] not in ("network", "loopback"):
        out(f"  source read    : {fmt_mb(adj['src_r'])}  ({adj['src_r'] / size:.2f} x)")
    calib_state = None
    if isinstance(calib, dict):
        if calib_ok:
            calib_state = "OK"
        elif calib["B"] < MEDIUM_READ:
            calib_state = "the counter does not see re-reads"
        else:
            calib_state = "the cache does not hold the data"
        if isinstance(calib_pre, dict):
            out(f"  calib. before  : " + "   ".join(f"{k} {v:.2f} x" for k, v in calib_pre.items()))
        out(f"  calibration    : " + "   ".join(f"{k} {v:.2f} x" for k, v in calib.items())
            + f"   -> {calib_state}")
    elif isinstance(calib, str):
        notes.append(f"calibration not run: {calib}")
    elif args.no_calibrate:
        notes.append("calibration skipped (--no-calibrate): the instrument was not "
                     "validated on this destination")

    if dst["kind"] == "network" and isinstance(calib, dict) and max(
            calib["A"], calib_pre["A"] if isinstance(calib_pre, dict) else 0.0) > NOT_READ:
        notes.append("network destination with no client cache: even reference A was read "
                     "back over the network, so here every verification read crosses the "
                     "network, whether the app chooses it or not. Repeating with less data "
                     "does not change that: on this destination a re-read cannot be "
                     "attributed, a zero can")

    out("-" * 72)
    verdict, rc = destination_verdict(copy_ok, calib, size_ok, r_dst,
                                      network=dst["kind"] == "network", calib_pre=calib_pre)
    out(f"  RESULT: {verdict}")

    # ---- the source row: physical reads only
    src_line = None
    if src["kind"] not in ("network", "loopback"):
        c = adj["src_r"] / size
        if not cold:
            src_line = "not evaluable (source not cold)"
        elif c < NOT_READ:
            src_line = "no physical read — was the source already in cache?"
        elif 0.8 <= c <= 1.3:
            src_line = "one physical read"
        elif 1.7 <= c <= 2.3:
            # Not necessarily a verification pass: the counters cannot tell
            # which program read the bytes, only how many reached the disk.
            src_line = ("TWO physical reads — a full re-read for verification, OR "
                        "other reads (probes, metadata, previews): the counters cannot tell which")
        else:
            src_line = f"{c:.2f} physical reads"
        out(f"  SOURCE: {src_line}")
        out("    (only reads that reach the disk count: two logical reads of which the")
        out("     second came from the cache count as one)")

    # Physical reads are a lower bound on logical reads. Whatever the cache did,
    # a byte read from the device twice was asked for at least twice. These
    # facts hold even when the verdict above is inconclusive.
    facts = []
    if copy_ok:
        if r_dst >= MEDIUM_READ:
            facts.append("the app read the destination back at least once")
        if cold and src["kind"] not in ("network", "loopback") and adj["src_r"] / size >= 1.7:
            facts.append("the app reads the source at least twice")
        if facts:
            out("  CERTAIN WHATEVER THE CACHE DID (physical reads = the least the app read):")
            for f_ in facts:
                out(f"    - {f_}")

    if notes:
        out()
        out("  NOTES")
        for n in notes:
            out(f"   - {n}")
    out()
    out("  Limits: the counters record the commands sent to the disk; if the disk")
    out("  answers them from its own internal memory, they are counted anyway.")
    out("=" * 72)

    os.makedirs(args.report_dir, exist_ok=True)
    rpath = report_path(args.report_dir, started_at, file_app,
                        verdict_words(copy_ok, rc, calib))
    with open(rpath, "w") as f:
        f.write("\n".join(report) + "\n")
    ui.say(f"\n  report: {rpath}")

    ui.result(rc=rc, verdict=verdict, size=size, runs=runs, secs=secs, noise=noise,
              found=found, copy_ok=copy_ok, matched_by=matched_by, adj=adj,
              network_dst=dst["kind"] == "network",
              network_src=src["kind"] in ("network", "loopback"),
              calib=calib if isinstance(calib, dict) else None, calib_state=calib_state,
              calib_pre=calib_pre if isinstance(calib_pre, dict) else None,
              src_line=src_line, facts=facts, notes=notes, cold=cold, seen=seen,
              report_path=rpath, report="\n".join(report) + "\n")

    # --guided made both folders itself, so it removes them without asking
    folders = [run_dir, source] if guided else [run_dir]
    if not args.keep:
        if guided or not interactive or ui.delete_folder():
            for p in folders:
                subprocess.run(["rm", "-rf", p])
                # Say what happened: a silent failure leaves gigabytes of test copies
                # on the disk with nothing to show for it.
                if os.path.exists(p):
                    ui.say(f"  WARNING: folder NOT deleted: {p}")
                else:
                    ui.say(f"  test folder deleted: {p}")
            if ui.steps:
                ui.emit("cleaned", ok=not any(os.path.exists(p) for p in folders),
                        folders=folders)
        else:
            ui.say(f"  test folder kept: {run_dir}")
    return rc


if __name__ == "__main__":
    sys.exit(main())
