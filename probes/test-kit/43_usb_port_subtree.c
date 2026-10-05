// 43_usb_port_subtree.c - Full, unfiltered dump of every USB host controller's
// port subtree, the bare IOPort socket nodes, the IOPort registry plane, and
// the firmware (IODeviceTree) port nodes.
//
// Why this exists: USB-A sockets cannot be modelled from the data any other
// probe captures. What is missing (measured 2026-10-02): a host controller's
// root ports with ALL their properties, each port's IODeviceTree node, the
// bare `IOPort` socket nodes macOS 26 publishes for non-HPM ports (for example
// a Mac mini's front `Port-USB-C@5`), and the `IOPort` registry plane that
// links socket > transport > attached device. Probes 36 and 40 read curated
// keys or hub ports only; none walks root ports in full or reads the IOPort
// plane.
//
// Sections, in emit order (small and rare data first, so that if the byte
// budget is ever hit on a machine with many hubs it is the commodity
// controller subtree at the end that gets cut, not the novel data):
//   1. Registry planes: the root entry's IORegistryPlanes property.
//   2. IOPort plane: every entry, walked from the root, one line each
//      (depth, class, name, registry entry ID, location, IOService path).
//      Gated on "IOPort" being listed in IORegistryPlanes.
//   3. IOPort nodes: IOServiceMatching("IOPort"), which includes subclasses
//      (AppleHPMInterface*, AppleHDMIPortController, AppleSDXCSlot and so
//      on). Every match gets ALL its properties plus its direct IOService
//      children that conform to IOPortTransportState, each with ALL their
//      properties. The full HPM subtree is NOT walked: probes 03 and 35
//      already cover it and it is large. Bare (exact class) IOPort instances
//      are counted separately: the class exists on macOS 14 and 15 as an
//      ancestor, but bare instances were only seen on 26 and later.
//   4. IODeviceTree port nodes: every IODeviceTree entry whose name starts
//      with "port-" (port-usb-c-N, port-hdmi0, and whatever a USB-A Mac
//      publishes), with ALL properties and their IOService children.
//   5. USB host controllers: IOServiceMatching("AppleUSBHostController"),
//      the shared base of every XHCI, EHCI and VHCI family in the corpus
//      class census (probe 41), so every vendor subclass (AppleT8132USBXHCI,
//      AppleEmbeddedUSBXHCIFL1100, AppleEmbeddedUSBXHCIASMedia3142, ...) is
//      caught. Each controller's whole IOService subtree is walked in
//      IOService order. Controllers, root and hub ports (AppleUSBHostPort),
//      hubs (AppleUSBHub), devices (IOUSBDevice) and interfaces
//      (IOUSBInterface) get ALL their properties. Every other node (class
//      drivers, HID services, network interfaces, user clients) gets its
//      header and path only, and the walk continues beneath it. Why: in the
//      corpus, 32 of 388 probe 40 outputs hit that probe's 3 MiB budget, and
//      on the largest one (3,145,863 bytes) AppleUserHIDDevice and
//      AppleUserHIDEventService nodes, mostly their "Elements" and
//      "Keyboard" tables, were 3,071,957 bytes of it (measured 2026-10-02).
//      Dumping driver properties here would push this probe's port data past
//      the budget on those machines. Probe 40 already captures those driver
//      nodes in full. Each node also gets its IODeviceTree
//      path when it is a device tree entry (properties are per entry, so the
//      device tree node's properties ARE the table printed). Any UsbIOPort /
//      UsbTransportState path on a node is resolved and the target (and the
//      target's IOService parent, e.g. the port-usb-c-N device tree node) is
//      printed with ALL properties.
//
// Nothing is filtered by live or active flags: everything is dumped raw.
// Hardware identifiers (serials, UUIDs, locationIDs, registry entry IDs) are
// deliberately kept: they are the join keys.
//
// Every node header line has the same shape so tooling can parse it:
//   <indent>- class=<cls> name=<name> id=0x<entryID> loc=<location> [depth N]
// followed by "path:" (IOService) and, where present, "dt-path:" lines, then
// the property table in probe 40's format ("key": value, nested by indent).
//
// Plain unprivileged registry read: no entitlement, no device open, no USB
// control transfer.
//
// Overrides for exercising branches a given machine cannot reach:
//   -DMAX_BYTES=N              byte budget (default 3 MiB, under the
//                              runner's 6 MiB cap, over which output is
//                              discarded whole)
//   -DPROBE43_PORT_PLANE=\"X\"   plane name to treat as the IOPort plane
//   -DPROBE43_IOPORT_CLASS=\"X\" class to match as IOPort
//
// Compile: clang -framework IOKit -framework CoreFoundation -o 43_usb_port_subtree 43_usb_port_subtree.c

#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>

#ifndef MAX_BYTES
#define MAX_BYTES (3LL * 1024 * 1024)
#endif
#ifndef PROBE43_PORT_PLANE
#define PROBE43_PORT_PLANE "IOPort"
#endif
#ifndef PROBE43_IOPORT_CLASS
#define PROBE43_IOPORT_CLASS "IOPort"
#endif

static const long long kByteBudget = MAX_BYTES;
// Registry-node recursion cap (runaway backstop; real subtrees are ~15 deep).
static const int kMaxDepth = 48;
// CF property-value recursion cap.
static const int kMaxValueDepth = 100;
// Cap on entries of one property dictionary we will buffer.
static const size_t kMaxDictEntries = 20000;

static long long g_bytes = 0;
static int g_truncatedNoted = 0;

// Per-section visited set on registry entry IDs (a node with two providers is
// dumped once per walk). Same open-addressing scheme as probe 40.
#define kSeenCap 65536u   /* power of two */
static uint64_t g_seen[kSeenCap];
static size_t g_seenCount = 0;

static void resetSeen(void) {
    memset(g_seen, 0, sizeof(g_seen));
    g_seenCount = 0;
}

static int alreadySeen(io_registry_entry_t e) {
    uint64_t id = 0;
    if (IORegistryEntryGetRegistryEntryID(e, &id) != KERN_SUCCESS) return 0;
    if (id == 0) return 0;
    const size_t mask = kSeenCap - 1u;
    size_t h = (size_t)((id * 0x9E3779B97F4A7C15ULL) >> 48) & mask;
    for (size_t i = 0; i < kSeenCap; i++) {
        size_t slot = (h + i) & mask;
        if (g_seen[slot] == id) return 1;
        if (g_seen[slot] == 0) {
            if (g_seenCount < kSeenCap - 1u) {
                g_seen[slot] = id;
                g_seenCount++;
            }
            return 0;
        }
    }
    return 0;
}

// printf wrapper: counts bytes and goes silent once the budget is spent.
static int emitf(const char *fmt, ...) {
    if (g_bytes >= kByteBudget) return 0;
    va_list ap;
    va_start(ap, fmt);
    int n = vprintf(fmt, ap);
    va_end(ap);
    if (n > 0) g_bytes += n;
    return n;
}

static int overBudget(void) {
    if (g_bytes < kByteBudget) return 0;
    if (!g_truncatedNoted) {
        g_truncatedNoted = 1;
        printf("\n[output budget reached: remaining nodes omitted to stay under the collector cap]\n");
    }
    return 1;
}

static void indentf(int indent) {
    for (int j = 0; j < indent; j++) emitf("  ");
}

static void dumpValue(CFTypeRef value, int indent, int vdepth);

static void dumpDict(CFDictionaryRef dict, int indent, int vdepth) {
    if (vdepth > kMaxValueDepth) { emitf("<max value depth>\n"); return; }
    CFIndex count = CFDictionaryGetCount(dict);
    if (count <= 0) return;
    if ((size_t)count > kMaxDictEntries) {
        indentf(indent);
        emitf("<dictionary too large: %ld entries omitted>\n", (long)count);
        return;
    }
    const void **keys = malloc(sizeof(void*) * (size_t)count);
    const void **vals = malloc(sizeof(void*) * (size_t)count);
    if (!keys || !vals) {
        free(keys); free(vals);
        indentf(indent);
        emitf("<alloc failed>\n");
        return;
    }
    CFDictionaryGetKeysAndValues(dict, keys, vals);
    for (CFIndex i = 0; i < count; i++) {
        if (overBudget()) break;
        indentf(indent);
        if (keys[i] && CFGetTypeID(keys[i]) == CFStringGetTypeID()) {
            char buf[256];
            buf[0] = '\0';
            if (CFStringGetCString(keys[i], buf, sizeof(buf), kCFStringEncodingUTF8))
                emitf("\"%s\": ", buf);
            else
                emitf("<unconvertible-key>: ");
        } else {
            emitf("<key>: ");
        }
        dumpValue(vals[i], indent + 1, vdepth + 1);
    }
    free(keys);
    free(vals);
}

static void dumpValue(CFTypeRef value, int indent, int vdepth) {
    if (overBudget()) { printf("<truncated>\n"); return; }
    if (vdepth > kMaxValueDepth) { emitf("<max value depth>\n"); return; }
    if (!value) { emitf("null\n"); return; }
    CFTypeID tid = CFGetTypeID(value);

    if (tid == CFStringGetTypeID()) {
        char buf[2048];
        buf[0] = '\0';
        if (CFStringGetCString(value, buf, sizeof(buf), kCFStringEncodingUTF8))
            emitf("\"%s\"\n", buf);
        else
            emitf("<unconvertible string>\n");
    } else if (tid == CFNumberGetTypeID()) {
        long long n = 0;
        if (CFNumberGetValue(value, kCFNumberLongLongType, &n))
            emitf("%lld (0x%llx)\n", n, n);
        else
            emitf("<unconvertible number>\n");
    } else if (tid == CFBooleanGetTypeID()) {
        emitf("%s\n", CFBooleanGetValue(value) ? "true" : "false");
    } else if (tid == CFDataGetTypeID()) {
        CFIndex len = CFDataGetLength(value);
        const UInt8 *b = CFDataGetBytePtr(value);
        emitf("<data %ld>: ", (long)len);
        for (CFIndex i = 0; b && i < len; i++) {
            if (overBudget()) break;
            emitf("%02x", b[i]);
            if (i < len - 1 && (i + 1) % 4 == 0) emitf(" ");
        }
        emitf("\n");
    } else if (tid == CFArrayGetTypeID()) {
        CFIndex count = CFArrayGetCount(value);
        emitf("[\n");
        for (CFIndex i = 0; i < count; i++) {
            if (overBudget()) break;
            indentf(indent);
            emitf("[%ld] ", (long)i);
            dumpValue(CFArrayGetValueAtIndex(value, i), indent + 1, vdepth + 1);
        }
        indentf(indent - 1);
        emitf("]\n");
    } else if (tid == CFDictionaryGetTypeID()) {
        emitf("{\n");
        dumpDict(value, indent, vdepth + 1);
        indentf(indent - 1);
        emitf("}\n");
    } else {
        emitf("<type-%lu>\n", (unsigned long)tid);
    }
}

// One-line identity for a node: class, name, entry ID, location in the given
// plane. Every section uses this so a parser needs one regex.
static void emitHeader(io_registry_entry_t e, const io_name_t plane, int indent, int depth) {
    io_name_t name = {0}, cls = {0}, loc = {0};
    uint64_t id = 0;
    if (IORegistryEntryGetName(e, name) != KERN_SUCCESS) snprintf(name, sizeof(name), "<no name>");
    if (IOObjectGetClass(e, cls) != KERN_SUCCESS) snprintf(cls, sizeof(cls), "<no class>");
    IORegistryEntryGetRegistryEntryID(e, &id);
    IORegistryEntryGetLocationInPlane(e, plane, loc);
    indentf(indent);
    emitf("- class=%s name=%s id=0x%llx loc=%s [depth %d]\n",
          cls, name, (unsigned long long)id, loc[0] ? loc : "(none)", depth);
}

// IOService path, plus IODeviceTree path when the entry is also a device
// tree node.
static void emitPaths(io_registry_entry_t e, int indent) {
    io_string_t path = {0};
    indentf(indent);
    if (IORegistryEntryGetPath(e, kIOServicePlane, path) == KERN_SUCCESS)
        emitf("path: %s\n", path);
    else
        emitf("path: (not in IOService plane)\n");
    if (IORegistryEntryInPlane(e, kIODeviceTreePlane)) {
        io_string_t dt = {0};
        indentf(indent);
        if (IORegistryEntryGetPath(e, kIODeviceTreePlane, dt) == KERN_SUCCESS)
            emitf("dt-path: %s (device tree node is this entry; properties below)\n", dt);
        else
            emitf("dt-path: (in plane, path unavailable)\n");
    }
}

static void emitProps(io_registry_entry_t e, int indent) {
    CFMutableDictionaryRef props = NULL;
    kern_return_t kr = IORegistryEntryCreateCFProperties(e, &props, kCFAllocatorDefault, 0);
    if (kr != KERN_SUCCESS || !props) {
        indentf(indent);
        emitf("(cannot read properties: 0x%x)\n", kr);
        return;
    }
    indentf(indent);
    emitf("properties (%ld):\n", (long)CFDictionaryGetCount(props));
    dumpDict(props, indent + 1, 0);
    CFRelease(props);
}

// Full dump of one entry (header, paths, all properties), no recursion.
static void dumpEntry(io_registry_entry_t e, const io_name_t plane, int indent, int depth) {
    emitHeader(e, plane, indent, depth);
    emitPaths(e, indent + 1);
    emitProps(e, indent + 1);
}

// ---------------------------------------------------------------------------
// Section 1: registry planes. Returns 1 if the port plane is listed.
// ---------------------------------------------------------------------------
static int dumpPlanes(void) {
    emitf("=== Registry planes (root IORegistryPlanes) ===\n");
    int havePortPlane = 0;
    io_registry_entry_t root = IORegistryGetRootEntry(kIOMainPortDefault);
    if (!root) {
        emitf("  (cannot get registry root)\n\n");
        return 0;
    }
    CFTypeRef planes = IORegistryEntryCreateCFProperty(root, CFSTR("IORegistryPlanes"),
                                                       kCFAllocatorDefault, 0);
    if (!planes) {
        emitf("  (IORegistryPlanes not readable)\n");
    } else {
        emitf("  IORegistryPlanes: ");
        dumpValue(planes, 2, 0);
        if (CFGetTypeID(planes) == CFDictionaryGetTypeID()) {
            CFStringRef key = CFStringCreateWithCString(kCFAllocatorDefault, PROBE43_PORT_PLANE,
                                                        kCFStringEncodingUTF8);
            if (key) {
                havePortPlane = CFDictionaryContainsKey(planes, key) ? 1 : 0;
                CFRelease(key);
            }
        }
        CFRelease(planes);
    }
    IOObjectRelease(root);
    emitf("  %s plane listed: %s\n\n", PROBE43_PORT_PLANE, havePortPlane ? "yes" : "no");
    return havePortPlane;
}

// ---------------------------------------------------------------------------
// Section 2: the IOPort plane, one line per entry (properties of the port and
// transport nodes are in section 3, of USB devices in section 5).
// ---------------------------------------------------------------------------
static int g_planeEntries = 0;

static void walkPlane(io_registry_entry_t e, const char *plane, int depth) {
    if (depth > kMaxDepth || overBudget()) return;
    io_iterator_t it = 0;
    kern_return_t kr = IORegistryEntryGetChildIterator(e, plane, &it);
    if (kr != KERN_SUCCESS || !it) {
        if (kr != KERN_SUCCESS) {
            indentf(depth + 1);
            emitf("(child iterator failed: 0x%x)\n", kr);
        }
        return;
    }
    io_registry_entry_t child;
    int sawAny = 0;
    while ((child = IOIteratorNext(it))) {
        sawAny = 1;
        if (overBudget()) { IOObjectRelease(child); break; }
        int seen = alreadySeen(child);
        emitHeader(child, plane, depth + 1, depth + 1);
        io_string_t path = {0};
        indentf(depth + 2);
        if (IORegistryEntryGetPath(child, kIOServicePlane, path) == KERN_SUCCESS)
            emitf("path: %s\n", path);
        else
            emitf("path: (not in IOService plane)\n");
        g_planeEntries++;
        if (seen) {
            indentf(depth + 2);
            emitf("[already listed above; children not repeated]\n");
        } else {
            walkPlane(child, plane, depth + 1);
        }
        IOObjectRelease(child);
    }
    if (sawAny && !IOIteratorIsValid(it))
        emitf("--- TRUNCATED: iterator invalidated mid-walk (registry changed) ---\n");
    IOObjectRelease(it);
}

static void dumpPortPlane(int havePortPlane) {
    emitf("=== %s plane (walked from root) ===\n", PROBE43_PORT_PLANE);
    if (!havePortPlane) {
        emitf("  %s plane: not present on this macOS\n\n", PROBE43_PORT_PLANE);
        return;
    }
    io_registry_entry_t root = IORegistryGetRootEntry(kIOMainPortDefault);
    if (!root) {
        emitf("  (cannot get registry root)\n\n");
        return;
    }
    resetSeen();
    g_planeEntries = 0;
    emitHeader(root, PROBE43_PORT_PLANE, 0, 0);
    walkPlane(root, PROBE43_PORT_PLANE, 0);
    IOObjectRelease(root);
    if (g_planeEntries == 0)
        emitf("  %s plane: listed but empty (no entries under the root)\n", PROBE43_PORT_PLANE);
    emitf("\n%s plane entries: %d\n\n", PROBE43_PORT_PLANE, g_planeEntries);
}

// ---------------------------------------------------------------------------
// Section 3: IOPort nodes and their transport-state children.
// ---------------------------------------------------------------------------
static void dumpIOPortNodes(void) {
    emitf("=== %s nodes (IOServiceMatching, subclasses included) ===\n", PROBE43_IOPORT_CLASS);
    io_iterator_t iter = 0;
    kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault,
        IOServiceMatching(PROBE43_IOPORT_CLASS), &iter);
    if (kr != KERN_SUCCESS) {
        emitf("  (matching %s failed: 0x%x)\n", PROBE43_IOPORT_CLASS, kr);
        emitf("  %s: not present on this macOS\n\n", PROBE43_IOPORT_CLASS);
        return;
    }
    int total = 0, bare = 0;
    io_service_t s;
    while ((s = IOIteratorNext(iter))) {
        if (overBudget()) { IOObjectRelease(s); break; }
        io_name_t cls = {0};
        IOObjectGetClass(s, cls);
        int isBare = strcmp(cls, PROBE43_IOPORT_CLASS) == 0;
        if (isBare) bare++;
        emitf("\n%s[%d] exact-class=%s\n", PROBE43_IOPORT_CLASS, total, isBare ? "yes" : "no");
        total++;
        dumpEntry(s, kIOServicePlane, 0, 0);

        io_iterator_t kids = 0;
        if (IORegistryEntryGetChildIterator(s, kIOServicePlane, &kids) == KERN_SUCCESS && kids) {
            io_service_t c;
            int sawAny = 0, transports = 0;
            while ((c = IOIteratorNext(kids))) {
                sawAny = 1;
                if (overBudget()) { IOObjectRelease(c); break; }
                if (IOObjectConformsTo(c, "IOPortTransportState")) {
                    transports++;
                    dumpEntry(c, kIOServicePlane, 1, 1);
                }
                IOObjectRelease(c);
            }
            if (sawAny && !IOIteratorIsValid(kids))
                emitf("--- TRUNCATED: iterator invalidated mid-walk (registry changed) ---\n");
            IOObjectRelease(kids);
            emitf("  transport-state children: %d\n", transports);
        } else {
            emitf("  (child iterator failed)\n");
        }
        IOObjectRelease(s);
    }
    if (total > 0 && !IOIteratorIsValid(iter))
        emitf("--- TRUNCATED: iterator invalidated mid-walk (registry changed) ---\n");
    IOObjectRelease(iter);

    emitf("\n%s matched: %d (exact class %s: %d, subclasses: %d)\n",
          PROBE43_IOPORT_CLASS, total, PROBE43_IOPORT_CLASS, bare, total - bare);
    if (total == 0)
        emitf("%s: not present on this macOS (no instances of the class or any subclass)\n",
              PROBE43_IOPORT_CLASS);
    else if (bare == 0)
        emitf("bare %s: not present on this macOS (no exact-class instances; %d subclass instances matched)\n",
              PROBE43_IOPORT_CLASS, total);
    emitf("\n");
}

// ---------------------------------------------------------------------------
// Section 4: device tree port nodes (name starts with "port-").
// ---------------------------------------------------------------------------
static int g_dtPorts = 0;

static void findDTPorts(io_registry_entry_t e, int depth) {
    if (depth > kMaxDepth || overBudget()) return;
    io_iterator_t it = 0;
    if (IORegistryEntryGetChildIterator(e, kIODeviceTreePlane, &it) != KERN_SUCCESS || !it) return;
    io_registry_entry_t c;
    int sawAny = 0;
    while ((c = IOIteratorNext(it))) {
        sawAny = 1;
        if (overBudget()) { IOObjectRelease(c); break; }
        io_name_t name = {0};
        IORegistryEntryGetName(c, name);
        if (strncmp(name, "port-", 5) == 0) {
            g_dtPorts++;
            emitf("\n");
            dumpEntry(c, kIODeviceTreePlane, 0, depth + 1);
            // IOService children (e.g. the IOPort Port-USB-C@5 under
            // port-usb-c-5): header and path only, their properties are in
            // section 3.
            io_iterator_t sk = 0;
            if (IORegistryEntryGetChildIterator(c, kIOServicePlane, &sk) == KERN_SUCCESS && sk) {
                io_registry_entry_t k;
                int n = 0;
                while ((k = IOIteratorNext(sk))) {
                    if (n == 0) emitf("  IOService children:\n");
                    n++;
                    emitHeader(k, kIOServicePlane, 2, depth + 2);
                    io_string_t p = {0};
                    if (IORegistryEntryGetPath(k, kIOServicePlane, p) == KERN_SUCCESS) {
                        indentf(3);
                        emitf("path: %s\n", p);
                    }
                    IOObjectRelease(k);
                }
                if (n == 0) emitf("  IOService children: none\n");
                IOObjectRelease(sk);
            }
        }
        findDTPorts(c, depth + 1);
        IOObjectRelease(c);
    }
    if (sawAny && !IOIteratorIsValid(it))
        emitf("--- TRUNCATED: iterator invalidated mid-walk (registry changed) ---\n");
    IOObjectRelease(it);
}

static void dumpDTPorts(void) {
    emitf("=== IODeviceTree port nodes (name starts with \"port-\") ===\n");
    io_registry_entry_t dtRoot = IORegistryEntryFromPath(kIOMainPortDefault, kIODeviceTreePlane ":/");
    if (!dtRoot) {
        emitf("  (cannot resolve IODeviceTree root)\n\n");
        return;
    }
    g_dtPorts = 0;
    findDTPorts(dtRoot, 0);
    IOObjectRelease(dtRoot);
    emitf("\nIODeviceTree port nodes: %d\n\n", g_dtPorts);
}

// ---------------------------------------------------------------------------
// Section 5: USB host controllers, full IOService subtree.
// ---------------------------------------------------------------------------

// Resolve a stored IOService path property (UsbIOPort, UsbTransportState) and
// dump the target, plus the target's IOService parent when it is a device
// tree node (e.g. port-usb-c-5 above Port-USB-C@5).
static void dumpLinkedPath(io_registry_entry_t e, CFStringRef key, const char *keyName, int indent) {
    CFTypeRef v = IORegistryEntryCreateCFProperty(e, key, kCFAllocatorDefault, 0);
    if (!v) return;
    char path[1024];
    path[0] = '\0';
    int ok = CFGetTypeID(v) == CFStringGetTypeID()
          && CFStringGetCString(v, path, sizeof(path), kCFStringEncodingUTF8);
    CFRelease(v);
    if (!ok || !path[0]) return;

    indentf(indent);
    emitf("linked %s -> %s\n", keyName, path);
    io_registry_entry_t target = IORegistryEntryFromPath(kIOMainPortDefault, path);
    if (!target) {
        indentf(indent + 1);
        emitf("(path unresolved)\n");
        return;
    }
    dumpEntry(target, kIOServicePlane, indent + 1, 0);
    io_registry_entry_t parent = 0;
    if (IORegistryEntryGetParentEntry(target, kIOServicePlane, &parent) == KERN_SUCCESS && parent) {
        indentf(indent + 1);
        emitf("linked %s parent:\n", keyName);
        dumpEntry(parent, kIOServicePlane, indent + 2, 0);
        IOObjectRelease(parent);
    }
    IOObjectRelease(target);
}

// Nodes whose properties describe USB topology, and so are dumped in full.
// Base classes from the probe 41 corpus census, so subclasses are included.
static int isUSBTopologyNode(io_service_t s) {
    static const char *const kTopology[] = {
        "AppleUSBHostController",
        "AppleUSBHostPort",
        "AppleUSBHub",
        "IOUSBDevice",
        "IOUSBInterface",
        NULL
    };
    for (int i = 0; kTopology[i]; i++)
        if (IOObjectConformsTo(s, kTopology[i])) return 1;
    return 0;
}

static void dumpUSBNode(io_service_t s, int depth) {
    if (depth > kMaxDepth) { indentf(depth); emitf("(depth cap %d hit)\n", kMaxDepth); return; }
    if (overBudget()) return;

    if (alreadySeen(s)) {
        emitHeader(s, kIOServicePlane, depth, depth);
        indentf(depth + 1);
        emitf("[already dumped, see above]\n");
        return;
    }
    if (isUSBTopologyNode(s)) {
        dumpEntry(s, kIOServicePlane, depth, depth);
    } else {
        emitHeader(s, kIOServicePlane, depth, depth);
        emitPaths(s, depth + 1);
        indentf(depth + 1);
        emitf("[properties not dumped: not a controller, port, hub, device or interface]\n");
    }
    dumpLinkedPath(s, CFSTR("UsbIOPort"), "UsbIOPort", depth + 1);
    dumpLinkedPath(s, CFSTR("UsbTransportState"), "UsbTransportState", depth + 1);

    io_iterator_t kids = 0;
    kern_return_t kr = IORegistryEntryGetChildIterator(s, kIOServicePlane, &kids);
    if (kr != KERN_SUCCESS || !kids) {
        if (kr != KERN_SUCCESS) { indentf(depth + 1); emitf("(child iterator failed: 0x%x)\n", kr); }
        return;
    }
    io_service_t c;
    int sawAny = 0;
    while ((c = IOIteratorNext(kids))) {
        sawAny = 1;
        if (overBudget()) { IOObjectRelease(c); break; }
        dumpUSBNode(c, depth + 1);
        IOObjectRelease(c);
    }
    if (sawAny && !IOIteratorIsValid(kids))
        emitf("--- TRUNCATED: iterator invalidated mid-walk (registry changed) ---\n");
    IOObjectRelease(kids);
}

static void dumpControllers(void) {
    emitf("=== USB host controllers (AppleUSBHostController, full IOService subtree) ===\n");
    io_iterator_t iter = 0;
    kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault,
        IOServiceMatching("AppleUSBHostController"), &iter);
    if (kr != KERN_SUCCESS) {
        emitf("  (matching AppleUSBHostController failed: 0x%x)\n\n", kr);
        return;
    }
    resetSeen();
    int n = 0;
    io_service_t s;
    while ((s = IOIteratorNext(iter))) {
        if (overBudget()) { IOObjectRelease(s); break; }
        io_name_t cls = {0};
        IOObjectGetClass(s, cls);
        emitf("\n########## controller[%d] %s ##########\n", n, cls);
        n++;
        dumpUSBNode(s, 0);
        IOObjectRelease(s);
    }
    if (n > 0 && !IOIteratorIsValid(iter))
        emitf("--- TRUNCATED: iterator invalidated mid-walk (registry changed) ---\n");
    IOObjectRelease(iter);
    emitf("\nUSB host controllers matched: %d\n", n);
    if (n == 0) emitf("(no USB host controller found)\n");
}

int main(void) {
    emitf("=== USB port subtree (probe 43) ===\n");
    emitf("Registry planes, the IOPort plane, IOPort nodes with transports, device tree\n");
    emitf("port nodes, then every USB host controller subtree. All properties, unfiltered.\n");
    emitf("Running as uid=%d\n\n", getuid());

    int havePortPlane = dumpPlanes();
    if (!overBudget()) dumpPortPlane(havePortPlane);
    if (!overBudget()) dumpIOPortNodes();
    if (!overBudget()) dumpDTPorts();
    if (!overBudget()) dumpControllers();

    // Plain printf: survives the budget.
    printf("\n=== end (%lld bytes emitted, budget %lld%s) ===\n",
           g_bytes, kByteBudget, g_truncatedNoted ? ", TRUNCATED" : "");
    return 0;
}
