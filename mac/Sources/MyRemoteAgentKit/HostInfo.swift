import Foundation
import SystemConfiguration

public enum HostInfo {
    /// The user-visible computer name ("Vlad's MacBook Pro"), which is both the
    /// Bonjour instance name and the `name` in the pairing URI.
    public static func computerName() -> String {
        if let name = SCDynamicStoreCopyComputerName(nil, nil) as String?, !name.isEmpty {
            return name
        }
        let host = ProcessInfo.processInfo.hostName
        let short = host.split(separator: ".").first.map(String.init) ?? host
        return short.isEmpty ? "Mac" : short
    }

    public struct InterfaceAddress: Equatable, Sendable {
        public let interface: String
        public let address: String
    }

    /// IPv4 addresses of interfaces that are up, excluding loopback and link-local.
    public static func ipv4Addresses() -> [InterfaceAddress] {
        var result: [InterfaceAddress] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }

        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                  let address = entry.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET)
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            let text = String(cString: host)
            guard !text.hasPrefix("169.254."), !text.hasPrefix("127.") else { continue }
            result.append(InterfaceAddress(interface: String(cString: entry.pointee.ifa_name), address: text))
        }
        return result
    }

    /// Picks the address a phone on the same LAN should use: built-in Ethernet/Wi-Fi
    /// (`en*`) before anything else (bridges, VPN tunnels, virtual machines).
    public static func preferredLANAddress(from addresses: [InterfaceAddress]) -> String? {
        func rank(_ interface: String) -> Int {
            if interface.hasPrefix("en") { return 0 }
            if interface.hasPrefix("bridge") { return 1 }
            if interface.hasPrefix("utun") || interface.hasPrefix("ipsec") || interface.hasPrefix("ppp") { return 3 }
            return 2
        }
        return addresses.enumerated()
            .min { lhs, rhs in
                let (l, r) = (rank(lhs.element.interface), rank(rhs.element.interface))
                if l != r { return l < r }
                if lhs.element.interface != rhs.element.interface {
                    return lhs.element.interface.compare(rhs.element.interface, options: .numeric) == .orderedAscending
                }
                return lhs.offset < rhs.offset
            }?
            .element.address
    }

    /// Host for the pairing URI: the LAN IPv4, else the mDNS hostname.
    public static func pairingHost(loopback: Bool) -> String {
        if loopback { return "127.0.0.1" }
        if let address = preferredLANAddress(from: ipv4Addresses()) { return address }
        let host = ProcessInfo.processInfo.hostName
        return host.isEmpty ? "localhost" : host
    }
}
