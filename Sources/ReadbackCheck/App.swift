// Copyright (C) 2026 Antonio Marogna — EVRApps
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import SwiftUI

@main
struct ReadbackCheckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var setup = Setup()
    @State private var session = Session()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("Readback Check", id: "main") {
            ContentView()
                .environment(\.locale, Locale(identifier: "en_US"))
                .environment(setup)
                .environment(session)
                .frame(minWidth: 720, idealWidth: 720, minHeight: 620, idealHeight: 640)
                .onAppear {
                    SelfTest.install(setup: setup, session: session)
                    if UserDefaults.standard.bool(forKey: "selfTestPastTests") { openWindow(id: "past-tests") }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    // A backup may have ended, a disk may have gone: check again on return.
                    if session.step == .choose && !setup.checking { setup.recheck() }
                }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Readback Check") { About.show() }
            }
            ReportCommands()
        }

        Window("Past Tests", id: "past-tests") {
            PastTestsView()
                .environment(\.locale, Locale(identifier: "en_US"))
        }
        .defaultSize(width: 860, height: 560)
        // Listed by ReportCommands, not twice in the Window menu.
        .commandsRemoved()
    }
}

/// Window ▸ Past Tests and File ▸ Show Reports in Finder.
struct ReportCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Show Reports in Finder") { History.showFolder() }
        }
        CommandGroup(before: .windowList) {
            Button("Past Tests") { openWindow(id: "past-tests") }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Divider()
        }
    }
}

/// The standard About panel, with the name spelled out (a bare executable has
/// no bundle name) and the maker in the credits, not in the app's name.
enum About {
    @MainActor
    static func show() {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "development build"
        let text = """
            Readback Check is free software: you can redistribute it and/or modify it under the terms of \
            the GNU General Public License version 3, with the additional terms in ADDITIONAL_TERMS.
            The evr_copyhash component is proprietary and is licensed separately.
            Readback Check and the Readback Check icon are trademarks of Antonio Marogna.
            by EVRApps
            """
        let credits = NSMutableAttributedString(
            string: text,
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                         .foregroundColor: NSColor.secondaryLabelColor])
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 4
        credits.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: credits.length))
        // The portable app carries the license texts: link them where they are.
        let licenses = Bundle.main.resourceURL?.appendingPathComponent("Licenses")
        for (words, file) in [("GNU General Public License version 3", "ReadbackCheck-LICENSE.txt"),
                              ("ADDITIONAL_TERMS", "ReadbackCheck-ADDITIONAL_TERMS.md"),
                              ("licensed separately", "evr_copyhash.txt")] {
            guard let url = licenses?.appendingPathComponent(file),
                  FileManager.default.fileExists(atPath: url.path) else { continue }
            credits.addAttribute(.link, value: url, range: (text as NSString).range(of: words))
        }
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "Readback Check",
            .applicationVersion: version,
            .credits: credits,
        ]
        if info["CFBundleVersion"] == nil { options[.version] = "" }
        NSApp.orderFrontStandardAboutPanel(options: options)
        NSApp.activate(ignoringOtherApps: true)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)           // a write to an engine that just exited
        // Also when launched as a bare executable (swift run), not only as a bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// The engine never outlives the app. SIGINT, so a test cut short still
    /// removes its test folders from both disks.
    func applicationWillTerminate(_ notification: Notification) {
        let me = String(ProcessInfo.processInfo.processIdentifier)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        p.arguments = ["-INT", "-P", me]
        try? p.run()
        p.waitUntilExit()
        Thread.sleep(forTimeInterval: 1)
    }
}

struct ContentView: View {
    @Environment(Session.self) private var session

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(session.step.title).font(.title3.weight(.semibold))
                Spacer()
                Text("Step \(session.step.rawValue) of 5")
                    .font(.body).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 10)

            // The content width comes from the window, never from the scroll
            // view: with legacy scrollers (a mouse attached) a width that follows
            // the scroller rewraps the text, which changes the height, which
            // hides the scroller again: an endless layout loop that hung the
            // window and crashed it. The scroller lives in the right margin.
            GeometryReader { geo in
                ScrollView {
                    Group {
                        switch session.step {
                        case .choose: ChooseView()
                        case .prepare: PrepareView()
                        case .copy: CopyView()
                        case .final: FinalView()
                        case .result: ResultView()
                        }
                    }
                    .frame(width: max(0, geo.size.width - 40), alignment: .leading)
                    .padding(.leading, 20).padding(.bottom, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Divider()
            BottomBar().padding(.horizontal, 20).padding(.vertical, 10)
        }
    }
}

struct BottomBar: View {
    @Environment(Setup.self) private var setup
    @Environment(Session.self) private var session
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 8) {
            Text("EVRApps").font(.callout).foregroundStyle(.tertiary)
            Spacer()
            switch session.step {
            case .choose:
                Button("Prepare Test") { session.start(setup) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!setup.canPrepare)
            case .prepare:
                if let e = session.remountError {
                    Button("Cancel") { session.cancel() }.disabled(session.cancelling)
                    Button("Continue Without") { session.continueWithoutRemount() }
                    if e.retryable {
                        Button("Retry") { session.retryRemount() }.keyboardShortcut(.defaultAction)
                    }
                } else {
                    Button("Cancel") { session.cancel() }.disabled(session.cancelling)
                }
            case .copy:
                Button("Cancel") { session.cancel() }.disabled(session.cancelling)
                Button("Finished") { session.finishedCopy() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(session.awaiting != "done")
            case .final:
                Button("Cancel") { session.cancel() }.disabled(session.cancelling || session.outcome != nil)
            case .result:
                if let o = session.outcome, !o.reportPath.isEmpty {
                    Button("Past Tests") { History.show(report: o.reportPath, open: openWindow) }
                }
                Button("Test Again") { session.reset(); setup.recheck() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
