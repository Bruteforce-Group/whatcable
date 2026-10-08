#!/usr/bin/env python3
"""Checks for 50_registry_snapshot output (format 1, probes/test-kit/FORMAT.md).

  snapshot_checks.py validate FILE        structure: header first, footer last, known records
  snapshot_checks.py vs-ioreg PROBE       completeness against Apple's own `ioreg -a` export
  snapshot_checks.py privacy FILE         no identifier of this Mac or its user in the output,
                                          and no join key withheld

Each prints counts only. Identifier values are never printed: a hit names the
identifier's kind and where it was found. Exit status 0 means the check passed.
Standard library only (Python 3.9).
"""
import ctypes
import json
import os
import plistlib
import pwd
import re
import subprocess
import sys
import tempfile

# Record types between header and footer, per probe. FORMAT.md lists the same
# names under each probe's "Record types:" line; a self-test keeps them equal.
RECORD_TYPES = {
    "50_registry_snapshot": {"entry", "link", "class", "failure", "withheld_summary", "skipped_summary"},
    "51_driver_access": {"cfplugin", "interest_notification", "user_client_open", "failure"},
    "52_usb_bos": {"bos", "failure"},
    "53_smc_keys": {"smc_open", "key_count", "smc_key"},
    "54_power_sources": {"adapter", "providing_type", "source", "failure"},
    "55_hub_ports": {"hub_descriptor", "failure"},
}


# The identifier-gathering steps that can stop a probe (probe_json.h,
# pj_ids_gather and its IOService walk): the only values the footer's step
# takes. FORMAT.md lists the same names under Privacy; a self-test keeps them
# equal.
GATHER_STEPS = frozenset({
    "platform_expert", "platform_props", "platform_serial", "platform_uuid",
    "device_tree", "device_tree_props", "chosen", "chosen_props",
    "network_iterator", "network_props", "network_address", "network_builtin", "bluetooth_node",
    "registry_changing", "bluetooth", "passwd",
})


def format_doc_gather_steps(text):
    """The footer step names, from FORMAT.md's "Step names:" line."""
    for line in text.splitlines():
        if line.startswith("Step names:"):
            return set(re.findall(r"`([a-z_]+)`", line))
    return set()


def format_doc_record_types(text):
    """probe -> record types, from FORMAT.md's "## <probe> records" sections."""
    out, probe = {}, None
    for line in text.splitlines():
        heading = re.match(r"## (\d{2}_[a-z0-9_]+) records$", line)
        if heading:
            probe = heading.group(1)
        elif line.startswith("## "):
            probe = None
        elif probe and line.startswith("Record types:"):
            out[probe] = set(re.findall(r"`([a-z_]+)`", line))
    return out

# Keys `ioreg -a` adds to every entry that are not registry properties
# (measured on the mini 2026-10-07: present on all 2740 IOService entries,
# never returned by IORegistryEntryCreateCFProperties).
IOREG_SYNTHETIC_KEYS = {
    "IOObjectClass", "IOObjectRetainCount", "IORegistryEntryID", "IORegistryEntryName",
    "IORegistryEntryLocation", "IORegistryEntryChildren", "IOServiceBusyState",
    "IOServiceBusyTime", "IOServiceState",
}

# Values that can change and change back between the two exports, so "same
# before and after" does not prove them stable: the root's live kernel object
# counts (a mismatch seen once in four runs on the mini, 2026-10-07), and the
# GPU's live scheduler counters (AGXAcceleratorG17G on the MacBook, 2026-10-07:
# AGCInfo's fLastSubmissionPID, SchedulerState's BusyWorkQueues and Stamps).
# Their presence is still checked; their values are not compared.
VOLATILE_KEYS = {"IOKitDiagnostics", "AGCInfo", "SchedulerState"}

# Identifiers that link information across the registry. None may be withheld
# (whatcable-app CLAUDE.md:9-12, spec acceptance criteria).
JOIN_KEYS = {"UsbIOPort", "locationID", "ConnectionUUID", "USB Serial Number",
             "kUSBSerialNumberString", "INQUIRY Unit Serial Number", "Serial Number"}
JOIN_KEY_CLASS_PREFIXES = {"UUID": ("AppleHPM", "AppleAPFS", "IOMedia", "IOGUIDPartitionScheme")}  # port and volume UUIDs


def read_records(path):
    """(records, problems). A probe killed mid-write (the runners' watchdog)
    leaves its last line half written: that line is dropped and reported, and
    the lines before it are read. Any other line that is not JSON raises."""
    with open(path, "rb") as f:
        lines = [line for line in f if line.strip()]
    records = [json.loads(line) for line in lines[:-1]]
    try:
        records += [json.loads(line) for line in lines[-1:]]
    except ValueError:
        return records, ["last line cut off mid-record"]
    return records, []


# ---- validate ---------------------------------------------------------------

def footer_step_problems(tail):
    """The footer's step: present on every footer, null unless the run is
    stopped for identifiers_incomplete, then one of the documented gathering
    steps (the only word a submission has on which lookup failed). Keyed on
    status as well as reason (Opus x3 review of PR 693): a complete footer
    has reason null and step null whatever the reason field says, and a step
    that is not a string is a problem, never a crash (a list or a dict is
    unhashable, so the membership test below would raise)."""
    if "step" not in tail:
        return ["footer has no step field"]
    step, status, reason = tail["step"], tail.get("status"), tail.get("reason")
    problems = []
    if status == "complete":
        if reason is not None:
            problems.append("footer complete with reason %r" % (reason,))
        if step is not None:
            problems.append("footer step %r on a complete run" % (step,))
        return problems
    if status == "stopped" and reason == "identifiers_incomplete":
        if step is None:
            return ["footer stopped for identifiers_incomplete without a step"]
        if not isinstance(step, str):
            return ["footer step %r is not a string" % (step,)]
        if step not in GATHER_STEPS:
            return ["footer step %r is not a documented gathering step" % (step,)]
        return []
    if step is not None:
        return ["footer step %r on a run that did not stop for identifiers_incomplete" % (step,)]
    return []


def validate_records(records, stopped_ok=()):
    """Returns a list of problems; empty means the file is structurally sound.
    stopped_ok: footer reasons that are not a problem for the caller (privacy
    judges a run the byte cap stopped on its content)."""
    problems = []
    if not records:
        return ["empty file"]
    head, tail, body = records[0], records[-1], records[1:-1]
    if head.get("record") != "header" or head.get("format") != 1:
        problems.append("first line is not a format 1 header")
    if tail.get("record") != "footer":
        problems.append("last line is not a footer: the run was cut off")
        body = records[1:]
    elif tail.get("status") != "complete" and tail.get("reason") not in stopped_ok:
        problems.append("footer status %r, reason %r" % (tail.get("status"), tail.get("reason")))
    if tail.get("record") == "footer":
        problems += footer_step_problems(tail)
    allowed = RECORD_TYPES.get(head.get("probe"))
    if allowed is None:
        problems.append("unknown probe %r: FORMAT.md lists no record types for it" % head.get("probe"))
    seen = set()
    for i, r in enumerate(body, start=2):
        kind = r.get("record")
        if allowed is not None and kind not in allowed:
            problems.append("line %d: unknown record %r" % (i, kind))
        if kind == "entry":
            if r["id"] in seen:
                problems.append("line %d: entry %s written twice" % (i, r["id"]))
            seen.add(r["id"])
    for i, r in enumerate(body, start=2):
        if r.get("record") == "entry":
            problems.extend("line %d: %s" % (i, p) for p in part_problems(r["props"]))
        else:
            problems.extend("line %d: %s" % (i, p) for p in field_part_problems(r))
        problems.extend("line %d: %s" % (i, p) for p in process_id_problems(r))
    for i, r in enumerate(body, start=2):
        if r.get("record") == "link" and r["id"] not in seen:
            problems.append("line %d: link to entry %s that has no entry record" % (i, r["id"]))
        # A process connection has an entry record too (its class and the
        # skipped marker), so a link never names a parent the file does not.
        if r.get("record") == "link" and r["parent"] is not None and r["parent"] not in seen:
            problems.append("line %d: link %s -> parent %s that has no entry record" % (i, r["id"], r["parent"]))
    if tail.get("record") == "footer" and tail.get("records") != len(body):
        problems.append("footer counts %s records, file has %d" % (tail.get("records"), len(body)))
    summaries = [r for r in body if r.get("record") == "withheld_summary"]
    skips = [r for r in body if r.get("record") == "skipped_summary"]
    if head.get("probe") == "50_registry_snapshot" and tail.get("status") == "complete":
        if len(summaries) != 1:
            problems.append("expected one withheld_summary record, found %d" % len(summaries))
        elif sum(n for _, n in summaries[0]["counts"]) != tail.get("withheld"):
            problems.append("withheld_summary counts %d, footer says %s withheld"
                            % (sum(n for _, n in summaries[0]["counts"]), tail.get("withheld")))
        if len(skips) != 1:
            problems.append("expected one skipped_summary record, found %d" % len(skips))
        else:
            ids = skips[0]["ids"]
            if sum(n for _, n in skips[0]["counts"]) != len(ids) or len(set(ids)) != len(ids):
                problems.append("skipped_summary counts %d, lists %d ids (%d distinct)"
                                % (sum(n for _, n in skips[0]["counts"]), len(ids), len(set(ids))))
            # A skipped connection keeps its class and its place in the tree
            # (Darryl, 2026-10-08): an entry record whose props are exactly the
            # skipped marker, and its links. Its properties are never written.
            marked = {r["id"] for r in body if r.get("record") == "entry" and r["props"] == SKIPPED_MARKER}
            for i in sorted(set(ids) - seen):
                problems.append("skipped %s has no entry record" % i)
            for i in sorted((set(ids) & seen) - marked):
                problems.append("skipped %s has properties, not the skipped marker" % i)
            for i in sorted(marked - set(ids)):
                problems.append("entry %s holds the skipped marker but is not in skipped_summary" % i)
            listed = sum(n for _, n in skips[0].get("properties", []))
            held = sum(json.dumps(r["props"]).count('{"t": "skipped"}')
                       for r in body if r.get("record") == "entry" and r["props"] != SKIPPED_MARKER)
            if listed != held:
                problems.append("skipped_summary lists %d properties, entries hold %d" % (listed, held))
        problems += connection_class_problems(body)
        problems += unreachable_problems(body, seen)
    return problems


SKIPPED_MARKER = {"t": "skipped"}
CONNECTION_CLASSES = {"IOUserClient", "IODTNVRAMDiags"}

# Keys whose "pid N, name" value the probe writes as "name" (Darryl,
# 2026-10-08; FORMAT.md "Privacy"). vs-ioreg rewrites the live value the same
# way; validate flags a PID left anywhere in any probe's output.
PROCESS_NAME_KEYS = {"UsbExclusiveOwner", "iAPAuthenticator"}
PID_PREFIX = re.compile(r"pid [0-9]+, .")


def process_name(value):
    """"pid N, name" as "name"; anything else unchanged."""
    if isinstance(value, str) and PID_PREFIX.match(value):
        return value[value.index(", ") + 2:]
    return value


def process_id_problems(r):
    """Every string in r (typed values at any depth, and a small probe's plain
    fields) that still starts with "pid N, ", named by its key or field."""
    out = []

    def typed(v, key):
        t = v.get("t") if isinstance(v, dict) else None
        if t == "str" and isinstance(v.get("v"), str) and PID_PREFIX.match(v["v"]):
            out.append("%r holds a process id" % key)
        elif t == "dict":
            for k, x in v["v"]:
                typed(x, k if isinstance(k, str) else key)
        elif t in ("array", "set"):
            for x in v["v"]:
                typed(x, key)
    if r.get("record") == "entry":
        typed(r["props"], "props")
        return out
    for k, v in r.items():
        if isinstance(v, str) and PID_PREFIX.match(v):
            out.append("%r holds a process id" % k)
        elif isinstance(v, dict) and "t" in v:
            typed(v, k)
    return out


def connection_class_problems(body):
    """Every entry whose class is, or derives from, a process connection class
    by the file's own class records holds the skipped marker (F3 of the Opus
    review after extra pass 1: the marker checks keyed on skipped_summary could
    not see a connection recorded in full and left off the list). Whether the
    marker is listed is checked with skipped_summary above. A class no class
    record describes cannot be judged, so that is a problem too; a null class
    is already a failure record."""
    chains = {r["name"]: r["super"] for r in body if r.get("record") == "class" and isinstance(r.get("name"), str)}
    problems = []
    for r in body:
        cls = r.get("class") if r.get("record") == "entry" else None
        if not isinstance(cls, str):
            continue
        if cls not in chains:
            problems.append("entry %s: class %r has no class record" % (r["id"], cls))
        elif CONNECTION_CLASSES & ({cls} | set(chains[cls])) and r["props"] != SKIPPED_MARKER:
            problems.append("entry %s: class %r is a process connection but its properties were recorded" % (r["id"], cls))
    return problems


def unreachable_problems(body, entries):
    """A complete snapshot is one tree per plane: a walk down from the root
    through link records reaches every linked entry (F1 of the last PR 693
    review: entries beneath a connection without a link were islands), and
    every entry has a link in some plane."""
    kids, roots, linked = {}, {}, {}
    for r in body:
        if r.get("record") != "link":
            continue
        linked.setdefault(r["plane"], set()).add(r["id"])
        if r["parent"] is None:
            roots.setdefault(r["plane"], set()).add(r["id"])
        else:
            kids.setdefault(r["plane"], {}).setdefault(r["parent"], []).append(r["id"])
    problems = []
    for plane in sorted(linked):
        stack = list(roots.get(plane, ()))
        reached = set(stack)
        while stack:
            for child in kids.get(plane, {}).get(stack.pop(), ()):
                if child not in reached:
                    reached.add(child)
                    stack.append(child)
        if linked[plane] - reached:
            problems.append("%s: %d entries not reachable from the root through links" % (plane, len(linked[plane] - reached)))
    for i in sorted(entries - set().union(*linked.values()) if linked else entries):
        problems.append("entry %s has no link in any plane" % i)
    return problems


# ---- typed values -----------------------------------------------------------

def range_problems(raw, ranges):
    """Withheld ranges in bounds, in order, not overlapping, their bytes zero."""
    out, end = [], 0
    for start, length in ranges:
        if length < 1 or start < end:
            out.append("withheld range %r overlaps or is out of order" % [start, length])
        if start + length > len(raw):
            out.append("withheld range %r runs past %d bytes" % ([start, length], len(raw)))
        elif any(raw[start:start + length]):
            out.append("withheld bytes %d-%d are not zero" % (start, start + length - 1))
        end = start + length
    return out


def field_part_problems(r):
    """A small probe's record: typed values in any field, and each raw-bytes
    field's <field>_withheld ranges (FORMAT.md, "Raw bytes")."""
    out = []
    for k, v in r.items():
        if isinstance(v, dict) and "t" in v:
            out.extend(part_problems(v))
        if k.endswith("_withheld"):
            field = k[:-len("_withheld")]
            if not isinstance(r.get(field), str):
                out.append("%s: no field %r of raw bytes beside it" % (k, field))
            else:
                out.extend("%s: %s" % (k, p) for p in range_problems(bytes.fromhex(r[field]), v))
    return out


def part_problems(v):
    """Problems with partly withheld data anywhere in a typed value: each range
    in bounds, in order, not overlapping, and its bytes written as zero."""
    out = []
    if not isinstance(v, dict):
        return out
    t = v.get("t")
    if t == "data" and "withheld" in v:
        out.extend(range_problems(bytes.fromhex(v["hex"]), v["withheld"]))
    elif t == "dict":
        for _, x in v["v"]:
            out.extend(part_problems(x))
    elif t in ("array", "set"):
        for x in v["v"]:
            out.extend(part_problems(x))
    return out


class PartData:
    """Data with some bytes withheld: only the other bytes can be compared."""

    def __init__(self, raw, ranges):
        self.raw, self.ranges = raw, ranges

    def kept(self, other):
        """other with the withheld bytes zeroed, for comparing with raw."""
        b = bytearray(other)
        for start, length in self.ranges:
            b[start:start + length] = bytes(len(b[start:start + length]))
        return bytes(b)

    def __repr__(self):
        return "PartData(%s, %r)" % (self.raw.hex(), self.ranges)


def plain(v):
    """A format 1 typed value as the value `ioreg -a` would show, or WITHHELD."""
    t = v["t"]
    if t == "withheld":
        return WITHHELD
    if t == "skipped":
        return SKIPPED
    if t == "int":
        bits, raw = v["bits"], int(v["hex"], 16)
        if bits < 64 and raw >> (bits - 1):  # ioreg shows CF's signed value sign-extended to 64 bits
            raw |= ((1 << 64) - 1) ^ ((1 << bits) - 1)
        return raw
    if t == "str":
        return v["v"] if "v" in v else ("utf16", v["utf16"])
    if t == "data":
        raw = bytes.fromhex(v["hex"])
        return PartData(raw, v["withheld"]) if "withheld" in v else raw
    if t == "bool":
        return v["v"]
    if t in ("array", "set"):
        return [plain(x) for x in v["v"]]
    if t == "dict":
        out = {}
        for i, (k, x) in enumerate(v["v"]):
            # A key withheld for its content is kept as a counted placeholder.
            out[k if isinstance(k, str) else ("withheld key", i)] = plain(x)
        return out
    return ("unsupported", t)


class _Withheld:
    def __repr__(self):
        return "WITHHELD"


WITHHELD = _Withheld()


class _Skipped:
    def __repr__(self):
        return "SKIPPED"


SKIPPED = _Skipped()  # not hardware (NVRAM boot state, settings): not recorded on purpose


def same_value(snap, ioreg):
    """True when a snapshot value equals ioreg's, treating sets as unordered and
    skipping anything withheld or of a type ioreg cannot show exactly."""
    if snap is WITHHELD or snap is SKIPPED:
        return True
    if isinstance(snap, tuple):
        return True  # unsupported or utf16: ioreg has no exact form to compare
    if isinstance(snap, PartData):
        return isinstance(ioreg, bytes) and len(ioreg) == len(snap.raw) and snap.kept(ioreg) == snap.raw
    if isinstance(snap, list) and isinstance(ioreg, list):
        if len(snap) != len(ioreg):
            return False
        if all(same_value(a, b) for a, b in zip(snap, ioreg)):
            return True
        return sorted(map(repr, snap)) == sorted(map(repr, ioreg))  # a set: order is meaningless
    if isinstance(snap, dict) and isinstance(ioreg, dict):
        return snap.keys() == ioreg.keys() and all(same_value(snap[k], ioreg[k]) for k in snap)
    if isinstance(ioreg, int) and not isinstance(ioreg, bool) and isinstance(snap, int) and not isinstance(snap, bool):
        return snap & ((1 << 64) - 1) == ioreg & ((1 << 64) - 1)
    return snap == ioreg


# ---- vs-ioreg -----------------------------------------------------------------

def ioreg_plane(plane):
    out = subprocess.run(["ioreg", "-a", "-l", "-p", plane], capture_output=True, check=True).stdout
    return plistlib.loads(out)


def index_ioreg(root):
    """entry id -> (properties, {(parent id)}) for one plane's export."""
    entries = {}

    def walk(node, parent):
        eid = node.get("IORegistryEntryID")
        props = {k: v for k, v in node.items() if k not in IOREG_SYNTHETIC_KEYS}
        if eid is not None:
            _, parents = entries.setdefault(eid, (props, set()))
            if parent is not None:
                parents.add(parent)
        for child in node.get("IORegistryEntryChildren", []):
            walk(child, eid)

    walk(root, None)
    return entries


def key_holds_identifier(key, ids):
    """True when a property name itself holds one of this Mac's identifiers
    (ids: kind -> forms, as live_identifiers gives them), so the probe withheld
    its whole pair. Whole-value forms cannot be inside a name."""
    name = key.encode("utf-8")
    return any(form in name for forms in (ids or {}).values() for form in forms if not isinstance(form, Exact))


def compare(records, before, after, may_skip, ids=None):
    """before and after: plane -> index_ioreg() taken either side of the probe run.
    may_skip: the entry IDs the probe may leave out (process_connection_ids).
    ids: this Mac's identifier forms (live_identifiers), for the keys withheld whole.
    Returns (problems, counts). Only what both exports agree on is required."""
    entries = {int(r["id"], 16): r for r in records if r.get("record") == "entry"}
    # Entries the probe skips on purpose: the process connections and NVRAM
    # statistics themselves. Each keeps its class and its place (an entry with
    # the skipped marker, and its links), and what hangs beneath it is recorded
    # like anything else (Darryl, 2026-10-07: keep the accessories), so no
    # parent excuses a skipped entry, and every link is required.
    skipped = {int(i, 16) for r in records if r.get("record") == "skipped_summary" for i in r["ids"]}
    links = {}
    for r in records:
        if r.get("record") == "link" and r["parent"] is not None:
            links.setdefault(r["plane"], set()).add((int(r["id"], 16), int(r["parent"], 16)))
    problems = []
    counts = {"entries_checked": 0, "values_checked": 0, "values_withheld": 0, "values_skipped": 0,
              "entries_skipped": len(skipped), "skips_verified": 0}
    compared, verified = set(), set()
    for plane in sorted(set(before) & set(after), key=lambda p: (p != "IOService", p)):
        a, b = before[plane], after[plane]
        for eid in sorted(set(a) & set(b)):
            if eid in skipped:
                # Not taken on trust: a skipped entry is an instance IOKit
                # itself says is a process connection (process_connection_ids).
                if eid not in may_skip:
                    problems.append("%s: skipped 0x%x is not a process connection" % (plane, eid))
                    continue
                verified.add(eid)
                # It keeps its class and its place: a marker entry and its
                # links, nothing else. Its properties are not compared.
                if eid not in entries:
                    problems.append("%s: skipped 0x%x has no entry record" % (plane, eid))
            elif eid not in entries:
                problems.append("%s: entry 0x%x present before and after, missing from the snapshot" % (plane, eid))
                continue
            elif eid in may_skip:
                problems.append("%s: process connection 0x%x was recorded" % (plane, eid))
            for parent in a[eid][1] & b[eid][1]:
                if (eid, parent) not in links.get(plane, set()):
                    problems.append("%s: link 0x%x -> parent 0x%x missing" % (plane, eid, parent))
            if eid in skipped or eid in compared:
                continue  # properties belong to the entry: compare them in the first plane that shows it
            compared.add(eid)
            counts["entries_checked"] += 1
            snap_props = plain(entries[eid]["props"])
            if not isinstance(snap_props, dict):
                problems.append("entry 0x%x: properties not captured" % eid)
                continue
            withheld_keys = sum(1 for k in snap_props if isinstance(k, tuple))
            stable_keys = set(a[eid][0]) & set(b[eid][0])
            missing = sorted(stable_keys - set(snap_props))
            # A missing live key is excused only when the key itself holds one
            # of the Mac's identifiers, so its pair was withheld whole, and only
            # one per withheld pair (Codex, last review of PR 693: an excuse by
            # count hid unrelated gaps). Every other missing key is a problem.
            excused = [k for k in missing if key_holds_identifier(k, ids)][:withheld_keys]
            counts["values_withheld"] += len(excused)
            for key in missing:
                if key not in excused:
                    problems.append("entry 0x%x: property %r missing" % (eid, key))
            for key in sorted(k for k in set(snap_props) - set(a[eid][0]) - set(b[eid][0]) if isinstance(k, str)):
                problems.append("entry 0x%x: property %r not in either ioreg export" % (eid, key))
            for key in sorted(stable_keys & set(snap_props)):
                va, vb = a[eid][0][key], b[eid][0][key]
                if key in PROCESS_NAME_KEYS:  # the probe writes "pid N, name" as "name"
                    va, vb = process_name(va), process_name(vb)
                if va != vb or key in VOLATILE_KEYS:
                    continue  # changed by itself between the two exports: volatile
                counts["values_checked"] += 1
                if snap_props[key] is WITHHELD:
                    counts["values_withheld"] += 1
                elif isinstance(snap_props[key], PartData):
                    counts["values_withheld"] += 1
                    if not same_value(snap_props[key], va):
                        problems.append("entry 0x%x: property %r differs from ioreg" % (eid, key))
                elif snap_props[key] is SKIPPED:
                    counts["values_skipped"] += 1
                elif not same_value(snap_props[key], va):
                    problems.append("entry 0x%x: property %r differs from ioreg" % (eid, key))
    counts["skips_verified"] = len(verified)
    return problems, counts


def iokit():
    """IOKit through ctypes (standard library), so the checker reads the
    registry itself rather than through the probe's code."""
    lib = ctypes.cdll.LoadLibrary("/System/Library/Frameworks/IOKit.framework/IOKit")
    u32 = ctypes.c_uint32
    lib.IORegistryCreateIterator.argtypes = [u32, ctypes.c_char_p, u32, ctypes.POINTER(u32)]
    lib.IORegistryCreateIterator.restype = ctypes.c_int
    lib.IOIteratorNext.argtypes = [u32]
    lib.IOIteratorNext.restype = u32
    lib.IOIteratorIsValid.argtypes = [u32]
    lib.IOIteratorIsValid.restype = ctypes.c_int
    lib.IOObjectConformsTo.argtypes = [u32, ctypes.c_char_p]
    lib.IOObjectConformsTo.restype = ctypes.c_int
    lib.IORegistryEntryGetRegistryEntryID.argtypes = [u32, ctypes.POINTER(ctypes.c_uint64)]
    lib.IORegistryEntryGetRegistryEntryID.restype = ctypes.c_int
    lib.IOObjectRelease.argtypes = [u32]
    return lib


def process_connection_ids(planes):
    """Entry IDs of every IOUserClient and IODTNVRAMDiags, subclasses included,
    in every plane: the only entries the snapshot may leave out. Each entry is
    asked IOObjectConformsTo on a walk of each
    plane. Not `ioreg -r -c`, which prints an instance inside another's subtree
    only there (two on the MacBook, 2026-10-07); not IOServiceGetMatchingServices,
    which returns only registered services (7 of 826 user clients on the mini)."""
    lib, ids = iokit(), set()
    for plane in planes:
        for _ in range(5):  # a registry that changed mid-walk invalidates the iterator: walk again
            it, found = ctypes.c_uint32(), set()
            if lib.IORegistryCreateIterator(0, plane.encode(), 1, ctypes.byref(it)) != 0:  # 1: recursively
                break
            entry = lib.IOIteratorNext(it.value)
            while entry:
                eid = ctypes.c_uint64()
                if (lib.IOObjectConformsTo(entry, b"IOUserClient") or lib.IOObjectConformsTo(entry, b"IODTNVRAMDiags")) \
                        and lib.IORegistryEntryGetRegistryEntryID(entry, ctypes.byref(eid)) == 0:
                    found.add(eid.value)
                lib.IOObjectRelease(entry)
                entry = lib.IOIteratorNext(it.value)
            valid = lib.IOIteratorIsValid(it.value)
            lib.IOObjectRelease(it.value)
            ids |= found
            if valid:
                break
    return ids


def registry_planes():
    """Every plane the live registry lists, from the root's IORegistryPlanes
    (eight on the mini, 2026-10-07), so a plane macOS adds is compared too."""
    root = plistlib.loads(subprocess.run(["ioreg", "-a", "-l", "-d", "1"], capture_output=True, check=True).stdout)
    return sorted(root["IORegistryPlanes"])


def run_vs_ioreg(probe):
    planes = registry_planes()
    before = {p: index_ioreg(ioreg_plane(p)) for p in planes}
    may_skip = process_connection_ids(planes)
    with tempfile.NamedTemporaryFile(suffix=".jsonl") as out:
        subprocess.run([probe], stdout=out, check=True)
        records, cut = read_records(out.name)
    after = {p: index_ioreg(ioreg_plane(p)) for p in planes}
    may_skip |= process_connection_ids(planes)  # either side: connections open and close during the run
    structure = cut + validate_records(records)
    problems, counts = compare(records, before, after, may_skip, live_identifiers())
    return structure + problems, counts


# ---- privacy ------------------------------------------------------------------

def weak(form):
    """A form mostly made of one byte value identifies nothing and matches
    countless unrelated values (a near-empty network address with five zero
    bytes matched 2335 small integers on the MacBook). Exactly half is kept:
    every UTF-16 form of ASCII text is half zero bytes."""
    return max(form.count(b) for b in set(form)) * 2 > len(form)


class Exact(bytes):
    """A form found only as a whole data value, never inside a longer one."""


class Text(bytes):
    """A text form (hex, decimal, a serial, in any encoding): '0' characters
    in it are padding as zero bytes are, for searchable()."""


def text_forms(text, cases=False):
    """A text identifier as published (and in upper and lower case), each as
    UTF-8, UTF-16LE and UTF-16BE. Text too short or too uniform to search for
    gives none: its UTF-16 forms would match as loosely."""
    variants = [text] + ([text.upper(), text.lower()] if cases else [])
    return [Text(v.encode(enc)) for v in variants if len(v.encode()) >= 4 and not weak(v.encode())
            for enc in ("utf-8", "utf-16-le", "utf-16-be")]


def binary_forms(raw):
    """Every form of a binary identifier: its bytes and their reverse, each
    with leading and with trailing zero bytes stripped; those as hex text in
    both cases, bare and with ':' or '-' between bytes (bare also without
    leading zero digits); up to 8 bytes, the value in decimal read either way
    round; and every text form again as UTF-16LE and UTF-16BE. An identifier
    with under 4 bytes once zeros are stripped gives no text: "12ab" or "4779"
    would match countless unrelated values."""
    blobs = []
    for b in (raw, raw[::-1]):
        for form in (b, b.lstrip(b"\0"), b.rstrip(b"\0"), b.strip(b"\0")):
            if form and form not in blobs:
                blobs.append(form)
    texts = []
    for b in blobs if len(raw.strip(b"\0")) >= 4 else []:
        for h in (b.hex(), b.hex().upper()):
            pairs = [h[i:i + 2] for i in range(0, len(h), 2)]
            texts += [h, h.lstrip("0"), ":".join(pairs), "-".join(pairs)]
    if len(raw) <= 8 and len(raw.strip(b"\0")) >= 4:
        texts += [str(int.from_bytes(raw, "big")), str(int.from_bytes(raw, "little"))]
    # Text forms too short or too uniform to search for give no UTF-16 forms either.
    texts = [t.encode() for t in texts if len(t) >= 4 and not weak(t.encode())]
    return blobs + [Text(t.decode().encode(enc)) for t in texts for enc in ("utf-8", "utf-16-le", "utf-16-be")]


def uuid_forms(text):
    """A UUID as text (as published, upper, lower), as its 16 bytes in every
    binary form, and in the EFI and SMBIOS order (first three fields
    little-endian) that Intel Macs publish (/efi/platform system-id, SMBIOS)."""
    raw = bytes.fromhex(text.replace("-", ""))
    efi = raw[3::-1] + raw[5:3:-1] + raw[7:5:-1] + raw[8:]
    return text_forms(text, cases=True) + binary_forms(raw) + [efi]


def address_forms(raw):
    """A network or Bluetooth address in every binary form, and as a whole
    6-byte data value either way round (PR 693 rerun: three of the mini's own
    addresses share 5 bytes). One mostly made of one byte value (the MacBook's
    Thunderbolt Bridge: five zero bytes) is found only as a whole value: its
    forms are too uniform to search for inside longer values."""
    forms = binary_forms(raw)
    if len(set(raw)) > 1:  # all one value (none, or broadcast) is no one's
        forms += [Exact(raw), Exact(raw[::-1])]
    return forms


def only_padding_besides(longer, shorter, text):
    """True when shorter occurs in longer with nothing else in longer but
    padding: zero bytes, and in a text form the '0' character too."""
    pad = (0, ord("0")) if text else (0,)
    at = longer.find(shorter)
    while at >= 0:
        if all(b in pad for b in longer[:at] + longer[at + len(shorter):]):
            return True
        at = longer.find(shorter, at + 1)
    return False


def searchable(forms):
    """The forms worth searching for, in order: at least 4 bytes, not weak,
    and not holding a shorter form with only padding besides (the shorter one
    already finds every place it is in, and leaves nothing of an identifier
    out). The same rule as pj_ids_finish in probe_json.h."""
    keep = [f for f in forms if isinstance(f, Exact)]
    text = {}
    for f in (f for f in forms if not isinstance(f, Exact)):
        text[bytes(f)] = text.get(bytes(f), True) and isinstance(f, Text)  # binary wins: the stricter rule
    found = []
    for f in sorted(text, key=lambda f: (len(f), f)):
        if len(f) >= 4 and not weak(f) and not any(only_padding_besides(f, k, text[f]) for k in found):
            found.append(f)
    return keep + found


def identifier_forms(serials=(), uuids=(), chip_ids=(), networks=(), bluetooth=(), homes=(), users=()):
    """kind -> the forms to search for, generated from each identifier's value
    (PR 693: listing forms by hand missed the chip ID twice, big-endian in the
    boot manifest and in SMC key RECI)."""
    kinds = {
        "mac serial": [f for v in serials for f in text_forms(v, cases=True)],
        "platform uuid": [f for v in uuids for f in uuid_forms(v)],
        "chip id": [f for v in chip_ids for f in binary_forms(v)],
        "built-in network address": [f for v in networks for f in address_forms(v)],
        "own bluetooth address": [f for v in bluetooth for f in address_forms(v)],
        "home folder": [f for v in homes for f in text_forms(v)],
        "user name": [f for v in users for f in text_forms(v)],
    }
    return {kind: searchable(forms) for kind, forms in kinds.items() if searchable(forms)}


def network_ports():
    """(port name, 6-byte address, the Mac's own port?) for every hardware port
    networksetup lists with an address."""
    out = []
    hw = subprocess.run(["networksetup", "-listallhardwareports"], capture_output=True, text=True).stdout
    for block in hw.split("\n\n"):
        port = re.search(r"Hardware Port: (.+)", block)
        mac = re.search(r"Ethernet Address: ([0-9a-f:]{17})", block)
        if not (port and mac) or mac.group(1) == "00:00:00:00:00:00":
            continue
        name = port.group(1).strip()
        own = name in ("Ethernet", "Wi-Fi", "Thunderbolt Bridge") or re.match(r"(Thunderbolt \d+|Ethernet Adapter \(en\d+\))$", name)
        out.append((name, bytes.fromhex(mac.group(1).replace(":", "")), bool(own)))
    return out


def live_identifiers():
    """kind -> forms (identifier_forms), from values read on this Mac without
    the probe's code: ioreg, networksetup, system_profiler and pwd."""
    values = {"serials": [], "uuids": [], "chip_ids": [], "bluetooth": [], "users": []}
    pe = plistlib.loads(subprocess.run(["ioreg", "-a", "-r", "-d", "1", "-c", "IOPlatformExpertDevice"],
                                       capture_output=True, check=True).stdout)
    for node in pe if isinstance(pe, list) else [pe]:
        if node.get("IOPlatformSerialNumber"):
            values["serials"].append(node["IOPlatformSerialNumber"])
        if node.get("IOPlatformUUID"):
            values["uuids"].append(node["IOPlatformUUID"])
    chosen = subprocess.run(["ioreg", "-a", "-p", "IODeviceTree", "-r", "-n", "chosen", "-d", "1"],
                            capture_output=True).stdout
    if chosen:
        nodes = plistlib.loads(chosen)
        for node in nodes if isinstance(nodes, list) else [nodes]:
            ecid = node.get("unique-chip-id")
            if isinstance(ecid, bytes) and len(ecid) == 8:
                values["chip_ids"].append(ecid)
    values["networks"] = [raw for _, raw, own in network_ports() if own]
    # The Mac's own Bluetooth address, from system_profiler (the probe reads the
    # device tree instead). Paired devices' addresses are not the Mac's and are kept.
    bt = subprocess.run(["system_profiler", "SPBluetoothDataType", "-json"], capture_output=True).stdout
    for e in (json.loads(bt).get("SPBluetoothDataType", []) if bt else []):
        own = e.get("controller_properties", {}).get("controller_address", "")
        if re.fullmatch(r"[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}", own):
            values["bluetooth"].append(bytes.fromhex(own.replace(":", "")))
    me = pwd.getpwuid(os.getuid())
    values["homes"] = [me.pw_dir]
    # The account name always; the full name when it is long enough to mean something.
    values["users"] = [me.pw_name] + ([me.pw_gecos] if len(me.pw_gecos.encode()) >= 4 else [])
    return identifier_forms(**values)


# kind -> what shows this Mac has one (None: every Mac): a device-tree key in
# /chosen, or a registry class present. The Bluetooth kind is required
# whenever a Bluetooth controller is present (Codex x1 #1: Intel Macs have the
# controller and no /chosen key). A kind the Mac has but the checker could
# not read means privacy looked for nothing: system_profiler returns nothing
# for some data types on some Macs.
EXPECTED_KINDS = {
    "mac serial": None,
    "platform uuid": None,
    "home folder": None,
    "chip id": (("chosen", "unique-chip-id"),),
    "own bluetooth address": (("chosen", "mac-address-bluetooth0"), ("class", "IOBluetoothHCIController")),
    "built-in network address": (("chosen", "mac-address-wifi0"), ("chosen", "mac-address-ethernet0")),
    "user name": None,
}
LIVE_CLASS_NEEDS = sorted({k for needs in EXPECTED_KINDS.values() if needs for where, k in needs if where == "class"})


def chosen_keys():
    """Property names on the device tree's /chosen node."""
    out = subprocess.run(["ioreg", "-a", "-p", "IODeviceTree", "-r", "-n", "chosen", "-d", "1"], capture_output=True).stdout
    if not out:
        return set()
    nodes = plistlib.loads(out)
    return {k for n in (nodes if isinstance(nodes, list) else [nodes]) for k in n}


def live_classes(names):
    """Those of names the live registry has an instance of (subclasses
    included, as `ioreg -c` matches), read without the probe's code."""
    present = set()
    for name in names:
        out = subprocess.run(["ioreg", "-a", "-r", "-c", name, "-d", "1"], capture_output=True).stdout
        if out.strip() and plistlib.loads(out):
            present.add(name)
    return present


def identifier_gaps(ids, keys, classes):
    """keys: the /chosen property names; classes: the registry classes present
    (live_classes). A kind is required when any of its needs is met."""
    def required(needs):
        return needs is None or any((k in keys) if where == "chosen" else (k in classes) for where, k in needs)
    return ["%s: this Mac has one but the check could not read it, so nothing was searched for" % kind
            for kind, needs in sorted(EXPECTED_KINDS.items()) if kind not in ids and required(needs)]


def volume_uuids():
    """APFS volume and container UUIDs. Not personal: kept unchanged (Darryl, 2026-10-07)."""
    out = []
    apfs = subprocess.run(["diskutil", "apfs", "list", "-plist"], capture_output=True).stdout
    if not apfs:
        return out
    for container in plistlib.loads(apfs).get("Containers", []):
        for u in [container.get("APFSContainerUUID")] + [v.get("APFSVolumeUUID") for v in container.get("Volumes", [])]:
            if u and u != "00000000-0000-0000-0000-000000000000":
                out.append(u)
    return out


def payloads(records):
    """(location, bytes, is data) for every string and data value, key and field
    in the output, in the snapshot's entries and in every small probe's records.
    Each line's text (every string, key and field, as UTF-8) comes first."""
    for i, r in enumerate(records):
        yield ("line %d" % (i + 1), json.dumps(r, ensure_ascii=False).encode("utf-8", "replace"), False)

        def walk(v, path):
            if isinstance(v, dict):
                t = v.get("t")
                if t == "data":
                    yield (path, bytes.fromhex(v["hex"]), True)
                elif t == "int":
                    raw = bytes.fromhex(v["hex"])
                    yield (path, raw, False)          # big-endian, as written
                    yield (path, raw[::-1], False)    # little-endian
                elif t == "str" and "utf16" in v:
                    yield (path, bytes.fromhex(v["utf16"]).decode("utf-16-be", "replace").encode(), False)
                elif t == "dict":
                    for k, x in v["v"]:
                        yield from walk(x, path + "/" + (k if isinstance(k, str) else "?"))
                elif t in ("array", "set"):
                    for x in v["v"]:
                        yield from walk(x, path + "/[]")
        if r.get("record") == "entry":
            yield from walk(r["props"], "line %d %s" % (i + 1, r.get("class")))
        elif r.get("record") not in ("header", "footer"):
            # Small probes: typed values in any field, and raw bytes written as
            # plain hex strings (53_smc_keys "bytes", 52_usb_bos descriptors).
            for k, v in r.items():
                where = "line %d %s.%s" % (i + 1, r.get("record"), k)
                if isinstance(v, dict) and "t" in v:
                    yield from walk(v, where)
                elif isinstance(v, str) and len(v) >= 8 and len(v) % 2 == 0 and re.fullmatch(r"[0-9a-f]+", v):
                    yield (where, bytes.fromhex(v), True)


def privacy_problems(records, ids):
    problems = []
    for where, blob, is_data in payloads(records):
        for kind, forms in ids.items():
            if any((is_data and blob == form) if isinstance(form, Exact) else form in blob for form in forms):
                problems.append("%s found at %s" % (kind, where))
    return problems


def is_withheld(v):
    """A typed value withheld whole or in part."""
    return isinstance(v, dict) and (v.get("t") == "withheld" or "withheld" in v)


def withheld_join_keys(records):
    """Join keys withheld at any depth of an entry's properties."""
    problems = []

    def walk(v, line, cls):
        if not isinstance(v, dict):
            return
        if v.get("t") == "dict":
            for k, x in v["v"]:
                prefixes = JOIN_KEY_CLASS_PREFIXES.get(k) if isinstance(k, str) else None
                if is_withheld(x) and (k in JOIN_KEYS or (prefixes and cls.startswith(prefixes))):
                    problems.append("line %d: join key %r withheld on %s" % (line, k, cls))
                walk(x, line, cls)
        elif v.get("t") in ("array", "set"):
            for x in v["v"]:
                walk(x, line, cls)

    for i, r in enumerate(records):
        if r.get("record") == "entry":
            walk(r["props"], i + 1, str(r.get("class", "")))
    return problems


def kept_data(value, key):
    """The bytes of every data value under key, at any depth, not withheld at all."""
    if isinstance(value, dict) and value.get("t") == "dict":
        for k, x in value["v"]:
            if k == key and x.get("t") == "data" and not is_withheld(x):
                yield bytes.fromhex(x["hex"])
            yield from kept_data(x, key)
    elif isinstance(value, dict) and value.get("t") in ("array", "set"):
        for x in value["v"]:
            yield from kept_data(x, key)


def adapter_problems(records, adapters):
    """An attached adapter's address is not the Mac's and is kept (spec,
    Privacy): each one the live registry shows must be in the snapshot unwithheld."""
    kept = {b for r in records if r.get("record") == "entry" for b in kept_data(r["props"], "IOMACAddress")}
    missing = sum(1 for a in adapters if a not in kept)
    return ["%d of %d attached adapters' network addresses withheld or missing" % (missing, len(adapters))] if missing else []


def count_key(value, key, keep):
    """Occurrences of key at any depth in a typed value; keep=True counts only
    values that were not withheld, wholly or in part."""
    n = 0
    if isinstance(value, dict):
        t = value.get("t")
        if t == "dict":
            for k, x in value["v"]:
                if k == key and (not keep or (x.get("t") != "withheld" and "withheld" not in x)):
                    n += 1
                n += count_key(x, key, keep)
        elif t in ("array", "set"):
            for x in value["v"]:
                n += count_key(x, key, keep)
    return n


def paired_bluetooth():
    """Addresses of the Bluetooth devices this Mac knows (paired), from system_profiler."""
    out = subprocess.run(["system_profiler", "SPBluetoothDataType", "-json"], capture_output=True).stdout
    addrs = []
    for e in (json.loads(out).get("SPBluetoothDataType", []) if out else []):
        for group in ("device_connected", "device_not_connected"):
            for dev in e.get(group, []):
                for props in dev.values():
                    a = props.get("device_address", "")
                    if re.fullmatch(r"[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}", a):
                        addrs.append(bytes.fromhex(a.replace(":", "")))
    return addrs


def paired_kept(records, paired):
    """How many paired-device addresses appear unwithheld, in either byte order."""
    blobs = [blob for _, blob, _ in payloads(records)]
    return sum(1 for a in paired if any(a in b or a[::-1] in b for b in blobs))


def kept_problems(records):
    """Device serials stay unchanged (whatcable-app CLAUDE.md:9-12): every one the
    live registry shows must be in the output unwithheld."""
    snap = sum(count_key(r["props"], "USB Serial Number", True) for r in records if r.get("record") == "entry")
    registry = subprocess.run(["ioreg", "-l", "-p", "IOService"], capture_output=True).stdout  # not always UTF-8
    live = registry.count(b'"USB Serial Number" =')
    macs = sum(count_key(r["props"], "IOMACAddress", True) for r in records if r.get("record") == "entry")
    # Attached adapters: ports networksetup lists that are not the Mac's own,
    # whose address the live registry publishes as an IOMACAddress.
    live_macs = {bytes.fromhex(h.decode()) for h in re.findall(rb'"IOMACAddress" = <([0-9a-f]{12})>', registry)}
    adapters = [raw for _, raw, own in network_ports() if not own and raw in live_macs]
    text = b"\n".join(json.dumps(r).encode() for r in records)
    volumes = volume_uuids()
    volumes_kept = sum(1 for u in volumes if u.encode() in text)
    paired = paired_bluetooth()
    print("device serials kept: %d (live registry shows %d); network addresses kept: %d (%d attached adapters); "
          "volume UUIDs kept: %d of %d; paired Bluetooth addresses present: %d of %d known"
          % (snap, live, macs, len(adapters), volumes_kept, len(volumes), paired_kept(records, paired), len(paired)))
    problems = [] if snap >= live else ["only %d of %d device serials kept unchanged" % (snap, live)]
    problems += adapter_problems(records, adapters)
    if volumes_kept < len(volumes):
        problems.append("only %d of %d volume UUIDs kept unchanged" % (volumes_kept, len(volumes)))
    return problems


def privacy_all(records, ids, keys, classes=frozenset()):
    """Every privacy check for one probe's output. The structure comes first: a
    file that is empty, has no header or no footer, or lacks a snapshot's
    summaries holds too little to search, and that is a failure, not a pass.
    A run the byte cap stopped is sound and is judged on its content. The kept
    checks (device serials, volume UUIDs, adapters) compare with the live
    registry, so they apply only to a complete snapshot: in a capped one a
    missing value was refused by the cap, not withheld."""
    problems = validate_records(records, stopped_ok=("byte_cap",)) + identifier_gaps(ids, keys, classes)
    problems += privacy_problems(records, ids) + withheld_join_keys(records)
    if records and records[0].get("probe") == "50_registry_snapshot" and records[-1].get("status") == "complete":
        problems += kept_problems(records)
    return problems


# ---- command line -------------------------------------------------------------

def main(argv):
    if len(argv) != 3 or argv[1] not in ("validate", "vs-ioreg", "privacy"):
        print(__doc__)
        return 2
    command, target = argv[1], argv[2]
    if command == "validate":
        records, problems = read_records(target)
        problems += validate_records(records)
        kinds = {}
        for r in records:
            kinds[r.get("record")] = kinds.get(r.get("record"), 0) + 1
        print("records: %s" % ", ".join("%s %d" % kv for kv in sorted(kinds.items())))
    elif command == "vs-ioreg":
        problems, counts = run_vs_ioreg(target)
        print("checked %(entries_checked)d entries, %(values_checked)d stable values (%(values_withheld)d withheld, "
              "%(values_skipped)d skipped); %(entries_skipped)d entries skipped by design, "
              "%(skips_verified)d of them checked against the live registry" % counts)
    else:
        records, problems = read_records(target)
        ids = live_identifiers()
        print("identifier kinds read from this Mac: %s" % ", ".join("%s (%d forms)" % (k, len(v)) for k, v in sorted(ids.items())))
        problems += privacy_all(records, ids, chosen_keys(), live_classes(LIVE_CLASS_NEEDS))
    for p in problems[:200]:
        print("PROBLEM " + p)
    if len(problems) > 200:
        print("... and %d more" % (len(problems) - 200))
    print("%s: %d problems" % (command, len(problems)))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
