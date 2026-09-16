import Foundation

/// The display sibling of `ChargingDiagnostic` (power) and
/// `DataLinkDiagnostic` (data speed): it answers "is my monitor getting the
/// bandwidth for its best picture, and if not, where is the limit?"
///
/// **Honest altitude.** This dimension is genuinely weaker as an automatic
/// bottleneck-namer than power was, and the type is shaped to say so. Power
/// had three independently measured numbers (charger / cable / negotiated).
/// Here the only "delivered" number we get is the *current* link state
/// (`laneCount x rate`), and a DisplayPort link trains itself down to satisfy
/// whatever mode is on screen right now, to save power. So a link carrying
/// less than the monitor's top mode might mean "the cable/adapter can't do
/// more" OR "the user simply hasn't selected the higher mode, so the GPU
/// trained a lazy link." From passive current-state IOKit data we cannot tell
/// those apart.
///
/// Therefore:
/// - `.fine` is the one confident, unambiguous verdict. If the current link
///   already carries the monitor's top mode, there is definitively no link
///   bottleneck. Lead with this.
/// - `.belowMonitorMax` is **informational, not accusatory**. It states both
///   explanations and never declares the cable guilty.
/// - `.adapterLimit` flags that a USB-C -> HDMI/DVI/VGA converter is in the
///   chain, so a shortfall can't be pinned on the cable.
/// - `.unknownMode` when the link is live but there is nothing solid to
///   compare it against: an unreadable EDID, or a readable one whose declared
///   timings cannot account for the capability the panel claims. Report what
///   the link is doing, blame nothing, promise nothing.
///
/// Phase wording is deliberately plain (not `String(localized:)`) while the
/// copy is under review; it moves to the localised bundle once approved,
/// matching how `DataLinkDiagnostic` was handled.
public struct DisplayDiagnostic {
    public enum Bottleneck: Hashable, Sendable {
        /// The current link already carries the monitor's top mode. No limit.
        case fine
        /// The link, as currently trained, carries less than the monitor's
        /// top mode. Ambiguous by nature (cable/adapter cap vs unselected
        /// mode), so the wording stays non-accusatory.
        case belowMonitorMax
        /// A USB-C -> HDMI / DVI / VGA adapter sits in the chain, so a
        /// shortfall cannot be attributed to the cable.
        case adapterLimit
        /// Live link, but nothing trustworthy to compare it against. Two
        /// shapes reach it:
        /// - No readable EDID (or no readable link rate) at all.
        /// - A readable EDID whose declared timings cannot account for the
        ///   capability the panel claims: its 0xFD envelope sits far above
        ///   every detailed timing we could parse, and CoreGraphics gave us no
        ///   usable top mode to settle it. See `topModeUnreadable`. Saying "running at
        ///   full quality" there would be the mirror of issue #596's bug, so we
        ///   assert nothing instead.
        case unknownMode
        /// The link is at the DisplayPort ceiling (every lane, HBR3 or faster)
        /// yet short of the monitor's *uncompressed* top mode. DSC (~3:1
        /// compression) may be carrying the top mode through the link, and
        /// there is no wider link to select, so we can't claim the display is
        /// under-driven. Informational, never a warning. (Issue #246.)
        case compressionPlausible
        /// DSC is **provably active right now**: the live on-screen mode needs
        /// more uncompressed bandwidth than the link is carrying, yet the
        /// picture is reaching the display. That can only happen with
        /// compression on. Stronger than `.compressionPlausible` (a reasoned
        /// inference from the link being at the DP ceiling): this one is
        /// grounded in the empirical gap between `currentMode` and
        /// `deliveredGbps`. Positive, never a warning. (Jimmy's group feedback:
        /// users on DSC-needing modes like 4K120 over DP 1.4 were reading the
        /// old "monitor can do more" shortfall message as a fault.)
        case compressionActive
    }

    /// The resolved numbers behind the verdict, for the Pro "receipts" view.
    /// Kept separate from the `Bottleneck` enum (which is just the verdict
    /// kind) so the screen has structured data and the tests stay simple.
    public struct Facts: Hashable, Sendable {
        public let monitorName: String?
        public let preferredWidth: Int?
        public let preferredHeight: Int?
        public let preferredRefreshHz: Int?
        /// Refresh of the display's TOP MODE, as `topMode` resolved it:
        /// CoreGraphics' native top mode where we have a usable one (see
        /// `usableMaxMode`), else the highest detailed timing in the EDID. **Not** the 0xFD scan-range ceiling,
        /// which is the range of signals the panel accepts rather than a mode
        /// it has (issue #596). The name is kept because the Pro Display screen
        /// and the tests read it.
        public let maxRefreshHz: Int?
        /// Resolution of that same top mode, so a label never pairs one
        /// mode's refresh with another mode's resolution. `topDetailedTiming`
        /// is max-by-pixel-clock, and a panel whose fastest timing is
        /// 1920x1080@240 while its preferred mode is 2560x1440 (Samsung
        /// Odyssey G60SD) has no 2560x1440@240 mode to label. nil exactly when
        /// `maxRefreshHz` is nil.
        public let topModeWidth: Int?
        public let topModeHeight: Int?
        /// Bandwidth the monitor's top mode needs, usable Gbps (estimated).
        public let neededGbps: Double?
        /// Bandwidth the current link carries, usable Gbps (estimated).
        public let deliveredGbps: Double?
        public let lanes: Int
        public let maxLanes: Int
        public let rateDescription: String?
        /// "HDMI" / "DVI" / "VGA" when an adapter is in the chain, else nil.
        public let sinkType: String?
        /// The adapter / branch device's reported DisplayPort version, e.g.
        /// "DisplayPort 1.2", from the DP node's `BranchDeviceID`. nil for a
        /// direct connection or when the field is absent. Descriptive only:
        /// it is what the device reports about itself, paired with the
        /// demonstrated lane usage to explain a cap.
        public let branchDevice: String?
        /// The live on-screen mode from CoreGraphics, when the backend could
        /// match this display to its port. Drives the true resolution label
        /// (issue #249: 5K displays whose EDID can't describe their native
        /// mode). nil when there's no live data (tests, or no match).
        public let currentMode: DisplayCurrentMode?
        /// The display's native top mode as macOS reports it (CoreGraphics):
        /// highest resolution at its best refresh, EDID-free. The authoritative
        /// "top mode" for the capability label and the at-top-mode check. Same
        /// nil contract as `currentMode`.
        public let maxMode: DisplayCurrentMode?
    }

    /// Whether the cable can be implicated in a shortfall. Deliberately has
    /// no "the cable is the problem" value: from passive current-state data we
    /// can only ever *exonerate* the cable with confidence, never convict it
    /// (the same limit that keeps `.belowMonitorMax` non-accusatory). So the
    /// only confident verdict is "unlikely the cable", backed by demonstrated
    /// evidence, not by the e-marker's claimed rating (issue #111: active
    /// cables misreport their own e-marker, so a rating can't exonerate them).
    public enum CableAssessment: Hashable, Sendable {
        /// Demonstrated, not rated: the DP is tunneled over a Thunderbolt /
        /// USB4 link (so the cable carries far more than any DP mode needs),
        /// or the link is already using every DisplayPort lane the host
        /// exposes on a non-active cable (so the cable isn't lane-limiting).
        case unlikelyTheCable
        /// Can't tell from current-state data. The honest default.
        case inconclusive
    }

    public let bottleneck: Bottleneck
    public let summary: String
    public let detail: String
    public let facts: Facts
    /// Cable attribution, orthogonal to `bottleneck`. Only changes the wording
    /// in the `.belowMonitorMax` case; informational elsewhere.
    public let cableAssessment: CableAssessment
    /// Whether a USB Billboard device is enumerated on this port. Set only by
    /// the Pro Display screen (the inline surfaces never pass it, which keeps
    /// the Billboard *diagnosis* out of the port card by construction). Drives
    /// `billboardNote`.
    public let billboardPresent: Bool

    /// The Billboard-device diagnosis, or `nil` when it should not be shown.
    /// Fires only when a Billboard device is present **and** the link is below
    /// the monitor's best mode (`isWarning`, the same `needed <= delivered`
    /// comparison that drives the verdict, so there is one definition of
    /// "degraded"). A Billboard device on its own is often benign (docks park
    /// them there normally), so naming it is safe everywhere but this pointed
    /// inference is gated on the corroborating degraded link.
    public var billboardNote: String? {
        guard billboardPresent, isWarning else { return nil }
        return String(localized: "A Billboard device is present on this port. That usually appears when an Alt Mode like DisplayPort was set up but didn't fully come up. Your display is below its best mode, so a re-plug, a different cable, or a different adapter may bring it up. Some docks show a Billboard device normally, so this isn't always a fault.", bundle: _coreLocalizedBundle)
    }

    /// True for the cases worth a glance in the inline verdict. `.fine` is the
    /// all-clear and `.unknownMode` is a non-event, so neither warns. Note the
    /// wording stays non-accusatory even when this is true: a warning here
    /// means "worth looking at", not "the cable is broken".
    public var isWarning: Bool {
        switch bottleneck {
        case .fine, .unknownMode, .compressionPlausible, .compressionActive: return false
        case .belowMonitorMax, .adapterLimit: return true
        }
    }
}

extension DisplayDiagnostic {
    /// Assume standard 8-bit RGB (24 bits/pixel) for the bandwidth estimate.
    /// Real links may use 10-bit (30 bpp), chroma subsampling, or DSC
    /// compression, all of which change the maths, so the verdict wording
    /// hedges accordingly.
    static let assumedBitsPerPixel = 24
    /// Don't declare a shortfall on estimation noise alone.
    static let tolerance = 0.05
    /// How far the 0xFD range-limits envelope may sit above the best detailed
    /// timing we parsed before that timing stops counting as the panel's top
    /// mode.
    ///
    /// A panel that accepts a pixel clock more than 1.4x anything it declares
    /// as a detailed timing is declaring modes somewhere this parser does not
    /// read, mostly CTA-861 VIC codes. Blanking overhead (10-20%) and a
    /// loosely specified range cannot account for a gap that size. So the top
    /// mode is genuinely unknown and the honest answer is to assert nothing
    /// rather than to guess low, which would reassure the user about a link
    /// we have not actually checked.
    ///
    /// Re-measured 2026-09-16 with an independent parser over the 490 unique
    /// panel EDIDs in the customer-probe corpus that carry both an 0xFD pixel
    /// clock and a parsed timing. Before DisplayID Type I / VII timings were
    /// parsed, 98 of 490 (20.0%) sat over this line. With them parsed, 30 of
    /// 490 (6.1%) do: 68 rescued, the AORUS FO32U2P (4.39x, now 1.02x), DELL
    /// S2725QC (2.23x, now 1.00x), MSI MAG274Q QD E2 (1.45x, now 0.96x) and
    /// Sceptre O34 (1.46x, now 0.89x) among them. A DisplayID timing can still
    /// sit above the envelope: the envelope is loosely specified, which is
    /// why it was never a mode.
    ///
    /// What is still over the line declares its top mode somewhere this
    /// parser does not read, mostly CTA-861 VIC codes: the LG TV SSCR2 family
    /// (2.00x, 4K120 as a VIC) and the ASUS PG27AQDP (10.13x) among them.
    ///
    /// The line stays at 1.4, not 1.5, because the 1.4-1.5 band still isn't
    /// empty. The two panels that pulled it down, the MAG274Q and Sceptre
    /// O34, now parse, but the band still holds the Acer VG270 M3 (1.49x),
    /// whose 0xFD says 180 Hz against a parsed 120 Hz mode, and whose 180 Hz
    /// mode is in no timing this parser or DisplayID carries. The other four
    /// in that band (Lenovo P27h-10 1.41x, Lenovo T2254pC 1.44x, DELL
    /// S2725DS 1.46x, a Xiaomi "Mi Monitor" 1.46x) look like loose envelopes
    /// on 60 and 100 Hz panels and would lose a `.fine` to `.unknownMode` on
    /// the no-CoreGraphics path. A false all-clear costs more than a
    /// non-answer, so the line holds.
    ///
    /// Issue #596's own reporter sits at 1.13x and is deliberately below it:
    /// his panel keeps the all-clear.
    static let envelopeOverreachRatio = 1.4
    /// Margin for `.compressionActive`'s "live mode needs more than the link
    /// carries" check. Kept at 5%, same as the noise margin used elsewhere.
    ///
    /// Why no blanking adjustment: `liveModeNeedsCompression` compares an
    /// active-pixel estimate against the delivered link, while the link
    /// actually carries the EDID pixel clock (active + blanking, 10-20%
    /// higher). So if the active estimate already exceeds delivered, the real
    /// wire is even further over and DSC must be on. The math is conservative
    /// in our favour, not against it; widening this margin to "absorb blanking"
    /// would only create a false-negative band where genuine DSC modes get read
    /// as fine.
    static let compressionActiveTolerance = 0.05
    /// Per-lane rate (Gbps) at or above which the link is running at a high
    /// rate. HBR3 (8.1 Gbps/lane) is the ceiling over USB-C DisplayPort Alt
    /// Mode; UHBR is higher still. At all lanes and this rate, a shortfall
    /// against the *uncompressed* top mode is most likely covered by DSC, not
    /// a link the user can widen (issue #246).
    static let highRatePerLaneGbps = 8.0

    /// Production entry point. Parses the EDID from the DisplayPort node's own
    /// monitor blob, then defers to the injectable initialiser below.
    public init?(dp: IOPortTransportStateDisplayPort, cable: USBPDSOP? = nil, billboardPresent: Bool = false, port: AppleHPMInterface? = nil) {
        let edid = dp.monitor?.edid.flatMap { EDIDInfo($0) }
        self.init(dp: dp, edid: edid, cable: cable, billboardPresent: billboardPresent, port: port)
    }

    /// Test seam: the parsed EDID is injected rather than read from `dp`.
    /// Returns `nil` when there is no live DisplayPort link on this node, so
    /// ports with nothing plugged in stay silent.
    ///
    /// `cable` is the port's USB-PD e-marker (SOP' / SOP''), used only to tell
    /// whether the cable is active (issue #111: active cables misreport, so we
    /// never exonerate one on its e-marker).
    ///
    /// `port` must be the port that `cable` belongs to, so the classifier can
    /// read its `ActiveCable` flag. See `CableClassification.resolve`.
    public init?(dp: IOPortTransportStateDisplayPort, edid: EDIDInfo?, cable: USBPDSOP? = nil, billboardPresent: Bool = false, port: AppleHPMInterface? = nil) {
        guard dp.link.active else { return nil }
        self.billboardPresent = billboardPresent

        let lanes = dp.link.laneCount
        let maxLanes = dp.link.maxLaneCount
        let rate = dp.link.linkRateDescription
        let perLane = Self.perLaneGbps(fromDescription: rate)
        let delivered = perLane.map {
            Double(lanes) * $0 * Self.codingEfficiency(perLaneGbps: $0)
        }
        // Don't treat the built-in HDMI port on an Apple Silicon MacBook Pro /
        // Mac mini as if the display were behind a USB-C-to-HDMI adapter. The
        // SoC drives HDMI directly, so the HDMI sink is the port itself, not a
        // dongle in the chain. With sinkType nil here we skip the adapter-blame
        // branch below AND fall through to the HBR3 + max-lanes DSC carve-out
        // when the link is at its ceiling, which is the right verdict for a
        // native HDMI 2.1 panel running 4K120 via compression. Signal source:
        // `ParentPortTypeDescription` on the DP transport node, populated for
        // every native HDMI display across M1 Pro through M5 Pro in the corpus.
        let sinkType: String?
        if dp.parentPortTypeDescription?.uppercased() == "HDMI" {
            sinkType = nil
        } else {
            sinkType = Self.adapterSinkType(dp.dfpType)
        }
        let branchDevice = Self.branchDeviceLabel(dp.branchDeviceId)

        // Cable attribution. Exonerate only on demonstrated evidence: a
        // Thunderbolt / USB4 tunnel (the cable carries far more than any DP
        // mode needs), or every host DisplayPort lane already in use on a
        // cable we've positively identified as passive (so the cable isn't
        // lane-limiting). We require a *known* passive e-marker, not merely a
        // non-active one: an absent e-marker means an unidentified cable we
        // can't vouch for (often a cheap passive cable that could itself be
        // rate-limiting), and an active cable can misreport its own e-marker
        // (issue #111). The e-marker's claimed rating is never used to
        // exonerate. Assigned once here so it holds on every return path.
        // Read through the classifier, not the e-marker's self-report. Two
        // cables lose their exoneration by that change, both in the direction
        // the paragraph above asks for, so `cableAssessment` moves from
        // `.unlikelyTheCable` to `.inconclusive` for each:
        //
        //   1. a cable on a port whose controller reports an active cable;
        //   2. a cable carrying the issue #111 layout contradiction, with or
        //      without a port. Its VDO[3] is decoded under the passive layout
        //      on purpose, so the raw self-report used to read passive.
        let cableKnownPassive = cable.flatMap {
            CableClassification.resolve(identity: $0, port: port)
        }?.type == .passive
        let cableUnlikely = dp.link.tunneled
            || (lanes > 0 && lanes == maxLanes && cableKnownPassive)
        self.cableAssessment = cableUnlikely ? .unlikelyTheCable : .inconclusive

        // No readable EDID: we can describe the link but have nothing to judge
        // it against. Report, blame nothing.
        guard let edid else {
            self.facts = Facts(
                monitorName: nil,
                preferredWidth: nil, preferredHeight: nil, preferredRefreshHz: nil,
                maxRefreshHz: nil, topModeWidth: nil, topModeHeight: nil,
                neededGbps: nil, deliveredGbps: delivered,
                lanes: lanes, maxLanes: maxLanes,
                rateDescription: rate, sinkType: sinkType,
                branchDevice: branchDevice,
                currentMode: dp.currentMode, maxMode: dp.maxMode
            )
            self.bottleneck = .unknownMode
            self.summary = String(localized: "Display connected", bundle: _coreLocalizedBundle)
            let base = String(localized: "A display is connected but its capabilities aren't readable, so there's nothing to compare the link against.", bundle: _coreLocalizedBundle)
            if let delivered {
                self.detail = base + " " + String(localized: "The link is carrying about \(Self.gbps(delivered)) (\(lanes) of \(maxLanes) lanes).", bundle: _coreLocalizedBundle)
            } else {
                self.detail = base
            }
            return
        }

        let name = edid.monitorName ?? String(localized: "display", bundle: _coreLocalizedBundle)
        // The monitor's top MODE drives the comparison, never the 0xFD
        // range-limits envelope. See `topMode` for why the two are not
        // interchangeable (issue #596).
        let top = Self.topMode(maxMode: dp.maxMode, edid: edid)
        let needed = Double(top.pixelClockHz) * Double(Self.assumedBitsPerPixel) / 1_000_000_000

        let baseFacts = Facts(
            monitorName: edid.monitorName,
            preferredWidth: edid.preferredWidth,
            preferredHeight: edid.preferredHeight,
            preferredRefreshHz: edid.preferredRefreshHz,
            maxRefreshHz: top.refreshHz,
            topModeWidth: top.width, topModeHeight: top.height,
            neededGbps: needed,
            deliveredGbps: delivered,
            lanes: lanes, maxLanes: maxLanes,
            rateDescription: rate, sinkType: sinkType,
            branchDevice: branchDevice,
            currentMode: dp.currentMode, maxMode: dp.maxMode
        )

        // Without a delivered figure (unparseable rate string) we can't
        // compare. Report the monitor, blame nothing.
        guard let delivered else {
            self.facts = baseFacts
            self.bottleneck = .unknownMode
            self.summary = String(localized: "Display connected", bundle: _coreLocalizedBundle)
            self.detail = String(localized: "Your \(name) is connected, but the link rate isn't readable, so there's nothing to compare its capability against.", bundle: _coreLocalizedBundle)
            return
        }

        // Does the current link already carry the monitor's top mode?
        if needed <= delivered * (1 + Self.tolerance) {
            // ...but only say so when we can stand up what the top mode IS.
            // With no CoreGraphics mode and an envelope far above every timing
            // we parsed, the panel has modes we cannot see, so the comparison
            // just cleared was against an understated top. Reassuring the user
            // there is the mirror image of issue #596's bug. Report the link,
            // claim nothing. (The copy is deliberately the same as the
            // no-readable-EDID case: it says the display's capabilities are not
            // readable, which is exactly what is true here, and it is already
            // in every localisation catalogue.)
            if Self.topModeUnreadable(maxMode: dp.maxMode, edid: edid) {
                // The top-mode figures (`neededGbps`, `maxRefreshHz`) are nil
                // here, as on the no-readable-EDID path: the Pro receipts and
                // heading would otherwise print "Top mode needs N Gbps" and
                // "up to NHz" directly under a verdict saying the capabilities
                // aren't readable. The link facts stay; they are what the
                // verdict reports.
                self.facts = Facts(
                    monitorName: edid.monitorName,
                    preferredWidth: edid.preferredWidth,
                    preferredHeight: edid.preferredHeight,
                    preferredRefreshHz: edid.preferredRefreshHz,
                    maxRefreshHz: nil, topModeWidth: nil, topModeHeight: nil,
                    neededGbps: nil,
                    deliveredGbps: delivered,
                    lanes: lanes, maxLanes: maxLanes,
                    rateDescription: rate, sinkType: sinkType,
                    branchDevice: branchDevice,
                    currentMode: dp.currentMode, maxMode: dp.maxMode
                )
                self.bottleneck = .unknownMode
                self.summary = String(localized: "Display connected", bundle: _coreLocalizedBundle)
                self.detail = String(localized: "A display is connected but its capabilities aren't readable, so there's nothing to compare the link against.", bundle: _coreLocalizedBundle)
                    + " "
                    + String(localized: "The link is carrying about \(Self.gbps(delivered)) (\(lanes) of \(maxLanes) lanes).", bundle: _coreLocalizedBundle)
                return
            }
            self.facts = baseFacts
            self.bottleneck = .fine
            self.summary = String(localized: "Display running at full quality", bundle: _coreLocalizedBundle)
            self.detail = String(localized: "Your \(name) is connected and the link has the bandwidth for its top mode. Nothing is holding the picture back.", bundle: _coreLocalizedBundle)
            return
        }

        // Shortfall. The current link carries less than the monitor's top
        // mode. Stay non-accusatory: we can't tell a cable/adapter cap from an
        // unselected mode.
        let needLabel = Self.gbps(needed)
        let haveLabel = Self.gbps(delivered)
        let laneLabel: String
        if let rate {
            laneLabel = String(localized: "\(lanes) of \(maxLanes) lanes at \(rate)", bundle: _coreLocalizedBundle)
        } else {
            laneLabel = String(localized: "\(lanes) of \(maxLanes) lanes", bundle: _coreLocalizedBundle)
        }
        let canDo = top.refreshHz
            .map { String(localized: "up to \($0)Hz", bundle: _coreLocalizedBundle) }
            ?? String(localized: "a higher mode than the link is carrying", bundle: _coreLocalizedBundle)
        let dscCaveat = " " + String(localized: "High-resolution displays often use compression (DSC) to fit their top mode through a link like this, so selecting the higher mode in Display settings may reach it normally.", bundle: _coreLocalizedBundle)

        if let sinkType {
            self.facts = baseFacts
            self.bottleneck = .adapterLimit
            self.summary = String(localized: "Video is going through a \(sinkType) adapter", bundle: _coreLocalizedBundle)
            if let branchDevice {
                self.detail = String(localized: "Your \(name) is reached through a USB-C to \(sinkType) adapter that reports as \(branchDevice), currently carrying about \(haveLabel) (\(laneLabel)), short of the monitor's top mode (\(canDo), about \(needLabel)). With an adapter in the chain, the adapter's own limit may be the cap rather than the cable. A native DisplayPort connection, or a higher-spec adapter, would tell you which.", bundle: _coreLocalizedBundle) + dscCaveat
            } else {
                self.detail = String(localized: "Your \(name) is reached through a USB-C to \(sinkType) adapter, and the link isn't currently carrying the monitor's top mode (\(canDo), about \(needLabel)); it's carrying about \(haveLabel) (\(laneLabel)). With an adapter in the chain, the adapter's own limit may be the cap rather than the cable. Trying the monitor over native DisplayPort, or a higher-spec adapter, would tell you which.", bundle: _coreLocalizedBundle) + dscCaveat
            }
            return
        }

        // The link is at the DisplayPort ceiling (every lane, HBR3 or faster)
        // but still short of the monitor's *uncompressed* top mode. High-
        // resolution displays use DSC (~3:1 compression) to fit a higher mode
        // through a link like this, so the link rate alone can't tell whether
        // the display is already at its best mode, and there is no wider link
        // to select. Drop the "monitor can do more / change your resolution"
        // verdict here: it is the wrong advice when the link is maxed and the
        // picture may already be at full quality via compression. (Issue #246:
        // a 4K240 monitor running 240Hz over HBR3 + DSC was wrongly flagged as
        // under-driven.) Native DisplayPort only: the adapter path returned
        // above, and DSC reasoning doesn't carry through an HDMI/DVI/VGA
        // converter.
        if lanes > 0, lanes == maxLanes, let perLane, perLane >= Self.highRatePerLaneGbps {
            // Certainty upgrade (issue #246): if CoreGraphics confirms the
            // display is actually at its top mode, replace the hedged "may be
            // using compression" with a definitive "running at full quality".
            // Strict and fail-closed: only when we have a matched live mode and
            // it meets the panel's top mode by active-pixel throughput.
            // Anything short, or no live mode at all, keeps today's verdict.
            if let current = dp.currentMode, Self.meetsTopMode(current, maxMode: dp.maxMode, edid: edid) {
                self.facts = baseFacts
                self.bottleneck = .fine
                self.summary = String(localized: "Display running at full quality", bundle: _coreLocalizedBundle)
                self.detail = String(localized: "macOS reports your \(name) at its top mode (\(current.label)), and the link is carrying it. Many high-resolution displays use compression (DSC) to fit a mode like this through the link, so the link rate alone can't show it; your display is at full quality.", bundle: _coreLocalizedBundle)
                return
            }
            self.facts = baseFacts
            self.bottleneck = .compressionPlausible
            self.summary = String(localized: "Display may be using compression to reach its top mode", bundle: _coreLocalizedBundle)
            self.detail = String(localized: "Your \(name) can run \(canDo), which uncompressed would need about \(needLabel). This link is already running every lane at a high rate, carrying about \(haveLabel) (\(laneLabel)). Many high-resolution displays use compression (DSC) to fit their top mode through a link like this, so the link rate alone can't tell whether you're already at your best mode. If the picture looks right, it most likely is.", bundle: _coreLocalizedBundle)
            return
        }

        // DSC provably active. The live on-screen mode needs more uncompressed
        // bandwidth than the link is carrying, yet the picture is reaching the
        // display. The only way that holds is compression on: this is the link
        // doing what it's designed to do, not a fault. Stronger than the
        // ceiling-based `.compressionPlausible` inference above because the
        // evidence is grounded in CoreGraphics' live mode, not just the link
        // being at HBR3. This catches the case Jimmy's group flagged: 4K120
        // DSC-mode displays (DELL U2725QE etc.) over sub-ceiling links being
        // wrongly read as a shortfall.
        if let current = dp.currentMode,
           Self.liveModeNeedsCompression(current, deliveredGbps: delivered) {
            self.facts = baseFacts
            self.bottleneck = .compressionActive
            self.summary = String(localized: "Display running compressed (DSC) to fit through the link", bundle: _coreLocalizedBundle)
            self.detail = String(localized: "macOS reports your \(name)'s current mode as \(current.label), which would need more bandwidth than this link carries uncompressed. High-resolution displays use compression (DSC) to fit a mode like this through a link like this. The picture is reaching the display, so this is working as intended.", bundle: _coreLocalizedBundle)
            return
        }

        self.facts = baseFacts
        self.bottleneck = .belowMonitorMax
        self.summary = String(localized: "Monitor can do more than the link is carrying", bundle: _coreLocalizedBundle)
        if cableUnlikely {
            // The cable is exonerated on demonstrated evidence, so point the
            // user at the likely real cause (the selected mode / the Mac)
            // instead of leaving the cable under suspicion.
            if dp.link.tunneled {
                self.detail = String(localized: "Your \(name) can run \(canDo), which needs about \(needLabel), but the link is currently carrying about \(haveLabel) (\(laneLabel)). The video is tunneled over Thunderbolt or USB4, so the cable carries far more than the display needs: this is unlikely to be the cable. It's most likely the resolution or refresh rate selected in Display settings, or this Mac's limit for this display.", bundle: _coreLocalizedBundle) + dscCaveat
            } else {
                self.detail = String(localized: "Your \(name) can run \(canDo), which needs about \(needLabel), but the link is currently carrying about \(haveLabel) (\(laneLabel)). The cable is already carrying every DisplayPort lane this Mac provides, so this is unlikely to be the cable. It's most likely the resolution or refresh rate selected in Display settings.", bundle: _coreLocalizedBundle) + dscCaveat
            }
        } else {
            self.detail = String(localized: "Your \(name) can run \(canDo), which needs about \(needLabel), but the link is currently carrying about \(haveLabel) (\(laneLabel)). If you've selected the higher mode and aren't getting it, the cable or adapter is the likely limit; if you haven't tried it, selecting it may retrain the link to a higher rate.", bundle: _coreLocalizedBundle) + dscCaveat
        }
    }

    // MARK: - Helpers

    /// Pull the per-lane Gbps figure out of macOS's own rate description, e.g.
    /// "5.4 Gbps (HBR2)" -> 5.4. Using the string sidesteps the unconfirmed
    /// numeric `linkRate` enum (only code 3 / HBR2 is confirmed on real
    /// hardware). Returns nil for "No Link" or anything unparseable.
    static func perLaneGbps(fromDescription desc: String?) -> Double? {
        guard let desc, let gbpsRange = desc.range(of: "Gbps") else { return nil }
        let prefix = desc[desc.startIndex..<gbpsRange.lowerBound]
            .trimmingCharacters(in: .whitespaces)
        return Double(prefix)
    }

    /// Line-coding efficiency: 8b/10b (0.8) for RBR/HBR/HBR2/HBR3
    /// (<= 8.1 Gbps/lane), 128b/132b (~0.97) for UHBR (>= 10 Gbps/lane).
    static func codingEfficiency(perLaneGbps: Double) -> Double {
        perLaneGbps >= 10 ? 0.9697 : 0.8
    }

    /// Friendly label for the DP node's `BranchDeviceID`, the version the
    /// adapter / branch device reports for itself. Observed format is "Dp1.2"
    /// (a USB-C to HDMI adapter reporting DisplayPort 1.2). Normalised to
    /// "DisplayPort 1.2"; anything that doesn't match the "Dp<version>" shape
    /// is surfaced as-is so we never hide or mangle an unfamiliar value.
    /// Returns nil for a direct connection or an empty field.
    static func branchDeviceLabel(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if raw.lowercased().hasPrefix("dp") {
            let version = raw.dropFirst(2).trimmingCharacters(in: .whitespaces)
            if !version.isEmpty, version.first?.isNumber == true {
                return "DisplayPort \(version)"
            }
        }
        return raw
    }

    /// Map a downstream-facing-port type to an adapter sink type, or nil when
    /// the sink is native DisplayPort (no adapter in the chain).
    static func adapterSinkType(_ dfpType: String?) -> String? {
        guard let t = dfpType?.uppercased() else { return nil }
        if t.contains("HDMI") { return "HDMI" }
        if t.contains("DVI") { return "DVI" }
        if t.contains("VGA") { return "VGA" }
        return nil
    }

    /// Human-readable bandwidth, one decimal place, e.g. "14.4 Gbps".
    static func gbps(_ value: Double) -> String {
        String(format: "%.1f Gbps", locale: .current, value)
    }

    /// Whether the live on-screen mode demands more bandwidth than the link
    /// can carry uncompressed: the empirical proof that DSC is active right
    /// now. Bits per pixel come from `current.bitsPerComponent` when
    /// CoreGraphics reported it (8bpc -> 24bpp standard, 10bpc -> 30bpp for
    /// HDR / 10-bit colour), so a HDR mode that legitimately needs more raw
    /// bandwidth is not misread as DSC. With nil bpc we fall back to the
    /// 24bpp assumption, which keeps today's behaviour on backends that don't
    /// plumb bpc.
    ///
    /// The 5% tolerance is an estimation-noise margin, not a blanking
    /// adjustment. The active-pixel figure on the needed side already
    /// understates the real wire draw (which adds blanking), so "needed >
    /// delivered" already implies "wire > delivered" by a comfortable margin.
    /// Widening the tolerance further would only create a false-negative band
    /// where real DSC modes get read as fine.
    static func liveModeNeedsCompression(_ current: DisplayCurrentMode, deliveredGbps: Double) -> Bool {
        guard current.refreshHz > 0 else { return false }
        let bitsPerPixel = current.bitsPerComponent.map { $0 * 3 } ?? Self.assumedBitsPerPixel
        let neededGbps = current.pixelThroughput * Double(bitsPerPixel) / 1_000_000_000
        return neededGbps > deliveredGbps * (1 + Self.compressionActiveTolerance)
    }

    /// The display's top mode: its resolution, pixel clock and refresh. The
    /// resolution travels with the refresh so a label never pairs one mode's
    /// refresh with another mode's resolution (see `Facts.topModeWidth`).
    ///
    /// Three sources, three different jobs, and using the wrong one is issue
    /// #596:
    /// - `maxMode` (CoreGraphics) is authoritative about WHICH mode is top. It
    ///   is EDID-free, so it is right even for 5K/6K panels whose EDID cannot
    ///   describe their native mode (issue #249).
    /// - A detailed timing supplies that mode's PIXEL CLOCK, which is what
    ///   bandwidth needs because it includes blanking. CoreGraphics reports
    ///   active pixels only and runs 10-20% lower at the very same mode (see
    ///   `meetsTopMode`).
    /// - The 0xFD range-limits envelope supplies neither. It is the range of
    ///   signals the panel accepts, not a mode it has. An AOC U24P10R, a 4K60
    ///   panel, declares a 75 Hz / 600 MHz envelope and has no 75 Hz mode; the
    ///   worst in the corpus (ASUS PG27AQDP) declares 2.52 GHz against a real
    ///   top timing of 248.87 MHz. So it appears at no rung below, and if you
    ///   find yourself reaching for it the ladder is wrong.
    ///
    /// `refreshHz` is nil when nothing readable supplies one; callers fall back
    /// to generic wording rather than printing a number they cannot stand up.
    static func topMode(maxMode: DisplayCurrentMode?, edid: EDIDInfo)
        -> (width: Int, height: Int, pixelClockHz: Int, refreshHz: Int?) {
        let timing = edid.topDetailedTiming

        // Rungs 1 and 2 run only on a max mode that can raise the top above
        // what the EDID declares. One that sits below the panel's own timing
        // is describing the link, not the panel (see `usableMaxMode`), and
        // falls straight through to rung 3.
        if let maxMode = Self.usableMaxMode(maxMode, against: timing) {
            let maxRefresh = Int(maxMode.refreshHz.rounded())

            // Rung 1. CoreGraphics names the top mode and the EDID has a
            // detailed timing for that same mode, so we get the authoritative
            // mode AND its real pixel clock. Everything below is a degradation
            // of this.
            //
            // "Same mode" means resolution and refresh both, not resolution
            // alone: a 4K120 panel that declares only a 4K60 detailed timing
            // matches on pixel count while its 533 MHz clock describes half the
            // mode CoreGraphics named. Matching on pixels alone there would pair
            // a 60 Hz bandwidth figure with a "120Hz" label, which is the same
            // class of mismatch as #596 itself. That case belongs on rung 2.
            if let timing,
               Self.withinTolerance(Double(timing.width), Double(maxMode.width)),
               Self.withinTolerance(Double(timing.height), Double(maxMode.height)),
               Self.withinTolerance(Double(timing.refreshHz), maxMode.refreshHz) {
                return (maxMode.width, maxMode.height, timing.pixelClockHz, maxRefresh)
            }

            // Rung 2. CoreGraphics names a mode no detailed timing describes:
            // the 5K/6K case, and any panel whose top mode is declared in a
            // form we don't parse. Below rung 1 because the pixel clock is
            // derived, not read. CoreGraphics counts active pixels only, so
            // scale its rate up by the blanking overhead of the panel's OWN top
            // timing. Self-calibrating from the same hardware, which beats a
            // hardcoded constant.
            let activeRate = Double(maxMode.width) * Double(maxMode.height) * maxMode.refreshHz
            if activeRate > 0 {
                let ratio: Double
                if let timing,
                   timing.width > 0, timing.height > 0, timing.refreshHz > 0,
                   timing.pixelClockHz > 0 {
                    let timingActive = Double(timing.width) * Double(timing.height) * Double(timing.refreshHz)
                    ratio = Double(timing.pixelClockHz) / timingActive
                } else {
                    // No timing to calibrate from. 1.08 is a CVT
                    // reduced-blanking approximation and an estimate, not a
                    // measurement: it is the weakest number in this function.
                    ratio = 1.08
                }
                return (maxMode.width, maxMode.height, Int((activeRate * ratio).rounded()), maxRefresh)
            }
        }

        // Rung 3. No usable CoreGraphics mode. The highest detailed timing is
        // then the only mode evidence the display has given us. Below rung 2
        // because the EDID can understate a panel whose top mode is declared
        // somewhere we don't parse; it can never overstate it the way the
        // envelope does.
        if let timing, timing.pixelClockHz > 0 {
            return (timing.width, timing.height, timing.pixelClockHz, timing.refreshHz > 0 ? timing.refreshHz : nil)
        }

        // Rung 4. No detailed timing at all (an EDID carrying only standard
        // timings). The preferred mode is the conservative floor: it is a mode
        // the panel really has, just not necessarily its best one.
        return (
            edid.preferredWidth,
            edid.preferredHeight,
            edid.preferredPixelClockHz,
            edid.preferredRefreshHz > 0 ? edid.preferredRefreshHz : nil
        )
    }

    /// Whether the top mode `topMode` resolved is too weak to reassure anyone
    /// with: the panel's 0xFD envelope sits more than `envelopeOverreachRatio`
    /// above the best detailed timing we could parse, and CoreGraphics gave us
    /// no usable top mode to settle it.
    ///
    /// The envelope is still never used as a mode (that is issue #596). It is
    /// used here only as evidence that a mode exists which we cannot see, so
    /// the ladder's rung-3 answer understates the panel and a `.fine` verdict
    /// built on it would be a false all-clear. See `envelopeOverreachRatio`.
    ///
    /// Three conditions, all required:
    /// - No usable CoreGraphics top mode, by the same `usableMaxMode` test the
    ///   ladder applies. Where macOS names a top mode at or above the panel's
    ///   own timing we trust it completely and this check never fires,
    ///   whatever the envelope says. A max mode BELOW the timing is
    ///   link-limited, not authoritative, so it does not switch the check off.
    ///   (`DisplayModeReader` drops the max mode when two identical panels
    ///   can't be told apart, or when a refresh reads zero, so the no-max-mode
    ///   path is a live-app path and not only corpus replay.)
    /// - An envelope pixel clock.
    /// - A parsed detailed timing to compare it against. No envelope or no
    ///   timing means no comparison to make, so behaviour is unchanged.
    static func topModeUnreadable(maxMode: DisplayCurrentMode?, edid: EDIDInfo) -> Bool {
        guard Self.usableMaxMode(maxMode, against: edid.topDetailedTiming) == nil else { return false }
        guard let envelope = edid.rangeLimitMaxPixelClockHz, envelope > 0,
              let timing = edid.topDetailedTiming, timing.pixelClockHz > 0
        else { return false }
        return Double(envelope) > Double(timing.pixelClockHz) * Self.envelopeOverreachRatio
    }

    /// The CoreGraphics max mode, if it is fit to name the panel's top mode;
    /// nil when it is not.
    ///
    /// The principle: **a max mode may only ever RAISE the top mode above what
    /// the EDID declares, never lower it.** A detailed timing is a mode the
    /// panel has. CoreGraphics builds its mode list (the one System Settings
    /// shows) from what the trained link can carry, so a 4K60 panel behind a
    /// 2-lane hub can report a 4K30 max mode. That number describes the link,
    /// not the panel, and taking it as the top mode would clear the link
    /// against the very cap the user came to ask about: a monitor capped by a
    /// weak cable reading as "full quality", which is the one failure
    /// `EDIDInfo`'s type comment forbids.
    ///
    /// So the max mode is usable when its refresh is readable and its
    /// active-pixel rate is at least the top timing's (within `tolerance`),
    /// or when there is no timing to compare against. Compared in the
    /// active-pixel domain on both sides, never against the timing's pixel
    /// clock, which carries blanking.
    private static func usableMaxMode(
        _ maxMode: DisplayCurrentMode?, against timing: EDIDInfo.DetailedTiming?
    ) -> DisplayCurrentMode? {
        guard let maxMode, maxMode.refreshHz > 0 else { return nil }
        guard let timing, timing.width > 0, timing.height > 0, timing.refreshHz > 0 else {
            return maxMode
        }
        let timingActive = Double(timing.width) * Double(timing.height) * Double(timing.refreshHz)
        guard maxMode.pixelThroughput >= timingActive * (1 - Self.tolerance) else { return nil }
        return maxMode
    }

    /// Whether two figures agree within `tolerance`, used to decide whether a
    /// detailed timing and a CoreGraphics mode are the same mode.
    private static func withinTolerance(_ a: Double, _ b: Double) -> Bool {
        guard a > 0, b > 0 else { return false }
        return abs(a - b) <= max(a, b) * Self.tolerance
    }

    /// Whether the live mode meets the monitor's top mode. Compared in one
    /// domain on purpose: active-pixel throughput on both sides. Never the EDID
    /// pixel clock, which includes blanking and would run ~10-20% higher than
    /// CoreGraphics' active-pixel figure at the very same mode, making this
    /// comparison fail when it shouldn't. The tolerance absorbs blanking and
    /// refresh rounding.
    ///
    /// The top-mode reference is the HIGHER of the CoreGraphics max mode (the
    /// EDID-free top mode, which handles 5K for free where the EDID
    /// under-reports the native mode) and the EDID's highest detailed timing,
    /// falling back to the preferred mode when neither is there. The higher of
    /// the two, not CoreGraphics first: a max mode may only raise the top
    /// above what the EDID declares, never lower it, because a max mode below
    /// a timing the panel really has is describing a link-limited mode list
    /// (see `usableMaxMode`). Never the 0xFD range-limits envelope: that is a
    /// range of acceptable signals, not a mode the panel has, and treating it
    /// as one is issue #596.
    static func meetsTopMode(_ current: DisplayCurrentMode, maxMode: DisplayCurrentMode?, edid: EDIDInfo) -> Bool {
        var candidates: [Double] = []
        if let maxMode {
            candidates.append(maxMode.pixelThroughput)
        }
        if let timing = edid.topDetailedTiming, timing.refreshHz > 0 {
            // The panel's own top mode, in active pixels. Deliberately the
            // timing's width/height/refresh and never its pixel clock: this
            // comparison lives in the active-pixel domain on both sides, and a
            // pixel clock carries blanking (see the doc comment above).
            candidates.append(Double(timing.width) * Double(timing.height) * Double(timing.refreshHz))
        }
        let topThroughput = candidates.max()
            ?? Double(edid.preferredWidth) * Double(edid.preferredHeight) * Double(edid.preferredRefreshHz)
        guard topThroughput > 0 else { return false }
        return current.pixelThroughput >= topThroughput * (1 - Self.tolerance)
    }

    // MARK: - Link-rate labelling (shared by every Pro UI surface)

    /// Confirmed numeric `linkRate` fallback, used only when macOS's own
    /// `linkRateDescription` string isn't available. Sourced from a sweep of
    /// the probe-33 (`displayport_capability`) customer submissions. As of the
    /// 2026-07-22 batch the only codes ever observed are 0 ("No Link"),
    /// 1 ("1.62 Gbps (RBR)"), 2 ("2.7 Gbps (HBR)"), 3 ("5.4 Gbps (HBR2)"), and
    /// 4 ("8.1 Gbps (HBR3)"). Code 1 (RBR) is now corpus-confirmed: it first
    /// appeared in that batch on an M2 Max driving an HP E271i over USB-C,
    /// which macOS itself labelled "1.62 Gbps (RBR)". The kernel's own table
    /// (IODisplayPortFamily transport state, build 25G83, read 2026-09-16)
    /// continues 5 "10 Gbps (UHBR10)", 6 "13.5 Gbps (UHBR13.5)",
    /// 7 "20 Gbps (UHBR20)"; none has appeared in the corpus, so they are
    /// left out here until one does. See
    /// research/classes/_meaning/IOPortTransportStateDisplayPort.md.
    public static let confirmedLinkRateDescriptions: [Int: String] = [
        0: "No Link",
        1: "1.62 Gbps (RBR)",
        2: "2.7 Gbps (HBR)",
        3: "5.4 Gbps (HBR2)",
        4: "8.1 Gbps (HBR3)",
    ]

    /// Best available link-rate description: macOS's own string when present
    /// and non-blank (always preferred, since it's what the OS itself
    /// reports), else the confirmed numeric fallback above, else nil.
    /// Callers render nil with their own "Rate N" / "Unknown" wording, since
    /// that's a presentation choice, not data this helper owns.
    /// Whitespace-only strings count as absent so a blank IOKit value can't
    /// render as an empty-looking row.
    public static func linkRateDescription(rate: Int, description: String?) -> String? {
        if let trimmed = description?.trimmingCharacters(in: .whitespacesAndNewlines),
           !trimmed.isEmpty {
            return trimmed
        }
        return confirmedLinkRateDescriptions[rate]
    }

    /// Short mode name parsed out of a link-rate description's parenthesised
    /// token, e.g. "5.4 Gbps (HBR2)" -> "HBR2". Follows the same
    /// description-first / confirmed-numeric order as `linkRateDescription`.
    /// When the description has no clean parenthesised token (a bare
    /// "UHBR20", nested parens, malformed pairs), the whole description is
    /// returned rather than a guessed fragment: a real OS string beats the
    /// caller's "Rate N" fallback. "No Link" returns nil so inactive links
    /// keep their own wording.
    public static func linkRateShortName(rate: Int, description: String?) -> String? {
        guard let resolved = linkRateDescription(rate: rate, description: description) else {
            return nil
        }
        if resolved == "No Link" { return nil }
        // Token between the first "(" and the last ")". A token that still
        // contains "(" means nested or malformed parens; fall back to the
        // full description instead of a garbled fragment.
        if let open = resolved.firstIndex(of: "("),
           let close = resolved.lastIndex(of: ")"),
           open < close {
            let token = resolved[resolved.index(after: open)..<close]
            if !token.isEmpty, !token.contains("(") { return String(token) }
        }
        return resolved
    }
}
