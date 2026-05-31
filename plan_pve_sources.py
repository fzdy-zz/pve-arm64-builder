#!/usr/bin/env python3
import re
import subprocess
from collections import defaultdict, deque


EXCLUDE = re.compile(
    r"(kernel|headers|zfs|zfsonlinux|spl|ceph|rados|rbd|^pve-firmware$|^proxmox-backup-restore-image$)",
    re.I,
)
FIELDS = ("Pre-Depends", "Depends", "Recommends")


def parse_records(text):
    for block in text.split("\n\n"):
        record = {}
        current = None
        for line in block.splitlines():
            if not line:
                continue
            if line[0].isspace() and current:
                record[current] += " " + line.strip()
                continue
            if ":" not in line:
                continue
            key, value = line.split(":", 1)
            current = key
            record[key] = value.strip()
        if "Package" in record:
            yield record


def source_name(record):
    source = record.get("Source") or record["Package"]
    return source.split()[0]


def dep_names(value):
    if not value:
        return []

    names = []
    for part in value.split(","):
        for alt in part.split("|"):
            name = alt.strip().split()[0]
            name = name.strip("<>")
            name = name.split(":", 1)[0]
            if name:
                names.append(name)
    return names


def is_proxmox_record(record):
    filename = record.get("Filename", "")
    return (
        "proxmox/debian" in filename
        or "/pve-" in filename
        or "pve-no-subscription" in filename
        or "pve-test" in filename
        or "/devel/" in filename
        or record["Package"].startswith(("pve-", "proxmox-", "libpve-"))
    )


def main():
    text = subprocess.check_output(["apt-cache", "dumpavail"], text=True, errors="replace")
    by_package = defaultdict(list)

    for record in parse_records(text):
        by_package[record["Package"]].append(record)

    queue = deque(["proxmox-ve"])
    seen = set()
    binaries = []

    while queue:
        package = queue.popleft().split(":", 1)[0]
        if package in seen:
            continue
        seen.add(package)

        if EXCLUDE.search(package):
            continue

        records = [record for record in by_package.get(package, []) if is_proxmox_record(record)]
        if not records:
            continue

        record = records[0]
        source = source_name(record)
        if EXCLUDE.search(source):
            continue

        binaries.append((package, source, record.get("Version", ""), record.get("Architecture", "")))

        for field in FIELDS:
            for dependency in dep_names(record.get(field, "")):
                if dependency not in seen:
                    queue.append(dependency)

    sources = []
    for _, source, _, _ in binaries:
        if source not in sources:
            sources.append(source)

    print("# binary packages")
    for package, source, version, arch in binaries:
        print(f"{package}\t{source}\t{version}\t{arch}")

    print("# source packages")
    for source in sources:
        print(source)


if __name__ == "__main__":
    main()
