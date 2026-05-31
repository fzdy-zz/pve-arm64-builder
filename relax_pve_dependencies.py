#!/usr/bin/env python3
import re
import sys
from pathlib import Path


RELAXED_DEPENDS = {
    "proxmox-ve": {"proxmox-default-kernel", "proxmox-kernel-helper"},
    "pve-manager": {"librados2-perl"},
    "libpve-storage-perl": {"ceph-common", "ceph-fuse", "librados2-perl"},
}


def parse_control(text):
    records = []
    record = []
    current = None

    for line in text.splitlines():
        if not line:
            if record:
                records.append(record)
                record = []
                current = None
            continue

        if line[0].isspace() and current is not None:
            record[current][1] += "\n" + line
            continue

        key, body = line.split(":", 1)
        record.append([key, body])
        current = len(record) - 1

    if record:
        records.append(record)

    return records


def unfold(body):
    return re.sub(r"\n[ \t]+", " ", body.strip())


def split_deps(value):
    if not value:
        return []

    deps = []
    depth = 0
    start = 0
    for idx, char in enumerate(value):
        if char in "([":
            depth += 1
        elif char in ")]" and depth:
            depth -= 1
        elif char == "," and depth == 0:
            dep = value[start:idx].strip()
            if dep:
                deps.append(dep)
            start = idx + 1

    dep = value[start:].strip()
    if dep:
        deps.append(dep)
    return deps


def dep_name(dep):
    first_alt = dep.split("|", 1)[0].strip()
    name = first_alt.split()[0]
    return name.split(":", 1)[0]


def field_index(record, key):
    for idx, (field_key, _) in enumerate(record):
        if field_key == key:
            return idx
    return None


def field_value(record, key):
    idx = field_index(record, key)
    if idx is None:
        return ""
    return unfold(record[idx][1])


def set_field(record, key, deps, after=None):
    body = " " + ", ".join(deps)
    idx = field_index(record, key)
    if idx is not None:
        record[idx][1] = body
        return

    insert_at = len(record)
    if after:
        after_idx = field_index(record, after)
        if after_idx is not None:
            insert_at = after_idx + 1
    record.insert(insert_at, [key, body])


def relax_record(record):
    package = field_value(record, "Package")
    targets = RELAXED_DEPENDS.get(package)
    if not targets:
        return False

    depends = split_deps(field_value(record, "Depends"))
    recommends = split_deps(field_value(record, "Recommends"))
    if not depends:
        return False

    moved = []
    kept = []
    for dep in depends:
        if dep_name(dep) in targets:
            moved.append(dep)
        else:
            kept.append(dep)

    if not moved:
        return False

    existing_recommends = {dep_name(dep) for dep in recommends}
    for dep in moved:
        if dep_name(dep) not in existing_recommends:
            recommends.append(dep)
            existing_recommends.add(dep_name(dep))

    set_field(record, "Depends", kept)
    set_field(record, "Recommends", recommends, after="Depends")
    return True


def serialize(records):
    blocks = []
    for record in records:
        blocks.append("\n".join(f"{key}:{body}" for key, body in record))
    return "\n\n".join(blocks) + "\n"


def main():
    changed_any = False
    for arg in sys.argv[1:]:
        path = Path(arg)
        text = path.read_text()
        records = parse_control(text)
        changed = any(relax_record(record) for record in records)
        if changed:
            path.write_text(serialize(records))
            changed_any = True
    return 0 if changed_any else 1


if __name__ == "__main__":
    raise SystemExit(main())
