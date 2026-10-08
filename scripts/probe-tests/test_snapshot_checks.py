"""Self-tests for snapshot_checks.py: every check must catch a planted fault.
Synthetic data, so they run anywhere, except LiveReader, which reads this Mac's
registry through the checker's own IOKit reader:
python3 -m unittest discover -s scripts/probe-tests"""
import json
import os
import plistlib
import stat
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import snapshot_checks as sc  # noqa: E402


def entry(eid, props):
    return {"record": "entry", "id": eid, "class": "AppleHPMDeviceHALType3", "props": {"t": "dict", "v": props}}


def skipped_entry(eid, cls="SomeUserClient"):
    """A process connection's entry: its class and the skipped marker, no properties."""
    return {"record": "entry", "id": eid, "class": cls, "props": {"t": "skipped"}}


def link(eid, parent, plane="IOService"):
    return {"record": "link", "plane": plane, "id": eid, "parent": parent, "pos": 0,
            "name": "x", "location": None, "path": None}


def int32(value):
    return {"t": "int", "bits": 32, "hex": "%08x" % (value & 0xFFFFFFFF)}


# Superclass chains for the classes the fixtures use, as the probe's class
# records give them. SomeUserClient is a process connection by its chain.
CHAINS = {"AppleHPMDeviceHALType3": ["AppleHPMDevice", "IOService", "IORegistryEntry", "OSObject"],
          "SomeUserClient": ["IOUserClient", "IOService", "IORegistryEntry", "OSObject"]}


def class_record(name, chain=None):
    return {"record": "class", "name": name, "super": chain if chain is not None else CHAINS.get(name, ["IOService", "IORegistryEntry", "OSObject"]),
            "bundle": "com.example.test"}


def wrap(body, withheld=0, summary=None, skipped=(), skipped_props=None):
    """A complete snapshot around body: a class record for every entry class
    body does not already describe, then the summaries, header and footer."""
    head = {"record": "header", "format": 1, "probe": "50_registry_snapshot"}
    described = {r["name"] for r in body if r.get("record") == "class"}
    body = body + [class_record(c) for c in sorted({r["class"] for r in body if r.get("record") == "entry" and isinstance(r.get("class"), str)} - described)]
    body = body + [{"record": "withheld_summary", "counts": summary if summary is not None else ([["X: k", withheld]] if withheld else [])},
                   {"record": "skipped_summary", "counts": [["SomeUserClient", len(skipped)]] if skipped else [], "ids": list(skipped),
                    "properties": skipped_props if skipped_props is not None else []}]
    foot = {"record": "footer", "status": "complete", "reason": None, "step": None, "records": len(body), "withheld": withheld}
    return [head] + body + [foot]


ROOT, CHILD = "0x1", "0x2"
GOOD = wrap([entry(ROOT, []), entry(CHILD, [["Priority", int32(-500)], ["Name", {"t": "str", "v": "port"}]]),
             link(ROOT, None), link(CHILD, ROOT)])


def ioreg(priority=0xFFFFFFFFFFFFFE0C, name="port"):
    """plane -> {id: (props, parents)} as index_ioreg builds it. ioreg shows a
    negative 32-bit value sign-extended to 64 bits."""
    return {"IOService": {1: ({}, set()), 2: ({"Priority": priority, "Name": name}, {1})}}


class Validate(unittest.TestCase):
    def test_good_file(self):
        self.assertEqual(sc.validate_records(GOOD), [])

    def test_missing_footer(self):
        self.assertIn("last line is not a footer: the run was cut off", sc.validate_records(GOOD[:-1]))

    def test_entry_written_twice(self):
        bad = wrap([entry(ROOT, []), entry(ROOT, [])])
        self.assertTrue(any("written twice" in p for p in sc.validate_records(bad)))

    def test_link_without_entry(self):
        bad = wrap([entry(ROOT, []), link("0x9", ROOT)])
        self.assertTrue(any("no entry record" in p for p in sc.validate_records(bad)))

    def test_footer_count(self):
        bad = GOOD[:-1] + [dict(GOOD[-1], records=99)]
        self.assertTrue(any("footer counts" in p for p in sc.validate_records(bad)))

    def test_footer_step_is_required(self):
        # The footer's step says which identifier lookup stopped a run (PR 693
        # extra pass 3): null on every other footer, a documented name on one
        # stopped for identifiers_incomplete, and never missing.
        missing = GOOD[:-1] + [{k: v for k, v in GOOD[-1].items() if k != "step"}]
        self.assertIn("footer has no step field", sc.validate_records(missing))
        on_complete = GOOD[:-1] + [dict(GOOD[-1], step="chosen")]
        self.assertIn("footer step 'chosen' on a complete run", sc.validate_records(on_complete))

        def stopped(step, reason="identifiers_incomplete"):
            return [GOOD[0], {"record": "footer", "status": "stopped", "reason": reason, "step": step, "records": 0, "withheld": 0}]
        ok = ("identifiers_incomplete", "byte_cap")
        self.assertEqual(sc.validate_records(stopped("chosen"), stopped_ok=ok), [])
        self.assertIn("footer step 'serial_number' is not a documented gathering step", sc.validate_records(stopped("serial_number"), stopped_ok=ok))
        self.assertIn("footer stopped for identifiers_incomplete without a step", sc.validate_records(stopped(None), stopped_ok=ok))
        self.assertIn("footer step 'chosen' on a run that did not stop for identifiers_incomplete", sc.validate_records(stopped("chosen", "byte_cap"), stopped_ok=ok))
        # The step is keyed on status as well as reason (Opus x3 review of PR
        # 693): a complete footer has reason null and step null, whatever the
        # reason says, and a step of any other type is a problem line, never
        # a crash (a list or a dict used to raise TypeError).
        complete_reason = GOOD[:-1] + [dict(GOOD[-1], reason="identifiers_incomplete", step="chosen")]
        self.assertIn("footer complete with reason 'identifiers_incomplete'", sc.validate_records(complete_reason))
        self.assertIn("footer step 'chosen' on a complete run", sc.validate_records(complete_reason))
        self.assertIn("footer complete with reason 'byte_cap'", sc.validate_records(GOOD[:-1] + [dict(GOOD[-1], reason="byte_cap")]))
        for shape in (["chosen"], {"step": "chosen"}, 5, True):
            self.assertIn("footer step %r is not a string" % (shape,), sc.validate_records(stopped(shape), stopped_ok=ok))

    def test_withheld_summary_must_add_up(self):
        bad = wrap([entry(ROOT, [])], withheld=2, summary=[["X: k", 1]])
        self.assertTrue(any("withheld_summary counts 1, footer says 2" in p for p in sc.validate_records(bad)))

    def test_skipped_summary_must_add_up(self):
        bad = wrap([entry(ROOT, [])])
        bad[-2] = {"record": "skipped_summary", "counts": [["SomeUserClient", 2]], "ids": ["0x9"]}
        self.assertTrue(any("skipped_summary counts 2, lists 1 ids" in p for p in sc.validate_records(bad)))

    def test_skipped_connection_keeps_its_class_and_place(self):
        # A process connection keeps its class and its place in the tree
        # (Darryl, 2026-10-08): an entry record whose props are exactly the
        # skipped marker, and its links. Its properties are never written.
        good = wrap([entry(ROOT, []), link(ROOT, None), skipped_entry(CHILD), link(CHILD, ROOT)], skipped=[CHILD])
        self.assertEqual(sc.validate_records(good), [])
        no_entry = wrap([entry(ROOT, []), link(ROOT, None)], skipped=[CHILD])
        self.assertIn("skipped 0x2 has no entry record", sc.validate_records(no_entry))
        with_props = wrap([entry(ROOT, []), link(ROOT, None), entry(CHILD, []), link(CHILD, ROOT)], skipped=[CHILD])
        self.assertIn("skipped 0x2 has properties, not the skipped marker", sc.validate_records(with_props))
        unlisted = wrap([entry(ROOT, []), link(ROOT, None), skipped_entry(CHILD), link(CHILD, ROOT)])
        self.assertIn("entry 0x2 holds the skipped marker but is not in skipped_summary", sc.validate_records(unlisted))

    def test_connection_recorded_in_full_is_caught_by_its_class(self):
        # F3 of the Opus review after extra pass 1: a connection recorded with
        # its properties and left out of skipped_summary passed validate, which
        # keyed every marker check on the probe's own list. The file's class
        # records say which classes derive from IOUserClient or IODTNVRAMDiags,
        # so validate requires the marker on every such entry, listed or not.
        in_full = wrap([entry(ROOT, []), link(ROOT, None), dict(entry(CHILD, [["IOUserClientCreator", {"t": "str", "v": "pid 1, x"}]]), **{"class": "SomeUserClient"}), link(CHILD, ROOT)])
        self.assertIn("entry 0x2: class 'SomeUserClient' is a process connection but its properties were recorded", sc.validate_records(in_full))
        # Through a deeper chain, and for IODTNVRAMDiags, which has no IOUserClient above it.
        deep = wrap([entry(ROOT, []), link(ROOT, None), dict(entry(CHILD, []), **{"class": "DeepClient"}), link(CHILD, ROOT),
                     class_record("DeepClient", ["SomeUserClient", "IOUserClient", "IOService", "IORegistryEntry", "OSObject"])])
        self.assertIn("entry 0x2: class 'DeepClient' is a process connection but its properties were recorded", sc.validate_records(deep))
        diags = wrap([entry(ROOT, []), link(ROOT, None), dict(entry(CHILD, []), **{"class": "IODTNVRAMDiags"}), link(CHILD, ROOT),
                      class_record("IODTNVRAMDiags", ["IOService", "IORegistryEntry", "OSObject"])])
        self.assertIn("entry 0x2: class 'IODTNVRAMDiags' is a process connection but its properties were recorded", sc.validate_records(diags))
        # The marker entry listed in skipped_summary is the right shape, and so
        # is hardware beneath a connection; a class no class record describes
        # cannot be checked, and that is a problem too.
        self.assertEqual(sc.validate_records(wrap([entry(ROOT, []), link(ROOT, None), skipped_entry(CHILD), link(CHILD, ROOT)], skipped=[CHILD])), [])
        undescribed = wrap([entry(ROOT, []), link(ROOT, None), dict(entry(CHILD, []), **{"class": "Mystery"}), link(CHILD, ROOT)])
        undescribed = [r for r in undescribed if not (r.get("record") == "class" and r["name"] == "Mystery")]
        undescribed[-1] = dict(undescribed[-1], records=undescribed[-1]["records"] - 1)
        self.assertIn("entry 0x2: class 'Mystery' has no class record", sc.validate_records(undescribed))

    def test_process_id_left_in_the_output_is_caught(self):
        # Darryl, 2026-10-08: a "pid N, name" value keeps the name only. A
        # PID left anywhere in any probe's output fails validate.
        bad = wrap([entry(ROOT, [["UsbExclusiveOwner", {"t": "str", "v": "pid 123, someapp"}]]), link(ROOT, None)])
        self.assertIn("line 2: 'UsbExclusiveOwner' holds a process id", sc.validate_records(bad))
        nested = wrap([entry(ROOT, [["Outer", {"t": "dict", "v": [["iAPAuthenticator", {"t": "str", "v": "pid 7, x"}]]}]]), link(ROOT, None)])
        self.assertIn("line 2: 'iAPAuthenticator' holds a process id", sc.validate_records(nested))
        good = wrap([entry(ROOT, [["UsbExclusiveOwner", {"t": "str", "v": "someapp"}], ["Driver", {"t": "str", "v": "AppleUSB20Hub"}]]), link(ROOT, None)])
        self.assertEqual(sc.validate_records(good), [])
        small = [{"record": "header", "format": 1, "probe": "51_driver_access"},
                 {"record": "user_client_open", "id": "0x1", "class": "X", "matched": "pid 9, y", "not_tried": None},
                 {"record": "footer", "status": "complete", "reason": None, "step": None, "records": 1, "withheld": 0}]
        self.assertIn("line 2: 'matched' holds a process id", sc.validate_records(small))

    def test_skipped_properties_must_add_up(self):
        bad = wrap([entry(ROOT, [["boot-volume", {"t": "skipped"}]])], skipped_props=[])
        self.assertTrue(any("skipped_summary lists 0 properties, entries hold 1" in p for p in sc.validate_records(bad)))
        # A connection's own marker is not a skipped property.
        marker_only = wrap([entry(ROOT, []), link(ROOT, None), skipped_entry(CHILD), link(CHILD, ROOT)], skipped=[CHILD], skipped_props=[])
        self.assertEqual(sc.validate_records(marker_only), [])

    def test_every_entry_reachable_from_the_root(self):
        # F1 of the last review: what hung beneath a connection was an island,
        # because the connection had no link. In every plane, a walk down from
        # the root through links must reach every linked entry, and every entry
        # has a link somewhere.
        island = wrap([entry(ROOT, []), link(ROOT, None), skipped_entry(CHILD), entry("0x3", []), link("0x3", CHILD)], skipped=[CHILD])
        problems = sc.validate_records(island)
        self.assertIn("IOService: 1 entries not reachable from the root through links", problems)
        self.assertIn("entry 0x2 has no link in any plane", problems)
        whole = wrap([entry(ROOT, []), link(ROOT, None), skipped_entry(CHILD), link(CHILD, ROOT), entry("0x3", []), link("0x3", CHILD)], skipped=[CHILD])
        self.assertEqual(sc.validate_records(whole), [])
        # Reachability is per plane: a link in IOPower does not place an entry in IOService.
        other_plane = wrap([entry(ROOT, []), link(ROOT, None), link(ROOT, None, "IOPower"), entry("0x3", []), link("0x3", ROOT, "IOPower"),
                            link("0x3", "0x4", "IOService"), entry("0x4", []), link("0x4", ROOT, "IOPower")])
        self.assertEqual([p for p in sc.validate_records(other_plane) if "reachable" in p],
                         ["IOService: 1 entries not reachable from the root through links"])

    def test_part_withheld_bytes_must_be_zero(self):
        bad = wrap([entry(ROOT, [["Blob", {"t": "data", "len": 4, "hex": "aabbccdd", "withheld": [[1, 2]]}]])], withheld=1)
        self.assertTrue(any("withheld bytes 1-2 are not zero" in p for p in sc.validate_records(bad)))

    def test_part_withheld_range_in_bounds(self):
        bad = wrap([entry(ROOT, [["Blob", {"t": "data", "len": 2, "hex": "aa00", "withheld": [[1, 4]]}]])], withheld=1)
        self.assertTrue(any("withheld range [1, 4] runs past" in p for p in sc.validate_records(bad)))

    def test_part_withheld_good(self):
        good = wrap([entry(ROOT, [["Blob", {"t": "data", "len": 4, "hex": "aa0000dd", "withheld": [[1, 2]]}]]), link(ROOT, None)], withheld=1)
        self.assertEqual(sc.validate_records(good), [])

    def test_small_probe_withheld_bytes_checked(self):
        # A raw-bytes field with some bytes withheld lists them in <field>_withheld.
        def smc(fields):
            body = [dict({"record": "smc_key", "index": 0, "key": "52454349"}, **fields)]
            return [{"record": "header", "format": 1, "probe": "53_smc_keys"}] + body + \
                [{"record": "footer", "status": "complete", "reason": None, "step": None, "records": 1, "withheld": 1}]
        self.assertEqual(sc.validate_records(smc({"bytes": "aa0000dd", "bytes_withheld": [[1, 2]]})), [])
        self.assertEqual(sc.validate_records(smc({"bytes": {"t": "withheld"}})), [])
        self.assertTrue(any("bytes_withheld: withheld bytes 1-2 are not zero" in p
                            for p in sc.validate_records(smc({"bytes": "aabbccdd", "bytes_withheld": [[1, 2]]}))))
        self.assertTrue(any("runs past" in p for p in sc.validate_records(smc({"bytes": "aa00", "bytes_withheld": [[1, 4]]}))))
        self.assertTrue(any("no field 'bytes'" in p for p in sc.validate_records(smc({"bytes_withheld": [[0, 1]]}))))

    def test_withheld_summary_required(self):
        bad = [r for r in GOOD if r.get("record") != "withheld_summary"]
        bad[-1] = dict(bad[-1], records=bad[-1]["records"] - 1)
        self.assertTrue(any("expected one withheld_summary" in p for p in sc.validate_records(bad)))

    def test_link_parent_is_an_entry(self):
        # A link's parent is always an entry record: a process connection has
        # one too (its class and the skipped marker), so what hangs beneath it
        # never links to an ID the file does not name.
        beneath = [entry(ROOT, []), link(ROOT, None), entry(CHILD, []), link(CHILD, "0x9")]
        self.assertEqual(sc.validate_records(wrap(beneath + [skipped_entry("0x9"), link("0x9", ROOT)], skipped=["0x9"])), [])
        self.assertTrue(any("link 0x2 -> parent 0x9 that has no entry record" in p for p in sc.validate_records(wrap(beneath, skipped=["0x9"]))))


class ReadRecords(unittest.TestCase):
    def read(self, text):
        with tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False) as f:
            f.write(text)
        try:
            return sc.read_records(f.name)
        finally:
            os.unlink(f.name)

    def test_cut_mid_line(self):
        # A watchdog kill leaves the last record half written: that is a cut-off
        # run to report, not a crash, and the lines before it still count.
        whole = "".join(json.dumps(r) + "\n" for r in GOOD[:3])
        records, problems = self.read(whole + json.dumps(GOOD[3])[:25])
        self.assertEqual(records, GOOD[:3])
        self.assertEqual(problems, ["last line cut off mid-record"])
        self.assertIn("last line is not a footer: the run was cut off", sc.validate_records(records))

    def test_whole_file(self):
        self.assertEqual(self.read("".join(json.dumps(r) + "\n" for r in GOOD)), (GOOD, []))

    def test_bad_middle_line_is_not_a_cut(self):
        # Only the last line can be cut off; garbage before it is corruption.
        with self.assertRaises(ValueError):
            self.read(json.dumps(GOOD[0]) + "\n{oops\n" + json.dumps(GOOD[1]) + "\n")


# Synthetic identifiers in every shape the live Mac publishes them.
CHIP_LE = bytes.fromhex("0fecdac8b6a41200")  # unique-chip-id: 8 bytes, little-endian
SAMPLE = {"serials": ["C02XYZ1234QW"], "uuids": ["4C4C4544-0039-4A10-8031-B4C04F4B5A31"], "chip_ids": [CHIP_LE],
          "networks": [bytes.fromhex("a4b1c2d3e4f5")], "bluetooth": [bytes.fromhex("f0b3ec123456")],
          "homes": ["/Users/jdoe"], "users": ["jdoe", "Jane Doe"]}


def found_kinds(value, ids):
    """The identifier kinds privacy_problems reports at one planted value: data
    and integers by their bytes, strings in their line's text."""
    where = " found at line 2" + (" AppleHPMDeviceHALType3/x" if value["t"] in ("data", "int") else "")
    return {p.split(" found")[0] for p in sc.privacy_problems(wrap([entry(ROOT, [["x", value]])]), ids)
            if p.endswith(where)}


def data(b):
    return {"t": "data", "len": len(b), "hex": b.hex()}


class IdentifierForms(unittest.TestCase):
    """Forms are generated, not listed: listing them by hand missed the chip ID
    twice (big-endian in the boot manifest and in SMC key RECI, PR 693)."""

    def test_every_generated_form_found(self):
        ids = sc.identifier_forms(**SAMPLE)
        self.assertEqual(set(ids), {"mac serial", "platform uuid", "chip id", "built-in network address",
                                    "own bluetooth address", "home folder", "user name"})
        for kind, forms in sorted(ids.items()):
            for form in (f for f in forms if not isinstance(f, sc.Exact)):  # whole-value forms: their own tests
                with self.subTest(kind=kind, form=form.hex()):
                    self.assertIn(kind, found_kinds(data(b"\x11\x22" + form + b"\x33\x44"), ids))

    def test_known_encodings_found(self):
        # Written out here, not taken from the generator, so a form it stops
        # producing fails this test.
        ids = sc.identifier_forms(**SAMPLE)
        chip_be = CHIP_LE[::-1]
        uuid = bytes.fromhex(SAMPLE["uuids"][0].replace("-", ""))
        efi = uuid[3::-1] + uuid[5:3:-1] + uuid[7:5:-1] + uuid[8:]
        cases = [
            ("chip id", data(b"\x16\x04ECID\x02\x07" + chip_be.lstrip(b"\0") + b"\xa0\x1f")),  # Image4 manifest, DER
            ("chip id", {"t": "str", "v": "ecid %d" % int.from_bytes(CHIP_LE, "little")}),
            ("chip id", {"t": "str", "v": "ECID:0x%X" % int.from_bytes(CHIP_LE, "little")}),
            ("chip id", {"t": "int", "bits": 64, "hex": chip_be.hex()}),
            ("mac serial", data("C02XYZ1234QW".encode("utf-16-le"))),  # Intel /efi/platform SystemSerialNumber
            ("mac serial", {"t": "str", "v": "sn c02xyz1234qw"}),
            ("platform uuid", data(b"\x01" + efi + b"\x02")),  # Intel system-id and SMBIOS type 1
            ("platform uuid", {"t": "str", "v": SAMPLE["uuids"][0].lower()}),
            ("built-in network address", {"t": "str", "v": "A4-B1-C2-D3-E4-F5"}),
            ("built-in network address", data(b"\x00" + bytes.fromhex("f5e4d3c2b1a4"))),
            ("own bluetooth address", {"t": "str", "v": "f0b3ec123456"}),
        ]
        for kind, value in cases:
            with self.subTest(kind=kind, value=value):
                self.assertIn(kind, found_kinds(value, ids))

    def test_reci_in_a_raw_bytes_field(self):
        # 53_smc_keys: SMC key RECI holds the chip ID big-endian.
        head = {"record": "header", "format": 1, "probe": "53_smc_keys"}
        rec = {"record": "smc_key", "index": 7, "key": "52454349", "bytes": CHIP_LE[::-1].hex()}
        problems = sc.privacy_problems([head, rec], sc.identifier_forms(**SAMPLE))
        self.assertTrue(any(p.startswith("chip id found at line 2 smc_key.bytes") for p in problems))

    def test_short_identifier_gives_no_short_text(self):
        # An address with four zero bytes strips to 2 bytes: its hex ("12ab")
        # and decimal ("4779") would match countless unrelated values. It is
        # still the Mac's, as a whole value.
        ids = sc.identifier_forms(networks=[bytes.fromhex("0000000012ab")])
        self.assertEqual(found_kinds({"t": "str", "v": "rev 12ab, 4779 mA"}, ids), set())
        self.assertIn("built-in network address", found_kinds(data(bytes.fromhex("0000000012ab")), ids))

    def test_shared_bytes_not_dropped(self):
        # The mini's Thunderbolt IP addresses share 5 bytes and one ends in 00
        # (PR 693 rerun): a form holding a shorter one is redundant only when
        # the rest of it is zero, or '0' in a text form. Each address keeps a
        # form with all 6 of its bytes, and is matched whole as a value.
        a, b, c = (bytes.fromhex(h) for h in ("025a6b7c8d00", "025a6b7c8d05", "025a6b7c8d30"))
        forms = sc.identifier_forms(networks=[a, b, c])["built-in network address"]
        for addr in (b, c):
            with self.subTest(addr=addr.hex()):
                self.assertIn(addr, [f for f in forms if not isinstance(f, sc.Exact)])
                self.assertIn(addr, [f for f in forms if isinstance(f, sc.Exact)])

    def test_utf16_forms_kept(self):
        # A UTF-16 form is exactly half zero bytes: the majority rule must keep it.
        forms = sc.identifier_forms(serials=["C02XYZ1234QW"])["mac serial"]
        self.assertIn("C02XYZ1234QW".encode("utf-16-le"), forms)
        self.assertIn("C02XYZ1234QW".encode("utf-16-be"), forms)


class RecordTypes(unittest.TestCase):
    def power(self, body):
        head = {"record": "header", "format": 1, "probe": "54_power_sources"}
        foot = {"record": "footer", "status": "complete", "reason": None, "step": None, "records": len(body), "withheld": 0}
        return [head] + body + [foot]

    def test_each_probe_has_its_own_record_types(self):
        good = self.power([{"record": "adapter", "details": None}, {"record": "providing_type", "value": None}])
        self.assertEqual(sc.validate_records(good), [])
        bad = self.power([{"record": "entry", "id": "0x1", "class": "X", "props": {"t": "dict", "v": []}}])
        self.assertTrue(any("unknown record 'entry'" in p for p in sc.validate_records(bad)))

    def test_unknown_probe(self):
        bad = [{"record": "header", "format": 1, "probe": "99_nothing"},
               {"record": "footer", "status": "complete", "reason": None, "step": None, "records": 0, "withheld": 0}]
        self.assertTrue(any("unknown probe '99_nothing'" in p for p in sc.validate_records(bad)))

    def test_format_doc_lists_the_same_records(self):
        # FORMAT.md is the contract; the checker must agree with it name for name.
        doc = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "probes", "test-kit", "FORMAT.md")
        with open(doc, encoding="utf-8") as f:
            text = f.read()
        self.assertEqual(sc.format_doc_record_types(text), sc.RECORD_TYPES)
        # The same for the footer's step names: the gathering steps that can
        # stop a probe, listed once under Privacy.
        self.assertEqual(sc.format_doc_gather_steps(text), sc.GATHER_STEPS)
        self.assertTrue(sc.GATHER_STEPS)


class Compare(unittest.TestCase):
    def test_clean_and_signed_32_bit(self):
        self.assertEqual(sc.compare(GOOD, ioreg(), ioreg(), set())[0], [])

    def test_process_name_compared_without_its_pid(self):
        # The probe writes "pid N, name" as "name" for the process-owner keys;
        # vs-ioreg rewrites the live value the same way before comparing.
        snap = wrap([entry(ROOT, []), entry(CHILD, [["UsbExclusiveOwner", {"t": "str", "v": "someapp"}]]), link(ROOT, None), link(CHILD, ROOT)])
        live = {"IOService": {1: ({}, set()), 2: ({"UsbExclusiveOwner": "pid 123, someapp"}, {1})}}
        self.assertEqual(sc.compare(snap, live, live, set())[0], [])
        other = wrap([entry(ROOT, []), entry(CHILD, [["UsbExclusiveOwner", {"t": "str", "v": "otherapp"}]]), link(ROOT, None), link(CHILD, ROOT)])
        self.assertEqual(sc.compare(other, live, live, set())[0], ["entry 0x2: property 'UsbExclusiveOwner' differs from ioreg"])
        # A driver name (no prefix) and a key outside the rule are compared as they are.
        driver = {"IOService": {1: ({}, set()), 2: ({"UsbExclusiveOwner": "AppleUSB20Hub"}, {1})}}
        plain = wrap([entry(ROOT, []), entry(CHILD, [["UsbExclusiveOwner", {"t": "str", "v": "AppleUSB20Hub"}]]), link(ROOT, None), link(CHILD, ROOT)])
        self.assertEqual(sc.compare(plain, driver, driver, set())[0], [])
        self.assertEqual(sc.process_name("pid 123, someapp"), "someapp")
        self.assertEqual(sc.process_name("pid 123,someapp"), "pid 123,someapp")

    def test_missing_entry(self):
        bad = [r for r in GOOD if not (r.get("record") == "entry" and r["id"] == CHILD)]
        self.assertTrue(any("missing from the snapshot" in p for p in sc.compare(bad, ioreg(), ioreg(), set())[0]))

    def test_skipped_entry_not_missing(self):
        # A process connection the probe skips on purpose is not a missing
        # entry: it has its marker entry and its links, and no properties to compare.
        held = wrap([entry(ROOT, []), link(ROOT, None), skipped_entry(CHILD), link(CHILD, ROOT)], skipped=[CHILD])
        problems, counts = sc.compare(held, ioreg(), ioreg(), {2})
        self.assertEqual(problems, [])
        self.assertEqual((counts["entries_checked"], counts["skips_verified"]), (1, 1))

    def test_skipped_connection_must_have_its_entry_and_links(self):
        # The F1 shape of the last review: the connection skipped with no entry
        # and no link, so what hangs beneath it was an island.
        no_entry = wrap([entry(ROOT, []), link(ROOT, None)], skipped=[CHILD])
        self.assertEqual(sc.compare(no_entry, ioreg(), ioreg(), {2})[0],
                         ["IOService: skipped 0x2 has no entry record", "IOService: link 0x2 -> parent 0x1 missing"])
        no_link = wrap([entry(ROOT, []), link(ROOT, None), skipped_entry(CHILD)], skipped=[CHILD])
        self.assertEqual(sc.compare(no_link, ioreg(), ioreg(), {2})[0], ["IOService: link 0x2 -> parent 0x1 missing"])

    def test_skipped_hardware_is_a_problem(self):
        # The probe's own skip list is not taken on trust (PR 693 review: a
        # build that also skipped IOHIDDevice or IOMedia passed): an entry
        # that is not a process connection, under a recorded parent, must be there.
        held = wrap([entry(ROOT, []), link(ROOT, None), skipped_entry(CHILD), link(CHILD, ROOT)], skipped=[CHILD])
        self.assertTrue(any("skipped 0x2 is not a process connection" in p for p in sc.compare(held, ioreg(), ioreg(), set())[0]))

    def test_beneath_a_process_connection_is_recorded(self):
        # Only the connection itself is skipped (Darryl, 2026-10-07: keep the
        # accessories): what hangs beneath it is recorded, linked to the
        # connection's ID. Skipping it with the connection was rounds 1 and 2's rule.
        live = {"IOService": {1: ({}, set()), 2: ({}, {1}), 3: ({}, {2})}}
        held = wrap([entry(ROOT, []), link(ROOT, None), skipped_entry(CHILD), link(CHILD, ROOT), entry("0x3", []), link("0x3", CHILD)],
                    skipped=[CHILD])
        self.assertEqual(sc.compare(held, live, live, {2})[0], [])
        old_rule = wrap([entry(ROOT, []), link(ROOT, None), skipped_entry(CHILD), link(CHILD, ROOT)], skipped=[CHILD, "0x3"])
        self.assertEqual([p[:22] for p in sc.compare(old_rule, live, live, {2})[0]], ["IOService: skipped 0x3"])
        # A connection recorded with its properties is the opposite fault.
        recorded = wrap([entry(ROOT, []), link(ROOT, None), entry(CHILD, []), link(CHILD, ROOT), entry("0x3", []), link("0x3", CHILD)])
        self.assertEqual([p[:33] for p in sc.compare(recorded, live, live, {2})[0]], ["IOService: process connection 0x2"])

    def test_skipped_property_not_compared(self):
        # NVRAM boot state is recorded as skipped on purpose: not a difference from ioreg.
        held = wrap([entry(ROOT, []), entry(CHILD, [["Priority", {"t": "skipped"}], ["Name", {"t": "str", "v": "port"}]]),
                     link(ROOT, None), link(CHILD, ROOT)], skipped_props=[["X: Priority", 1]])
        problems, counts = sc.compare(held, ioreg(), ioreg(), set())
        self.assertEqual(problems, [])
        self.assertEqual(counts["values_skipped"], 1)

    def test_part_withheld_compares_other_bytes(self):
        # Only the blanked bytes are exempt: the rest must still match ioreg.
        def snap(hexv):
            return wrap([entry(ROOT, []), entry(CHILD, [["Priority", int32(-500)], ["Name", {"t": "data", "len": 4, "hex": hexv, "withheld": [[1, 2]]}]]),
                         link(ROOT, None), link(CHILD, ROOT)], withheld=1)
        live = ioreg(name=bytes.fromhex("aabbccdd"))
        problems, counts = sc.compare(snap("aa0000dd"), live, live, set())
        self.assertEqual(problems, [])
        self.assertEqual(counts["values_withheld"], 1)
        self.assertTrue(any("'Name' differs" in p for p in sc.compare(snap("ff0000dd"), live, live, set())[0]))

    def test_every_plane_compared(self):
        # Not only the five planes the checks once named: whatever the registry lists.
        live = dict(ioreg(), CoreCapture={1: ({}, set()), 3: ({}, {1})})
        self.assertTrue(any(p.startswith("CoreCapture: entry 0x3") for p in sc.compare(GOOD, live, live, set())[0]))

    def test_missing_link(self):
        bad = [r for r in GOOD if not (r.get("record") == "link" and r["id"] == CHILD)]
        self.assertTrue(any("link 0x2 -> parent 0x1 missing" in p for p in sc.compare(bad, ioreg(), ioreg(), set())[0]))

    def test_different_value(self):
        self.assertTrue(any("differs" in p for p in sc.compare(GOOD, ioreg(name="other"), ioreg(name="other"), set())[0]))

    def test_volatile_value_ignored(self):
        self.assertEqual(sc.compare(GOOD, ioreg(name="before"), ioreg(name="after"), set())[0], [])

    def test_volatile_gpu_counters_ignored(self):
        # Live GPU counters change and change back between the two ioreg exports
        # (MacBook, 2026-10-07): a snapshot value between them is not a fault.
        held = wrap([entry(ROOT, []), entry(CHILD, [["Priority", int32(-500)], ["Name", {"t": "str", "v": "port"}],
                                                     ["AGCInfo", {"t": "str", "v": "during"}],
                                                     ["SchedulerState", {"t": "str", "v": "during"}]]),
                     link(ROOT, None), link(CHILD, ROOT)])
        live = {"IOService": {1: ({}, set()), 2: ({"Priority": 0xFFFFFFFFFFFFFE0C, "Name": "port",
                                                   "AGCInfo": "export", "SchedulerState": "export"}, {1})}}
        self.assertEqual(sc.compare(held, live, live, set())[0], [])

    def test_missing_key(self):
        bad = wrap([entry(ROOT, []), entry(CHILD, [["Name", {"t": "str", "v": "port"}]]), link(ROOT, None), link(CHILD, ROOT)])
        self.assertTrue(any("'Priority' missing" in p for p in sc.compare(bad, ioreg(), ioreg(), set())[0]))

    def test_missing_key_excused_only_when_it_holds_an_identifier(self):
        # Codex, last review of PR 693: a withheld dictionary key excused any
        # missing property, by count. Only a live key that itself holds one of
        # the Mac's identifiers (the forms the privacy check generates, so its
        # pair was withheld whole) is excused, one per withheld pair.
        ids = sc.identifier_forms(networks=[bytes.fromhex("a4b1c2d3e4f5")])
        pair = [{"t": "withheld"}, {"t": "withheld"}]

        def snap(pairs):
            return wrap([entry(ROOT, []), entry(CHILD, pairs + [["Name", {"t": "str", "v": "port"}]]), link(ROOT, None), link(CHILD, ROOT)],
                        withheld=len(pairs))

        def live(**keys):
            return {"IOService": {1: ({}, set()), 2: (dict(keys, Name="port"), {1})}}
        named = live(**{"a4:b1:c2:d3:e4:f5": 1})
        self.assertEqual(sc.compare(snap([pair]), named, named, set(), ids)[0], [])
        unrelated = live(Priority=1)
        self.assertEqual(sc.compare(snap([pair]), unrelated, unrelated, set(), ids)[0], ["entry 0x2: property 'Priority' missing"])
        both = live(Priority=1, **{"a4:b1:c2:d3:e4:f5": 1})
        self.assertEqual(sc.compare(snap([pair, pair]), both, both, set(), ids)[0], ["entry 0x2: property 'Priority' missing"])
        # An identifier-named key missing without a withheld pair for it is a gap too.
        self.assertEqual(sc.compare(snap([]), named, named, set(), ids)[0], ["entry 0x2: property 'a4:b1:c2:d3:e4:f5' missing"])
        # Without the identifiers nothing is excused.
        self.assertEqual(sc.compare(snap([pair]), named, named, set())[0], ["entry 0x2: property 'a4:b1:c2:d3:e4:f5' missing"])

    def test_withheld_counted_not_failed(self):
        held = wrap([entry(ROOT, []), entry(CHILD, [["Priority", {"t": "withheld"}], ["Name", {"t": "str", "v": "port"}]]),
                     link(ROOT, None), link(CHILD, ROOT)])
        problems, counts = sc.compare(held, ioreg(), ioreg(), set())
        self.assertEqual(problems, [])
        self.assertEqual(counts["values_withheld"], 1)


class MacBookShapes(unittest.TestCase):
    """The registry shapes that broke rounds 1 and 2 of PR 693 on the MacBook,
    which the two-node single-plane fixture above could not express: a user
    client nested in another's subtree, a virtual HID device (a Bluetooth
    accessory) beneath a user client, and an entry reachable through IOPower
    whose IOService parent sits beneath a user client. Each check must fail on
    a planted fault in these shapes, not only on the mini's registry.

    IOService: root 1 > IOHIDResourceDeviceUserClient 2 > IOHIDUserDevice 3
               > IOHIDInterface 4 > { IOHIDEventServiceUserClient 5, AppleMesaAccessory 6 }
    IOPower:   root 1 > AppleMesaAccessory 6
    Instances (what IOKit says conforms to IOUserClient): 2 and 5. Each keeps
    its class and its place: a marker entry and its links, no properties."""
    LIVE = {"IOService": {1: ({}, set()), 2: ({}, {1}), 3: ({}, {2}), 4: ({}, {3}), 5: ({}, {4}), 6: ({}, {4})},
            "IOPower": {1: ({}, set()), 6: ({}, {1})}}
    INSTANCES = {2, 5}

    def snapshot(self, recorded=("0x1", "0x3", "0x4", "0x6"), skipped=("0x2", "0x5"), markers=("0x2", "0x5"), drop_links=()):
        links = [link("0x1", None), link("0x2", "0x1"), link("0x3", "0x2"), link("0x4", "0x3"), link("0x5", "0x4"), link("0x6", "0x4"),
                 link("0x1", None, "IOPower"), link("0x6", "0x1", "IOPower")]
        body = [entry(i, []) for i in recorded] + [skipped_entry(i) for i in markers] + \
            [l for l in links if (l["id"], l["parent"], l["plane"]) not in drop_links]
        return wrap(body, skipped=list(skipped))

    def test_accessories_beneath_user_clients_pass(self):
        problems, counts = sc.compare(self.snapshot(), self.LIVE, self.LIVE, self.INSTANCES)
        self.assertEqual(problems, [])
        self.assertEqual(counts["skips_verified"], 2)
        self.assertEqual(counts["entries_checked"], 4)
        self.assertEqual(sc.validate_records(self.snapshot()), [])

    def test_connection_without_its_entry_is_an_island(self):
        # F1 of the last review: the connection skipped with no entry and no
        # link, so a walk down from the root never reaches the accessory.
        island = self.snapshot(markers=(), drop_links={("0x2", "0x1", "IOService"), ("0x5", "0x4", "IOService")})
        self.assertEqual(sorted(sc.compare(island, self.LIVE, self.LIVE, self.INSTANCES)[0]),
                         ["IOService: link 0x2 -> parent 0x1 missing", "IOService: link 0x5 -> parent 0x4 missing",
                          "IOService: skipped 0x2 has no entry record", "IOService: skipped 0x5 has no entry record"])
        self.assertIn("IOService: 3 entries not reachable from the root through links", sc.validate_records(island))

    def test_nested_user_client_must_be_an_instance(self):
        # Round 1's reader took the top-level nodes of `ioreg -r -c IOUserClient`
        # and missed the inner one: the probe skipped 5, the allowed set lacked it.
        problems = sc.compare(self.snapshot(), self.LIVE, self.LIVE, {2})[0]
        self.assertEqual(problems, ["IOService: skipped 0x5 is not a process connection"])

    def test_virtual_hid_device_skipped_with_its_user_client(self):
        # The old subtree rule: everything beneath 2 left out. Every entry it
        # dropped is flagged, in every plane it appears in.
        old_rule = self.snapshot(recorded=("0x1",), skipped=("0x2", "0x3", "0x4", "0x5", "0x6"),
                                 drop_links={("0x3", "0x2", "IOService"), ("0x4", "0x3", "IOService"),
                                             ("0x6", "0x4", "IOService"), ("0x6", "0x1", "IOPower")})
        problems = sc.compare(old_rule, self.LIVE, self.LIVE, self.INSTANCES)[0]
        self.assertEqual(sorted(problems), ["IOPower: skipped 0x6 is not a process connection",
                                            "IOService: skipped 0x3 is not a process connection",
                                            "IOService: skipped 0x4 is not a process connection",
                                            "IOService: skipped 0x6 is not a process connection"])

    def test_virtual_hid_device_missing(self):
        # Neither recorded nor listed as skipped: a plain gap.
        gap = self.snapshot(recorded=("0x1", "0x4", "0x6"), drop_links={("0x3", "0x2", "IOService")})
        problems = sc.compare(gap, self.LIVE, self.LIVE, self.INSTANCES)[0]
        self.assertEqual(problems, ["IOService: entry 0x3 present before and after, missing from the snapshot"])

    def test_cross_plane_entry_keeps_its_service_link(self):
        # The F1 mechanism: 6 recorded through IOPower, its IOService parent 4
        # beneath a user client. The link 6 -> 4 must be there, in IOService.
        no_link = self.snapshot(drop_links={("0x6", "0x4", "IOService")})
        problems = sc.compare(no_link, self.LIVE, self.LIVE, self.INSTANCES)[0]
        self.assertEqual(problems, ["IOService: link 0x6 -> parent 0x4 missing"])
        # And the old per-plane rule, which recorded 6 only because IOPower
        # reached it, is flagged for 3 and 4 as well as the link.
        per_plane = self.snapshot(recorded=("0x1", "0x6"), skipped=("0x2", "0x3", "0x4", "0x5"),
                                  drop_links={("0x3", "0x2", "IOService"), ("0x4", "0x3", "IOService"), ("0x6", "0x4", "IOService")})
        problems = sc.compare(per_plane, self.LIVE, self.LIVE, self.INSTANCES)[0]
        self.assertEqual(sorted(problems), ["IOService: link 0x6 -> parent 0x4 missing",
                                            "IOService: skipped 0x3 is not a process connection",
                                            "IOService: skipped 0x4 is not a process connection"])


class FakeIOKit:
    """A synthetic registry answering the reader's ctypes calls, so the reader
    is tested on a fixed tree whatever this Mac holds tonight (F1 of the Opus
    review after extra pass 1: a return to round 1's `ioreg -r -c` reader
    passed the live test whenever no connection sat inside another's subtree).
    tree: parent id -> child ids, rooted at 1; conforms: id -> class names
    IOObjectConformsTo answers yes to. Handles are small integers; an out
    argument arrives as ctypes.byref(x), whose _obj is x."""

    def __init__(self, tree, conforms):
        self.tree, self.conforms, self.handles, self.calls = tree, conforms, {}, []

    def _handle(self, what):
        h = 100 + len(self.handles)
        self.handles[h] = what
        return h

    def IORegistryCreateIterator(self, port, plane, options, it_ref):
        self.calls.append(("iterator", plane, options))
        order = []
        stack = list(reversed(self.tree.get(1, [])))
        while stack:
            eid = stack.pop()
            order.append(eid)
            if options & 1:  # kIORegistryIterateRecursively
                stack.extend(reversed(self.tree.get(eid, [])))
        it_ref._obj.value = self._handle(iter(order))
        return 0

    def IOIteratorNext(self, it):
        try:
            return self._handle(next(self.handles[it]))
        except StopIteration:
            return 0

    def IOIteratorIsValid(self, it):
        return 1

    def IOObjectConformsTo(self, h, cls):
        return int(cls.decode() in self.conforms.get(self.handles[h], ()))

    def IORegistryEntryGetRegistryEntryID(self, h, eid_ref):
        eid_ref._obj.value = self.handles[h]
        return 0

    def IOObjectRelease(self, h):
        pass


class ReaderShapes(unittest.TestCase):
    """process_connection_ids on the fake registry: every entry IOKit calls a
    process connection, wherever it sits.
    root 1 > { IOUserClient 2 > IOHIDUserDevice 6 > IOUserClient 3, IODTNVRAMDiags 4, plain 5 }"""
    TREE = {1: [2, 4, 5], 2: [6], 6: [3]}
    CONFORMS = {2: {"IOUserClient"}, 3: {"IOUserClient"}, 4: {"IODTNVRAMDiags"}}

    def test_reader_returns_every_instance_nested_included(self):
        fake = FakeIOKit(self.TREE, self.CONFORMS)
        real = sc.iokit
        sc.iokit = lambda: fake
        try:
            ids = sc.process_connection_ids(["IOService"])
        finally:
            sc.iokit = real
        self.assertEqual(ids, {2, 3, 4})
        self.assertEqual(fake.calls, [("iterator", b"IOService", 1)])


@unittest.skipUnless(sys.platform == "darwin", "reads this Mac's registry through IOKit")
class LiveReader(unittest.TestCase):
    """The checker's own IOKit reader and its wiring (F2 of the last PR 693
    review): the allowed skip set comes from a recursive walk of the live
    registry, never from the probe's own skip list. Live, so the mutants the
    synthetic fixtures let through (a non-recursive walk, trusting the probe)
    fail here. Counts only: no identifier value is read or printed."""

    def test_reader_finds_connections_nested_below_the_root(self):
        # A non-recursive walk sees only the root's children (one on the mini,
        # IOPlatformExpertDevice): the instances must include deeper ones.
        root = plistlib.loads(subprocess.run(["ioreg", "-a", "-d", "2", "-p", "IOService"], capture_output=True, check=True).stdout)
        top = {c["IORegistryEntryID"] for c in root.get("IORegistryEntryChildren", [])} | {root["IORegistryEntryID"]}
        ids = sc.process_connection_ids(["IOService"])
        self.assertTrue(ids, "no process connection found in IOService")
        self.assertTrue(ids - top, "every instance found is the root or one of its direct children")

    def test_vs_ioreg_does_not_trust_the_probe_skip_list(self):
        # A probe whose skip list names an entry IOKit does not call a process
        # connection is caught by the whole vs-ioreg path, with the live reader
        # supplying the allowed set and a synthetic export standing in for ioreg.
        live = {"IOService": {1: ({}, set()), 2: ({}, {1})}}
        export = {"IORegistryEntryID": 1, "IORegistryEntryChildren": [{"IORegistryEntryID": 2}]}
        over_skipped = wrap([entry(ROOT, []), link(ROOT, None), skipped_entry(CHILD), link(CHILD, ROOT)], skipped=[CHILD])
        recorded = wrap([entry(ROOT, []), link(ROOT, None), entry(CHILD, []), link(CHILD, ROOT)])
        real = sc.registry_planes, sc.ioreg_plane
        sc.registry_planes, sc.ioreg_plane = lambda: ["IOService"], lambda plane: export
        try:
            with tempfile.TemporaryDirectory() as d:
                for name, records, want in (("over", over_skipped, ["IOService: skipped 0x2 is not a process connection"]), ("ok", recorded, [])):
                    with self.subTest(name):
                        data, probe = os.path.join(d, name + ".jsonl"), os.path.join(d, name + ".sh")
                        with open(data, "w") as f:
                            f.write("".join(json.dumps(r) + "\n" for r in records))
                        with open(probe, "w") as f:
                            f.write("#!/bin/sh\nexec cat %s\n" % data)
                        os.chmod(probe, stat.S_IRWXU)
                        problems, counts = sc.run_vs_ioreg(probe)
                        self.assertEqual(problems, want)
                        self.assertEqual(sc.compare(records, live, live, set())[0], want)
        finally:
            sc.registry_planes, sc.ioreg_plane = real


class Privacy(unittest.TestCase):
    IDS = {"mac serial": [b"C02XYZ1234"], "built-in network address": [bytes.fromhex("a4b1c2d3e4f5"), b"a4b1c2d3e4f5"]}

    def test_clean(self):
        self.assertEqual(sc.privacy_problems(GOOD, self.IDS), [])

    def test_planted_in_string(self):
        bad = wrap([entry(ROOT, [["x", {"t": "str", "v": "serial C02XYZ1234"}]])])
        self.assertTrue(any(p.startswith("mac serial found") for p in sc.privacy_problems(bad, self.IDS)))

    def test_planted_in_data(self):
        bad = wrap([entry(ROOT, [["x", {"t": "data", "len": 8, "hex": "00a4b1c2d3e4f500"}]])])
        self.assertTrue(any(p.startswith("built-in network address found") for p in sc.privacy_problems(bad, self.IDS)))

    def test_planted_in_integer(self):
        bad = wrap([entry(ROOT, [["EntityID", {"t": "int", "bits": 64, "hex": "a4b1c2d3e4f50001"}]])])
        self.assertTrue(any(p.startswith("built-in network address found") for p in sc.privacy_problems(bad, self.IDS)))

    def test_planted_in_raw_bytes_field(self):
        # The small probes write raw bytes as plain hex fields (53_smc_keys "bytes").
        head = {"record": "header", "format": 1, "probe": "53_smc_keys"}
        rec = {"record": "smc_key", "index": 0, "key": "52534e20", "bytes": b"xC02XYZ1234x".hex()}
        self.assertTrue(any(p.startswith("mac serial found") for p in sc.privacy_problems([head, rec], self.IDS)))

    def test_near_empty_address_matched_only_whole(self):
        # A near-empty own network address (one real byte, five zeros; the
        # MacBook's Thunderbolt Bridge) is still the Mac's: a data value that
        # is exactly it is a leak. Inside a longer value, or as a small
        # integer, it is a coincidence and must not be flagged.
        ids = sc.identifier_forms(networks=[bytes.fromhex("820000000000")])

        def found(value):
            return any(p.startswith("built-in network address found")
                       for p in sc.privacy_problems(wrap([entry(ROOT, [["x", value]])]), ids))
        self.assertTrue(found({"t": "data", "len": 6, "hex": "820000000000"}))
        self.assertTrue(found({"t": "data", "len": 6, "hex": "000000000082"}))
        self.assertFalse(found({"t": "data", "len": 7, "hex": "00820000000000"}))
        self.assertFalse(found({"t": "int", "bits": 64, "hex": "0000000000000082"}))

    def test_identifier_not_read_is_a_problem(self):
        # A kind the Mac has but the checker failed to read would make privacy green from no data.
        ids = {"mac serial": [b"x"], "platform uuid": [b"x"], "home folder": [b"x"], "built-in network address": [b"x"],
               "user name": [b"x"]}
        gaps = sc.identifier_gaps(ids, {"mac-address-bluetooth0", "mac-address-wifi0"}, set())
        self.assertTrue(any("own bluetooth address" in p for p in gaps))
        self.assertEqual(sc.identifier_gaps(dict(ids, **{"own bluetooth address": [b"x"]}), {"mac-address-bluetooth0", "mac-address-wifi0"}, set()), [])
        # The Bluetooth kind is required whenever the live registry has a
        # Bluetooth controller (Codex x1 #1: an Intel Mac has the controller
        # and no /chosen key), not only when /chosen advertises the address.
        gaps = sc.identifier_gaps(ids, {"mac-address-wifi0"}, {"IOBluetoothHCIController"})
        self.assertTrue(any("own bluetooth address" in p for p in gaps))
        self.assertEqual([p for p in sc.identifier_gaps(ids, {"mac-address-wifi0"}, set()) if "bluetooth" in p], [])

    def test_paired_bluetooth_kept_count(self):
        paired = [bytes.fromhex("112233445566"), bytes.fromhex("aabbccddeeff")]
        snap = wrap([entry(ROOT, [["BluetoothUHEDevices", {"t": "data", "len": 14, "hex": "000000000000" + "0000" + "112233445566",
                                                           "withheld": [[0, 6]]}]])], withheld=1)
        self.assertEqual(sc.paired_kept(snap, paired), 1)

    def test_small_probe_skips_snapshot_only_checks(self):
        # Device serials and volume UUIDs live in the snapshot; a small probe's
        # privacy check must not demand them.
        head = {"record": "header", "format": 1, "probe": "54_power_sources"}
        foot = {"record": "footer", "status": "complete", "reason": None, "step": None, "records": 0, "withheld": 0}
        ids = {"mac serial": [b"C02XYZ1234"], "platform uuid": [b"x"], "home folder": [b"x"], "user name": [b"x"]}
        self.assertEqual(sc.privacy_all([head, foot], ids, set()), [])

    def test_privacy_fails_on_a_broken_file(self):
        # Nothing to search is not a pass (Codex rerun of PR 693): an empty,
        # headerless or footerless capture fails privacy as well as validate.
        head = {"record": "header", "format": 1, "probe": "54_power_sources"}
        rec = {"record": "providing_type", "value": None}
        foot = {"record": "footer", "status": "complete", "reason": None, "step": None, "records": 1, "withheld": 0}
        ids = {"mac serial": [b"C02XYZ1234"], "platform uuid": [b"x"], "home folder": [b"x"], "user name": [b"x"]}
        self.assertEqual(sc.privacy_all([head, rec, foot], ids, set()), [])
        for name, records in (("empty", []), ("headerless", [rec, foot]), ("footerless", [head, rec])):
            with self.subTest(name):
                self.assertTrue(sc.privacy_all(records, ids, set()))

    def test_privacy_judges_a_capped_file_on_its_content(self):
        # A run the byte cap stopped is structurally sound and is judged on what
        # it holds (PR 693 final review): being stopped is not a privacy problem,
        # an identifier in it still is, and no other stop reason is excused.
        head = {"record": "header", "format": 1, "probe": "54_power_sources"}
        rec = {"record": "providing_type", "value": {"t": "str", "v": "AC Power"}}
        leak = {"record": "providing_type", "value": {"t": "str", "v": "serial C02XYZ1234"}}
        ids = {"mac serial": [b"C02XYZ1234"], "platform uuid": [b"x"], "home folder": [b"x"], "user name": [b"x"]}

        def capped(body, reason="byte_cap"):
            step = "chosen" if reason == "identifiers_incomplete" else None
            return [head] + body + [{"record": "footer", "status": "stopped", "reason": reason, "step": step, "records": len(body), "withheld": 0}]
        self.assertEqual(sc.privacy_all(capped([rec]), ids, set()), [])
        self.assertEqual(sc.privacy_all(capped([leak]), ids, set()), ["mac serial found at line 2"])
        self.assertTrue(any("no_root" in p for p in sc.privacy_all(capped([rec], "no_root"), ids, set())))
        self.assertTrue(any("identifiers_incomplete" in p for p in sc.privacy_all(capped([], "identifiers_incomplete"), ids, set())))
        self.assertTrue(any("byte_cap" in p for p in sc.validate_records(capped([rec]))))

    def test_capped_snapshot_skips_the_live_kept_checks(self):
        # The kept checks compare with the live registry: in a capped snapshot a
        # device serial can be missing because the cap refused its record, not
        # because it was withheld. A withheld join key is still caught.
        ids = {"mac serial": [b"C02XYZ1234"], "platform uuid": [b"4C4C4544"], "home folder": [b"/Users/jdoe"], "user name": [b"jdoe"]}
        body = [entry(ROOT, [["USB Serial Number", {"t": "withheld"}]]), link(ROOT, None)]
        capped = [GOOD[0]] + body + [{"record": "footer", "status": "stopped", "reason": "byte_cap", "step": None, "records": 2, "withheld": 0}]
        real = sc.kept_problems
        sc.kept_problems = lambda records: ["only 0 of 12 device serials kept unchanged"]
        try:
            self.assertEqual(sc.privacy_all(capped, ids, set()), ["line 2: join key 'USB Serial Number' withheld on AppleHPMDeviceHALType3"])
            self.assertIn("only 0 of 12 device serials kept unchanged", sc.privacy_all(GOOD, ids, set()))
        finally:
            sc.kept_problems = real

    def test_withheld_join_key(self):
        bad = wrap([entry(ROOT, [["UUID", {"t": "withheld"}]])])
        self.assertTrue(any("join key 'UUID' withheld" in p for p in sc.withheld_join_keys(bad)))

    def test_part_withheld_join_key(self):
        bad = wrap([entry(ROOT, [["UUID", {"t": "data", "len": 2, "hex": "0000", "withheld": [[0, 2]]}]])], withheld=1)
        self.assertTrue(any("join key 'UUID' withheld" in p for p in sc.withheld_join_keys(bad)))

    def test_part_withheld_not_counted_as_kept(self):
        props = {"t": "dict", "v": [["IOMACAddress", {"t": "data", "len": 6, "hex": "000000000000", "withheld": [[0, 6]]}],
                                    ["Child", {"t": "dict", "v": [["IOMACAddress", {"t": "data", "len": 6, "hex": "a4b1c2d3e4f5"}]]}]]}
        self.assertEqual(sc.count_key(props, "IOMACAddress", True), 1)

    def test_withheld_device_serial_flagged(self):
        # "Serial Number" (internal NVMe, disk images) is a device serial: kept,
        # top level or nested (2 of 3 on the mini are nested).
        top = wrap([entry(ROOT, [["Serial Number", {"t": "withheld"}]])])
        nested = wrap([entry(ROOT, [["Info", {"t": "dict", "v": [["Serial Number", {"t": "withheld"}]]}]])])
        self.assertTrue(any("join key 'Serial Number' withheld" in p for p in sc.withheld_join_keys(top)))
        self.assertTrue(any("join key 'Serial Number' withheld" in p for p in sc.withheld_join_keys(nested)))

    def test_user_name_found(self):
        ids = sc.identifier_forms(users=["jdoe", "Jane Doe"])
        bad = wrap([entry(ROOT, [["Owner", {"t": "str", "v": "Jane Doe's Mac"}]])])
        self.assertTrue(any(p.startswith("user name found") for p in sc.privacy_problems(bad, ids)))

    def test_attached_adapter_must_be_kept(self):
        # An adapter's address is not the Mac's: a withheld one is over-withholding.
        adapter = bytes.fromhex("0050b6a1b2c3")
        kept = wrap([entry(ROOT, [["IOMACAddress", {"t": "data", "len": 6, "hex": adapter.hex()}]])])
        held = wrap([entry(ROOT, [["IOMACAddress", {"t": "withheld"}]])], withheld=1)
        self.assertEqual(sc.adapter_problems(kept, [adapter]), [])
        self.assertTrue(any("adapter" in p for p in sc.adapter_problems(held, [adapter])))

    def test_withheld_volume_uuid_flagged(self):
        media = dict(entry(ROOT, [["UUID", {"t": "withheld"}]]), **{"class": "IOMedia"})
        self.assertTrue(any("join key 'UUID' withheld on IOMedia" in p for p in sc.withheld_join_keys(wrap([media]))))


if __name__ == "__main__":
    unittest.main()
