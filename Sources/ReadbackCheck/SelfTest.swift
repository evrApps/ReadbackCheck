// Copyright (C) 2026 Antonio Marogna — EVRApps
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import Foundation

/// Self-test, off unless launched with these arguments:
///
///   -selfTestSource DIR -selfTestDest DIR   the disks of step 1
///   -selfTestCmd 'cp {src}/* {dst}/'        the copy, run as soon as step 3
///        is watching ({src} test data folder, {dst} test folder). Prepare Test
///        is clicked as soon as the checks pass,
///        Finished when the command ends. A failed reset of the source is
///        continued without after 5 s. The same path as in real use.
///   -selfTestApp PATH       the offload app of step 1
///   -selfTestVerify TEXT    the verification setting of step 1
///   -selfTestCancel STEP    click Cancel 2 s into step 2, 3 or 4 instead
///   -selfTestQuit YES       quit 5 s after the result, writing DIR/selftest.json
///                           when -snapshotDir is given
///   -selfTestAbout YES      open About and save it as DIR/about.png
///   -selfTestPastTests YES  open Past Tests too, saved as DIR/past-NNN.png
///   -snapshotDir DIR        the window, as the app draws it, saved every 2 s as
///        DIR/shot-NNN.png (needs no Screen Recording permission);
///        -snapshotEvery 0.25 for a faster cadence
///   -engineScript PATH      run this script instead of the engine (development)
enum SelfTest {
    static let defaults = UserDefaults.standard
    static var active: Bool { defaults.string(forKey: "selfTestCmd") != nil }

    @MainActor
    static func install(setup: Setup, session: Session) {
        let snapshots = defaults.string(forKey: "snapshotDir")
        if let command = defaults.string(forKey: "selfTestCmd") {
            if let s = defaults.string(forKey: "selfTestSource") { setup.source = s }
            if let d = defaults.string(forKey: "selfTestDest") { setup.dest = d }
            if let a = defaults.string(forKey: "selfTestApp") { setup.appPath = a }
            if let v = defaults.string(forKey: "selfTestVerify") { setup.verifySetting = v }
            var prepared = false, jobRunning = false, quitting = false
            var failedSince: Date?, stepSince = (Step.choose, Date())
            let cancelAt = Step(rawValue: defaults.integer(forKey: "selfTestCancel"))
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                MainActor.assumeIsolated {
                    if session.step != stepSince.0 { stepSince = (session.step, Date()) }
                    if let c = cancelAt, session.step == c, !session.cancelling,
                       Date().timeIntervalSince(stepSince.1) > 2 {
                        session.cancel()
                    } else if prepared && session.step == .choose && !session.running && !quitting
                                && defaults.bool(forKey: "selfTestQuit") {
                        quitting = true            // cancelled: back at step 1
                        if let dir = snapshots { writeSummary(session, to: dir) }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { NSApp.terminate(nil) }
                    } else if session.step == .choose && !prepared && setup.canPrepare {
                        prepared = true
                        session.start(setup)
                    } else if session.remountError != nil {
                        if let t = failedSince, Date().timeIntervalSince(t) > 5 {
                            failedSince = nil
                            session.continueWithoutRemount()
                        } else if failedSince == nil {
                            failedSince = Date()
                        }
                    } else if session.awaiting == "done", !jobRunning, let h = session.header {
                        jobRunning = true
                        let cmd = command.replacingOccurrences(of: "{src}", with: shellQuote(h.source))
                                         .replacingOccurrences(of: "{dst}", with: shellQuote(h.runDir))
                        Task.detached {
                            let p = Process()
                            p.executableURL = URL(fileURLWithPath: "/bin/sh")
                            p.arguments = ["-c", cmd]
                            try? p.run()
                            p.waitUntilExit()
                            try? await Task.sleep(nanoseconds: 3_000_000_000)   // let the warning show
                            await MainActor.run { session.finishedCopy(); jobRunning = false }
                        }
                    } else if session.step == .result && !session.running && !quitting
                                && defaults.bool(forKey: "selfTestQuit") {
                        quitting = true
                        if let dir = snapshots { writeSummary(session, to: dir) }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { NSApp.terminate(nil) }
                    }
                }
            }
        }
        if let dir = snapshots, defaults.bool(forKey: "selfTestAbout") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                About.show()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    if let v = NSApp.windows.first(where: { $0.isVisible && $0.title != "Readback Check" })?.contentView {
                        save(v, to: URL(fileURLWithPath: dir).appendingPathComponent("about.png"))
                    }
                }
            }
        }
        if let dir = snapshots {
            var n = 0
            let every = defaults.double(forKey: "snapshotEvery")   // seconds, default 2
            Timer.scheduledTimer(withTimeInterval: every > 0 ? every : 2, repeats: true) { t in
                MainActor.assumeIsolated {
                    if let past = NSApp.windows.first(where: { $0.isVisible && $0.title == "Past Tests" })?.contentView {
                        save(past, to: URL(fileURLWithPath: dir).appendingPathComponent(String(format: "past-%03d.png", n)))
                    }
                    guard let view = NSApp.windows.first(where: { $0.isVisible && $0.title == "Readback Check" })?.contentView
                    else { return }
                    save(view, to: URL(fileURLWithPath: dir).appendingPathComponent(String(format: "shot-%03d.png", n)))
                    n += 1
                    if n >= 300 { t.invalidate() }
                }
            }
        }
    }

    /// A window's content as the app draws it. The content view draws no
    /// window background: it is laid under, or dark mode saves light text on
    /// a transparent image.
    @MainActor
    static func save(_ view: NSView, to url: URL) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide,
                                         pixelsHigh: rep.pixelsHigh, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: out) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        let r = NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh)
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            r.fill()
        }
        rep.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        try? out.representation(using: .png, properties: [:])?.write(to: url)
    }

    @MainActor
    private static func writeSummary(_ s: Session, to dir: String) {
        var d: [String: Any] = ["tag": s.verdict?.tag ?? "", "title": s.verdict?.title ?? "",
                                "what": s.verdict?.what ?? "", "exit": Int(s.exitCode ?? -99)]
        if let o = s.outcome {
            d["rc"] = o.rc
            d["copy_ok"] = o.copyOK
            d["calib"] = o.calib ?? [:]
            d["calib_pre"] = o.calibPre ?? [:]
            d["report_path"] = o.reportPath
        }
        if let c = s.cleaned { d["cleaned"] = c.ok; d["folders"] = c.folders }
        d["stderr"] = s.stderrText
        if let data = try? JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("selftest.json"))
        }
    }
}

private func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
