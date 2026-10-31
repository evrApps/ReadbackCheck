// Copyright (C) 2026 Antonio Marogna — EVRApps
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import SwiftUI

/// One finished test, as the Past Tests window lists it. Written next to the
/// engine's report as "<report name>.json" when the result arrives, so the
/// list never has to read the report's text.
struct PastTest: Codable, Identifiable, Hashable {
    var date: Date
    var app: String
    var source: String
    var dest: String
    /// "readsBack", "doesNotReadBack", "undetermined", "runAgain".
    var result: String
    var report: String                 // file name in the reports folder

    var id: String { report }

    var resultText: String {
        switch result {
        case "readsBack": "Read back"
        case "doesNotReadBack": "Not read back"
        case "undetermined": "Can't be determined"
        case "runAgain": "Run it again"
        default: "—"
        }
    }

    var resultColor: Color {
        switch result {
        case "readsBack": Palette.ok
        case "doesNotReadBack": Palette.warn
        case "runAgain": Palette.info
        default: .secondary
        }
    }
}

extension Verdict {
    var key: String {
        switch self {
        case .readsBack: "readsBack"
        case .doesNotReadBack: "doesNotReadBack"
        case .undetermined: "undetermined"
        case .runAgain: "runAgain"
        case .stopped: "stopped"
        }
    }
}

enum History {
    static let changed = Notification.Name("ReadbackCheckPastTestsChanged")

    /// The report the window selects the next time it loads: the result's
    /// Show Report opens Past Tests on its own test.
    @MainActor static var focus: String?

    @MainActor
    static func show(report path: String, open: OpenWindowAction) {
        focus = (path as NSString).lastPathComponent
        open(id: "past-tests")
        NotificationCenter.default.post(name: changed, object: nil)   // when it was open already
    }

    static var folder: URL { URL(fileURLWithPath: EnginePaths.reportDir) }

    static func record(_ t: PastTest) {
        let url = folder.appendingPathComponent(t.report).appendingPathExtension("json")
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(t).write(to: url)
        NotificationCenter.default.post(name: changed, object: nil)
    }

    /// Newest first. Each test is listed from the .json entry written with its
    /// report; a report without one is not listed.
    static func load() -> [PastTest] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return names.filter { $0.hasSuffix(".txt.json") }.compactMap { name in
            (try? Data(contentsOf: folder.appendingPathComponent(name))).flatMap { try? dec.decode(PastTest.self, from: $0) }
        }
        .sorted { $0.date > $1.date }
    }

    static func text(of t: PastTest) -> String {
        (try? String(contentsOf: folder.appendingPathComponent(t.report), encoding: .utf8)) ?? "The report file is missing."
    }

    static func showFolder() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }
}

/// Window ▸ Past Tests: every test run on this Mac, newest first, with its report.
struct PastTestsView: View {
    @State private var tests: [PastTest] = []
    @State private var selection: PastTest.ID?

    var body: some View {
        VSplitView {
            Table(tests, selection: $selection) {
                TableColumn("Date") { t in Text(dateText(t.date)).monospacedDigit() }
                    .width(min: 120, ideal: 130)
                TableColumn("Offload app", value: \.app)
                    .width(min: 140, ideal: 280)
                TableColumn("Destination", value: \.dest)
                    .width(min: 100, ideal: 160)
                TableColumn("Result") { t in Text(t.resultText).foregroundStyle(t.resultColor) }
                    .width(min: 100, ideal: 130)
            }
            .frame(minHeight: 140)

            Group {
                if let t = tests.first(where: { $0.id == selection }) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(t.report).font(.callout).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("Show in Finder") { Mac.reveal(History.folder.appendingPathComponent(t.report).path) }
                        }
                        ScrollView([.vertical, .horizontal]) {
                            Text(History.text(of: t))
                                .font(.system(size: 12, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                        }
                        .background(Palette.field, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.line))
                    }
                } else {
                    Text(tests.isEmpty ? "No tests yet. Each finished test is listed here with its report."
                                       : "Select a test to see its report.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(12)
            .frame(minHeight: 200)
        }
        .frame(minWidth: 640, minHeight: 440)
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: History.changed)) { _ in reload() }
    }

    private func reload() {
        tests = History.load()
        if let f = History.focus, tests.contains(where: { $0.id == f }) {
            selection = f
            History.focus = nil
        } else if selection == nil || !tests.contains(where: { $0.id == selection }) { selection = tests.first?.id }
    }

    private func dateText(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d, yyyy HH:mm"
        return f.string(from: d)
    }
}
