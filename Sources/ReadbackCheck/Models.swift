// Copyright (C) 2026 Antonio Marogna — EVRApps
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

let MB = 1024.0 * 1024.0

/// Whole megabytes with a thousands separator, as the engine's fmt_mb.
func fmtMB(_ bytes: Double) -> String {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.groupingSeparator = ","
    f.maximumFractionDigits = 0
    return (f.string(from: NSNumber(value: (bytes / MB).rounded())) ?? "0") + " MB"
}

/// The engine writes its messages as lower-case clauses; the interface shows sentences.
func sentence(_ s: String) -> String {
    var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let first = t.first else { return t }
    t = first.uppercased() + t.dropFirst()
    if let last = t.last, !".!?".contains(last) { t += "." }
    return t
}

func num(_ v: Any?) -> Double {
    if let d = v as? Double { return d }
    if let i = v as? Int { return Double(i) }
    if let n = v as? NSNumber { return n.doubleValue }
    return 0
}

/// The four live counters.
enum Counter: String, CaseIterable {
    case srcR = "src_r", dstW = "dst_w", dstR = "dst_r", srcW = "src_w"
}

/// Where a path lives, as the engine's classify() describes it.
struct Location {
    var path = "", mount = "", kind = "", disk: String?, detail = "", fstype = ""

    init(_ d: [String: Any]?) {
        guard let d else { return }
        path = d["path"] as? String ?? ""
        mount = d["mount"] as? String ?? ""
        kind = d["kind"] as? String ?? ""
        disk = d["disk"] as? String
        detail = d["detail"] as? String ?? ""
        fstype = d["fstype"] as? String ?? ""
    }

    var isNetwork: Bool { kind == "network" || kind == "loopback" }
}

/// Result of `--guided --check`.
struct Preflight {
    var refusal: String?
    var notes: [String] = []
    var source = Location(nil), dest = Location(nil)
    var size = 0.0, ram = 0.0
    var remountable = false

    init(_ d: [String: Any]) {
        refusal = d["refusal"] as? String
        notes = d["notes"] as? [String] ?? []
        source = Location(d["source"] as? [String: Any])
        dest = Location(d["dest"] as? [String: Any])
        size = num(d["size"])
        ram = num(d["ram"])
        remountable = d["remountable"] as? Bool ?? false
    }
}

/// The `header` event: the test data exists and the destination passed its first check.
struct Header {
    var app = "", version = "", source = "", runDir = ""
    var files = 0
    var size = 1.0

    init(_ d: [String: Any]) {
        app = d["app"] as? String ?? ""
        version = d["version"] as? String ?? ""
        source = d["source"] as? String ?? ""
        runDir = d["run_dir"] as? String ?? ""
        files = d["files"] as? Int ?? 0
        size = max(num(d["size"]), 1)
    }
}

/// The `result` event.
struct Outcome {
    var rc = 3
    var size = 1.0
    var adj: [Counter: Double] = [:]
    var calib: [String: Double]?
    var calibPre: [String: Double]?
    var calibState: String?
    var networkDst = false, copyOK = false, cold = false
    var found = 0.0
    var reportPath = ""
    var report = ""

    init(_ d: [String: Any]) {
        rc = d["rc"] as? Int ?? 3
        size = max(num(d["size"]), 1)
        for (k, v) in d["adj"] as? [String: Any] ?? [:] {
            if let c = Counter(rawValue: k) { adj[c] = num(v) }
        }
        calib = (d["calib"] as? [String: Any])?.mapValues { num($0) }
        calibPre = (d["calib_pre"] as? [String: Any])?.mapValues { num($0) }
        calibState = d["calib_state"] as? String
        networkDst = d["network_dst"] as? Bool ?? false
        copyOK = d["copy_ok"] as? Bool ?? false
        cold = d["cold"] as? Bool ?? false
        found = num(d["found"])
        reportPath = d["report_path"] as? String ?? ""
        report = d["report"] as? String ?? ""
    }

    func x(_ c: Counter) -> Double { (adj[c] ?? 0) / size }
}

// --------------------------------------------------------------------------
// the four outcomes, from the result fields and never from the verdict text
// --------------------------------------------------------------------------

/// Thresholds of the engine (MEDIUM_READ, NOT_READ).
let mediumRead = 0.8, notRead = 0.1

enum Verdict: Equatable {
    case readsBack
    case doesNotReadBack
    case undetermined(why: String)
    case runAgain
    /// The engine stopped before a result (a refusal, an internal error).
    case stopped(reason: String)

    init(_ o: Outcome) {
        if !o.copyOK {
            self = .runAgain
        } else if o.rc == 0 {
            self = .readsBack
        } else if o.rc == 1, let b = o.calib?["B"], b >= mediumRead {
            self = .doesNotReadBack
        } else {
            self = .undetermined(why: Verdict.why(o))
        }
    }

    /// Reference B not seen: before the job (the engine stops) or after it.
    static let counterBlind = "On this disk the test does not see reads that reach the disk. "
                            + "Try the test with another destination disk."

    private static func why(_ o: Outcome) -> String {
        if o.networkDst {
            return "On this network share every read goes over the network anyway. "
                 + "Try the test with a local disk as the destination."
        }
        guard let c = o.calib else {
            return "The second check of the destination did not run, so the test can't tell "
                 + "whether it would have seen a read. Run the test again."
        }
        if (c["B"] ?? 0) < mediumRead { return counterBlind }
        if (c["A"] ?? 0) > notRead {
            return "This Mac did not keep the test files in memory, so a read from the disk "
                 + "could just be the system's. Quit some apps to free memory, then run the test again."
        }
        return "Only part of the copy was read back. Run the test again "
             + "with nothing else using the destination disk."
    }

    var tag: String {
        switch self {
        case .readsBack: "Result: reads back"
        case .doesNotReadBack: "Result: does not read back"
        case .undetermined: "Result: can't be determined"
        case .runAgain: "Result: run it again"
        case .stopped: "Result: test stopped"
        }
    }

    var title: String {
        switch self {
        // Only what the counters show: whether the destination disk read the
        // copy back. Whether the app verified at all, and against what, they
        // can't tell (Finder, which does not verify, gets "not read back" too).
        case .readsBack: "The copy was read back from the destination disk."
        case .doesNotReadBack: "The copy was not read back from the destination disk."
        case .undetermined: "This can't be determined on this disk."
        case .runAgain: "The copy did not land in the test folder."
        case .stopped: "The test stopped before it could finish."
        }
    }

    var text: String {
        switch self {
        case .readsBack:
            "During the test the destination disk read the whole copy again. "
            + "If your app verifies the copy, it checks what is actually stored on the disk."
        case .doesNotReadBack:
            "During the test the destination disk read nothing back. If your app verified the copy, "
            + "it did not check what is stored on the disk: a problem that happens while the data "
            + "is being stored would not be caught."
        case .undetermined:
            "On this destination the test can't tell whether a read was your app's choice "
            + "or simply how the disk works."
        case .runAgain:
            "Your app copied the files somewhere else, so there is nothing to judge. "
            + "This says nothing about your app or your disk."
        case .stopped(let reason):
            reason
        }
    }

    var what: String {
        switch self {
        case .readsBack: ""
        case .doesNotReadBack:
            "Check whether your app offers a verification mode that reads the copy back from the disk, "
            + "then run the test again with it."
        case .undetermined(let why): why
        case .runAgain:
            "In your offload app, set the destination to the test folder shown in step 3, "
            + "then run the test again."
        case .stopped: "Nothing was judged."
        }
    }
}
