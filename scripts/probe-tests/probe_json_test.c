/*
 * Unit tests for probes/test-kit/probe_json.h. Run by scripts/probe-tests/run.sh,
 * which scripts/ci.sh calls. Plain C because nothing else in the repo compiles
 * the probes' code.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../../probes/test-kit/probe_json.h"

static int g_run = 0, g_failed = 0;

static void expect_eq(const char *name, const char *got, const char *want) {
    g_run++;
    if (strcmp(got, want) != 0) {
        g_failed++;
        fprintf(stderr, "FAIL %s\n  want: %s\n  got:  %s\n", name, want, got);
    }
}

static void expect_contains(const char *name, const char *got, const char *part) {
    g_run++;
    if (!strstr(got, part)) {
        g_failed++;
        fprintf(stderr, "FAIL %s\n  expected to contain: %s\n  got: %s\n", name, part, got);
    }
}

static void expect_true(const char *name, int ok) {
    g_run++;
    if (!ok) {
        g_failed++;
        fprintf(stderr, "FAIL %s\n", name);
    }
}

/* A writer on a memory stream. Call finish() to get what it wrote. */
typedef struct {
    pj_writer w;
    FILE *f;
    char *buf;
    size_t len;
} capture;

static void start(capture *c, unsigned long long cap) {
    c->buf = NULL;
    c->len = 0;
    c->f = open_memstream(&c->buf, &c->len);
    pj_init(&c->w, c->f, cap);
}

static char *finish(capture *c) {
    fclose(c->f);
    return c->buf;
}

static char *value_json(CFTypeRef v) {
    capture c;
    start(&c, 0);
    pj_value(&c.w, v, NULL, 0);
    return finish(&c);
}

static void check_value(const char *name, CFTypeRef v, const char *want) {
    char *got = value_json(v);
    expect_eq(name, got, want);
    free(got);
}

static void test_integers(void) {
    int8_t a = -1;
    int16_t b = -2;
    int32_t c = (int32_t)0x80200000;
    int32_t d = -500;
    int64_t e = -1;
    int64_t f = 1;
    struct { const char *name; CFNumberType type; const void *value; const char *want; } cases[] = {
        {"SInt8 -1", kCFNumberSInt8Type, &a, "{\"t\":\"int\",\"bits\":8,\"hex\":\"ff\"}"},
        {"SInt16 -2", kCFNumberSInt16Type, &b, "{\"t\":\"int\",\"bits\":16,\"hex\":\"fffe\"}"},
        {"SInt32 0x80200000 (a top-bit locationID)", kCFNumberSInt32Type, &c, "{\"t\":\"int\",\"bits\":32,\"hex\":\"80200000\"}"},
        {"SInt32 -500 (Brick ID Priority)", kCFNumberSInt32Type, &d, "{\"t\":\"int\",\"bits\":32,\"hex\":\"fffffe0c\"}"},
        {"SInt64 -1", kCFNumberSInt64Type, &e, "{\"t\":\"int\",\"bits\":64,\"hex\":\"ffffffffffffffff\"}"},
        {"SInt64 1", kCFNumberSInt64Type, &f, "{\"t\":\"int\",\"bits\":64,\"hex\":\"0000000000000001\"}"},
    };
    for (size_t i = 0; i < sizeof cases / sizeof cases[0]; i++) {
        CFNumberRef n = CFNumberCreate(NULL, cases[i].type, cases[i].value);
        check_value(cases[i].name, n, cases[i].want);
        CFRelease(n);
    }
}

static void test_floats(void) {
    double one = 1.0;
    float half = 1.5f;
    CFNumberRef a = CFNumberCreate(NULL, kCFNumberFloat64Type, &one);
    CFNumberRef b = CFNumberCreate(NULL, kCFNumberFloat32Type, &half);
    check_value("Float64 1.0", a, "{\"t\":\"float\",\"bits\":64,\"hex\":\"3ff0000000000000\"}");
    check_value("Float32 1.5", b, "{\"t\":\"float\",\"bits\":32,\"hex\":\"3fc00000\"}");
    CFRelease(a);
    CFRelease(b);
}

static void test_strings(void) {
    CFStringRef escapes = CFStringCreateWithCString(NULL, "a\"b\\c\n\t\x01\xc3\xa9", kCFStringEncodingUTF8);
    check_value("escapes and UTF-8 kept", escapes, "{\"t\":\"str\",\"v\":\"a\\\"b\\\\c\\n\\t\\u0001\xc3\xa9\"}");
    CFRelease(escapes);

    const UniChar with_nul[] = {'a', 0, 'b'};
    CFStringRef nul = CFStringCreateWithCharacters(NULL, with_nul, 3);
    check_value("embedded NUL is not a terminator", nul, "{\"t\":\"str\",\"v\":\"a\\u0000b\"}");
    CFRelease(nul);

    const UniChar lone[] = {0xD800, 'x'};
    CFStringRef surrogate = CFStringCreateWithCharacters(NULL, lone, 2);
    check_value("lone surrogate written as UTF-16 units", surrogate, "{\"t\":\"str\",\"utf16\":\"d8000078\"}");
    CFRelease(surrogate);
}

/* A "pid N, name" value under a process-owner key keeps the name only
   (Darryl, 2026-10-08): UsbExclusiveOwner and iAPAuthenticator, the two keys
   the corpus holds such values under besides IOUserClientCreator. A driver
   name is unchanged, and so is the same text under any other key. */
static void test_process_name(void) {
    capture c;
    CFStringRef owner = CFStringCreateWithCString(NULL, "pid 123, someapp", kCFStringEncodingUTF8);
    CFStringRef driver = CFStringCreateWithCString(NULL, "AppleUSB20Hub", kCFStringEncodingUTF8);
    static const char *const keys[] = {"UsbExclusiveOwner", "iAPAuthenticator", NULL};
    for (int i = 0; keys[i]; i++) {
        CFStringRef key = CFStringCreateWithCString(NULL, keys[i], kCFStringEncodingUTF8);
        start(&c, 0);
        pj_value(&c.w, owner, key, 1);
        pj_value(&c.w, driver, key, 1);
        char *got = finish(&c);
        char name[96];
        snprintf(name, sizeof name, "%s: the name without its pid, a driver name unchanged", keys[i]);
        expect_eq(name, got, "{\"t\":\"str\",\"v\":\"someapp\"}{\"t\":\"str\",\"v\":\"AppleUSB20Hub\"}");
        free(got);
        CFRelease(key);
    }
    CFStringRef other = CFStringCreateWithCString(NULL, "SomeOtherKey", kCFStringEncodingUTF8);
    start(&c, 0);
    pj_value(&c.w, owner, other, 1);
    pj_value(&c.w, owner, NULL, 1);
    char *got = finish(&c);
    expect_eq("the same text under another key, or with no key, is unchanged", got, "{\"t\":\"str\",\"v\":\"pid 123, someapp\"}{\"t\":\"str\",\"v\":\"pid 123, someapp\"}");
    free(got);
    expect_true("the name offset: 9 for a 3-digit pid, 0 without the prefix",
                pj_process_name_at((const unsigned char *)"pid 123, someapp", 16) == 9 && pj_process_name_at((const unsigned char *)"pid 123,someapp", 15) == 0
                && pj_process_name_at((const unsigned char *)"pid , x", 7) == 0 && pj_process_name_at((const unsigned char *)"pid 1, ", 7) == 0);
    CFRelease(other);
    CFRelease(owner);
    CFRelease(driver);
}

static void test_data(void) {
    const UInt8 bytes[] = {0x00, 0xff, 0x10};
    CFDataRef d = CFDataCreate(NULL, bytes, 3);
    check_value("data", d, "{\"t\":\"data\",\"len\":3,\"hex\":\"00ff10\"}");
    CFRelease(d);

    CFDataRef empty = CFDataCreate(NULL, NULL, 0);
    check_value("empty data", empty, "{\"t\":\"data\",\"len\":0,\"hex\":\"\"}");
    CFRelease(empty);

    /* Longer than every old probe's cut (32 to 128 bytes) and than the hex buffer. */
    enum { N = 5000 };
    UInt8 *big = malloc(N);
    memset(big, 0xab, N);
    CFDataRef long_data = CFDataCreate(NULL, big, N);
    char *want = malloc(64 + 2 * N);
    int at = sprintf(want, "{\"t\":\"data\",\"len\":%d,\"hex\":\"", N);
    for (int i = 0; i < N; i++) at += sprintf(want + at, "ab");
    sprintf(want + at, "\"}");
    check_value("5000-byte data written in full", long_data, want);
    free(want);
    free(big);
    CFRelease(long_data);
}

static void test_containers(void) {
    check_value("bool true", kCFBooleanTrue, "{\"t\":\"bool\",\"v\":true}");
    check_value("bool false", kCFBooleanFalse, "{\"t\":\"bool\",\"v\":false}");
    check_value("null", kCFNull, "{\"t\":\"null\"}");

    int32_t one = 1, seven = 7;
    CFNumberRef n1 = CFNumberCreate(NULL, kCFNumberSInt32Type, &one);
    CFNumberRef n7 = CFNumberCreate(NULL, kCFNumberSInt32Type, &seven);

    const void *items[] = {n1, CFSTR("x")};
    CFArrayRef arr = CFArrayCreate(NULL, items, 2, &kCFTypeArrayCallBacks);
    check_value("array keeps order", arr,
                "{\"t\":\"array\",\"v\":[{\"t\":\"int\",\"bits\":32,\"hex\":\"00000001\"},{\"t\":\"str\",\"v\":\"x\"}]}");
    CFRelease(arr);

    const void *keys[] = {CFSTR("b"), CFSTR("a")};
    const void *vals[] = {n1, kCFBooleanTrue};
    CFDictionaryRef dict = CFDictionaryCreate(NULL, keys, vals, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    check_value("dict as sorted pairs", dict,
                "{\"t\":\"dict\",\"v\":[[\"a\",{\"t\":\"bool\",\"v\":true}],[\"b\",{\"t\":\"int\",\"bits\":32,\"hex\":\"00000001\"}]]}");
    CFRelease(dict);

    const void *members[] = {n7};
    CFSetRef set = CFSetCreate(NULL, members, 1, &kCFTypeSetCallBacks);
    check_value("set members in full", set, "{\"t\":\"set\",\"v\":[{\"t\":\"int\",\"bits\":32,\"hex\":\"00000007\"}]}");
    CFRelease(set);

    CFDateRef epoch = CFDateCreate(NULL, 0.0);
    check_value("date as IEEE bits", epoch, "{\"t\":\"date\",\"bits\":64,\"hex\":\"0000000000000000\"}");
    CFRelease(epoch);

    CFURLRef url = CFURLCreateWithString(NULL, CFSTR("file:///x"), NULL);
    char *got = value_json(url);
    expect_contains("unknown CF type recorded, not skipped", got, "{\"t\":\"other\",\"cf_type_id\":");
    expect_contains("unknown CF type is named", got, "\"cf_type\":\"CFURL\"}");
    free(got);
    CFRelease(url);

    CFRelease(n1);
    CFRelease(n7);
}

static int withhold_secret(void *ctx, CFStringRef key, CFTypeRef value) {
    (void)ctx;
    if (key && CFStringCompare(key, CFSTR("secret"), 0) == kCFCompareEqualTo) return 1;
    /* Called with key NULL on dictionary keys and members: catch a key named "badkey". */
    return !key && CFGetTypeID(value) == CFStringGetTypeID() &&
           CFStringCompare((CFStringRef)value, CFSTR("badkey"), 0) == kCFCompareEqualTo;
}

static void test_withhold(void) {
    const void *keys[] = {CFSTR("secret"), CFSTR("open"), CFSTR("badkey")};
    const void *vals[] = {CFSTR("x"), CFSTR("y"), CFSTR("z")};
    CFDictionaryRef dict = CFDictionaryCreate(NULL, keys, vals, 3, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    capture c;
    start(&c, 0);
    c.w.withhold = withhold_secret;
    pj_value(&c.w, dict, NULL, 0);
    unsigned long long withheld = c.w.withheld;
    char *got = finish(&c);
    expect_eq("withheld by key and by key content", got,
              "{\"t\":\"dict\",\"v\":[[{\"t\":\"withheld\"},{\"t\":\"withheld\"}],[\"open\",{\"t\":\"str\",\"v\":\"y\"}],[\"secret\",{\"t\":\"withheld\"}]]}");
    expect_true("withheld counter", withheld == 2);
    free(got);
    CFRelease(dict);
}

static int skip_boot(void *ctx, CFStringRef key, CFTypeRef value) {
    (void)ctx;
    (void)value;
    return key && CFStringCompare(key, CFSTR("boot"), 0) == kCFCompareEqualTo ? PJ_SKIP : 0;
}

static void test_skip(void) {
    const void *keys[] = {CFSTR("boot"), CFSTR("bt")};
    const void *vals[] = {CFSTR("x"), CFSTR("y")};
    CFDictionaryRef dict = CFDictionaryCreate(NULL, keys, vals, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    capture c;
    start(&c, 0);
    c.w.withhold = skip_boot;
    pj_value(&c.w, dict, NULL, 0);
    unsigned long long withheld = c.w.withheld;
    char *got = finish(&c);
    expect_eq("skipped is its own marker", got,
              "{\"t\":\"dict\",\"v\":[[\"boot\",{\"t\":\"skipped\"}],[\"bt\",{\"t\":\"str\",\"v\":\"y\"}]]}");
    expect_true("skipped is not counted as withheld", withheld == 0);
    free(got);
    CFRelease(dict);
}

static int part_all(void *ctx, CFStringRef key, CFTypeRef value) {
    (void)ctx;
    (void)key;
    (void)value;
    return PJ_PART;
}

/* Marks bytes 1-2 and 5 as the Mac's own: two separate ranges. */
static void mask_some(void *ctx, const unsigned char *b, size_t n, unsigned char *mask) {
    (void)ctx;
    (void)b;
    if (n >= 6) mask[1] = mask[2] = mask[5] = 1;
}

static void mask_all(void *ctx, const unsigned char *b, size_t n, unsigned char *mask) {
    (void)ctx;
    (void)b;
    memset(mask, 1, n);
}

static void test_part(void) {
    const unsigned char bytes[] = {0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x11};
    CFDataRef data = CFDataCreate(NULL, bytes, sizeof bytes);
    capture c;
    start(&c, 0);
    c.w.withhold = part_all;
    c.w.mask = mask_some;
    pj_value(&c.w, data, NULL, 0);
    unsigned long long withheld = c.w.withheld;
    char *got = finish(&c);
    expect_eq("partly withheld data zeroes only the marked bytes", got,
              "{\"t\":\"data\",\"len\":7,\"hex\":\"aa0000ddee0011\",\"withheld\":[[1,2],[5,1]]}");
    expect_true("partly withheld counts once", withheld == 1);
    free(got);
    CFRelease(data);

    const unsigned char addr[] = {0x01, 0x02, 0x03};
    CFDataRef all = CFDataCreate(NULL, addr, sizeof addr);
    start(&c, 0);
    c.w.withhold = part_all;
    c.w.mask = mask_all;
    pj_value(&c.w, all, NULL, 0);
    withheld = c.w.withheld;
    got = finish(&c);
    expect_eq("data with every byte withheld is plain withheld", got, "{\"t\":\"withheld\"}");
    expect_true("and counts once", withheld == 1);
    free(got);
    CFRelease(all);

    start(&c, 0);
    c.w.withhold = part_all;
    c.w.mask = mask_some;
    pj_value(&c.w, CFSTR("text"), NULL, 0);
    got = finish(&c);
    expect_eq("partly withheld on a string withholds it whole", got, "{\"t\":\"withheld\"}");
    free(got);
}

/* Synthetic identifiers in the shapes the live Mac publishes them. */
static const unsigned char kChipLE[8] = {0x0f, 0xec, 0xda, 0xc8, 0xb6, 0xa4, 0x12, 0x00}; /* unique-chip-id */
static const unsigned char kMac[6] = {0xa4, 0xb1, 0xc2, 0xd3, 0xe4, 0xf5};
static const unsigned char kWeakMac[6] = {0x82, 0, 0, 0, 0, 0}; /* the MacBook's Thunderbolt Bridge shape */

static void sample_ids(pj_ids *ids) {
    pj_ids_init(ids);
    pj_ids_add_binary(ids, kChipLE, sizeof kChipLE);
    pj_ids_add_text(ids, "C02XYZ1234QW", 12, 1);
    pj_ids_add_uuid(ids, CFSTR("4C4C4544-0039-4A10-8031-B4C04F4B5A31"));
    pj_ids_add_address(ids, kMac);
    pj_ids_add_address(ids, kWeakMac);
}

/* What the writer makes of v under key, with ids attached. */
static void check_private(pj_ids *ids, const char *name, const char *key, CFTypeRef v, const char *want) {
    capture c;
    start(&c, 0);
    pj_privacy_attach(&c.w, ids);
    CFStringRef k = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
    pj_value(&c.w, v, k, 1);
    CFRelease(k);
    char *got = finish(&c);
    expect_eq(name, got, want);
    free(got);
    CFRelease(v);
}

static CFDataRef bytes_of(const unsigned char *b, size_t n) { return CFDataCreate(NULL, b, (CFIndex)n); }

/* Each case is an encoding the PR 693 review found unmatched, or one the
   generated forms must cover, written out here rather than taken from the
   generator. */
static void test_privacy(void) {
    pj_ids ids;
    sample_ids(&ids);

    const unsigned char der[] = {0x16, 0x04, 'E', 'C', 'I', 'D', 0x02, 0x07, 0x12, 0xa4, 0xb6, 0xc8, 0xda, 0xec, 0x0f, 0xa0, 0x1f};
    check_private(&ids, "chip ID big-endian in a DER manifest: only its bytes withheld", "sfr-manifest-data",
                  bytes_of(der, sizeof der),
                  "{\"t\":\"data\",\"len\":17,\"hex\":\"160445434944020700000000000000a01f\",\"withheld\":[[8,7]]}");

    int64_t chip = 0x0012a4b6c8daec0fLL;
    check_private(&ids, "chip ID as an integer", "Value", CFNumberCreate(NULL, kCFNumberSInt64Type, &chip), "{\"t\":\"withheld\"}");

    char decimal[32];
    snprintf(decimal, sizeof decimal, "ecid %lld", (long long)chip);
    check_private(&ids, "chip ID in decimal", "Text", CFStringCreateWithCString(NULL, decimal, kCFStringEncodingUTF8),
                  "{\"t\":\"withheld\"}");

    /* Intel's /efi/platform SystemSerialNumber: UTF-16LE, exactly half zero bytes. */
    unsigned char u16[2 + 24] = {0xaa, 0xbb};
    for (int i = 0; i < 12; i++) u16[2 + 2 * i] = (unsigned char)"C02XYZ1234QW"[i];
    check_private(&ids, "serial as UTF-16LE", "SystemSerialNumber", bytes_of(u16, sizeof u16),
                  "{\"t\":\"data\",\"len\":26,\"hex\":\"aabb000000000000000000000000000000000000000000000000\",\"withheld\":[[2,24]]}");
    check_private(&ids, "serial in lower case", "Text", CFSTR("sn c02xyz1234qw"), "{\"t\":\"withheld\"}");

    /* Intel's system-id and SMBIOS: the platform UUID with its first three fields little-endian. */
    const unsigned char efi[] = {0x01, 0x44, 0x45, 0x4c, 0x4c, 0x39, 0x00, 0x10, 0x4a, 0x80, 0x31, 0xb4, 0xc0, 0x4f, 0x4b, 0x5a, 0x31, 0x02};
    check_private(&ids, "platform UUID in EFI order", "system-id", bytes_of(efi, sizeof efi),
                  "{\"t\":\"data\",\"len\":18,\"hex\":\"010000000000000000000000000000000002\",\"withheld\":[[1,16]]}");

    check_private(&ids, "network address as dashed upper-case text", "Text", CFSTR("port A4-B1-C2-D3-E4-F5"), "{\"t\":\"withheld\"}");
    const unsigned char rev[] = {0x00, 0xf5, 0xe4, 0xd3, 0xc2, 0xb1, 0xa4};
    check_private(&ids, "network address reversed in data", "Blob", bytes_of(rev, sizeof rev),
                  "{\"t\":\"data\",\"len\":7,\"hex\":\"00000000000000\",\"withheld\":[[1,6]]}");

    /* A near-empty own address is the Mac's when a value is exactly it, and a
       coincidence anywhere else. */
    check_private(&ids, "near-empty address, exactly", "Blob", bytes_of(kWeakMac, 6), "{\"t\":\"withheld\"}");
    const unsigned char weak_rev[] = {0, 0, 0, 0, 0, 0x82};
    check_private(&ids, "near-empty address reversed, exactly", "Blob", bytes_of(weak_rev, 6), "{\"t\":\"withheld\"}");
    const unsigned char weak_inside[] = {0, 0x82, 0, 0, 0, 0, 0};
    check_private(&ids, "near-empty address inside a longer value is kept", "Blob", bytes_of(weak_inside, 7),
                  "{\"t\":\"data\",\"len\":7,\"hex\":\"00820000000000\"}");
    int32_t small = 0x82;
    check_private(&ids, "a small integer is kept", "Count", CFNumberCreate(NULL, kCFNumberSInt32Type, &small),
                  "{\"t\":\"int\",\"bits\":32,\"hex\":\"00000082\"}");

    /* An address with four zero bytes strips to 2 bytes: its hex ("12ab") and
       decimal ("4779") would match countless unrelated values. */
    pj_ids sparse_ids;
    pj_ids_init(&sparse_ids);
    const unsigned char sparse[6] = {0, 0, 0, 0, 0x12, 0xab};
    pj_ids_add_address(&sparse_ids, sparse);
    check_private(&sparse_ids, "a short identifier gives no short text form", "Text", CFSTR("rev 12ab, 4779 mA"),
                  "{\"t\":\"str\",\"v\":\"rev 12ab, 4779 mA\"}");
    check_private(&sparse_ids, "but is still matched as a whole value", "Blob", bytes_of(sparse, 6), "{\"t\":\"withheld\"}");

    const unsigned char other[] = {1, 2, 3, 4, 5, 6, 7};
    check_private(&ids, "a key withheld by name is withheld whole", "local-mac-address", bytes_of(other, 7), "{\"t\":\"withheld\"}");
    check_private(&ids, "anything else is kept", "IOClass", CFSTR("AppleHPM"), "{\"t\":\"str\",\"v\":\"AppleHPM\"}");
}

/* Two own addresses sharing 5 bytes, one ending in 00, as on the mini's
   Thunderbolt IP ports (PR 693 rerun): the zero-stripped form of one sits
   inside the other, and neither may leave a byte of its own visible. A
   binary form is dropped only for zero bytes beyond the shorter one, so a
   last byte of 0x30 (the '0' character) is kept too. */
static void test_shared_bytes(void) {
    const unsigned char a[6] = {0x02, 0x5a, 0x6b, 0x7c, 0x8d, 0x00};
    const unsigned char b[6] = {0x02, 0x5a, 0x6b, 0x7c, 0x8d, 0x05};
    const unsigned char c[6] = {0x02, 0x5a, 0x6b, 0x7c, 0x8d, 0x30};
    pj_ids ids;
    pj_ids_init(&ids);
    pj_ids_add_address(&ids, a);
    pj_ids_add_address(&ids, b);
    pj_ids_add_address(&ids, c);
    check_private(&ids, "an own address as a value is withheld whole", "IOMACAddress", bytes_of(a, 6), "{\"t\":\"withheld\"}");
    check_private(&ids, "so is one sharing 5 bytes with it", "IOMACAddress", bytes_of(b, 6), "{\"t\":\"withheld\"}");
    const unsigned char in_b[] = {0x11, 0x02, 0x5a, 0x6b, 0x7c, 0x8d, 0x05, 0x22};
    check_private(&ids, "inside a longer value, all 6 of its bytes withheld", "Blob", bytes_of(in_b, sizeof in_b),
                  "{\"t\":\"data\",\"len\":8,\"hex\":\"1100000000000022\",\"withheld\":[[1,6]]}");
    const unsigned char in_c[] = {0x11, 0x02, 0x5a, 0x6b, 0x7c, 0x8d, 0x30, 0x22};
    check_private(&ids, "a last byte of 0x30 withheld too", "Blob", bytes_of(in_c, sizeof in_c),
                  "{\"t\":\"data\",\"len\":8,\"hex\":\"1100000000000022\",\"withheld\":[[1,6]]}");
}

static void test_bytes_field(void) {
    pj_ids ids;
    sample_ids(&ids);
    const unsigned char plain[] = {0x01, 0x02, 0x03};
    const unsigned char reci[] = {0x00, 0x12, 0xa4, 0xb6, 0xc8, 0xda, 0xec, 0x0f}; /* SMC key RECI: the chip ID big-endian */
    capture c;
    start(&c, 0);
    pj_privacy_attach(&c.w, &ids);
    pj_bytes_field(&c.w, "bytes", plain, sizeof plain);
    pj_bytes_field(&c.w, "bytes", reci + 1, 7);
    pj_bytes_field(&c.w, "bytes", reci, 8);
    unsigned long long withheld = c.w.withheld;
    char *got = finish(&c);
    /* RECI's leading zero byte is not the chip ID's: it stays. */
    expect_eq("raw bytes: kept, fully withheld, partly withheld with a sibling range list", got,
              ",\"bytes\":\"010203\""
              ",\"bytes\":{\"t\":\"withheld\"}"
              ",\"bytes\":\"0000000000000000\",\"bytes_withheld\":[[1,7]]");
    expect_true("each withheld field counts once", withheld == 2);
    free(got);

    start(&c, 0);
    pj_bytes_field(&c.w, "bytes", reci, 8);
    got = finish(&c);
    expect_eq("raw bytes without privacy attached", got, ",\"bytes\":\"0012a4b6c8daec0f\"");
    free(got);
}

/* Two 30-byte records; pad adds that many bytes of data to the second. */
static void write_two_entries(pj_writer *w, size_t pad) {
    if (pj_record_begin(w, "entry")) {
        pj_field(w, "id");
        pj_text(w, "0x1");
        pj_record_end(w);
    }
    if (pj_record_begin(w, "entry")) {
        pj_field(w, "id");
        pj_text(w, "0x2");
        if (pad) {
            unsigned char *b = calloc(1, pad);
            pj_field(w, "pad");
            pj_hex(w, b, pad);
            free(b);
        }
        pj_record_end(w);
    }
    pj_footer(w, w->capped ? "byte_cap" : NULL);
}

static void test_records_and_cap(void) {
    capture c;
    start(&c, 0);
    write_two_entries(&c.w, 0);
    char *got = finish(&c);
    expect_contains("uncapped first record", got, "{\"record\":\"entry\",\"id\":\"0x1\"}\n{\"record\":\"entry\",\"id\":\"0x2\"}\n");
    expect_contains("uncapped footer", got, "{\"record\":\"footer\",\"status\":\"complete\",\"reason\":null,\"step\":null,\"records\":2,\"failures\":0,\"withheld\":0,\"bytes_before_footer\":60,");
    free(got);

    /* A record is written only if it fits: the cap is never passed (PR 693
       review: one large value used to carry a record far beyond it). */
    const size_t pads[] = {0, 100000};
    for (size_t i = 0; i < sizeof pads / sizeof pads[0]; i++) {
        start(&c, 40);
        write_two_entries(&c.w, pads[i]);
        got = finish(&c);
        expect_contains("cap lets the record that fits through", got, "{\"record\":\"entry\",\"id\":\"0x1\"}\n{\"record\":\"footer\"");
        expect_true("cap refuses the record that would pass it", strstr(got, "0x2") == NULL);
        expect_contains("capped footer says why, counting only records written", got,
                        "\"status\":\"stopped\",\"reason\":\"byte_cap\",\"step\":null,\"records\":1,");
        const char *footer = strstr(got, "{\"record\":\"footer\"");
        expect_true("nothing but the footer past the cap", footer && footer - got <= 40);
        free(got);
    }
}

/* The entry ID a small probe joins on: read before its record opens, so a
   lookup that fails is a failure record and not a record with a null ID
   (Codex review of PR 693: 52 dropped the device, 51 wrote 0x0, 55 null). */
static void test_entry_id(void) {
    capture c;
    uint64_t id = 0;
    start(&c, 0);
    io_registry_entry_t root = IORegistryGetRootEntry(kIOMainPortDefault);
    expect_true("a live entry gives its ID", pj_entry_id(&c.w, root, &id) == 1 && id != 0);
    IOObjectRelease(root);
    unsigned long long failures = c.w.failures;
    char *got = finish(&c);
    expect_eq("and writes nothing", got, "");
    expect_true("and counts no failure", failures == 0);
    free(got);

    start(&c, 0);
    id = 7;
    expect_true("an invalid object gives no ID", pj_entry_id(&c.w, MACH_PORT_NULL, &id) == 0 && id == 0);
    failures = c.w.failures;
    unsigned long long records = c.w.records;
    got = finish(&c);
    expect_contains("and writes a failure record", got, "{\"record\":\"failure\",\"what\":\"entry_id\",\"class\":null,\"kr\":\"0x");
    expect_true("that is counted once", failures == 1 && records == 1);
    expect_true("with a non-zero kr", strstr(got, "\"kr\":\"0x00000000\"") == NULL);
    free(got);
}

/* Identifier gathering fails closed (Codex, last review of PR 693): a lookup
   it depends on that fails, or a registry walk still changing after a few
   tries, leaves the probe unable to say what to withhold, so it writes only
   the header and a footer stopped with reason identifiers_incomplete. Each
   step is made to fail through the test-only seam (PJ_FAULT_INJECTION).
   Nothing gathered is printed: only return values and the footer text. */
/* pj_ids_gather for a check that expects an exact number of walks, or a
   named step. Another process starting or stopping on this Mac opens or
   closes a user client, and a walk that meets it is made again, so a count
   below the cap reads one high, and a read named on the last walk reads
   registry_changing instead (0 of 300 idle gathers here, but the suite
   shares the machine). Such a gather is made again, with the seam's budget
   restored, at most three times; a result still wrong fails. step is the
   name expected, or NULL. */
static int gather_walking(pj_ids *ids, int walks, const char *step) {
    int r = 0;
    for (int i = 0; i < 3; i++) {
        int times = pj_fault_times;
        r = pj_ids_gather(ids);
        int named = !step || (ids->incomplete && strcmp(ids->incomplete, step) == 0);
        if (ids->walks == walks && named) break;
        pj_fault_times = times;
    }
    return r;
}

/* The seam's kern_return by walk, for the reset check below: a faulted read
   fails with no sign on the first walk and with the churn sign on every
   later one. The hook sees only the entry, so the test's ids is reached
   through a pointer. Set both ways, so a gather made again (gather_walking)
   starts from the first state. */
static pj_ids *reset_ids = NULL;
static void churn_sign_from_walk_two(io_registry_entry_t e) {
    (void)e;
    pj_fault_kr = reset_ids->walks >= 2 ? MACH_SEND_INVALID_DEST : kIOReturnError;
}

static void test_ids_gather_fails_closed(void) {
    pj_ids ids;
    pj_fault_step = NULL;
    expect_true("gathering completes on this Mac", pj_ids_gather(&ids) == 1 && ids.incomplete == NULL);

    /* Outside the walk, a lookup that fails stops gathering at once. */
    static const char *const steps[] = {"platform_expert", "platform_props", "device_tree", "device_tree_props",
                                        "chosen", "chosen_props", "passwd", NULL};
    for (int i = 0; steps[i]; i++) {
        pj_fault_step = steps[i];
        pj_fault_times = 1 << 20; /* every time */
        int r = gather_walking(&ids, 1, steps[i]);
        char name[96];
        snprintf(name, sizeof name, "step %s failing stops gathering and names itself", steps[i]);
        expect_true(name, r == 0 && ids.incomplete && strcmp(ids.incomplete, steps[i]) == 0);
        snprintf(name, sizeof name, "step %s failing is not retried", steps[i]);
        expect_true(name, ids.walks == 1);
    }
    /* A read inside the walk is never final on its first failure (Opus x3
       review of PR 693, measured on the mini: a user client closed between
       IOIteratorNext and the read fails the read with MACH_SEND_INVALID_DEST
       while the walk's iterator still says valid, so a failed read can be
       churn before any iterator says so). The walk is made again, with the
       pauses; a read that keeps failing with no sign of churn (the entry
       still in the plane, another kern_return, the iterator valid) is named
       once the attempts run out. */
    static const char *const reads[] = {"network_iterator", "network_props", "network_builtin", "bluetooth_node", NULL};
    for (int i = 0; reads[i]; i++) {
        char name[128];
        pj_fault_step = reads[i];
        pj_fault_times = 1 << 20;
        int r = gather_walking(&ids, 4, reads[i]);
        snprintf(name, sizeof name, "read %s failing every time, with no sign of churn, is walked again four times and then named", reads[i]);
        expect_true(name, r == 0 && ids.incomplete && strcmp(ids.incomplete, reads[i]) == 0 && ids.walks == 4 && pj_fault_times < (1 << 20));
        pj_fault_times = 1;
        r = gather_walking(&ids, 2, NULL);
        snprintf(name, sizeof name, "read %s failing once is walked again and completes", reads[i]);
        expect_true(name, r == 1 && ids.incomplete == NULL && ids.walks == 2 && pj_fault_times == 0);
    }
    /* The measured signs of churn after a failed read, each on its own: the
       read's kern_return is MACH_SEND_INVALID_DEST (the entry's ports are
       gone), or the entry is no longer in the plane. Either means the walk
       stops as registry_changing, never as the read's own step. */
    static const char *const entry_reads[] = {"network_props", "network_builtin", "bluetooth_node", NULL};
    for (int i = 0; entry_reads[i]; i++) {
        char name[128], both[64];
        pj_fault_step = entry_reads[i];
        pj_fault_times = 1 << 20;
        pj_fault_kr = MACH_SEND_INVALID_DEST;
        int r = pj_ids_gather(&ids);
        snprintf(name, sizeof name, "read %s failing with MACH_SEND_INVALID_DEST is churn", entry_reads[i]);
        expect_true(name, r == 0 && ids.incomplete && strcmp(ids.incomplete, "registry_changing") == 0 && ids.walks == 4 && pj_fault_times < (1 << 20));
        pj_fault_kr = kIOReturnError;
        snprintf(both, sizeof both, "%s entry_gone", entry_reads[i]);
        pj_fault_step = both;
        pj_fault_times = 1 << 20;
        r = pj_ids_gather(&ids);
        snprintf(name, sizeof name, "read %s failing on an entry no longer in the plane is churn", entry_reads[i]);
        expect_true(name, r == 0 && ids.incomplete && strcmp(ids.incomplete, "registry_changing") == 0 && ids.walks == 4 && pj_fault_times < (1 << 20));
    }
    /* The read a walk failed with no sign of churn is the last walk's only:
       ids->read_failed is reset at the start of every walk (extra pass 5 of
       PR 693). The first walk fails a read with no sign, every later walk
       fails one with the churn sign, so the attempts run out as
       registry_changing and not as the first walk's read. The name carries
       the step and walk count (fixed names and a count), so a wrong answer
       says which. */
    reset_ids = &ids;
    pj_before_read = churn_sign_from_walk_two;
    pj_fault_step = "network_props";
    pj_fault_times = 1 << 20;
    int reset_r = gather_walking(&ids, 4, "registry_changing");
    pj_before_read = NULL;
    pj_fault_kr = kIOReturnError;
    reset_ids = NULL;
    char reset_name[160];
    snprintf(reset_name, sizeof reset_name, "a read failed with no sign on the first walk, then churn on every later one, stops as registry_changing (step %s, walks %d)",
             ids.incomplete ? ids.incomplete : "null", ids.walks);
    expect_true(reset_name, reset_r == 0 && ids.incomplete && strcmp(ids.incomplete, "registry_changing") == 0 && ids.walks == 4 && pj_fault_times < (1 << 20));
    /* The registry changing under the walk (its iterator no longer valid)
       makes the walk go again whatever it read. */
    pj_fault_step = "network_changed";
    pj_fault_times = 2; /* two walks invalidated, the third is good */
    expect_true("a registry walk that settles within the retries completes", gather_walking(&ids, 3, NULL) == 1 && ids.incomplete == NULL && ids.walks == 3);
    pj_fault_times = 1 << 20;
    expect_true("one still changing after four walks stops and says so",
                pj_ids_gather(&ids) == 0 && ids.incomplete && strcmp(ids.incomplete, "registry_changing") == 0 && ids.walks == 4);
    /* An entry removed mid-walk fails its property read and leaves the
       iterator invalid: that is a changed walk, not a failed one. */
    pj_fault_step = "network_props network_changed";
    pj_fault_times = 2; /* the first walk: one failed read, then the iterator found invalid */
    expect_true("a failed read with the iterator invalidated is walked again", gather_walking(&ids, 2, NULL) == 1 && ids.incomplete == NULL && ids.walks == 2);
    /* The same beneath a network interface: the built-in check reads the
       entry's children, and a child removed under it fails its read and
       leaves that child iterator invalid, which the walk's own iterator does
       not see. Changed every time, so four walks and registry_changing. */
    pj_fault_step = "network_builtin network_builtin_changed";
    pj_fault_times = 1 << 20;
    expect_true("a failed read beneath a changed interface is walked again, not a failure",
                pj_ids_gather(&ids) == 0 && ids.incomplete && strcmp(ids.incomplete, "registry_changing") == 0 && ids.walks == 4);
    /* And a marker read from a child set that then proved to have changed
       is not trusted either (Codex x3 review of PR 693): a stale "not built
       in" would keep a Mac-owned address unwithheld. Both factory-assigned
       interfaces here publish IOBuiltin one level down (measured), so the
       marker is found and the child iterator is asked: invalid every time,
       so four walks and registry_changing. */
    pj_fault_step = "network_builtin_changed";
    pj_fault_times = 1 << 20;
    expect_true("a marker found while the children changed is walked again, not accepted",
                pj_ids_gather(&ids) == 0 && ids.incomplete && strcmp(ids.incomplete, "registry_changing") == 0 && ids.walks == 4 && pj_fault_times < (1 << 20));

    capture c;
    start(&c, 0);
    pj_fault_step = "chosen_props";
    pj_fault_times = 1 << 20;
    int r = pj_privacy_begin(&c.w, &ids, "50_test");
    char *got = finish(&c);
    expect_true("an incomplete gathering makes the probe stop", r == 0);
    expect_contains("after the header", got, "{\"record\":\"header\",\"format\":1,\"probe\":\"50_test\",");
    /* The step is the footer's only word on which lookup failed (Opus x2
       review of PR 693: a stop on a tester's Mac could not be diagnosed from
       the submission). A fixed name, never anything read from the Mac. */
    expect_contains("with a stopped footer naming the reason and the step that failed, and no records", got,
                    "{\"record\":\"footer\",\"status\":\"stopped\",\"reason\":\"identifiers_incomplete\",\"step\":\"chosen_props\",\"records\":0,\"failures\":0,\"withheld\":0,");
    int lines = 0;
    for (const char *p = got; *p; p++) lines += *p == '\n';
    expect_true("header and footer only", lines == 2);
    free(got);

    pj_fault_step = NULL;
    start(&c, 0);
    r = pj_privacy_begin(&c.w, &ids, "50_test");
    got = finish(&c);
    expect_true("a complete gathering lets the probe go on, header written, no footer", r == 1 && strstr(got, "\"record\":\"header\"") && !strstr(got, "\"record\":\"footer\""));
    free(got);
}

static CFDictionaryRef dict_with_number(const char *key, long n) {
    CFStringRef k = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
    CFNumberRef v = CFNumberCreate(NULL, kCFNumberLongType, &n);
    CFDictionaryRef d = CFDictionaryCreate(NULL, (const void **)&k, (const void **)&v, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFRelease(k);
    CFRelease(v);
    return d;
}

static CFDictionaryRef dict_with_string(const char *key, const char *s) {
    CFStringRef k = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
    CFStringRef v = CFStringCreateWithCString(NULL, s, kCFStringEncodingUTF8);
    CFDictionaryRef d = CFDictionaryCreate(NULL, (const void **)&k, (const void **)&v, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFRelease(k);
    CFRelease(v);
    return d;
}

static CFDictionaryRef dict_with_data(const char *key, const unsigned char *b, size_t n) {
    CFStringRef k = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
    CFDataRef v = CFDataCreate(NULL, b, (CFIndex)n);
    CFDictionaryRef d = CFDictionaryCreate(NULL, (const void **)&k, (const void **)&v, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFRelease(k);
    CFRelease(v);
    return d;
}

/* The gathering's own shape checks, each shown to the code through the fault
   seam (Opus review of PR 693 after extra pass 1: four mutants that turned
   fail-closed back into fail-open survived the suite). Every fault must be
   seen to fire, or the check tested nothing. */
static void test_ids_gather_shapes(void) {
    pj_ids ids;
    CFTypeRef out = NULL;
    CFDictionaryRef number = dict_with_number("IOPlatformSerialNumber", 7);
    pj_ids_init(&ids);
    expect_true("a key of the wrong type is a failed step, not absent",
                pj_ids_typed(&ids, number, "IOPlatformSerialNumber", CFStringGetTypeID(), "platform_props", &out) == -1
                && ids.incomplete && strcmp(ids.incomplete, "platform_props") == 0);
    pj_ids_init(&ids);
    expect_true("an absent key is absent", pj_ids_typed(&ids, number, "IOPlatformUUID", CFStringGetTypeID(), "platform_props", &out) == 0 && ids.incomplete == NULL);
    CFRelease(number);

    /* The sources of this Mac's own Bluetooth address (Codex x1 #1), each
       gathered on its own: /chosen and the device-tree node named bluetooth
       (measured on the mini, 2026-10-08; IOBluetoothDevice is not one, it
       stands for connected devices too). A Mac with a Bluetooth controller
       and no address from any source fails closed; one without a controller
       needs none. The two checks that read the walk's source pass only on an
       Apple-silicon Mac. */
    pj_fault_step = NULL;
    expect_true("this Mac has a Bluetooth controller and its address was gathered", pj_ids_gather(&ids) == 1 && ids.bt_controllers >= 1 && ids.bt_addresses >= 1);
    CFDictionaryRef empty = CFDictionaryCreate(NULL, NULL, NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    pj_fault_step = "chosen_props";
    pj_fault_times = 1 << 20;
    pj_fault_value = empty;
    expect_true("without the /chosen key the controller's own entries still give the address", pj_ids_gather(&ids) == 1 && ids.bt_addresses >= 1 && pj_fault_times < (1 << 20));
    pj_fault_step = "chosen_props network_props";
    pj_fault_times = 1 << 20;
    expect_true("a controller present and no address from any source fails closed", pj_ids_gather(&ids) == 0 && ids.incomplete && strcmp(ids.incomplete, "bluetooth") == 0 && ids.bt_controllers >= 1 && ids.bt_addresses == 0);
    pj_fault_step = "platform_props";
    pj_fault_times = 1 << 20;
    expect_true("an absent IOPlatformSerialNumber fails closed", pj_ids_gather(&ids) == 0 && ids.incomplete && strcmp(ids.incomplete, "platform_serial") == 0);
    CFDictionaryRef serial_only = dict_with_string("IOPlatformSerialNumber", "C02TEST12345");
    pj_fault_value = serial_only;
    pj_fault_times = 1 << 20;
    expect_true("an absent IOPlatformUUID fails closed", pj_ids_gather(&ids) == 0 && ids.incomplete && strcmp(ids.incomplete, "platform_uuid") == 0);
    pj_fault_step = "device_tree_props";
    pj_fault_value = empty;
    pj_fault_times = 1 << 20;
    expect_true("absent device-tree serials are fine (Intel Macs)", pj_ids_gather(&ids) == 1 && pj_fault_times < (1 << 20));
    pj_fault_value = NULL;
    pj_fault_step = NULL;
    CFRelease(serial_only);
    CFRelease(empty);

    static const unsigned char eight[8] = {1, 2, 3, 4, 5, 6, 7, 8};
    CFDictionaryRef wide = dict_with_data("IOMACAddress", eight, sizeof eight);
    pj_fault_step = "network_props";
    pj_fault_times = 1 << 20;
    pj_fault_value = wide;
    expect_true("an IOMACAddress that is not 6 bytes stops the walk", pj_ids_gather(&ids) == 0 && ids.incomplete && strcmp(ids.incomplete, "network_address") == 0 && ids.walks == 1 && pj_fault_times < (1 << 20));
    pj_fault_value = NULL;
    /* The same rule for the bluetooth node's own address (extra pass 5 of
       PR 693): read whole in another shape, it cannot be churn, so the walk
       stops at once, named, after one walk, neither walked again nor called
       churn. Every entry is shown an 8-byte local-mac-address and only the
       real entry named bluetooth acts on it, so this passes only on an
       Apple-silicon Mac, where that device-tree node is in the IOService
       plane. Every entry's name is read for real on the way there, so a
       client closing under one of those reads is churn and a second walk
       (gather_walking). The name carries the step and walk count so a wrong
       answer says which rule broke: fixed names and a count, nothing read
       from the Mac. */
    CFDictionaryRef btwide = dict_with_data("local-mac-address", eight, sizeof eight);
    pj_fault_times = 1 << 20;
    pj_fault_value = btwide;
    int bt_r = gather_walking(&ids, 1, "bluetooth_node");
    char bt_name[160];
    snprintf(bt_name, sizeof bt_name, "a bluetooth node address that is not 6 bytes stops the walk at once, named (step %s, walks %d)",
             ids.incomplete ? ids.incomplete : "null", ids.walks);
    expect_true(bt_name, bt_r == 0 && ids.incomplete && strcmp(ids.incomplete, "bluetooth_node") == 0 && ids.walks == 1 && pj_fault_times < (1 << 20));
    pj_fault_value = NULL;
    CFRelease(btwide);
    pj_fault_times = 1 << 20;
    expect_true("a property read in the walk that keeps failing is walked again, then named", gather_walking(&ids, 4, "network_props") == 0 && ids.incomplete && strcmp(ids.incomplete, "network_props") == 0 && ids.walks == 4 && pj_fault_times < (1 << 20));
    pj_fault_step = "network_builtin";
    pj_fault_times = 1 << 20;
    expect_true("a built-in check that keeps failing is walked again, then named", gather_walking(&ids, 4, "network_builtin") == 0 && ids.incomplete && strcmp(ids.incomplete, "network_builtin") == 0 && ids.walks == 4 && pj_fault_times < (1 << 20));
    pj_fault_step = NULL;
    CFRelease(wide);
}

/* The walk's churn handling against the real kernel, not only the seam
   (Opus x3 review of PR 693: deleting the real IOIteratorIsValid calls
   passed the suite). This process opens a user client on IOPMrootDomain,
   the one registry change a test may make, and closes it from the hook at
   the moment the walk is about to read an entry, as another process closing
   its connection does. Measured on the mini, 2026-10-08: (a) closed as the
   walk reads it, that read fails with MACH_SEND_INVALID_DEST while the
   walk's iterator still says valid, and the walk runs on to the end (2434
   entries, valid at the end, 3 of 3 runs); (b) closed as the walk reads its
   first sibling, with the cursor on that child set, no read fails and the
   walk ends after 45 to 57 of 2611 entries with the iterator invalid (9 of
   9 runs, at 0, 20 and 50 ms). Either way the gather must walk again and
   complete with no step. (c) closed as the walk reads it on every walk, a
   new one opened for the next, every walk fails a read with the signs of
   churn (the read's MACH_SEND_INVALID_DEST, the entry out of the plane),
   so the attempts run out as registry_changing and not as network_props:
   the signs' real answers decide the name, where (a) proves only the retry.
   Counts and booleans only are printed. */
static io_service_t live_pm = 0;
static io_connect_t live_conn = 0;
static uint64_t live_pm_id = 0, live_client_id = 0;
static int live_fired = 0;

static uint64_t entry_id(io_registry_entry_t e) {
    uint64_t id = 0;
    IORegistryEntryGetRegistryEntryID(e, &id);
    return id;
}

static int live_child_ids(uint64_t *ids, int max) {
    io_iterator_t it = 0;
    int n = 0;
    if (IORegistryEntryGetChildIterator(live_pm, kIOServicePlane, &it) != KERN_SUCCESS) return -1;
    io_registry_entry_t c;
    while ((c = IOIteratorNext(it))) {
        if (n < max) ids[n++] = entry_id(c);
        IOObjectRelease(c);
    }
    IOObjectRelease(it);
    return n;
}

/* Opens the client and finds its entry: the child of IOPMrootDomain that
   appeared on opening. Another process opening one at the same moment makes
   that ambiguous, so a few tries. 1 with live_conn and live_client_id set. */
static int live_open_client(void) {
    for (int attempt = 0; attempt < 5; attempt++) {
        uint64_t before[1024], after[1024];
        int nb = live_child_ids(before, 1024);
        if (nb < 0 || IOServiceOpen(live_pm, mach_task_self(), 0, &live_conn) != KERN_SUCCESS) return 0;
        int na = live_child_ids(after, 1024), found = 0;
        for (int i = 0; i < na; i++) {
            int seen = 0;
            for (int j = 0; j < nb; j++) seen |= after[i] == before[j];
            if (!seen) {
                live_client_id = after[i];
                found++;
            }
        }
        if (found == 1) return 1;
        IOServiceClose(live_conn);
        live_conn = 0;
    }
    return 0;
}

static void live_close(void) {
    IOServiceClose(live_conn);
    live_conn = 0;
    live_fired = 1;
}

/* (a): the walk is about to read the client. */
static void close_as_read(io_registry_entry_t e) {
    if (!live_fired && entry_id(e) == live_client_id) live_close();
}

/* (b): the walk is about to read a sibling of the client (the client was
   appended last, so every sibling comes before it). The 20 ms lets the
   detach land while the cursor is still on that child set, so the cut
   point is the same every run (45 entries, measured). */
static void close_as_sibling_read(io_registry_entry_t e) {
    if (live_fired || entry_id(e) == live_client_id) return;
    io_registry_entry_t parent = 0;
    if (IORegistryEntryGetParentEntry(e, kIOServicePlane, &parent) != KERN_SUCCESS) return;
    int under_pm = entry_id(parent) == live_pm_id;
    IOObjectRelease(parent);
    if (!under_pm) return;
    live_close();
    usleep(20000);
}

/* (c): the walk is about to read the current client: close it and open
   the next, for the next walk to meet. */
static void close_each_read(io_registry_entry_t e) {
    if (!live_conn || entry_id(e) != live_client_id) return;
    IOServiceClose(live_conn);
    live_conn = 0;
    live_fired++;
    live_open_client();
}

static void test_ids_gather_live_churn(void) {
    pj_ids ids;
    pj_fault_step = NULL;
    pj_fault_value = NULL;
    live_pm = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"));
    expect_true("IOPMrootDomain is there to open a user client on", live_pm != 0);
    if (!live_pm) return;
    live_pm_id = entry_id(live_pm);

    expect_true("(a) this process's user client is told from its siblings", live_open_client());
    live_fired = 0;
    pj_before_read = close_as_read;
    int r = pj_ids_gather(&ids);
    pj_before_read = NULL;
    expect_true("(a) a user client closed as the walk reads it is churn: walked again and completed with no step",
                live_fired && r == 1 && ids.incomplete == NULL && ids.walks >= 2);
    if (live_conn) live_close();

    expect_true("(b) this process's user client is told from its siblings", live_open_client());
    live_fired = 0;
    pj_before_read = close_as_sibling_read;
    r = pj_ids_gather(&ids);
    pj_before_read = NULL;
    expect_true("(b) a walk cut short by a detach, with no read failing, is seen by its iterator: walked again and completed with no step",
                live_fired && r == 1 && ids.incomplete == NULL && ids.walks >= 2);
    if (live_conn) live_close();

    expect_true("(c) this process's user client is told from its siblings", live_open_client());
    live_fired = 0;
    pj_before_read = close_each_read;
    r = pj_ids_gather(&ids);
    pj_before_read = NULL;
    expect_true("(c) a read failed on every walk by a client closed under it stops as registry_changing, not as the read",
                live_fired >= 1 && r == 0 && ids.incomplete && strcmp(ids.incomplete, "registry_changing") == 0 && ids.walks == 4);
    if (live_conn) live_close();
    IOObjectRelease(live_pm);
    live_pm = 0;
}

/* The identifier walk's retries pause between attempts, growing (Opus review
   after extra pass 1: four attempts back to back, about 0.3 s together, all
   failed under a burst of about 580 user-client opens a second). */
static double seconds_now(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (double)t.tv_sec + (double)t.tv_nsec / 1e9;
}

static void test_retry_pause(void) {
    expect_true("no pause before the first attempt", pj_retry_pause(0) == 0);
    expect_true("10 ms before the second", pj_retry_pause(1) == 10000);
    expect_true("50 ms before the third", pj_retry_pause(2) == 50000);
    expect_true("200 ms before the fourth", pj_retry_pause(3) == 200000);
    expect_true("and 200 ms before any later one", pj_retry_pause(4) == 200000 && pj_retry_pause(9) == 200000);

    /* And the gather does pause (Opus x2 review of PR 693: with the usleep
       deleted every check still passed). Every walk is made to come back
       changed at its first read, so the walks cost microseconds and the
       time taken is the pauses. A lower bound only: a slow machine takes
       longer, never less. */
    pj_ids ids;
    pj_fault_step = "network_props network_changed";
    pj_fault_times = 1 << 20;
    double started = seconds_now();
    int r = pj_ids_gather(&ids);
    double took = seconds_now() - started;
    double pauses = (pj_retry_pause(1) + pj_retry_pause(2) + pj_retry_pause(3)) / 1e6;
    pj_fault_step = NULL;
    expect_true("four walks that all came back changed stop as registry_changing",
                r == 0 && ids.incomplete && strcmp(ids.incomplete, "registry_changing") == 0 && ids.walks == 4);
    char name[96];
    snprintf(name, sizeof name, "and take at least the three pauses between them (%.3f s, at least %.3f s)", took, pauses);
    expect_true(name, took >= pauses);
    /* A read that keeps failing with no sign of churn walks the same path
       (extra pass 4 of PR 693): the pauses, then its own name. */
    pj_fault_step = "network_props";
    pj_fault_times = 1 << 20;
    started = seconds_now();
    r = gather_walking(&ids, 4, "network_props");
    took = seconds_now() - started;
    pj_fault_step = NULL;
    expect_true("four walks that all failed the same read stop with its name", r == 0 && ids.incomplete && strcmp(ids.incomplete, "network_props") == 0 && ids.walks == 4);
    snprintf(name, sizeof name, "after the same three pauses (%.3f s, at least %.3f s)", took, pauses);
    expect_true(name, took >= pauses);
}

/* The USB class guard of 51 and 52 fails closed (Codex, PR 693 extra pass 2):
   a read that did not complete is unknown (-1), never "safe". The live part
   runs on the registry root (no class keys, children without them), with the
   fault seam standing in for the registry misbehaving; each fault must be seen
   to fire, or the check tested nothing. */
static void test_usb_class_guard(void) {
    long cls = 0;
    CFDictionaryRef eight = dict_with_number("bDeviceClass", 0x08), three = dict_with_number("bInterfaceClass", 0x03),
                    iface_eight = dict_with_number("bInterfaceClass", 0x08),
                    text = dict_with_string("bDeviceClass", "08"), none = dict_with_number("other", 1);
    expect_true("a class number is found", pj_usb_class_in(eight, "bDeviceClass", &cls) == 1 && cls == 0x08);
    expect_true("an absent key is absent", pj_usb_class_in(none, "bDeviceClass", &cls) == 0);
    expect_true("a class in another shape is unknown", pj_usb_class_in(text, "bDeviceClass", &cls) == -1);
    expect_true("mass storage is wanted", pj_usb_class_wanted(eight, "bDeviceClass", 0) == 1);
    expect_true("HID is wanted only when asked", pj_usb_class_wanted(three, "bInterfaceClass", 1) == 1 && pj_usb_class_wanted(three, "bInterfaceClass", 0) == 0);
    expect_true("another shape stays unknown through wanted", pj_usb_class_wanted(text, "bDeviceClass", 1) == -1);

    io_registry_entry_t root = IORegistryGetRootEntry(kIOMainPortDefault);
    pj_fault_step = NULL;
    pj_fault_value = NULL;
    expect_true("the root carries no USB class: confirmed neither", pj_usb_class_guard(root, 1) == 0);

    static const char *const steps[] = {"usb_class_props", "usb_class_children", "usb_class_child_props", "usb_class_iterator", NULL};
    for (int i = 0; steps[i]; i++) {
        pj_fault_step = steps[i];
        pj_fault_times = 1 << 20;
        int r = pj_usb_class_guard(root, 1);
        char name[96];
        snprintf(name, sizeof name, "a failed %s makes the guard unknown", steps[i]);
        expect_true(name, r == -1 && pj_fault_times < (1 << 20));
    }
    pj_fault_step = "usb_class_props";
    pj_fault_times = 1 << 20;
    pj_fault_value = text;
    expect_true("a class key of the wrong type makes the guard unknown", pj_usb_class_guard(root, 1) == -1);
    pj_fault_value = eight;
    expect_true("a mass-storage device is found", pj_usb_class_guard(root, 0) == 1);
    pj_fault_value = three;
    expect_true("a HID interface is found when HID counts", pj_usb_class_guard(root, 1) == 1);
    expect_true("and is not storage when it does not", pj_usb_class_guard(root, 0) == 0);
    pj_fault_step = "usb_class_child_props";
    pj_fault_value = iface_eight;
    expect_true("a mass-storage child is found", pj_usb_class_guard(root, 0) == 1 && pj_fault_times < (1 << 20));
    pj_fault_step = NULL;
    pj_fault_value = NULL;
    IOObjectRelease(root);
    CFRelease(eight);
    CFRelease(iface_eight);
    CFRelease(three);
    CFRelease(text);
    CFRelease(none);
}

/* The snapshot's walk stays under a depth limit. An entry with two parents in
   a plane can be reached first by a path that hits the limit and later by a
   shallower one (Codex review of PR 693: the mini has two such entries in
   IOService, first at depth 15 and 16, shallowest at 3 and 4): it is walked
   again from the shallower path, and never from the same depth or deeper. */
static void test_walk_first(void) {
    CFMutableDictionaryRef shallowest = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    expect_true("never walked: walk, however deep", pj_walk_first(shallowest, 7, 300) == 1);
    expect_true("reached again at the same depth (a second parent, or a cycle): no", pj_walk_first(shallowest, 7, 300) == 0);
    expect_true("reached deeper: no", pj_walk_first(shallowest, 7, 350) == 0);
    expect_true("reached shallower: walk again", pj_walk_first(shallowest, 7, 5) == 1);
    expect_true("reached between the two: no", pj_walk_first(shallowest, 7, 9) == 0);
    expect_true("another entry is its own case", pj_walk_first(shallowest, 8, 9) == 1);
    CFRelease(shallowest);
}

static void test_header_and_text(void) {
    capture c;
    setenv("WHATCABLE_APP_VERSION", "9.9.9", 1);
    start(&c, 0);
    pj_header(&c.w, "50_test");
    char *got = finish(&c);
    expect_contains("header fields", got,
                    "{\"record\":\"header\",\"format\":1,\"probe\":\"50_test\",\"probe_source_sha256\":\"unstamped\",\"app_version\":\"9.9.9\",\"started_at\":\"");
    free(got);

    unsetenv("WHATCABLE_APP_VERSION");
    start(&c, 0);
    pj_header(&c.w, "50_test");
    got = finish(&c);
    expect_contains("app_version null without the variable", got, "\"app_version\":null,");
    free(got);

    start(&c, 0);
    pj_text(&c.w, "plain");
    pj_text(&c.w, "\xff\xfe");
    got = finish(&c);
    expect_eq("text valid and invalid UTF-8", got, "\"plain\"{\"hex\":\"fffe\"}");
    free(got);
}

int main(void) {
    test_integers();
    test_floats();
    test_strings();
    test_process_name();
    test_data();
    test_containers();
    test_withhold();
    test_skip();
    test_part();
    test_privacy();
    test_shared_bytes();
    test_bytes_field();
    test_records_and_cap();
    test_entry_id();
    test_walk_first();
    test_usb_class_guard();
    test_retry_pause();
    test_ids_gather_fails_closed();
    test_ids_gather_shapes();
    test_ids_gather_live_churn();
    test_header_and_text();
    printf("probe_json: %d checks, %d failed\n", g_run, g_failed);
    return g_failed ? 1 : 0;
}
