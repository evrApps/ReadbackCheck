// Copyright (C) 2026 Antonio Marogna — EVRApps
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI

// --------------------------------------------------------------------------
// shared pieces
// --------------------------------------------------------------------------

enum Palette {
    static let ok = Color(nsColor: .systemGreen)
    static let warn = Color(nsColor: .systemOrange)
    static let bad = Color(nsColor: .systemRed)
    static let info = Color(nsColor: .systemBlue)
    static let field = Color(nsColor: .textBackgroundColor)
    static let row = Color.primary.opacity(0.035)
    static let line = Color.primary.opacity(0.1)
}

struct Lead: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).foregroundStyle(.secondary).padding(.bottom, 12).fixedSize(horizontal: false, vertical: true)
    }
}

/// A titled group.
struct Panel<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.callout.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 2)
            GroupBox { content.frame(maxWidth: .infinity, alignment: .leading).padding(4) }
        }
        .padding(.bottom, 14)
    }
}

/// A coloured line: the fixed spare-disk warning, the copy-elsewhere warning.
struct Banner: View {
    let tint: Color
    let text: Text
    var body: some View {
        text.font(.body)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(tint.opacity(0.35)))
    }
}

/// A read-only path with Copy and Show.
struct PathField: View {
    let path: String
    var body: some View {
        HStack(spacing: 6) {
            Text(path)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Palette.field, in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Palette.line))
            Button("Copy") { Mac.copy(path) }.controlSize(.small)
            Button("Show") { Mac.reveal(path) }.controlSize(.small)
        }
    }
}

struct TaskRow {
    var title: String
    var sub: String
    var state: TaskState
}

/// The task table of steps 2 and 4, with the overall bar under it.
struct TaskTable: View {
    let rows: [TaskRow]
    /// Rough seconds per task: the bar moves inside a running task too.
    let estimates: [Double]
    let started: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 0) {
                HStack {
                    Text("Task").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Status").frame(width: 96, alignment: .leading)
                }
                .font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.vertical, 4)
                Divider()
                ForEach(rows.indices, id: \.self) { i in
                    let r = rows[i]
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(r.title).foregroundStyle(r.state == .waiting ? .tertiary : .primary)
                            Text(r.sub).font(.callout).foregroundStyle(r.state == .failed ? Palette.bad : .secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text(r.state.label).foregroundStyle(color(r.state)).frame(width: 96, alignment: .leading)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(i % 2 == 0 ? Palette.row : .clear)
                }
            }
            .background(Palette.field, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.line))

            TimelineView(.periodic(from: .now, by: 0.25)) { ctx in
                let p = progress(at: ctx.date)
                HStack(spacing: 10) {
                    ProgressView(value: p)
                    Text("\(Int((p * 100).rounded()))%").font(.callout).foregroundStyle(.secondary)
                        .monospacedDigit().frame(width: 36, alignment: .trailing)
                }
            }
        }
    }

    private func color(_ s: TaskState) -> Color {
        switch s {
        case .waiting: Color.secondary.opacity(0.6)
        case .running: Palette.info
        case .done: Palette.ok
        case .failed: Palette.bad
        case .skipped: Palette.warn
        }
    }

    /// Finished tasks count whole; the running one creeps towards 90 % of its share.
    private func progress(at now: Date) -> Double {
        var p = 0.0
        for (i, r) in rows.enumerated() {
            switch r.state {
            case .done, .skipped, .failed: p += 1
            case .running:
                let t = now.timeIntervalSince(started)
                p += 0.9 * (1 - exp(-t / max(estimates[i], 1)))
            case .waiting: break
            }
        }
        return min(1, p / Double(rows.count))
    }
}

/// Dropping a disk, a folder or an app from the Finder on a row of step 1.
enum Drop {
    static func isFolder(_ u: URL) -> Bool {
        let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return v?.isDirectory == true && v?.isPackage != true
    }

    static func isApp(_ u: URL) -> Bool { u.pathExtension == "app" && Bundle(url: u) != nil }
}

private struct Droppable: ViewModifier {
    let accept: (URL) -> Bool
    let drop: (URL) -> Void
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 6).padding(.vertical, 3)
            .contentShape(Rectangle())
            .overlay(RoundedRectangle(cornerRadius: 5)
                .stroke(Color.accentColor, lineWidth: 2).opacity(targeted ? 1 : 0))
            .background(RoundedRectangle(cornerRadius: 5)
                .fill(Color.accentColor.opacity(targeted ? 0.1 : 0)))
            .padding(.horizontal, -6).padding(.vertical, -3)
            .dropDestination(for: URL.self) { urls, _ in
                guard let u = urls.first(where: { $0.isFileURL && accept($0) }) else { return false }
                drop(u)
                return true
            } isTargeted: { targeted = $0 }
    }
}

extension View {
    func droppable(accept: @escaping (URL) -> Bool, drop: @escaping (URL) -> Void) -> some View {
        modifier(Droppable(accept: accept, drop: drop))
    }
}

// --------------------------------------------------------------------------
// 1 Choose the disks
// --------------------------------------------------------------------------

struct ChooseView: View {
    @Environment(Setup.self) private var setup

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Lead("This test finds out whether your offload app reads the copy back from the destination disk "
                 + "during the copy: a verification that checks what is stored on the disk has to.")

            Panel(title: "Disks") {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 9) {
                    GridRow {
                        label("Source:")
                        disk(setup.sourceInfo)
                            .droppable(accept: Drop.isFolder) { setup.choose(source: $0.path) }
                        Button("Choose…") {
                            if let p = Mac.chooseDisk(title: "Choose the source: a spare card or disk", prompt: "Choose") {
                                setup.choose(source: p)
                            }
                        }
                        .controlSize(.small).gridColumnAlignment(.trailing)
                    }
                    GridRow {
                        label("Destination:")
                        disk(setup.destInfo)
                            .droppable(accept: Drop.isFolder) { setup.choose(dest: $0.path) }
                        Button("Choose…") {
                            if let p = Mac.chooseDisk(title: "Choose the destination disk", prompt: "Choose") {
                                setup.choose(dest: p)
                            }
                        }
                        .controlSize(.small)
                    }
                    GridRow {
                        label("Offload app:")
                        app
                            .droppable(accept: Drop.isApp) { setup.choose(app: $0.path) }
                        HStack(spacing: 6) {
                            Button(setup.appPath.isEmpty ? "Choose…" : "Change…") {
                                if let p = Mac.chooseApp() { setup.choose(app: p) }
                            }
                            if !setup.appPath.isEmpty {
                                Button("Clear") { setup.choose(app: "") }
                            }
                        }
                        .controlSize(.small)
                    }
                    GridRow {
                        label("Verification:")
                        TextField("Optional: how your app's verification is set, for example \"xxHash64, source and destination\"",
                                  text: Binding(get: { setup.verifySetting }, set: { setup.choose(verify: $0) }))
                            .textFieldStyle(.roundedBorder)
                            .gridCellColumns(2)
                    }
                    GridRow {
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        Text("Recorded in the report as you type it. The test doesn't check it.")
                            .font(.callout).foregroundStyle(.tertiary)
                            .gridCellColumns(2)
                    }
                }
            }

            checks

            Banner(tint: Palette.warn, text: Text(
                "Use a spare card or disk, not one holding footage you still need. The test writes a small "
                + "folder of test files on it and deletes it at the end."))
                .padding(.top, 12)
        }
    }

    private func label(_ s: String) -> some View {
        Text(s).foregroundStyle(.secondary).frame(width: 90, alignment: .trailing).gridColumnAlignment(.trailing)
    }

    @ViewBuilder
    private func disk(_ d: DiskInfo?) -> some View {
        if let d {
            VStack(alignment: .leading, spacing: 1) {
                (Text(d.name).fontWeight(.semibold) + Text("  " + d.detail).font(.body).foregroundStyle(.secondary))
                if let sub = d.subfolder {
                    Text(sub).font(.system(.callout, design: .monospaced)).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text("Not chosen. Choose… or drop a disk or folder here.").font(.body).foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var app: some View {
        if setup.appPath.isEmpty {
            Text("None chosen. Optional, recorded in the report with its version. Choose… or drop it here.")
                .font(.body).foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 1) {
                (Text(setup.appName).fontWeight(.semibold)
                 + Text("  version \(setup.appVersion ?? "?")").font(.body).foregroundStyle(.secondary))
                Text(setup.appPath).font(.system(.callout, design: .monospaced)).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // ---- the pre-flight checks, as lines of text

    private enum Kind { case ok, note, refusal }
    private struct Line: Identifiable {
        let id = UUID()
        var kind: Kind
        var text: String
        var sub: String?
    }

    private var lines: [Line] {
        if let e = setup.checkError { return [Line(kind: .refusal, text: e)] }
        guard let p = setup.preflight else { return [] }
        if let r = p.refusal { return [Line(kind: .refusal, text: sentence(r))] }
        var l = [Line(kind: .ok, text: "Source and destination are on different disks"),
                 Line(kind: .ok, text: "The destination can be written")]
        l.append(p.remountable
            ? Line(kind: .ok, text: "The source can be ejected and mounted again")
            : Line(kind: .note, text: "The source can't be ejected and mounted again",
                   sub: "The test still runs, but it won't say how your app reads the source."))
        for n in p.notes {
            if n.hasPrefix("network destination") {
                l.append(Line(kind: .note, text: "The destination is a network share",
                              sub: "On some shares every read goes over the network anyway. If so, the test "
                                 + "will say it can't decide. You can still try."))
            } else {
                l.append(Line(kind: .note, text: sentence(n)))
            }
        }
        l.append(Line(kind: .ok, text: "This Mac's free memory can hold \(fmtMB(p.size)) of test data"))
        return l
    }

    @ViewBuilder
    private var checks: some View {
        if setup.source.isEmpty || setup.dest.isEmpty {
            Text("Choose a source and a destination to check them.")
                .font(.body).foregroundStyle(.secondary)
        } else if setup.checking {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking the disks…").font(.body).foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(lines) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text(tag(line.kind)).font(.callout.weight(.semibold)).foregroundStyle(color(line.kind))
                            .frame(width: 44, alignment: .leading)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(line.text).foregroundStyle(line.kind == .refusal ? Palette.bad : .primary)
                                .fixedSize(horizontal: false, vertical: true)
                            if let s = line.sub {
                                Text(s).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                if lines.contains(where: { $0.kind == .refusal }) {
                    Button("Check Again") { setup.recheck() }.controlSize(.small).padding(.top, 4).padding(.leading, 44)
                }
            }
            .font(.body)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Palette.field, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.line))
        }
    }

    private func tag(_ k: Kind) -> String {
        switch k { case .ok: "OK"; case .note: "Note"; case .refusal: "No" }
    }

    private func color(_ k: Kind) -> Color {
        switch k { case .ok: Palette.ok; case .note: Palette.warn; case .refusal: Palette.bad }
    }
}

// --------------------------------------------------------------------------
// 2 Preparing the test
// --------------------------------------------------------------------------

struct PrepareView: View {
    @Environment(Session.self) private var session

    var body: some View {
        let src = session.measured.source?.name ?? "the source"
        let dst = session.measured.dest?.name ?? "the destination"
        let data: String = if let g = session.generated {
            "\(g.files) files, \(fmtMB(g.size)) in total, sized for this Mac's free memory"
        } else {
            "About \(fmtMB(session.expectedSize)) in total, sized for this Mac's free memory"
        }
        let reset: String = switch session.prep[2] {
        case .failed: "Could not eject and mount it again: \(session.remountError?.detail ?? "")"
        case .skipped: "Not reset: the test won't say how your app reads the source."
        default: "\(src) is ejected and mounted again. Close any app that has it open."
        }
        VStack(alignment: .leading, spacing: 0) {
            Lead(session.remountError == nil
                 ? "Nothing to do yet. This takes about a minute."
                 : "\(src) could not be reset. Close any app that has it open and click Retry, or continue "
                   + "without: then the part about how your app reads the source is not judged.")
            TaskTable(rows: [
                TaskRow(title: "Creating test files on \(src)", sub: data, state: session.prep[0]),
                TaskRow(title: "Checking that \(dst) can be measured",
                        sub: "A short copy on the destination with a known result", state: session.prep[1]),
                TaskRow(title: "Resetting \(src)", sub: reset, state: session.prep[2]),
                TaskRow(title: "Measuring background activity",
                        sub: "Don't touch anything for 5 seconds", state: session.prep[3]),
            ], estimates: [6, 12, 4, 3], started: session.taskStarted)
        }
    }
}

// --------------------------------------------------------------------------
// 3 Copy with your offload app
// --------------------------------------------------------------------------

struct CopyView: View {
    @Environment(Session.self) private var session

    var body: some View {
        let h = session.header
        VStack(alignment: .leading, spacing: 0) {
            Lead("Set up the copy in your offload app exactly as you normally would, with verification on.")
            VStack(alignment: .leading, spacing: 9) {
                item(1) { Text("Open your offload app.") }
                item(2) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Copy this folder:")
                        PathField(path: h?.source ?? "")
                    }
                }
                item(3) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("to this folder:")
                        PathField(path: h?.runDir ?? "")
                    }
                }
                item(4) {
                    Text("Turn verification on. Turn off previews, proxies, thumbnails and reports for this test: "
                         + "they read the files too and skew the result.")
                }
                item(5) { Text("Start the copy in your app. The disks are already being watched.") }
            }
            .padding(.bottom, 8)

            live
        }
    }

    private func item<C: View>(_ n: Int, @ViewBuilder _ c: () -> C) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(n).").foregroundStyle(.secondary).frame(width: 16, alignment: .trailing)
            c().fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var live: some View {
        Panel(title: "Watching the disks") {
            VStack(alignment: .leading, spacing: 10) {
                TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                    let size = session.header?.size ?? 0
                    let elapsed = session.jobStarted.map { (session.jobEnded ?? ctx.date).timeIntervalSince($0) } ?? 0
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                        figure("Elapsed:", "\(Int(elapsed)) s")
                        figure("Copy in the test folder:",
                               "\(fmtMB(min(session.runDirBytes, size)).dropLast(3)) of \(fmtMB(size))")
                        figure("App seen copying:", session.seenApps.isEmpty
                               ? "none yet" : session.seenApps.map(\.label).joined(separator: ", "))
                    }
                    if session.runDirBytes == 0 && session.seenApps.isEmpty {
                        Label("Waiting for your app to start the copy…", systemImage: "hourglass")
                            .foregroundStyle(.secondary)
                    }
                }
                DiskBars(bars: PhaseBars.bars("job", session: session), size: session.header?.size ?? 1)
                Text(PhaseBars.caption("job", source: ""))
                    .font(.callout).foregroundStyle(.secondary)
                if session.copyElsewhere {
                    Banner(tint: Palette.bad, text: elsewhereText)
                }
                (Text("When your app says the copy and verification are complete, click ")
                 + Text("Finished").bold() + Text("."))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(.top, 8)
    }

    private var elsewhereText: Text {
        var t = Text("The copy is going somewhere else.").bold()
            + Text(" The destination disk is being written, but nothing arrives in the test folder.")
        if let d = session.misplaced.first {
            t = t + Text(" Found in ") + Text(d).font(.system(.body, design: .monospaced)) + Text(".")
        }
        return t + Text(" Stop the copy and set the destination shown above.")
    }

    private func figure(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary).frame(width: 170, alignment: .trailing)
            Text(v).monospacedDigit()
        }
        .font(.body)
    }
}

// --------------------------------------------------------------------------
// 4 Final check
// --------------------------------------------------------------------------

struct FinalView: View {
    @Environment(Session.self) private var session

    var body: some View {
        let n = session.header?.files ?? 0
        VStack(alignment: .leading, spacing: 0) {
            Lead("Almost done.")
            TaskTable(rows: [
                TaskRow(title: "Counting the copy", sub: "Background activity is measured again, and all \(n) files must be in the test folder", state: session.fin[0]),
                TaskRow(title: "Checking the destination again",
                        sub: session.fin[1] == .skipped ? "Not needed: the copy is not in the test folder"
                                                        : "Conditions can change during a copy",
                        state: session.fin[1]),
                TaskRow(title: "Removing the test files", sub: "From both disks", state: session.fin[2]),
            ], estimates: [2, 12, 2], started: session.taskStarted)
        }
    }
}

// --------------------------------------------------------------------------
// 5 Result
// --------------------------------------------------------------------------

struct ResultView: View {
    @Environment(Session.self) private var session
    @State private var showReport = false

    var body: some View {
        let v = session.verdict ?? .stopped(reason: "")
        let m = session.measured
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Rectangle().fill(tint(v)).frame(width: 3)
                VStack(alignment: .leading, spacing: 6) {
                    Text(v.tag).font(.callout).foregroundStyle(.secondary)
                    Text(v.title).font(.title3.weight(.semibold)).foregroundStyle(titleColor(v))
                    Text(v.text).fixedSize(horizontal: false, vertical: true)
                    if !v.what.isEmpty {
                        Text(v.what).font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Palette.field)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.line))
            .padding(.bottom, 14)

            if let o = session.outcome, o.copyOK {
                Panel(title: "During the copy") {
                    VStack(alignment: .leading, spacing: 10) {
                        DiskBars(bars: copyBars(o), size: o.size, ratioOnly: true)
                        // A failed check is already the result, "Can't be determined", with
                        // its reason; the reference values are in the full report.
                        if o.calib != nil, v.key == "readsBack" || v.key == "doesNotReadBack" {
                            Text("Instrument check: passed.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Panel(title: "Measured with") {
                VStack(alignment: .leading, spacing: 8) {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 3) {
                        scope("Destination:", m.dest?.short ?? "—")
                        scope("Source:", m.source?.short ?? "—")
                        scope("Offload app:", appText)
                        if let s = seenText { scope("Seen copying:", s) }
                        if let v = m.verify { scope("Verification:", v) }
                        scope("Test data:", testData)
                        scope("Date:", dateText(m.date))
                    }
                    Text("This result is about your app on this disk, with the settings used for this test. "
                         + "Other disks or settings can give a different result.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }

            if !reportText.isEmpty {
                DisclosureGroup("Full report", isExpanded: $showReport) {
                    ScrollView([.vertical, .horizontal]) {
                        Text(reportText)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(maxHeight: 230)
                    .background(Palette.field, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.line))
                    .padding(.top, 6)
                }
                .font(.body)
            }

            if let c = cleanLine {
                Text(c).font(.callout).foregroundStyle(cleanOK ? .secondary : Palette.bad)
                    .textSelection(.enabled).padding(.top, 8)
            }
        }
    }

    /// "Oct 30, 2026 15:42", whatever the Mac's region.
    private func dateText(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d, yyyy HH:mm"
        return f.string(from: d)
    }

    /// The job's counts with the background subtracted, as the verdict reads them.
    private func copyBars(_ o: Outcome) -> [DiskBar] {
        let net = o.networkDst ? "over the network" : nil
        var b: [DiskBar] = []
        if session.measured.source?.isNetwork != true {
            b.append(DiskBar(title: "Source read", subtitle: o.cold ? nil : "source not reset",
                             bytes: o.adj[.srcR] ?? 0, tint: .blue))
        }
        b.append(DiskBar(title: "Destination written", subtitle: net, bytes: o.adj[.dstW] ?? 0, tint: .purple))
        b.append(DiskBar(title: "Destination read", subtitle: net, bytes: o.adj[.dstR] ?? 0, tint: .green))
        return b
    }

    /// The app chosen in step 1, or the one seen copying when none was chosen.
    private var appText: String { session.appSummary }

    /// Only when it adds something: several apps seen, none seen, or not the
    /// one chosen.
    private var seenText: String? {
        let seen = session.seenApps, m = session.measured
        guard session.jobEnded != nil else { return nil }
        let list = seen.map(\.label).joined(separator: ", ")
        if seen.isEmpty { return "no app was seen with files open in the test folders" }
        if m.app == nil { return seen.count > 1 ? list : nil }
        let chosen = m.appPath.map { ($0 as NSString).resolvingSymlinksInPath }
        if seen.contains(where: { $0.path == chosen }) { return seen.count > 1 ? list : nil }
        return "\(list), not the app chosen in step 1"
    }

    private var testData: String {
        if let h = session.header { return "\(h.files) files, \(fmtMB(h.size))" }
        if let g = session.generated { return "\(g.files) files, \(fmtMB(g.size))" }
        return "—"
    }

    private var reportText: String {
        if let o = session.outcome { return o.report }
        return session.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Leftovers: what the engine reported, or what is still on the disks after it stopped.
    private var leftovers: [String] {
        if let c = session.cleaned { return c.ok ? [] : c.folders.filter { FileManager.default.fileExists(atPath: $0) } }
        return [session.header?.runDir, session.header?.source ?? session.generated?.folder]
            .compactMap { $0 }.filter { !$0.isEmpty && FileManager.default.fileExists(atPath: $0) }
    }

    private var cleanOK: Bool { leftovers.isEmpty }

    private var cleanLine: String? {
        let src = session.measured.source?.name ?? "the source", dst = session.measured.dest?.name ?? "the destination"
        if session.cleaned == nil && session.generated == nil { return nil }   // stopped before creating anything
        if cleanOK { return "Test files removed from \(src) and \(dst)." }
        return "Some test files could not be removed. Delete them yourself: " + leftovers.joined(separator: ", ")
    }

    private func scope(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary).frame(width: 110, alignment: .trailing)
            Text(v).textSelection(.enabled)
        }
        .font(.body)
    }

    private func tint(_ v: Verdict) -> Color {
        switch v {
        case .readsBack: Palette.ok
        case .doesNotReadBack: Palette.warn
        case .runAgain: Palette.info
        case .undetermined, .stopped: Color.secondary.opacity(0.5)
        }
    }

    private func titleColor(_ v: Verdict) -> Color {
        switch v {
        case .readsBack: Palette.ok
        case .doesNotReadBack: Palette.warn
        case .runAgain: Palette.info
        case .undetermined, .stopped: .primary
        }
    }
}
