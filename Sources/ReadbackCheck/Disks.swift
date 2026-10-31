// Copyright (C) 2026 Antonio Marogna — EVRApps
// SPDX-License-Identifier: GPL-3.0-only

import DiskArbitration
import Foundation

/// What the operator sees next to a chosen disk: volume name, model, capacity,
/// connection, file system. For display only: the engine classifies the disks
/// itself and decides from its own reading.
struct DiskInfo: Equatable {
    var path = ""
    var name = ""
    var mount = ""
    var model: String?
    /// For a memory card: the reader it sits in. Through a reader macOS sees
    /// only the reader's name, never the card's maker or model.
    var reader: String?
    var capacity: Int64?
    var connection: String?
    var format: String?
    var isNetwork = false

    init(path: String) {
        self.path = path
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [.volumeURLKey, .volumeLocalizedNameKey, .volumeTotalCapacityKey,
                                         .volumeTypeNameKey, .volumeIsLocalKey, .volumeURLForRemountingKey]
        let v = try? url.resourceValues(forKeys: keys)
        mount = v?.volume?.path ?? path
        name = v?.volumeLocalizedName ?? (mount as NSString).lastPathComponent
        capacity = v?.volumeTotalCapacity.map(Int64.init)
        let type = v?.volumeTypeName ?? ""
        format = DiskInfo.formats[type] ?? (type.isEmpty ? nil : type.uppercased())
        isNetwork = v?.volumeIsLocal == false
        if isNetwork {
            connection = "network share"
            if let r = v?.volumeURLForRemounting, let scheme = r.scheme, let host = r.host {
                connection! += ", \(scheme)://\(host)"          // without the user name
            }
            return
        }
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
              let d = DADiskCopyDescription(disk) as? [String: Any] else { return }
        let vendor = (d[kDADiskDescriptionDeviceVendorKey as String] as? String ?? "")
            .trimmingCharacters(in: .whitespaces)
        let product = (d[kDADiskDescriptionDeviceModelKey as String] as? String ?? "")
            .trimmingCharacters(in: .whitespaces)
        let m = [vendor, product].filter { !$0.isEmpty }.joined(separator: " ")
        model = m.isEmpty ? nil : m
        let proto = d[kDADiskDescriptionDeviceProtocolKey as String] as? String ?? ""
        let isInternal = d[kDADiskDescriptionDeviceInternalKey as String] as? Bool ?? false
        let removable = d[kDADiskDescriptionMediaRemovableKey as String] as? Bool ?? false
        switch proto {
        case "Secure Digital": connection = "built-in"
        case _ where isInternal: connection = "internal"
        case "": connection = nil
        default: connection = removable ? "\(proto), removable" : proto
        }
        if DiskInfo.isCard(protocol: proto, removable: removable, model: m) {
            reader = model.map(DiskInfo.cleanReaderName)
            model = nil
            if connection == "\(proto), removable" { connection = proto }
        }
    }

    /// A card in a reader rather than a disk of its own. A removable USB stick
    /// has no reader to name, so it needs a reader-like name to count.
    static func isCard(protocol proto: String, removable: Bool, model: String) -> Bool {
        if proto == "Secure Digital" { return true }
        guard removable else { return false }
        let m = model.lowercased()
        return ["reader", "card", "sd", "cfexpress", "cfast", "compactflash", "xqd", "microsd", "multi"]
            .contains { m.range(of: "\\b\($0)", options: .regularExpression) != nil }
    }

    /// "ProGrade SD PG02 Media" names the reader's slot; the reader is "ProGrade SD PG02".
    static func cleanReaderName(_ s: String) -> String {
        s.hasSuffix(" Media") ? String(s.dropLast(6)) : s
    }

    /// "card reader: ProGrade SD PG02 (USB)"
    var readerText: String? {
        reader.map { r in "card reader: \(r)" + (connection.map { " (\($0))" } ?? "") }
    }

    static let formats = ["apfs": "APFS", "exfat": "ExFAT", "msdos": "FAT", "hfs": "Mac OS Extended",
                          "smbfs": "SMB", "afpfs": "AFP", "nfs": "NFS", "webdav": "WebDAV"]

    /// "64.8 GB", "2 TB": decimal units, always with the English decimal point.
    var capacityText: String? {
        guard let c = capacity, c > 0 else { return nil }
        var v = Double(c), unit = 0
        let units = ["bytes", "KB", "MB", "GB", "TB", "PB"]
        while v >= 1000 && unit < units.count - 1 { v /= 1000; unit += 1 }
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US")
        f.maximumFractionDigits = v < 100 ? 1 : 0
        return "\(f.string(from: NSNumber(value: v)) ?? "\(Int(v))") \(units[unit])"
    }

    /// "Samsung T7, 2 TB, USB, APFS"; for a card "64.8 GB, ExFAT, card reader: ProGrade SD PG02 (USB)"
    var detail: String {
        if reader != nil { return [capacityText, format, readerText].compactMap { $0 }.joined(separator: ", ") }
        return [model, capacityText, connection, format].compactMap { $0 }.joined(separator: ", ")
    }

    /// "Crucial_2TB_P2_nvme, USB, APFS", for "Measured with".
    var short: String {
        if reader != nil { return [name, format, readerText].compactMap { $0 }.joined(separator: ", ") }
        return [name, connection, format].compactMap { $0 }.joined(separator: ", ")
    }

    /// The chosen folder, when it is not the volume itself.
    var subfolder: String? { path == mount ? nil : path }
}
