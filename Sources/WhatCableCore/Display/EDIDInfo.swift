import Foundation

/// Parsed fields from a monitor's EDID (Extended Display Identification
/// Data): the descriptor block every display sends over DisplayPort / HDMI
/// describing what it is and which modes it supports.
///
/// Two different things live here, and they must not be confused:
///
/// - **Modes.** `preferredWidth`/`Height`/`RefreshHz` is the first detailed
///   timing (the out-of-the-box default); `topDetailedTiming` is the highest
///   detailed timing anywhere in the EDID. Both are modes the panel has.
/// - **The envelope.** `rangeLimitMaxRefreshHz` and
///   `rangeLimitMaxPixelClockHz` come from the 0xFD display range-limits
///   descriptor. They describe the range of signals the panel will *accept*,
///   not a mode it has. A 4K60 panel routinely declares a 75 Hz vertical
///   ceiling it has no 75 Hz mode for.
///
/// The diagnostic compares the link against the display's **top mode**, never
/// the preferred one: the feature's whole question is "why won't my monitor
/// run at its *full* refresh?", so checking against the preferred
/// (conservative) mode would hide exactly the bottleneck we are looking for,
/// a 100 Hz monitor capped to 60 Hz by a weak cable reading as "fine". The
/// top mode comes from `topDetailedTiming` here, and in `DisplayDiagnostic`
/// from CoreGraphics' `maxMode` in preference to it. It never comes from the
/// 0xFD envelope.
///
/// Pure value type, no platform imports, so it compiles on every target. The
/// 128-byte base block carries the preferred mode, the 0xFD envelope and four
/// timing slots; the CTA-861 extension block and the DisplayID extension
/// block (when present) are scanned too, so a top mode declared only there
/// still counts. Other extension data (DSC capability, audio, HDR) is not
/// yet parsed.
public struct EDIDInfo: Hashable, Sendable {
    /// One detailed timing descriptor: a mode the display actually has, as
    /// opposed to the 0xFD range-limits envelope, which is only the set of
    /// signals it will accept.
    public struct DetailedTiming: Hashable, Sendable {
        public let width: Int
        public let height: Int
        public let refreshHz: Int
        /// Pixel clock in Hz. Includes blanking, so this is the figure a
        /// bandwidth calculation needs. CoreGraphics reports active pixels
        /// only and runs 10-20% lower at the very same mode.
        public let pixelClockHz: Int

        public init(width: Int, height: Int, refreshHz: Int, pixelClockHz: Int) {
            self.width = width
            self.height = height
            self.refreshHz = refreshHz
            self.pixelClockHz = pixelClockHz
        }
    }

    /// Monitor name from the 0xFC descriptor, e.g. "LEN G34w-10". Not every
    /// EDID includes one, so optional.
    public let monitorName: String?

    /// EDID structure version / revision, e.g. 1 and 3 for EDID 1.3.
    public let versionMajor: Int
    public let versionMinor: Int

    /// Preferred mode, from the first detailed timing descriptor.
    public let preferredWidth: Int
    public let preferredHeight: Int
    public let preferredRefreshHz: Int
    /// Pixel clock of the preferred mode, in Hz.
    public let preferredPixelClockHz: Int

    /// Top of the vertical scan range the monitor will accept, in Hz, from
    /// byte 6 of the 0xFD range-limits descriptor. **Not a mode.** A panel
    /// with no mode above 60 Hz can and does declare 75 Hz here. Optional: a
    /// monitor EDID is not required to carry a range-limits descriptor.
    public let rangeLimitMaxRefreshHz: Int?
    /// Top of the pixel-clock range the monitor will accept, in Hz, from byte
    /// 9 of the 0xFD descriptor (stored there in units of 10 MHz). **Not a
    /// mode**, and not the same signal as the refresh ceiling above: the two
    /// bound the envelope independently. Not subject to the EDID 1.4
    /// rate-offset flags.
    public let rangeLimitMaxPixelClockHz: Int?

    /// The highest detailed timing in the EDID, by pixel clock: the display's
    /// real top mode. Nil when the EDID carries no detailed timing at all.
    public let topDetailedTiming: DetailedTiming?

    /// Memberwise init, mainly so tests (and the diagnostic's own tests) can
    /// fabricate an `EDIDInfo` without a raw byte blob.
    public init(
        monitorName: String?,
        versionMajor: Int,
        versionMinor: Int,
        preferredWidth: Int,
        preferredHeight: Int,
        preferredRefreshHz: Int,
        preferredPixelClockHz: Int,
        rangeLimitMaxRefreshHz: Int?,
        rangeLimitMaxPixelClockHz: Int?,
        topDetailedTiming: DetailedTiming? = nil
    ) {
        self.monitorName = monitorName
        self.versionMajor = versionMajor
        self.versionMinor = versionMinor
        self.preferredWidth = preferredWidth
        self.preferredHeight = preferredHeight
        self.preferredRefreshHz = preferredRefreshHz
        self.preferredPixelClockHz = preferredPixelClockHz
        self.rangeLimitMaxRefreshHz = rangeLimitMaxRefreshHz
        self.rangeLimitMaxPixelClockHz = rangeLimitMaxPixelClockHz
        self.topDetailedTiming = topDetailedTiming
    }

    /// Parse the 128-byte EDID base block. Returns `nil` when the blob is too
    /// short, the EDID header is wrong, or no usable timing is present.
    public init?(_ data: Data) {
        // Copy to a 0-based array. `Data` can be a slice with a non-zero
        // start index, so never index it directly.
        let bytes = [UInt8](data)
        guard bytes.count >= 128 else { return nil }

        // Every EDID base block starts with this fixed 8-byte header.
        let header: [UInt8] = [0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00]
        guard Array(bytes[0..<8]) == header else { return nil }

        self.versionMajor = Int(bytes[18])
        self.versionMinor = Int(bytes[19])

        // The four 18-byte descriptor slots in the base block.
        let descriptorOffsets = [54, 72, 90, 108]

        // Preferred timing = the first detailed timing descriptor. A slot is a
        // detailed timing when its pixel-clock word (bytes 0-1) is non-zero; a
        // zero there marks a display (text) descriptor instead.
        var preferred: DetailedTiming? = nil
        for off in descriptorOffsets {
            guard let timing = Self.detailedTiming(bytes, at: off) else { continue }
            preferred = timing
            break // first detailed timing is the preferred one
        }
        guard let preferred, preferred.width > 0, preferred.height > 0 else { return nil }
        self.preferredWidth = preferred.width
        self.preferredHeight = preferred.height
        self.preferredRefreshHz = preferred.refreshHz
        self.preferredPixelClockHz = preferred.pixelClockHz

        // Walk the display descriptors (bytes 0-2 all zero) for the range
        // limits (0xFD) and the monitor name (0xFC).
        var maxRefresh: Int? = nil
        var maxPixelClock: Int? = nil
        var name: String? = nil
        let isEDID14 = bytes[18] == 1 && bytes[19] >= 4
        for off in descriptorOffsets {
            guard bytes[off] == 0, bytes[off + 1] == 0, bytes[off + 2] == 0 else { continue }
            switch bytes[off + 3] {
            case 0xFD: // display range limits
                // EDID 1.4 can add 255 to the max vertical rate via an offset
                // flag (byte off+4, bit 1). 1.3 has no offsets. The pixel
                // clock ceiling below is unaffected by these flags.
                var maxV = Int(bytes[off + 6])
                if isEDID14 && (Int(bytes[off + 4]) & 0x02) != 0 {
                    maxV += 255
                }
                maxRefresh = maxV
                let pclk10MHz = Int(bytes[off + 9])
                if pclk10MHz != 0 {
                    maxPixelClock = pclk10MHz * 10_000_000
                }
            case 0xFC: // monitor name
                name = Self.decodeDescriptorString(Array(bytes[(off + 5)..<(off + 18)]))
            default:
                break
            }
        }
        // The 0xFD figures stay exactly what the descriptor said: they are the
        // envelope, never a mode. The real top mode is the highest detailed
        // timing, which for some monitors lives only in the CTA-861 or
        // DisplayID extension block, so the scan covers those too.
        self.rangeLimitMaxRefreshHz = maxRefresh
        self.rangeLimitMaxPixelClockHz = maxPixelClock
        self.topDetailedTiming = Self.highestDetailedTiming(bytes)
        self.monitorName = name
    }

    /// Decode the 18-byte detailed timing descriptor at `off`. Returns nil when
    /// the slot is a display (text) descriptor instead, which a zero pixel-clock
    /// word marks.
    private static func detailedTiming(_ bytes: [UInt8], at off: Int) -> DetailedTiming? {
        guard off + 17 < bytes.count else { return nil }
        let pixelClock10kHz = Int(bytes[off]) | (Int(bytes[off + 1]) << 8)
        guard pixelClock10kHz != 0 else { return nil }
        let clockHz = pixelClock10kHz * 10_000
        // Active / blanking are split across a low byte and a high nibble.
        let hActive = Int(bytes[off + 2]) | ((Int(bytes[off + 4]) >> 4) << 8)
        let hBlank  = Int(bytes[off + 3]) | ((Int(bytes[off + 4]) & 0x0F) << 8)
        let vActive = Int(bytes[off + 5]) | ((Int(bytes[off + 7]) >> 4) << 8)
        let vBlank  = Int(bytes[off + 6]) | ((Int(bytes[off + 7]) & 0x0F) << 8)
        // EDID 1.4 detailed-timing border bytes: offset +15 is the
        // horizontal border and +16 the vertical border, and each value
        // is per side, so the active picture is flanked by two of them.
        // Border pixels occupy pixel-clock cycles, so they widen the
        // total period and must be counted (twice) in the refresh
        // denominator — omitting them makes the rate read too high.
        let hBorder = Int(bytes[off + 15])
        let vBorder = Int(bytes[off + 16])
        let hTotal = hActive + hBlank + 2 * hBorder
        let vTotal = vActive + vBlank + 2 * vBorder
        var refreshHz = 0
        if hTotal > 0 && vTotal > 0 {
            refreshHz = Int((Double(clockHz) / Double(hTotal * vTotal)).rounded())
        }
        return DetailedTiming(
            width: hActive,
            height: vActive,
            refreshHz: refreshHz,
            pixelClockHz: clockHz
        )
    }

    /// The highest detailed timing in the EDID, by pixel clock: the four
    /// base-block slots plus, when present, the CTA-861 and DisplayID
    /// extension blocks' timings. This is the display's real top mode.
    /// Returns nil when the EDID carries no detailed timing at all.
    static func highestDetailedTiming(_ bytes: [UInt8]) -> DetailedTiming? {
        var highest: DetailedTiming? = nil
        func consider(_ timing: DetailedTiming?) {
            guard let timing else { return }
            if timing.pixelClockHz > (highest?.pixelClockHz ?? 0) { highest = timing }
        }

        // Base-block detailed timing slots.
        for off in [54, 72, 90, 108] {
            consider(detailedTiming(bytes, at: off))
        }

        // Extension blocks. EDID can carry several 128-byte blocks. Byte 126
        // of the base block is nominally the count, but it is not trusted:
        // measured against the corpus, 10 EDIDs under-declare it, each
        // hiding a further block past what byte 126 admits. 6 of those are a
        // DisplayID block, 3 are zero padding, and 1 (a Xiaomi Mi Monitor) is
        // a second CTA-861 block. Walk every complete 128-byte block actually
        // present in the buffer instead.
        let blocksPresent = max(0, (bytes.count - 128) / 128)
        for block in 0..<blocksPresent {
            let base = 128 + 128 * block
            switch bytes[base] {
            case 0x02:
                // CTA-861. Byte 2 of the block is the offset to its first
                // detailed timing (a value below 4 means none). Timings then
                // run in 18-byte chunks up to the block's checksum, ending at
                // a zero pixel clock.
                let dtdOffsetInExt = Int(bytes[base + 2])
                guard dtdOffsetInExt >= 4 else { continue }
                let blockChecksum = base + 127
                var off = base + dtdOffsetInExt
                while off + 18 <= blockChecksum {
                    let pclk10kHz = Int(bytes[off]) | (Int(bytes[off + 1]) << 8)
                    if pclk10kHz == 0 { break } // padding marks the end
                    consider(detailedTiming(bytes, at: off))
                    off += 18
                }
            case 0x70:
                // DisplayID. The section header (version, length, product
                // type, extension count) starts at block byte 1; data blocks
                // (tag, revision, payload length, payload) start at block
                // byte 5. Section length counts data-block bytes only, not
                // the checksum at byte 127, and a corrupt length must not
                // walk past it.
                let sectionVersion = bytes[base + 1]
                let sectionLength = Int(bytes[base + 2])
                let sectionEnd = base + min(5 + sectionLength, 127)
                var off = base + 5
                while off + 3 <= sectionEnd {
                    let tag = bytes[off]
                    let payloadLength = Int(bytes[off + 2])
                    if tag == 0 && payloadLength == 0 { break } // section end marker
                    // A data block whose header plus payload does not fit
                    // inside the section is corrupt or truncated: reject it
                    // whole and stop walking the section, rather than reading
                    // into the checksum byte or a neighbouring block.
                    guard off + 3 + payloadLength <= sectionEnd else { break }
                    // Only Type I (DisplayID 1.x) and Type VII (DisplayID
                    // 2.0) data blocks carry a full 20-byte detailed timing.
                    // Type II-VI are 1.x short/enumerated forms and Type
                    // VIII-X are 2.x enumerated/formula forms: none of them
                    // carry a full timing, and no corpus panel needs them for
                    // its top mode. The tag alone doesn't say which unit a
                    // clock is in: a 1.x section could in principle reuse a
                    // 2.x tag byte, so gate on the section version too (below
                    // 0x20 = 1.x, Type I; 0x20+ = 2.0, Type VII). Measured in
                    // the corpus: no 0x22 tag ever appears in a 1.x section,
                    // and no 0x03 tag in a 2.x one, so this loses nothing real.
                    let clockUnitHz: Int?
                    if tag == 0x03 && sectionVersion < 0x20 {
                        clockUnitHz = 10_000 // Type I
                    } else if tag == 0x22 && sectionVersion >= 0x20 {
                        clockUnitHz = 1_000 // Type VII
                    } else {
                        clockUnitHz = nil
                    }
                    if let clockUnitHz, payloadLength > 0, payloadLength % 20 == 0 {
                        var payloadOff = off + 3
                        let payloadEnd = payloadOff + payloadLength
                        while payloadOff + 20 <= payloadEnd {
                            consider(displayIDTiming(bytes, at: payloadOff, clockUnitHz: clockUnitHz))
                            payloadOff += 20
                        }
                    }
                    off += 3 + payloadLength
                }
            default:
                continue
            }
        }

        return highest
    }

    /// Decode a DisplayID 20-byte detailed timing payload at `off`. Same
    /// field layout for Type I and Type VII; `clockUnitHz` is the only
    /// difference (10 kHz for Type I, 1 kHz for Type VII). Unlike the
    /// base/CTA `detailedTiming(_:at:)`, DisplayID has no border bytes.
    private static func displayIDTiming(_ bytes: [UInt8], at off: Int, clockUnitHz: Int) -> DetailedTiming? {
        guard off + 19 < bytes.count else { return nil }
        let pixelClockUnits = Int(bytes[off]) | (Int(bytes[off + 1]) << 8) | (Int(bytes[off + 2]) << 16)
        let clockHz = (pixelClockUnits + 1) * clockUnitHz
        let hActive = (Int(bytes[off + 4]) | (Int(bytes[off + 5]) << 8)) + 1
        let hBlank  = (Int(bytes[off + 6]) | (Int(bytes[off + 7]) << 8)) + 1
        let vActive = (Int(bytes[off + 12]) | (Int(bytes[off + 13]) << 8)) + 1
        let vBlank  = (Int(bytes[off + 14]) | (Int(bytes[off + 15]) << 8)) + 1
        let hTotal = hActive + hBlank
        let vTotal = vActive + vBlank
        var refreshHz = 0
        if hTotal > 0 && vTotal > 0 {
            refreshHz = Int((Double(clockHz) / Double(hTotal * vTotal)).rounded())
        }
        return DetailedTiming(
            width: hActive,
            height: vActive,
            refreshHz: refreshHz,
            pixelClockHz: clockHz
        )
    }

    /// Decode a 13-byte EDID text payload (monitor name / serial). The string
    /// is ASCII, terminated by a line feed (0x0A) and padded with spaces.
    /// Only printable ASCII bytes (0x20-0x7E) are accepted; anything outside
    /// that range (including 0x0A terminator and Latin-1 high bytes) ends the
    /// scan so misbehaving monitors can't produce garbled output.
    private static func decodeDescriptorString(_ raw: [UInt8]) -> String? {
        var out = ""
        for b in raw {
            guard b >= 0x20, b <= 0x7E else { break }
            out.append(Character(UnicodeScalar(b)))
        }
        let trimmed = out.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}
