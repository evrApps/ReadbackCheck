// Copyright (C) 2026 Antonio Marogna — EVRApps
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import Foundation
import Observation

// --------------------------------------------------------------------------
// where the engine is
// --------------------------------------------------------------------------

/// The engine script and the Python to run it with.
///
/// The portable build (build_portable.sh) carries both inside the bundle. An
/// ordinary build (swift build, build_app.sh) uses engine/ in the source tree
/// it was built from and a system Python. For development only, the defaults
/// key `engineScript` names another script.
enum EnginePaths {
    /// Contents/Resources/engine/verify_offload_app.py
    static var embeddedScript: String? {
        guard let r = Bundle.main.resourcePath else { return nil }
        let s = r + "/engine/verify_offload_app.py"
        return FileManager.default.fileExists(atPath: s) ? s : nil
    }

    /// Contents/<RCPythonHome>/python-<arch>/bin/python3.x, for the architecture running now.
    static var embeddedPython: String? {
        guard let home = Bundle.main.object(forInfoDictionaryKey: "RCPythonHome") as? String else { return nil }
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        let bin = "\(Bundle.main.bundlePath)/Contents/\(home)/python-\(arch)/bin"
        let name = (try? FileManager.default.contentsOfDirectory(atPath: bin))?
            .first { $0.hasPrefix("python3") }
        return name.map { "\(bin)/\($0)" }
    }

    /// engine/ next to Sources/, from where this file was compiled.
    static var sourceTreeScript: String {
        let here = URL(fileURLWithPath: #filePath)
        return here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("engine/verify_offload_app.py").path
    }

    static var script: String {
        if let s = UserDefaults.standard.string(forKey: "engineScript"), !s.isEmpty { return s }
        return embeddedScript ?? sourceTreeScript
    }

    static var python: String {
        if let s = embeddedPython { return s }
        // A GUI app does not inherit the shell's PATH: look where Python usually is.
        let candidates = ["/Library/Frameworks/Python.framework/Versions/Current/bin/python3",
                          "/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/python3"
    }

    static var problem: String? {
        if !FileManager.default.fileExists(atPath: script) { return "The test engine is missing: \(script)" }
        if !FileManager.default.isExecutableFile(atPath: python) { return "Python is missing: \(python)" }
        return nil
    }

    /// Reports are written here by the engine, each with its Past Tests entry (.json).
    static var reportDir: String {
        NSHomeDirectory() + "/Library/Application Support/Readback Check/Reports"
    }

    static func process(_ args: [String]) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        // Isolated from the environment, and never writing bytecode: anything
        // written into the bundle would break its signature.
        p.arguments = ["-I", "-B", "-u", script] + args
        p.currentDirectoryURL = URL(fileURLWithPath: (script as NSString).deletingLastPathComponent)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"      // ioreg, diskutil, tmutil, sync
        env["PYTHONUNBUFFERED"] = "1"
        p.environment = env
        return p
    }
}

// --------------------------------------------------------------------------
// step 1: what the operator chose, and the pre-flight checks
// --------------------------------------------------------------------------

@MainActor @Observable
final class Setup {
    var source = "" { didSet { sourceInfo = source.isEmpty ? nil : DiskInfo(path: source); recheck() } }
    var dest = "" { didSet { destInfo = dest.isEmpty ? nil : DiskInfo(path: dest); recheck() } }
    private(set) var sourceInfo: DiskInfo?
    private(set) var destInfo: DiskInfo?

    var appPath = UserDefaults.standard.string(forKey: "appPath") ?? ""
    /// How the offload app's verification was set, in the user's words: free
    /// text, recorded in the report and never checked.
    var verifySetting = UserDefaults.standard.string(forKey: "verifySetting") ?? ""

    var preflight: Preflight?
    var checking = false
    var checkError: String?
    private var checkProcess: Process?
    private var checkToken = 0

    init() {
        // Disks come and go between launches: keep the last choice only if still mounted.
        if let p = UserDefaults.standard.string(forKey: "source"), FileManager.default.fileExists(atPath: p) { source = p }
        if let p = UserDefaults.standard.string(forKey: "dest"), FileManager.default.fileExists(atPath: p) { dest = p }
        if !appPath.isEmpty && !FileManager.default.fileExists(atPath: appPath) { choose(app: "") }
    }

    func choose(source path: String) { source = path; UserDefaults.standard.set(path, forKey: "source") }
    func choose(dest path: String) { dest = path; UserDefaults.standard.set(path, forKey: "dest") }
    // Saved only when chosen here: the self-test sets the fields directly and
    // must not leave its choices in the user's settings.
    func choose(app path: String) {
        // The setting belongs to the app it was typed for.
        if !appPath.isEmpty && path != appPath { choose(verify: "") }
        appPath = path
        UserDefaults.standard.set(path, forKey: "appPath")
    }
    func choose(verify text: String) {
        verifySetting = text
        // The field writes through here as soon as it has focus, the self-test's text too.
        if !SelfTest.active { UserDefaults.standard.set(text, forKey: "verifySetting") }
    }

    var verifyText: String? {
        let t = verifySetting.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    var appBundle: Bundle? { appPath.isEmpty ? nil : Bundle(path: appPath) }

    var appName: String {
        guard let b = appBundle else { return "" }
        return (b.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? (b.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? URL(fileURLWithPath: appPath).deletingPathExtension().lastPathComponent
    }

    /// "3.2 (1204)"
    var appVersion: String? {
        guard let b = appBundle else { return nil }
        let short = b.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = b.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(short) (\(build))"
    }

    var canPrepare: Bool {
        guard let p = preflight, !checking else { return false }
        return p.refusal == nil
    }

    func recheck() {
        preflight = nil
        checkError = nil
        // A check still running is superseded (its result is dropped by the
        // token). Only a launched one can be stopped: terminate() on a Process
        // its task has not started yet raises, which crashed the window.
        if let c = checkProcess, c.isRunning { c.terminate() }
        checkProcess = nil
        checking = false
        guard !source.isEmpty, !dest.isEmpty else { return }
        if let problem = EnginePaths.problem { checkError = problem; return }
        checkToken += 1
        let token = checkToken
        checking = true
        let p = EnginePaths.process([source, dest, "--guided", "--check"])
        checkProcess = p
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        Task.detached {
            var result: Result<[String: Any], Error>
            do {
                try p.run()
                let data = out.fileHandleForReading.readDataToEndOfFile()
                let errData = err.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    result = .success(obj)
                } else {
                    let msg = String(data: errData, encoding: .utf8) ?? ""
                    result = .failure(NSError(domain: "check", code: Int(p.terminationStatus),
                                              userInfo: [NSLocalizedDescriptionKey: msg.isEmpty ? "The check failed." : msg]))
                }
            } catch {
                result = .failure(error)
            }
            let r = result
            await MainActor.run {
                guard token == self.checkToken else { return }
                self.checking = false
                self.checkProcess = nil
                switch r {
                case .success(let obj): self.preflight = Preflight(obj)
                case .failure(let e): self.checkError = refusalText(e.localizedDescription)
                }
            }
        }
    }

    func arguments() -> [String] {
        // Step 3 asks for previews, proxies, thumbnails and reports to be off.
        var a = [source, dest, "--guided", "--steps", "--report-dir", EnginePaths.reportDir]
        if !appPath.isEmpty { a += ["--app", appName, "--app-path", appPath] }
        if let v = verifyText { a += ["--verify-mode", v] }
        return a
    }
}

/// The engine's "NOT EVALUABLE: ..." line, or its last line, as a sentence.
func refusalText(_ stderr: String) -> String {
    let lines = stderr.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    if let r = lines.first(where: { $0.hasPrefix("NOT EVALUABLE:") }) {
        return sentence(String(r.dropFirst("NOT EVALUABLE:".count)))
    }
    return lines.last.map { sentence($0) } ?? "The test engine stopped unexpectedly."
}

// --------------------------------------------------------------------------
// steps 2-5: one test, the engine in --guided --steps mode
// --------------------------------------------------------------------------

enum Step: Int {
    case choose = 1, prepare, copy, final, result

    var title: String {
        switch self {
        case .choose: "Choose the disks"
        case .prepare: "Preparing the test"
        case .copy: "Copy with your offload app"
        case .final: "Final check"
        case .result: "Result"
        }
    }
}

enum TaskState {
    case waiting, running, done, failed, skipped

    var label: String {
        switch self {
        case .waiting: "Waiting"
        case .running: "In progress…"
        case .done: "Done"
        case .failed: "Failed"
        case .skipped: "Skipped"
        }
    }
}

/// What step 5 shows about the disks and the app, kept from the moment the test started.
struct Measured {
    var source: DiskInfo?
    var dest: DiskInfo?
    var app: String?
    /// The bundle chosen in step 1, to compare with what was seen.
    var appPath: String?
    var verify: String?
    var date = Date()
}

@MainActor @Observable
final class Session {
    var step = Step.choose
    var measured = Measured()
    var expectedSize = 0.0
    var generated: (files: Int, size: Double, folder: String)?
    var calibPre: [String: Double]?
    var header: Header?
    var outcome: Outcome?
    var verdict: Verdict?
    var cleaned: (ok: Bool, folders: [String])?
    var awaiting: String?

    // ---- the task tables of steps 2 and 4
    var prep: [TaskState] = Array(repeating: .waiting, count: 4)
    var fin: [TaskState] = Array(repeating: .waiting, count: 3)
    var taskStarted = Date()
    var remountError: (detail: String, retryable: Bool)?

    // ---- step 3
    var jobStarted: Date?
    var jobEnded: Date?
    /// Bytes moved since each phase began, and the latest rates: for the bars only.
    var traces: [String: [Counter: Double]] = [:]
    var rates: [Counter: Double] = [:]
    /// The latest phase worth bars, for steps 2 and 4.
    var shownPhase: String?
    static let barPhases: Set<String> = ["generate", "precal_A", "precal_B", "job", "calib_A", "calib_B"]
    var written: Double { traces["job"]?[.dstW] ?? 0 }
    var runDirBytes = 0.0
    var misplaced: [String] = []       // folders outside the test folder with fresh copies
    private var watch: Timer?
    /// Apps seen with files open in the test folders during the copy.
    var seenApps: [SeenApp] = []
    private var detect: Timer?
    private var scanning = false
    private var searching = false
    private var suspectSince: Date?
    /// Judged once a second, right after the folder is re-read, and only after
    /// it has held this long: compared live, the first bytes of every copy
    /// outran the folder's last reading and flashed the warning.
    static let elsewhereAfter: TimeInterval = 3
    private var elsewhereConfirmed = false

    var stderrText = ""
    var log: [String] = []
    var exitCode: Int32?
    var cancelling = false
    var running: Bool { process != nil }

    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    /// While a test runs the window is usually behind the offload app, and App
    /// Nap held the once-a-second folder check back by 10-15 s at a time.
    private var activity: NSObjectProtocol?

    /// The destination disk is being written but nothing reaches the test folder.
    var copyElsewhere: Bool { elsewhereConfirmed && awaiting == "done" }

    private var looksElsewhere: Bool {
        guard let h = header else { return false }
        return written > 0.1 * h.size && runDirBytes < 0.05 * h.size
    }

    func start(_ setup: Setup) {
        reset()
        measured = Measured(source: setup.sourceInfo, dest: setup.destInfo,
                            app: setup.appPath.isEmpty ? nil : "\(setup.appName) \(setup.appVersion ?? "")",
                            appPath: setup.appPath.isEmpty ? nil : setup.appPath,
                            verify: setup.verifyText)
        expectedSize = setup.preflight?.size ?? 0
        step = .prepare
        setTask(prep: 0, .running)
        let p = EnginePaths.process(setup.arguments())
        let out = Pipe(), err = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = inp
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            Task { @MainActor in self?.receive(data) }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] h in
            let s = String(data: h.availableData, encoding: .utf8) ?? ""
            Task { @MainActor in self?.stderrText += s }
        }
        p.terminationHandler = { [weak self] p in
            let code = p.terminationStatus
            Task { @MainActor in
                // Let the last stdout/stderr chunks arrive first.
                try? await Task.sleep(nanoseconds: 300_000_000)
                self?.finished(code)
            }
        }
        do {
            try p.run()
            process = p
            input = inp.fileHandleForWriting
            activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Readback Check test")
        } catch {
            stderrText = "Could not start the test engine: \(error.localizedDescription)"
            finished(-1)
        }
    }

    func reset() {
        step = .choose; measured = Measured(); expectedSize = 0; generated = nil; header = nil
        outcome = nil; verdict = nil; cleaned = nil; awaiting = nil; calibPre = nil
        prep = Array(repeating: .waiting, count: 4); fin = Array(repeating: .waiting, count: 3)
        taskStarted = Date(); remountError = nil
        jobStarted = nil; jobEnded = nil; traces = [:]; rates = [:]; shownPhase = nil; runDirBytes = 0; misplaced = []
        watch?.invalidate(); watch = nil; suspectSince = nil; elsewhereConfirmed = false
        detect?.invalidate(); detect = nil; seenApps = []
        stderrText = ""; log = []; exitCode = nil; cancelling = false; buffer = Data()
    }

    private func setTask(prep i: Int, _ s: TaskState) {
        if prep[i] != s { prep[i] = s; if s == .running { taskStarted = Date() } }
    }

    private func setTask(fin i: Int, _ s: TaskState) {
        if fin[i] != s { fin[i] = s; if s == .running { taskStarted = Date() } }
    }

    // ---- what the operator does

    func send(_ cmd: String) {
        guard let input else { return }
        awaiting = nil
        try? input.write(contentsOf: (cmd + "\n").data(using: .utf8)!)
    }

    func finishedCopy() {
        guard awaiting == "done" else { return }
        jobEnded = Date()
        detect?.invalidate(); detect = nil
        // What was seen goes into the engine's report with the reply.
        let seen = ["seen": seenApps.map { $0.json() }]
        if !seenApps.isEmpty, let d = try? JSONSerialization.data(withJSONObject: seen),
           let j = String(data: d, encoding: .utf8) {
            send("ok " + j)
        } else {
            send("ok")
        }
        step = .final
        setTask(fin: 0, .running)
    }

    func retryRemount() {
        remountError = nil
        setTask(prep: 2, .running)
        send("retry")
    }

    func continueWithoutRemount() {
        remountError = nil
        setTask(prep: 2, .skipped)
        send("ok")
    }

    /// At a wait the engine is told to stop; elsewhere it is interrupted. Either
    /// way it removes the test folders itself before it exits.
    func cancel() {
        guard let p = process else { reset(); return }
        cancelling = true
        if awaiting != nil { send("abort") } else { p.interrupt() }
    }

    private func finished(_ code: Int32) {
        exitCode = code
        process = nil
        input = nil
        awaiting = nil
        watch?.invalidate(); watch = nil
        detect?.invalidate(); detect = nil
        if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
        rates = [:]                    // nobody samples any more: no stale lights
        if cancelling && outcome == nil {
            reset()
            return
        }
        if outcome == nil {
            // The engine stops when reference B is not seen before the job: on
            // this destination the answer can't be determined, whatever the app.
            if let b = calibPre?["B"], b < mediumRead {
                verdict = .undetermined(why: Verdict.counterBlind)
            } else {
                verdict = .stopped(reason: refusalText(stderrText.isEmpty
                    ? "The test engine exited with code \(code)." : stderrText))
            }
        }
        step = .result
    }

    // ---- what the engine says

    private func receive(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer = Data(buffer[buffer.index(after: nl)...])
            if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                handle(obj)
            }
        }
    }

    private func handle(_ e: [String: Any]) {
        switch e["ev"] as? String {
        case "generated":
            generated = ((e["files"] as? [Any])?.count ?? 0, num(e["size"]), e["folder"] as? String ?? "")
            setTask(prep: 0, .done)
            setTask(prep: 1, .running)
        case "precal":
            calibPre = (e["calib"] as? [String: Any])?.mapValues { num($0) }
            setTask(prep: 1, .done)
        case "header":
            header = Header(e)
            if prep[1] != .done { setTask(prep: 1, .done) }
        case "line", "say":
            log.append(e["text"] as? String ?? "")
        case "phase":
            let name = e["name"] as? String ?? "idle"
            if Session.barPhases.contains(name) { traces[name] = [:]; shownPhase = name }
            switch name {
            case "noise": setTask(prep: 3, .running)
            case "job": jobStarted = Date()
            case "calib_A":
                setTask(fin: 0, .done)
                setTask(fin: 1, .running)
            default: break
            }
        case "sample":
            for (k, v) in e["rate"] as? [String: Any] ?? [:] {
                if let c = Counter(rawValue: k) { rates[c] = num(v) }
            }
            if let name = e["phase"] as? String, traces[name] != nil, let b = e["bytes"] as? [String: Any] {
                for (k, v) in b { if let c = Counter(rawValue: k) { traces[name]![c] = num(v) } }
            }
        case "cold":
            if e["ok"] as? Bool == true { setTask(prep: 2, .done) }
        case "noise":
            setTask(prep: 3, .done)
        case "await":
            let step = e["step"] as? String ?? ""
            awaiting = step
            switch step {
            case "remount":
                setTask(prep: 2, .running)
                send("ok")
            case "remount_failed":
                setTask(prep: 2, .failed)
                let detail = (e["detail"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                remountError = (detail.isEmpty ? "The disk could not be ejected." : detail,
                                e["retryable"] as? Bool ?? true)
            case "configure":
                // The background is measured before the operator sets up the
                // job, which is step 3.
                send("ok")
            case "start":
                // The window opens as soon as the folders are shown: no Start
                // Test click, and the app's own setup reads (previews, a
                // first scan) fall inside the measurement, where they belong.
                self.step = .copy
                send("ok")
            case "done":
                startWatch()
            case "confirm_large":
                // Guided data is sized from free memory; if memory shrank since,
                // the calibration after the job tells whether it still held.
                send("ok")
            default:
                send("ok")
            }
        case "result":
            let o = Outcome(e)
            outcome = o
            verdict = Verdict(o)
            if fin[0] != .done { setTask(fin: 0, .done) }
            setTask(fin: 1, o.calib == nil ? .skipped : .done)
            setTask(fin: 2, .running)
            if !o.copyOK { locateCopy() }
            if !o.reportPath.isEmpty {
                History.record(PastTest(date: measured.date, app: appSummary,
                                        source: measured.source?.name ?? "", dest: measured.dest?.name ?? "",
                                        result: verdict?.key ?? "",
                                        report: (o.reportPath as NSString).lastPathComponent))
            }
        case "cleaned":
            cleaned = (e["ok"] as? Bool ?? false, e["folders"] as? [String] ?? [])
            setTask(fin: 2, cleaned!.ok ? .done : .failed)
        default:
            break
        }
    }

    // ---- is the copy landing in the test folder? Only the engine's copy check
    // looks at the folder (the counters see the whole disk), so an app pointed
    // elsewhere is caught here, during the copy, by the app alone.

    private func startWatch() {
        watch?.invalidate()
        watch = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        detect?.invalidate()
        detect = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scanApps() }
        }
        scanApps()
    }

    /// The app chosen in step 1, or the one seen copying when none was chosen.
    var appSummary: String {
        if let a = measured.app { return a }
        if seenApps.count == 1 { return "\(seenApps[0].label), identified during the copy" }
        return "not chosen"
    }

    /// Which app is copying: processes with files open in the two test folders.
    private func scanApps() {
        guard let h = header, awaiting == "done", !scanning else { return }
        scanning = true
        let folders = [(side: "source", path: h.source), (side: "destination", path: h.runDir)]
        let engine = process?.processIdentifier
        Task.detached {
            let found = Detector.scan(folders: folders, engine: engine)
            await MainActor.run {
                self.scanning = false
                for app in found {
                    if let i = self.seenApps.firstIndex(where: { $0.path == app.path }) {
                        self.seenApps[i].sides.formUnion(app.sides)
                    } else {
                        self.seenApps.append(app)
                    }
                }
            }
        }
    }

    /// Stat-only: directory metadata, no file data is read.
    private func poll() {
        guard let h = header, awaiting == "done" else { return }
        let dir = h.runDir
        Task.detached {
            let b = Session.bytes(in: dir)
            await MainActor.run {
                self.runDirBytes = b
                if self.looksElsewhere {
                    let since = self.suspectSince ?? Date()
                    self.suspectSince = since
                    if Date().timeIntervalSince(since) >= Session.elsewhereAfter { self.elsewhereConfirmed = true }
                } else {
                    self.suspectSince = nil
                    self.elsewhereConfirmed = false
                }
                if self.copyElsewhere && self.misplaced.isEmpty { self.locateCopy() }
            }
        }
    }

    nonisolated static func bytes(in dir: String) -> Double {
        var total = 0.0
        let e = FileManager.default.enumerator(at: URL(fileURLWithPath: dir),
                                               includingPropertiesForKeys: [.fileSizeKey])
        while let u = e?.nextObject() as? URL {
            total += Double((try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }

    /// Folders near the test folder holding files with a test file's name and
    /// size, changed after this test started.
    func locateCopy() {
        guard let h = header, !searching else { return }
        searching = true
        let source = h.source, runDir = h.runDir, since = measured.date.addingTimeInterval(-2)
        let parent = (runDir as NSString).deletingLastPathComponent
        Task.detached {
            var wanted = Set<String>()
            let fm = FileManager.default
            if let e = fm.enumerator(at: URL(fileURLWithPath: source), includingPropertiesForKeys: [.fileSizeKey]) {
                while let u = e.nextObject() as? URL {
                    if u.lastPathComponent.hasPrefix(".") { continue }
                    let sz = (try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                    wanted.insert("\(u.lastPathComponent)|\(sz)")
                }
            }
            var found = [String: Int]()
            var seen = 0
            let keys: [URLResourceKey] = [.fileSizeKey, .attributeModificationDateKey, .isDirectoryKey]
            if let e = fm.enumerator(at: URL(fileURLWithPath: parent), includingPropertiesForKeys: keys,
                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                while let u = e.nextObject() as? URL, seen < 50_000 {
                    seen += 1
                    if u.path == runDir || u.path == source { e.skipDescendants(); continue }
                    if e.level > 4 { e.skipDescendants(); continue }
                    guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isDirectory != true,
                          let changed = v.attributeModificationDate, changed >= since,
                          wanted.contains("\(u.lastPathComponent)|\(v.fileSize ?? -1)") else { continue }
                    found[u.deletingLastPathComponent().path, default: 0] += 1
                }
            }
            let dirs = found.sorted { $0.value > $1.value }.prefix(3).map(\.key)
            await MainActor.run {
                self.misplaced = dirs
                self.searching = false
            }
        }
    }
}

// --------------------------------------------------------------------------
// small AppKit helpers
// --------------------------------------------------------------------------

enum Mac {
    static func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    static func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    @MainActor
    static func chooseDisk(title: String, prompt: String) -> String? {
        let p = NSOpenPanel()
        p.title = title
        p.message = title
        p.prompt = prompt
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = false
        p.directoryURL = URL(fileURLWithPath: "/Volumes")
        return p.runModal() == .OK ? p.url?.path : nil
    }

    @MainActor
    static func chooseApp() -> String? {
        let p = NSOpenPanel()
        p.title = "Choose your offload app"
        p.prompt = "Choose"
        p.allowedContentTypes = [.applicationBundle]
        p.canChooseDirectories = false
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        return p.runModal() == .OK ? p.url?.path : nil
    }
}
