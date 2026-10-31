// Copyright (C) 2026 Antonio Marogna — EVRApps
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI

/// One disk counter, as a bar with a mark at every whole multiple of the test data.
struct DiskBar {
    var title: String
    var subtitle: String?
    var bytes: Double
    /// nil for a finished measurement: no activity light.
    var rate: Double?
    var tint: Color
}

/// Bars that share one scale, so they can be compared at a glance. For the
/// eyes only: the verdict is the engine's, from its own readings.
struct DiskBars: View {
    let bars: [DiskBar]
    let size: Double
    /// The result shows the multiple alone, to one decimal: the MB after the
    /// background is subtracted (253 of 256) read like an incomplete copy.
    /// Both stay in the full report.
    var ratioOnly = false

    /// Above this a disk counts as busy for the activity light.
    static let activeRate = 0.5 * MB
    /// The scale stops growing here; a bar beyond it stays full. One mark is a
    /// handful of views, so an unbounded count (a wild counter reading) hung
    /// the window and exhausted SwiftUI's graph.
    static let maxMarks = 4

    var body: some View {
        let size = max(size, 1)
        let most = bars.map(\.bytes).filter(\.isFinite).max() ?? 0
        let marks = min(DiskBars.maxMarks, max(1, Int(min(most / size - 0.05, 100).rounded(.up))))
        let scale = Double(marks) * size
        VStack(alignment: .leading, spacing: 10) {
            ForEach(bars.indices, id: \.self) { i in
                row(bars[i], size: size, scale: scale, marks: marks)
            }
        }
    }

    private func row(_ b: DiskBar, size: Double, scale: Double, marks: Int) -> some View {
        let active = (b.rate ?? 0) > DiskBars.activeRate
        let frac = b.bytes.isFinite ? min(max(b.bytes / scale, 0), 1) : 0
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                if b.rate != nil {
                    Circle()
                        .fill(active ? b.tint : Color.secondary.opacity(0.25))
                        .frame(width: 8, height: 8)
                        .shadow(color: active ? b.tint : .clear, radius: 3)
                        .animation(.easeOut(duration: 0.15), value: active)
                }
                Text(b.title).font(.body.weight(.medium))
                if let s = b.subtitle { Text(s).font(.callout).foregroundStyle(.secondary) }
                Spacer()
                Text(ratioOnly ? "\(String(format: "%.1f", b.bytes / size)) x"
                               : "\(fmtMB(b.bytes)) · \(String(format: "%.2f", b.bytes / size)) x")
                    .font(.body).monospacedDigit()
            }
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(b.tint.gradient)
                        .frame(width: max(0, w * frac))
                        .animation(.linear(duration: 0.25), value: frac)
                    ForEach(1...marks, id: \.self) { k in
                        Rectangle()
                            .fill(Color.primary.opacity(0.5))
                            .frame(width: 2, height: 18)
                            .offset(x: w * CGFloat(k) / CGFloat(marks) - (k == marks ? 2 : 1))
                    }
                }
            }
            .frame(height: 14)
            GeometryReader { geo in
                ForEach(1...marks, id: \.self) { k in
                    Text("\(k).0 x")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        .position(x: geo.size.width * CGFloat(k) / CGFloat(marks) - (k == marks ? 12 : 0), y: 5)
                }
            }
            .frame(height: 10)
        }
    }
}

/// What the bars of each phase show, and what is expected of them.
enum PhaseBars {
    static func caption(_ phase: String, source: String) -> String {
        switch phase {
        case "generate": "Writing the test files to \(source)."
        case "precal_A", "calib_A":
            "Reference A: a copy whose read-back should come from memory. Expected: destination read about 0 x."
        case "precal_B", "calib_B":
            "Reference B: a copy whose read-back should come from the disk. Expected: destination read about 1 x."
        case "job":
            "If your app reads the copy back from the disk, Destination read reaches the 1.0 x mark."
        default: ""
        }
    }

    @MainActor
    static func bars(_ phase: String, session: Session, live: Bool = true) -> [DiskBar] {
        let t = session.traces[phase] ?? [:]
        let rate = { (c: Counter) in live ? session.rates[c] ?? 0 : nil }
        let net = session.measured.dest?.isNetwork == true ? "over the network" : nil
        let srcNet = session.measured.source?.isNetwork == true
        switch phase {
        case "generate":
            return srcNet ? [] : [DiskBar(title: "Source written", bytes: t[.srcW] ?? 0, rate: rate(.srcW), tint: .teal)]
        case "job":
            return (srcNet ? [] : [DiskBar(title: "Source read", bytes: t[.srcR] ?? 0, rate: rate(.srcR), tint: .blue)])
                + destination(t, rate, net)
        default:
            return destination(t, rate, net)
        }
    }

    private static func destination(_ t: [Counter: Double], _ rate: (Counter) -> Double?, _ net: String?) -> [DiskBar] {
        [DiskBar(title: "Destination written", subtitle: net, bytes: t[.dstW] ?? 0, rate: rate(.dstW), tint: .purple),
         DiskBar(title: "Destination read", subtitle: net, bytes: t[.dstR] ?? 0, rate: rate(.dstR), tint: .green)]
    }
}
