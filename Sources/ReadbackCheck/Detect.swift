// Copyright (C) 2026 Antonio Marogna — EVRApps
// SPDX-License-Identifier: GPL-3.0-only

import Darwin
import Foundation

/// An app (or a command-line tool) seen with files open in the test folders
/// during the copy. Only the user's own processes can be read, and that needs
/// no permission: an offload app runs as the user.
struct SeenApp: Hashable {
    /// The outermost .app bundle the executable lives in, or the executable.
    var path: String
    var name: String
    var version: String?
    var sides: Set<String> = []        // "source", "destination"

    var label: String { version.map { "\(name) \($0)" } ?? name }

    func json() -> [String: Any] {
        ["path": path, "name": name, "version": version ?? "", "sides": sides.sorted()]
    }
}

enum Detector {
    /// Executables here are the system's own: Spotlight, Finder, Quick Look and
    /// friends open the test files too, and none of them is an offload app.
    static let systemPrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/"]

    /// Processes with a file open under one of the folders. The engine, its
    /// helpers and this app are left out. Polled twice a second by the session;
    /// an app that opens and closes a file between two polls can be missed.
    static func scan(folders: [(side: String, path: String)], engine: pid_t?) -> [SeenApp] {
        let me = getpid(), uid = getuid()
        let own = Bundle.main.bundlePath + "/"
        let roots = folders.map { (side: $0.side, prefix: ($0.path as NSString).standardizingPath + "/") }
        var seen = [String: SeenApp]()
        for pid in allPids() where pid > 0 && pid != me && pid != engine {
            guard let info = bsdInfo(pid), info.pbi_uid == uid,
                  !descends(pid, from: engine, first: info) else { continue }
            let sides = Set(openPaths(pid).compactMap { p in roots.first { p.hasPrefix($0.prefix) }?.side })
            guard !sides.isEmpty, let exe = executable(pid),
                  !exe.hasPrefix(own), !systemPrefixes.contains(where: exe.hasPrefix) else { continue }
            var app = seen[bundle(of: exe)] ?? identify(exe)
            app.sides.formUnion(sides)
            seen[app.path] = app
        }
        return seen.values.sorted { $0.name < $1.name }
    }

    /// The outermost .app around an executable: helpers inside an app's bundle
    /// (XPC services, login items, bundled tools) count as that app.
    static func bundle(of exe: String) -> String {
        guard let r = exe.range(of: ".app/") else { return exe }
        return String(exe[..<r.lowerBound]) + ".app"
    }

    static func identify(_ exe: String) -> SeenApp {
        let path = bundle(of: exe)
        guard path.hasSuffix(".app"), let b = Bundle(path: path) else {
            return SeenApp(path: path, name: (path as NSString).lastPathComponent)
        }
        let name = b.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? b.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        var version: String?
        if let short = b.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            let build = b.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            version = build.map { $0 == short ? short : "\(short) (\($0))" } ?? short
        }
        return SeenApp(path: path, name: name, version: version)
    }

    // ---- libproc

    private static func allPids() -> [pid_t] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(n) + 64)
        let got = pids.withUnsafeMutableBufferPointer {
            proc_listallpids($0.baseAddress, Int32($0.count * MemoryLayout<pid_t>.size))
        }
        return Array(pids.prefix(max(0, Int(got))))
    }

    private static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }

    /// A child or grandchild of the engine (its evr_copyhash runs, the sync).
    private static func descends(_ pid: pid_t, from engine: pid_t?, first: proc_bsdinfo) -> Bool {
        guard let engine else { return false }
        var parent = pid_t(first.pbi_ppid)
        for _ in 0..<4 {
            if parent == engine { return true }
            guard parent > 1, let i = bsdInfo(parent) else { return false }
            parent = pid_t(i.pbi_ppid)
        }
        return false
    }

    private static func executable(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return String(cString: buf)
    }

    private static func openPaths(_ pid: pid_t) -> [String] {
        let need = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard need > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(need) / stride + 16)
        let got = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard got > 0 else { return [] }
        var paths: [String] = []
        for fd in fds.prefix(Int(got) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var vi = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &vi, size) == size else { continue }
            let path = withUnsafeBytes(of: &vi.pvip.vip_path) { raw in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
            paths.append(path)
        }
        return paths
    }
}
