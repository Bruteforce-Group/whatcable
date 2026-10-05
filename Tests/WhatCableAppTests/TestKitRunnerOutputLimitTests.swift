import Foundation
import Testing
@testable import WhatCable

// These tests launch real subprocesses and include an intentional watchdog
// timeout. Serial execution keeps the timeout test from racing the two
// concurrent 6 MiB output fixtures on slower CI hosts.
@Suite("Test Kit probe output limit", .serialized)
struct TestKitRunnerOutputLimitTests {
    @Test("Output at the byte limit is preserved")
    @MainActor
    func outputAtLimitIsPreserved() async throws {
        let fixture = try makeOutputFixture(byteCount: TestKitRunner.maxProbeOutputBytes)
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }

        let result = await TestKitRunner.shared.runProbe(at: fixture)

        #expect(result.output?.utf8.count == TestKitRunner.maxProbeOutputBytes)
        #expect(!result.didExceedOutputLimit)
    }

    @Test("Output over the byte limit is rejected")
    @MainActor
    func outputOverLimitIsRejected() async throws {
        let fixture = try makeOutputFixture(byteCount: TestKitRunner.maxProbeOutputBytes + 1)
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }

        let result = await TestKitRunner.shared.runProbe(at: fixture)

        let outputWasRejected = result.output == nil
        #expect(outputWasRejected)
        #expect(result.didExceedOutputLimit)
    }

    @Test("An unbounded child is terminated as soon as it exceeds the limit")
    @MainActor
    func unboundedChildIsTerminatedAtLimit() async {
        let clock = ContinuousClock()
        let started = clock.now

        let result = await TestKitRunner.shared.runProbe(
            at: URL(fileURLWithPath: "/usr/bin/yes"),
            timeout: 5
        )

        let elapsed = started.duration(to: clock.now)
        #expect(result.output == nil)
        #expect(result.didExceedOutputLimit)
        #expect(elapsed < .seconds(3))
    }

    @Test("A SIGTERM-ignoring child is force-killed after the grace period", .timeLimit(.minutes(1)))
    @MainActor
    func sigtermImmuneChildIsForceKilled() async throws {
        // trap '' TERM makes the shell ignore SIGTERM, and the ignored
        // disposition is inherited by every child it spawns, so only the
        // SIGKILL escalation ends this fixture early. It is deliberately
        // self-limiting (exits on its own after the sleep): if the
        // escalation regresses, the test must FAIL fast on the elapsed-time
        // assertion, not hang the suite on a child nothing can kill.
        // 97 x 64 KiB = 6.0625 MiB, just over the cap.
        let fixture = try makeScript(contents: """
            #!/bin/sh
            trap '' TERM
            i=0
            while [ $i -lt 97 ]; do
              /bin/dd if=/dev/zero bs=65536 count=1 2>/dev/null
              i=$((i+1))
            done
            /bin/sleep 15
            """)
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let clock = ContinuousClock()
        let started = clock.now

        let result = await TestKitRunner.shared.runProbe(at: fixture, timeout: 10)

        let elapsed = started.duration(to: clock.now)
        #expect(result.output == nil)
        #expect(result.didExceedOutputLimit)
        #expect(!result.didTimeout)
        // Cap is hit almost instantly, so the run should end at roughly the
        // 2s SIGKILL grace period, well before the 10s watchdog.
        #expect(elapsed < .seconds(8))
    }

    @Test("Small partial output from the watchdog path is preserved")
    @MainActor
    func timeoutPartialOutputIsPreserved() async throws {
        let fixture = try makeScript(contents: "#!/bin/sh\n/bin/echo partial\n/bin/sleep 5\n")
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let clock = ContinuousClock()
        let started = clock.now

        let result = await TestKitRunner.shared.runProbe(at: fixture, timeout: 2)

        let elapsed = started.duration(to: clock.now)
        #expect(result.output == "partial\n")
        #expect(result.didTimeout)
        #expect(!result.didExceedOutputLimit)
        // The watchdog fires at 2s; returning near the fixture's 5s sleep
        // would mean a leftover writer kept the pipe open.
        #expect(elapsed < .seconds(4))
    }

    @Test("An incomplete UTF-8 sequence from the watchdog path is preserved")
    @MainActor
    func timeoutIncompleteUTF8IsPreserved() async throws {
        let fixture = try makeScript(contents: "#!/bin/sh\n/usr/bin/printf '\\303'\n/bin/sleep 5\n")
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let clock = ContinuousClock()
        let started = clock.now

        let result = await TestKitRunner.shared.runProbe(at: fixture, timeout: 2)

        let elapsed = started.duration(to: clock.now)
        #expect(result.output == "\u{FFFD}")
        #expect(result.didTimeout)
        #expect(!result.didExceedOutputLimit)
        #expect(elapsed < .seconds(4))
    }

    @Test("Oversized JSON request bodies are rejected")
    @MainActor
    func oversizedJSONBodyIsRejected() throws {
        let payload = ["output": String(repeating: "x", count: TestKitRunner.maxRequestBodyBytes)]

        let body = try TestKitRunner.boundedJSONBody(payload)

        #expect(body == nil)
    }

    @Test("Small JSON request bodies are preserved")
    @MainActor
    func smallJSONBodyIsPreserved() throws {
        let payload = ["output": "diagnostic"]

        let body = try TestKitRunner.boundedJSONBody(payload)

        #expect(body != nil)
    }

    @Test("Every budgeted probe stops below the app's output cap")
    @MainActor
    func probeBudgetsSitUnderTheOutputCap() throws {
        // A probe whose own byte budget reaches the app's cap has its whole
        // output discarded (see outputOverLimitIsRejected), not trimmed. The
        // budget can overshoot by one value, so keep at least 512 KiB clear.
        let probes = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // WhatCableAppTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("probes/test-kit")
        let budgeted = [
            "04_raw_registry_dump.c",
            "40_hub_port_statistics.c",
            "43_usb_port_subtree.c",
        ]
        let pattern = try NSRegularExpression(
            pattern: #"(?:kByteBudget =|#define MAX_BYTES) \(?(\d+)LL \* 1024 \* 1024"#
        )
        for name in budgeted {
            let source = try String(contentsOf: probes.appendingPathComponent(name), encoding: .utf8)
            let ns = source as NSString
            let match = try #require(
                pattern.firstMatch(in: source, range: NSRange(location: 0, length: ns.length)),
                "no MiB byte budget found in \(name)"
            )
            let mib = try #require(Int(ns.substring(with: match.range(at: 1))))
            let headroom = 512 * 1024
            #expect(mib * 1024 * 1024 + headroom <= TestKitRunner.maxProbeOutputBytes,
                    "\(name) budget \(mib) MiB is too close to the app cap")
        }
    }

    private func makeOutputFixture(byteCount: Int) throws -> URL {
        try makeScript(contents: "#!/bin/sh\n/usr/bin/yes x | /usr/bin/head -c \(byteCount)\n")
    }

    private func makeScript(contents: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("whatcable-test-kit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let script = directory.appendingPathComponent("emit-output")
        try Data(contents.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return script
    }
}
