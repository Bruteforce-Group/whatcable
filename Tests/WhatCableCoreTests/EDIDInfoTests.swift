import Foundation
import Testing
@testable import WhatCableCore

@Suite("EDID Info")
struct EDIDInfoTests {

    /// The 128-byte EDID base block of a Lenovo G34w-10, captured verbatim
    /// from a real Mac in `probes/17_deep_property_dump_output.txt`. This is
    /// the golden sample: a 3440x1440 ultrawide whose preferred mode is 60 Hz
    /// but whose range-limits descriptor advertises a 100 Hz / 600 MHz
    /// ceiling. It is the exact case the feature exists to catch.
    /// Shared with `DisplayDiagnosticTests` for its end-to-end parse test.
    static let g34wBaseBlock: [UInt8] = [
        0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00, 0x30, 0xae, 0xa1, 0x66, 0x00, 0x00, 0x00, 0x00,
        0x34, 0x1d, 0x01, 0x03, 0x80, 0x50, 0x21, 0x78, 0xb6, 0xee, 0x95, 0xa3, 0x54, 0x4c, 0x99, 0x26,
        0x0f, 0x50, 0x54, 0xaf, 0xef, 0x00, 0x81, 0xc0, 0x81, 0x80, 0x95, 0x00, 0xa9, 0xc0, 0xb3, 0x00,
        0xd1, 0xc0, 0x71, 0x4f, 0x81, 0x8a, 0xf5, 0x7c, 0x70, 0xa0, 0xd0, 0xa0, 0x29, 0x50, 0x30, 0x20,
        0x35, 0x00, 0x1d, 0x4e, 0x31, 0x00, 0x00, 0x1a, 0x00, 0x00, 0x00, 0xff, 0x00, 0x55, 0x47, 0x57,
        0x30, 0x30, 0x32, 0x30, 0x35, 0x0a, 0x20, 0x20, 0x20, 0x20, 0x00, 0x00, 0x00, 0xfd, 0x00, 0x30,
        0x64, 0x17, 0xa0, 0x3c, 0x00, 0x0a, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x00, 0x00, 0x00, 0xfc,
        0x00, 0x4c, 0x45, 0x4e, 0x20, 0x47, 0x33, 0x34, 0x77, 0x2d, 0x31, 0x30, 0x0a, 0x20, 0x01, 0x49,
    ]

    /// The CTA-861 extension block (128 bytes) of the same G34w-10, captured
    /// live. Starts with the CTA tag 0x02; its detailed timings are all lower
    /// than the base block's modes. Appended to `g34wBaseBlock` to form the
    /// full 256-byte EDID without re-transcribing the proven base bytes.
    static let g34wExtensionHex =
        "020331f34b0102030405901213141f4e230907078301000067030c001000384267" +
        "d85dc401788000681a000001013064ed44d070a0d0a02950584045001d4e3100001e" +
        "662156aa51001e30468f33001d4e3100001e6a5e00a0a0a02950302035001d4e3100" +
        "001e226870a0d0a02950302035001d4e3100001a00000000000081"

    /// Full 384-byte EDID (base block + two CTA-861 extensions) of an LG
    /// UltraFine 4K (manufacturer GSM = LG, sink "22MD4K"), captured live from
    /// an Apple M3 Max over a *tunnelled* DisplayPort link via Test Kit probe
    /// 33 on 2026-05-30. Native DisplayPort, no adapter. The second real
    /// monitor golden sample alongside the G34w, and the first from a 4K panel.
    /// Verbatim from `research/dumps/displayport/2026-05-30_m3max_lg-ultrafine.md`.
    static let lgUltraFineHex =
        "00ffffffffffff001e6d7b5b00000000041d0104b5351e78803e31ae5047ac270c50542000000101010101010101010101010101010150d000a0f0703e803020630c0d272100001a000000ff0000000000000000000000000000000000fd00303c1e873c010a202020202020000000fc004c4720556c74726146696e650a027a701279000001000c8e126e0a0010000950784e772900106c370bdf4a3f44a19fc3f816f25e900d03003cbb9c00041f0d4f0007801f006107350000000700a25b0004ff094f0007801f009f05280000000700133400047f074f0007801f0037041e0000000700000000000000000000000000000000000000000000000000c390701279000003003c4fd00084ff0e9f002f801f006f083d003500020093ad0004ff0e9f002f801f006f083d003500020025680004ff0e9f002f801f006f083d0035000200000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000008f90"

    static func hexBytes(_ hex: String) -> [UInt8] {
        var out: [UInt8] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            out.append(UInt8(hex[i..<j], radix: 16)!)
            i = j
        }
        return out
    }

    @Test("Parses the real G34w-10 base block: preferred mode")
    func parsesPreferredMode() throws {
        let edid = try #require(EDIDInfo(Data(Self.g34wBaseBlock)))
        #expect(edid.preferredWidth == 3440)
        #expect(edid.preferredHeight == 1440)
        #expect(edid.preferredRefreshHz == 60)
        #expect(edid.preferredPixelClockHz == 319_890_000)
    }

    @Test("Parses the 0xFD range-limits descriptor: the max ceiling")
    func parsesMaxCapability() throws {
        let edid = try #require(EDIDInfo(Data(Self.g34wBaseBlock)))
        // This is the load-bearing assertion: the monitor's ceiling is 100 Hz
        // / 600 MHz, far above its 60 Hz preferred mode. The diagnostic must
        // compare the link against this, not the preferred mode.
        #expect(edid.rangeLimitMaxRefreshHz == 100)
        #expect(edid.rangeLimitMaxPixelClockHz == 600_000_000)
    }

    // MARK: - CTA-861 extension

    @Test("Parses the full 256-byte EDID with CTA extension: ceiling unchanged")
    func parsesFullBlockWithExtension() throws {
        let bytes = Self.g34wBaseBlock + Self.hexBytes(Self.g34wExtensionHex)
        #expect(bytes.count == 256)
        let edid = try #require(EDIDInfo(Data(bytes)))
        // The extension's detailed timings are all below the base block's, so
        // the preferred mode and the ceiling are identical to the base parse.
        #expect(edid.preferredWidth == 3440)
        #expect(edid.rangeLimitMaxPixelClockHz == 600_000_000)
    }

    @Test("Detailed-timing scan reads both base and extension descriptors")
    func scansAllDetailedTimings() {
        let bytes = Self.g34wBaseBlock + Self.hexBytes(Self.g34wExtensionHex)
        // The G34w declares its top mode (3440x1440 at ~100 Hz, 533.16 MHz) as
        // a detailed timing in the CTA extension, above the base block's 60 Hz
        // preferred (319.89 MHz). The scan must find it. The 0xFD ceiling
        // (600 MHz) still covers it, so the diagnostic's max is unchanged, but
        // this proves the extension scan reads a real higher mode that the base
        // block alone misses.
        let top = EDIDInfo.highestDetailedTiming(bytes)
        #expect(top?.pixelClockHz == 533_160_000)
        #expect(top?.width == 3440)
        #expect(top?.height == 1440)
    }

    @Test("The 0xFD ceiling sits above every real timing, and reads as its own figure")
    func ceilingIsNotAMode() throws {
        // The #596 shape: the envelope is higher than any mode the panel has.
        // The G34w declares a 600 MHz pixel-clock ceiling in its 0xFD
        // descriptor while its top real timing is 533.16 MHz. The two must not
        // be conflated: one is what the panel will accept, the other is what it
        // can actually show.
        let bytes = Self.g34wBaseBlock + Self.hexBytes(Self.g34wExtensionHex)
        let edid = try #require(EDIDInfo(Data(bytes)))
        #expect(edid.rangeLimitMaxPixelClockHz == 600_000_000)
        #expect(edid.topDetailedTiming?.pixelClockHz == 533_160_000)
        #expect(edid.rangeLimitMaxPixelClockHz != edid.topDetailedTiming?.pixelClockHz)
    }

    @Test("A mode declared only in the CTA extension becomes the top detailed timing")
    func extensionModeBecomesTopTiming() throws {
        // Base block (0xFD ceiling = 600 MHz) plus a synthetic CTA extension
        // whose detailed timing is 640 MHz, above the base ceiling. This is the
        // case that needs the extension scan: a real monitor where the top mode
        // lives only in the extension. The top timing must follow it, while the
        // 0xFD envelope stays exactly what the descriptor said.
        var bytes = Self.g34wBaseBlock
        var ext = [UInt8](repeating: 0, count: 128)
        ext[0] = 0x02 // CTA-861 tag
        ext[1] = 0x03 // revision
        ext[2] = 0x04 // detailed timings start right after the 4-byte header
        // Detailed timing at extension offset 4: pixel clock 640 MHz = 64000
        // (0xFA00) in 10 kHz units, little-endian.
        ext[4] = 0x00
        ext[5] = 0xFA
        ext[6] = 0x80 // arbitrary non-zero h-active, irrelevant to the scan
        bytes.append(contentsOf: ext)
        let edid = try #require(EDIDInfo(Data(bytes)))
        #expect(edid.topDetailedTiming?.pixelClockHz == 640_000_000)
        // And the envelope is byte 9 of the 0xFD descriptor, nothing else:
        // a higher detailed timing never raises it.
        #expect(edid.rangeLimitMaxPixelClockHz == 600_000_000)
    }

    @Test("Parses the monitor name and EDID version")
    func parsesNameAndVersion() throws {
        let edid = try #require(EDIDInfo(Data(Self.g34wBaseBlock)))
        #expect(edid.monitorName == "LEN G34w-10")
        #expect(edid.versionMajor == 1)
        #expect(edid.versionMinor == 3)
    }

    // MARK: - Second real monitor: LG UltraFine 4K (live, tunnelled DP)

    @Test("Parses the live LG UltraFine 4K EDID (base block + CTA extensions)")
    func parsesLGUltraFine() throws {
        let edid = try #require(EDIDInfo(Data(Self.hexBytes(Self.lgUltraFineHex))))
        #expect(edid.monitorName == "LG UltraFine")
        #expect(edid.preferredWidth == 3840)
        #expect(edid.preferredHeight == 2160)
        // 0xFD range-limits ceiling: 60 Hz, 600 MHz max pixel clock. The CTA
        // extensions carry only lower modes, so the ceiling is unchanged.
        #expect(edid.rangeLimitMaxRefreshHz == 60)
        #expect(edid.rangeLimitMaxPixelClockHz == 600_000_000)
    }

    @Test("Rejects a blob with a bad header")
    func rejectsBadHeader() {
        var bad = Self.g34wBaseBlock
        bad[0] = 0x01 // header must start 00 FF FF...
        #expect(EDIDInfo(Data(bad)) == nil)
    }

    @Test("Rejects a blob that is too short")
    func rejectsShortBlob() {
        let short = Array(Self.g34wBaseBlock.prefix(64))
        #expect(EDIDInfo(Data(short)) == nil)
    }

    @Test("Monitor name stops at first non-ASCII byte, not garbled Latin-1")
    func monitorNameIgnoresHighBytes() throws {
        // Inject a Latin-1 byte (0xE9 = 'e with accent') into the 0xFC monitor
        // name descriptor of the G34w base block. The 0xFC block starts at
        // offset 108; the name payload is at offsets 113-125. Byte 113 is the
        // first name character ('L'). Replacing it with 0xE9 should cause the
        // decoder to stop immediately, yielding nil (no printable chars before
        // the bad byte).
        var bytes = Self.g34wBaseBlock
        // 0xFC descriptor starts at offset 108; name bytes start at 108+5 = 113.
        bytes[113] = 0xE9
        let edid = try #require(EDIDInfo(Data(bytes)))
        // The name is truncated to nothing before the bad byte, so it should be nil.
        #expect(edid.monitorName == nil)
    }

    // MARK: - Detailed-timing border bytes and the preferred refresh rate

    /// Build a minimal valid 128-byte EDID 1.4 base block whose first
    /// descriptor slot (offset 54) carries a detailed timing with the given
    /// fields. Only the bytes `EDIDInfo` reads are populated: the 8-byte
    /// header, the 1.4 version bytes, the 18-byte detailed timing at offset
    /// 54, and a zero extension count (byte 126). The other three descriptor
    /// slots stay zero, so they are inert — a zero pixel clock is not a
    /// detailed timing, and a zero descriptor tag is not a monitor descriptor.
    /// Used to exercise the preferred-mode parse in isolation, in particular
    /// the refresh-rate formula's handling of the horizontal/vertical border
    /// bytes (detailed-timing offsets +15 / +16 per the EDID 1.4 spec).
    static func syntheticDetailedTimingBaseBlock(
        hActive: Int, hBlank: Int,
        vActive: Int, vBlank: Int,
        hBorder: Int, vBorder: Int,
        pixelClock10kHz: Int
    ) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 128)
        let header: [UInt8] = [0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00]
        for (i, b) in header.enumerated() { bytes[i] = b }
        bytes[18] = 1   // EDID 1.4
        bytes[19] = 4
        bytes[126] = 0  // no extension blocks

        let off = 54 // first descriptor slot == preferred timing
        // Pixel clock in 10 kHz units, little-endian word.
        bytes[off]     = UInt8(truncatingIfNeeded: pixelClock10kHz)
        bytes[off + 1] = UInt8(truncatingIfNeeded: pixelClock10kHz >> 8)
        // Active / blanking are split across a low byte and a high nibble.
        bytes[off + 2] = UInt8(truncatingIfNeeded: hActive)
        bytes[off + 3] = UInt8(truncatingIfNeeded: hBlank)
        bytes[off + 4] = UInt8(truncatingIfNeeded: (((hActive >> 8) << 4) | ((hBlank >> 8) & 0x0F)))
        bytes[off + 5] = UInt8(truncatingIfNeeded: vActive)
        bytes[off + 6] = UInt8(truncatingIfNeeded: vBlank)
        bytes[off + 7] = UInt8(truncatingIfNeeded: (((vActive >> 8) << 4) | ((vBlank >> 8) & 0x0F)))
        bytes[off + 15] = UInt8(truncatingIfNeeded: hBorder) // horizontal border, each side
        bytes[off + 16] = UInt8(truncatingIfNeeded: vBorder) // vertical border, each side
        return bytes
    }

    @Test("Preferred refresh accounts for non-zero h/v borders (lowers the rate)")
    func preferredRefreshHzAccountsForBorders() throws {
        // 1920x1080 active, 148.5 MHz pixel clock, with a 16-pixel horizontal
        // border and an 8-line vertical border on each side. Hand-computed
        // period (borders counted twice — one per side):
        //   hTotal = 1920 + 280 + 2×16 = 2232
        //   vTotal = 1080 +  45 + 2×8  = 1141
        //   rate   = round(148_500_000 / (2232 × 1141)) = round(58.31) = 58
        // Without borders the period would be 2200 × 1125 and the rate 60 —
        // the too-high value this test guards against.
        let bytes = Self.syntheticDetailedTimingBaseBlock(
            hActive: 1920, hBlank: 280,
            vActive: 1080, vBlank: 45,
            hBorder: 16, vBorder: 8,
            pixelClock10kHz: 14850
        )
        let edid = try #require(EDIDInfo(Data(bytes)))
        // Borders are timing overhead, not addressable pixels: the reported
        // resolution stays the active (addressable) area.
        #expect(edid.preferredWidth == 1920)
        #expect(edid.preferredHeight == 1080)
        #expect(edid.preferredRefreshHz == 58)
    }

    @Test("Zero borders leave the preferred refresh rate unchanged (control)")
    func preferredRefreshHzZeroBordersControl() throws {
        // Same timing as the bordered case but with zero borders: the rate is
        // the plain 148_500_000 / (2200 × 1125) = 60. This must hold both
        // before and after the border fix, proving borders are only ever added.
        let bytes = Self.syntheticDetailedTimingBaseBlock(
            hActive: 1920, hBlank: 280,
            vActive: 1080, vBlank: 45,
            hBorder: 0, vBorder: 0,
            pixelClock10kHz: 14850
        )
        let edid = try #require(EDIDInfo(Data(bytes)))
        #expect(edid.preferredRefreshHz == 60)
    }

    @Test("Each border axis widens the period independently and on both sides")
    func preferredRefreshHzAppliesEachBorderAxis() throws {
        // Horizontal border only (16 px each side): hTotal = 2232, vTotal = 1125.
        //   rate = round(148_500_000 / (2232 × 1125)) = round(59.10) = 59
        let hOnly = Self.syntheticDetailedTimingBaseBlock(
            hActive: 1920, hBlank: 280,
            vActive: 1080, vBlank: 45,
            hBorder: 16, vBorder: 0,
            pixelClock10kHz: 14850
        )
        #expect(try #require(EDIDInfo(Data(hOnly))).preferredRefreshHz == 59)

        // Vertical border only (8 lines each side): hTotal = 2200, vTotal = 1141.
        //   rate = round(148_500_000 / (2200 × 1141)) = round(59.16) = 59
        let vOnly = Self.syntheticDetailedTimingBaseBlock(
            hActive: 1920, hBlank: 280,
            vActive: 1080, vBlank: 45,
            hBorder: 0, vBorder: 8,
            pixelClock10kHz: 14850
        )
        #expect(try #require(EDIDInfo(Data(vOnly))).preferredRefreshHz == 59)
    }

    // MARK: - DisplayID extension
    //
    // DisplayID is a second, newer extension format (EDID extension tag
    // 0x70) that some panels use to declare their real top mode instead of,
    // or in addition to, a base-block or CTA-861 detailed timing. Layout:
    // a 128-byte block starting 0x70, structure version (0x12 = 1.2,
    // 0x13 = 1.3, 0x20 = 2.0), section length, product type, extension
    // count, then data blocks (tag, revision, payload length, payload)
    // starting at block byte 5. Type I timings (tag 0x03, DisplayID 1.x)
    // give the pixel clock in 10 kHz units, same as a base/CTA detailed
    // timing; Type VII timings (tag 0x22, DisplayID 2.0) use 1 kHz units
    // instead, same 20-byte payload shape otherwise.

    /// MSI MAG274Q QD E2, 384 bytes, captured live from a real Mac
    /// (`research/customer-probes/m1pro_macos26.5.2_z`). Base block + CTA-861
    /// extension (tag 0x02) + DisplayID 1.2 extension (tag 0x70, version
    /// 0x12). The DisplayID block holds one Type I data block (tag 0x03,
    /// four 20-byte timings); the fourth is the panel's real top mode,
    /// above anything the base or CTA blocks carry.
    static let mag274qHex =
        "00ffffffffffff003669c2ac000000000f220104b53c2178f957a5af4f3db727085054bfcf0081809500b300d1c0714fa9c0b33cd1fc386100a0a0a055503020350055502100001a000000fd0c30b4ffff48010a202020202020000000fc004d414732373451205144204532000000ff004343324848333437303135343802bd020333f123090707830100004a0103049011131f203f12e2007fe305c000e6060701665f006d1a0000020130b4000473217321023a801871382d40582c450055502100001e6fc200a0a0a055503020350055502100001aa08380a070382d403020350055502100001a00000000000000000000000000000000000000000000b8701279030003015034e30004ff099f002f001f009f052c0002000400fb310004ff049f002f001f009f052800020004004f110104ff099f002f001f009f05760002000400a7230104ff099f002f001f009f0554000200040000000000000000000000000000000000000000000000000000000000000000000000000000000a90"

    /// HG573T42, 384 bytes, captured live from a real Mac
    /// (`research/customer-probes/m4pro_macos26.6.2_e`). Base block + CTA-861
    /// extension (tag 0x02) + DisplayID 2.0 extension (tag 0x70, version
    /// 0x20). Four separate Type VII data blocks (tag 0x22), one 20-byte
    /// timing each, pixel clock in 1 kHz units rather than Type I's 10 kHz.
    static let hg573t42Hex =
        "00ffffffffffff004a8b42730000000015230104a5000078fe6435a5544f9e27125054210800d1c0a9c081c00101010101010101010150d000a0f0703e803020350061632100001a50d000a0f0703e803020350061632100001a000000fc0048473537335434320a20202020000000fd0028781e8780010a2020202020200299020334f149104c5d5e5f60613f7623097f078301000067030c002000b8ff67d85dc401ff8043e200eae3056000e606050169694f023a801871382d40582c450061632100001e565e00a0a0a029503020350061632100001e0000000000000000000000000000000000000000000000000000000000000000000000000000008970207900002200143f461084ff0e9f002f801f006f083d0002000400220014df8f0d04ff0e9f002f801f006f083d0002000400220014af340c04ff0e9f002f801f006f083d0002000400220014e72b0a04ff0e9f002f801f006f083d000200040000000000000000000000000000000000000000000000000000000000001490"

    /// DELL S2725QC, 384 bytes, captured live from a real Mac
    /// (`research/customer-probes/m4_macos26.5.2_j`). Base block byte 126
    /// declares 1 extension, but the buffer carries two: a CTA-861 block
    /// (tag 0x02) and, beyond what byte 126 admits, a DisplayID 1.2 block
    /// (tag 0x70) whose Type I timings include the panel's real 4K120 mode.
    static let s2725qcHex =
        "00ffffffffffff0010ac73a2000000001b230103803c2278eae1b5ac524d9d230e5054a54b00714f8180a9c0a940d1c0e1000101010108e80030f2705a80b0588a0055502100001e000000ff0000000000000000000000000000000000fc0044454c4c20533237323551430a000000fd0030781bff77000a20202020202001a9020364f1e278025361010302040510121113141f20213f5d5e5f7623090707830100006d030c00100038442000600302016ad85dc40178886b023078e40f010004e305c301e6060501626227741a000003013078e6000000000078000000008000e200ea565e00a0a0a029503020350055502100001a0000000000000000006270123f030003013c856f00047f079f002f801f0037043f00020004006ec20004ff099f002f801f009f055400020004000fd00104ff0e2f02af8057006f08590007800900520000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000090"

    @Test("MAG274Q: a Type I timing in a DisplayID 1.2 block becomes the top detailed timing")
    func mag274qDisplayIDTypeITopTiming() throws {
        let edid = try #require(EDIDInfo(Data(Self.hexBytes(Self.mag274qHex))))
        #expect(edid.topDetailedTiming?.width == 2560)
        #expect(edid.topDetailedTiming?.height == 1440)
        #expect(edid.topDetailedTiming?.refreshHz == 180)
        #expect(edid.topDetailedTiming?.pixelClockHz == 746_640_000)
        // The 0xFD envelope is a separate signal from the real top mode and
        // must not move when the top mode changes.
        #expect(edid.rangeLimitMaxPixelClockHz == 720_000_000)
        #expect(edid.monitorName == "MAG274Q QD E2")
    }

    @Test("MAG274Q: highestDetailedTiming reads the DisplayID block directly")
    func mag274qHighestDetailedTimingReadsDisplayIDDirectly() {
        let bytes = Self.hexBytes(Self.mag274qHex)
        #expect(EDIDInfo.highestDetailedTiming(bytes)?.pixelClockHz == 746_640_000)
    }

    @Test("HG573T42: a Type VII timing in a DisplayID 2.0 block uses 1 kHz pixel-clock units")
    func hg573t42DisplayIDTypeVIIUsesOneKHzUnits() throws {
        let edid = try #require(EDIDInfo(Data(Self.hexBytes(Self.hg573t42Hex))))
        #expect(edid.topDetailedTiming?.width == 3840)
        #expect(edid.topDetailedTiming?.height == 2160)
        #expect(edid.topDetailedTiming?.refreshHz == 120)
        // If Type VII were misread as 10 kHz units (Type I's unit) this
        // would come out as 10_665_600_000 Hz at 1200 Hz: asserting the
        // refresh here too means that unit mistake cannot pass.
        #expect(edid.topDetailedTiming?.pixelClockHz == 1_066_560_000)
        #expect(edid.rangeLimitMaxPixelClockHz == 1_280_000_000)
    }

    @Test("A Type VII tag inside a DisplayID 1.x section is not decoded")
    func typeVIITagInsideOnePointXSectionNotDecoded() throws {
        var bytes = Self.g34wBaseBlock
        bytes[126] = 1 // one extension block
        var block = [UInt8](repeating: 0, count: 128)
        block[0] = 0x70 // DisplayID extension tag
        block[1] = 0x12 // section version: DisplayID 1.2
        block[2] = 0x17 // section length: 3-byte header + 20-byte payload
        block[3] = 0x03 // product type
        block[4] = 0x00 // extension count
        block[5] = 0x22 // data block tag: Type VII, which only exists in 2.0
        block[6] = 0x00 // revision
        block[7] = 0x14 // payload length: 20 bytes
        // Huge under either clock unit: a correct version gate skips this
        // block regardless, since Type VII cannot appear in a 1.x section.
        block[8] = 0xFF
        block[9] = 0xFF
        block[10] = 0xFF
        bytes.append(contentsOf: block)
        let edid = try #require(EDIDInfo(Data(bytes)))
        #expect(edid.topDetailedTiming?.pixelClockHz == 319_890_000)
    }

    @Test("A Type I tag inside a DisplayID 2.0 section is not decoded")
    func typeITagInsideTwoPointOhSectionNotDecoded() throws {
        var bytes = Self.g34wBaseBlock
        bytes[126] = 1 // one extension block
        var block = [UInt8](repeating: 0, count: 128)
        block[0] = 0x70
        block[1] = 0x20 // section version: DisplayID 2.0
        block[2] = 0x17
        block[3] = 0x03
        block[4] = 0x00
        block[5] = 0x03 // data block tag: Type I, which only exists in 1.x
        block[6] = 0x00
        block[7] = 0x14
        block[8] = 0xFF
        block[9] = 0xFF
        block[10] = 0xFF
        bytes.append(contentsOf: block)
        let edid = try #require(EDIDInfo(Data(bytes)))
        #expect(edid.topDetailedTiming?.pixelClockHz == 319_890_000)
    }

    @Test("A DisplayID data block that is not a Type I / VII timing is skipped")
    func nonTimingDisplayIDBlockSkipped() throws {
        var bytes = Self.g34wBaseBlock
        bytes[126] = 1 // one extension block
        var block = [UInt8](repeating: 0, count: 128)
        block[0] = 0x70 // DisplayID extension tag
        block[1] = 0x12 // DisplayID 1.2
        block[2] = 0x17 // section length: 3-byte data-block header + 20-byte payload
        block[3] = 0x03 // product type
        block[4] = 0x00 // extension count
        block[5] = 0x04 // data block tag: Type II timing (short form), not Type I/VII
        block[6] = 0x00 // revision
        block[7] = 0x14 // payload length: 20 bytes
        // Payload: if misread as a 20-byte timing, the first three bytes
        // decode to a huge pixel clock under either unit (167.77 GHz at
        // Type I's 10 kHz, 16.78 GHz at Type VII's 1 kHz), well above the
        // base block's real top mode. A correct tag check must skip this
        // block regardless of which unit it would have used.
        block[8] = 0xFF
        block[9] = 0xFF
        block[10] = 0xFF
        bytes.append(contentsOf: block)
        let edid = try #require(EDIDInfo(Data(bytes)))
        #expect(edid.topDetailedTiming?.pixelClockHz == 319_890_000)
    }

    @Test("A DisplayID timing block whose length is not a multiple of 20 is skipped")
    func misalignedDisplayIDTimingBlockSkipped() throws {
        var bytes = Self.g34wBaseBlock
        bytes[126] = 1 // one extension block
        var block = [UInt8](repeating: 0, count: 128)
        block[0] = 0x70
        block[1] = 0x12
        block[2] = 0x21 // section length: 3-byte header + 30-byte payload
        block[3] = 0x03
        block[4] = 0x00
        block[5] = 0x03 // data block tag: Type I timing
        block[6] = 0x00 // revision
        block[7] = 0x1E // payload length: 30 bytes, not a multiple of 20
        // First 20 bytes decode to a huge pixel clock. Without the guard the
        // inner loop reads this as one valid 20-byte timing (the trailing 10
        // bytes going unread), well above the base block's real top mode.
        // With the guard the whole block is rejected. The remaining 10 bytes
        // of the 30-byte payload stay zero.
        block[8] = 0xFF
        block[9] = 0xFF
        block[10] = 0xFF
        bytes.append(contentsOf: block)
        let edid = try #require(EDIDInfo(Data(bytes)))
        #expect(edid.topDetailedTiming?.pixelClockHz == 319_890_000)
    }

    @Test("A DisplayID section length past the block end never indexes out of range")
    func sectionLengthPastBlockEndClamped() throws {
        var bytes = Self.g34wBaseBlock
        bytes[126] = 1 // one extension block
        var block = [UInt8](repeating: 0, count: 128)
        block[0] = 0x70
        block[1] = 0x12
        block[2] = 0xFF // section length claims far more than the 128-byte block holds
        block[3] = 0x03
        block[4] = 0x00
        block[5] = 0x03 // data block tag: Type I timing
        block[6] = 0x00 // revision
        block[7] = 0x14 // payload length: 20 bytes
        let timing = Self.hexBytes("a7230104ff099f002f001f009f05540002000400") // MAG274Q's fourth timing
        for (i, b) in timing.enumerated() { block[8 + i] = b }
        // Non-zero past the timing, so the walk cannot stop early on the
        // zero-tag/zero-length end marker: only the sectionEnd clamp keeps
        // it from reading past the 128-byte block.
        for i in 28...126 { block[i] = 0x01 }
        bytes.append(contentsOf: block)
        let edid = try #require(EDIDInfo(Data(bytes)))
        // The walk must clamp to the 128-byte block and still return the
        // timing it can read, rather than crashing.
        #expect(edid.topDetailedTiming?.pixelClockHz == 746_640_000)
    }

    @Test("An extension count larger than the buffer is walked only as far as the bytes go")
    func extensionCountLargerThanBufferWalksOnlyPresentBytes() throws {
        var bytes = Self.g34wBaseBlock
        bytes[126] = 3 // claims three extension blocks; only one is appended
        var block = [UInt8](repeating: 0, count: 128)
        block[0] = 0x70
        block[1] = 0x12
        block[2] = 0x17 // sane section length: 3-byte header + 20-byte payload
        block[3] = 0x03
        block[4] = 0x00
        block[5] = 0x03
        block[6] = 0x00
        block[7] = 0x14
        let timing = Self.hexBytes("a7230104ff099f002f001f009f05540002000400") // MAG274Q's fourth timing
        for (i, b) in timing.enumerated() { block[8 + i] = b }
        bytes.append(contentsOf: block)
        let edid = try #require(EDIDInfo(Data(bytes)))
        #expect(edid.topDetailedTiming?.pixelClockHz == 746_640_000)

        // Truncated to the base block plus a partial extension: must not
        // crash, and falls back to the base block's own real top mode.
        let truncated = Array(bytes.prefix(200))
        let truncatedEDID = try #require(EDIDInfo(Data(truncated)))
        #expect(truncatedEDID.topDetailedTiming?.pixelClockHz == 319_890_000)
    }

    @Test("A DisplayID data block whose payload runs past the section end is rejected whole")
    func dataBlockPayloadOverrunsSectionEndRejected() throws {
        var bytes = Self.g34wBaseBlock
        bytes[126] = 1 // one extension block
        var block = [UInt8](repeating: 0, count: 128)
        block[0] = 0x70
        block[1] = 0x12
        block[2] = 0x17 // section length: one 3-byte header + 20 bytes, not 40
        block[3] = 0x03
        block[4] = 0x00
        block[5] = 0x03 // data block tag: Type I timing
        block[6] = 0x00 // revision
        block[7] = 0x28 // payload length: 40 bytes, twice what the section holds
        let timing = Self.hexBytes("a7230104ff099f002f001f009f05540002000400") // MAG274Q's fourth timing
        for (i, b) in timing.enumerated() { block[8 + i] = b }
        // A second, far higher pixel clock right after it: if the overrunning
        // block were read instead of rejected, this is what a correct decode
        // of the (wrong) 40-byte payload would surface as the top mode.
        var secondTiming = timing
        secondTiming[0] = 0xFF
        secondTiming[1] = 0xFF
        secondTiming[2] = 0x0F
        for (i, b) in secondTiming.enumerated() { block[28 + i] = b }
        bytes.append(contentsOf: block)
        let edid = try #require(EDIDInfo(Data(bytes)))
        // The overrunning block is rejected whole, so neither timing counts;
        // the base block's own real top mode is what's left.
        #expect(edid.topDetailedTiming?.pixelClockHz == 319_890_000)
    }

    @Test("S2725QC: a DisplayID block beyond the extension count in byte 126 is still walked")
    func s2725qcDisplayIDBlockBeyondExtensionCountByteWalked() throws {
        let bytes = Self.hexBytes(Self.s2725qcHex)
        // Fixture guards: byte 126 under-declares what the buffer actually holds.
        #expect(bytes[126] == 1)
        #expect(bytes.count == 384)

        let edid = try #require(EDIDInfo(Data(bytes)))
        #expect(edid.monitorName == "DELL S2725QC")
        #expect(edid.topDetailedTiming?.width == 3840)
        #expect(edid.topDetailedTiming?.height == 2160)
        #expect(edid.topDetailedTiming?.refreshHz == 120)
        #expect(edid.topDetailedTiming?.pixelClockHz == 1_188_000_000)
        // The 0xFD envelope is a separate signal from the real top mode and
        // must not move when the top mode changes.
        #expect(edid.rangeLimitMaxPixelClockHz == 1_190_000_000)
    }

    @Test("highestDetailedTiming on an empty buffer returns nil")
    func highestDetailedTimingOnEmptyBufferReturnsNil() {
        #expect(EDIDInfo.highestDetailedTiming([]) == nil)
    }
}
