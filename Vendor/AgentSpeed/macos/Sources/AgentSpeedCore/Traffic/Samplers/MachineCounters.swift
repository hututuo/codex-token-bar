import Darwin
import Foundation
import notify
import SystemConfiguration

/// The interfaces whose bytes are machine traffic (METRICS 10.2): the BSD names of `SCNetworkInterfaceCopyAll()`
/// except Bridge, Bond and VLAN interfaces (and, defensively, tunnels, peer-to-peer links and virtual machines).
enum CountedInterfaces {
    private static let excludedPrefixes = ["lo", "utun", "ipsec", "ppp", "awdl", "llw", "bridge", "vmenet", "feth", "anpi",
                                           "gif", "stf"]

    static func current() -> Set<String> {
        guard let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return [] }
        // "Bridge" is `kSCNetworkInterfaceTypeBridge`, which the public headers do not declare.
        let excludedTypes: Set<String> = ["Bridge", kSCNetworkInterfaceTypeBond as String, kSCNetworkInterfaceTypeVLAN as String]
        var names: Set<String> = []
        for interface in all {
            guard let name = SCNetworkInterfaceGetBSDName(interface) as String?, !name.isEmpty else { continue }
            if let type = SCNetworkInterfaceGetInterfaceType(interface) as String?, excludedTypes.contains(type) { continue }
            if excludedPrefixes.contains(where: { name.hasPrefix($0) }) { continue }
            names.insert(name)
        }
        return names
    }
}

/// Cumulative 64-bit interface counters from `sysctl NET_RT_IFLIST2` (`if_msghdr2.ifm_data`, `if_data64`), not
/// `getifaddrs`, whose 32-bit counters wrap every 4 GiB (METRICS 10.2). Not thread-safe; one queue uses it.
final class MachineCounterReader {
    private var buffer: UnsafeMutableRawPointer?
    private var capacity = 0

    deinit { buffer?.deallocate() }

    /// Counters of the `counted` interfaces that are up and running, by BSD name; nil when the call fails.
    func read(counted: Set<String>) -> [String: TrafficCounter]? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        for _ in 0..<3 {
            guard sysctl(&mib, 6, nil, &length, nil, 0) == 0 else { return nil }
            let wanted = length + length / 4 + 1024
            if wanted > capacity {
                buffer?.deallocate()
                buffer = UnsafeMutableRawPointer.allocate(byteCount: wanted, alignment: 8)
                capacity = wanted
            }
            length = capacity
            if sysctl(&mib, 6, buffer, &length, nil, 0) == 0 { break }
            guard errno == ENOMEM else { return nil }
            length = 0
        }
        guard let buffer, length > 0 else { return nil }
        return Self.parse(UnsafeRawBufferPointer(start: buffer, count: length), counted: counted)
    }

    static func parse(_ bytes: UnsafeRawBufferPointer, counted: Set<String>) -> [String: TrafficCounter] {
        var counters: [String: TrafficCounter] = [:]
        let headerSize = MemoryLayout<if_msghdr2>.size
        let running = IFF_UP | IFF_RUNNING
        var offset = 0
        while offset + 4 <= bytes.count {
            let messageLength = Int(bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
            guard messageLength > 0, offset + messageLength <= bytes.count else { break }
            defer { offset += messageLength }
            let type = bytes.loadUnaligned(fromByteOffset: offset + 3, as: UInt8.self)
            guard Int32(type) == RTM_IFINFO2, messageLength >= headerSize + 8 else { continue }
            let message = bytes.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
            guard message.ifm_flags & running == running, message.ifm_addrs & RTA_IFP != 0 else { continue }
            let link = offset + headerSize
            let nameLength = Int(bytes.loadUnaligned(fromByteOffset: link + 5, as: UInt8.self))
            guard nameLength > 0, link + 8 + nameLength <= offset + messageLength else { continue }
            let name = String(decoding: UnsafeRawBufferPointer(rebasing: bytes[(link + 8)..<(link + 8 + nameLength)]), as: UTF8.self)
            guard counted.contains(name) else { continue }
            counters[name] = TrafficCounter(rx: Int64(clamping: message.ifm_data.ifi_ibytes),
                                            tx: Int64(clamping: message.ifm_data.ifi_obytes))
        }
        return counters
    }
}

/// Keeps the counted-interface list fresh: on SystemConfiguration network-change notifications (at most every 5 s;
/// up and running is read with every counter sample anyway) and every 60 s (METRICS 10.2). Confined to the queue it is
/// created with.
final class CountedInterfaceList {
    static let refreshIntervalMs: Int64 = 60_000
    static let minimumRefreshMs: Int64 = 5000

    private(set) var names: Set<String> = []
    /// Diagnostics: how often the list was read.
    private(set) var refreshes = 0
    private var refreshedAtMs: Int64?
    private var token: Int32 = 0
    private var registered = false
    private var changed = true

    init(queue: DispatchQueue) {
        let status = notify_register_dispatch("com.apple.system.config.network_change", &token, queue) { [weak self] _ in
            self?.changed = true
        }
        registered = status == NOTIFY_STATUS_OK
    }

    deinit {
        if registered { notify_cancel(token) }
    }

    /// The current list, refreshed first when due.
    func current(nowMs: Int64) -> Set<String> {
        let age = refreshedAtMs.map { nowMs - $0 } ?? .max
        if age >= Self.refreshIntervalMs || (changed && age >= Self.minimumRefreshMs) {
            changed = false
            refreshedAtMs = nowMs
            names = CountedInterfaces.current()
            refreshes += 1
        }
        return names
    }
}
