import Vapor
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// MARK: - Client IP

extension Request {
    /// The client's IP address, for per-IP rate limits. See `ClientIP.resolve`.
    var clientIP: String {
        ClientIP.resolve(
            forwardedFor: headers[.xForwardedFor],
            cfConnectingIP: headers.first(name: "CF-Connecting-IP"),
            remoteAddress: remoteAddress?.ipAddress
        )
    }
}

enum ClientIP {
    /// On Render a request passes Cloudflare and Render's own proxies. Each appends the
    /// address it got the request from to `X-Forwarded-For`, after whatever the client
    /// sent, so the leftmost entries can be forged. The client is the rightmost entry
    /// that is not one of those proxies: walking from the right, Render's private
    /// addresses are skipped, and on reaching a Cloudflare address `CF-Connecting-IP`
    /// is used, which Cloudflare sets itself and overwrites if a client sends one.
    static func resolve(forwardedFor: [String], cfConnectingIP: String?, remoteAddress: String?) -> String {
        let hops = forwardedFor
            .flatMap { $0.split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        for hop in hops.reversed() {
            // Proxies write valid addresses, so anything else is the client's own text.
            guard let address = IPAddress(hop) else { return hop }
            if address.isPrivate { continue }
            if address.isCloudflare {
                if let cfConnectingIP, IPAddress(cfConnectingIP) != nil { return cfConnectingIP }
                continue
            }
            return hop
        }
        // Only proxies and private addresses: a direct or local request.
        return hops.first ?? remoteAddress ?? "unknown"
    }
}

// MARK: - IP Address

/// An IPv4 or IPv6 address as bytes in network order; IPv4-mapped IPv6 becomes IPv4.
struct IPAddress: Equatable {
    let bytes: [UInt8]

    init?(_ string: String) {
        var v4 = in_addr()
        if inet_pton(AF_INET, string, &v4) == 1 {
            bytes = withUnsafeBytes(of: &v4) { Array($0) }
            return
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, string, &v6) == 1 else { return nil }
        let all = withUnsafeBytes(of: &v6) { Array($0) }
        let isV4Mapped = all[0..<10].allSatisfy { $0 == 0 } && all[10] == 0xff && all[11] == 0xff
        bytes = isV4Mapped ? Array(all[12...]) : all
    }

    var isPrivate: Bool { Self.privateNetworks.contains { $0.contains(self) } }
    var isCloudflare: Bool { Self.cloudflareNetworks.contains { $0.contains(self) } }

    /// Loopback, link-local, private and carrier-grade NAT ranges: never a client as
    /// seen from the internet, so here always a proxy inside Render's network.
    private static let privateNetworks = [
        "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8",
        "169.254.0.0/16", "172.16.0.0/12", "192.168.0.0/16",
        "::/128", "::1/128", "fc00::/7", "fe80::/10",
    ].map(Network.init)

    /// https://www.cloudflare.com/ips/ (October 2026)
    private static let cloudflareNetworks = [
        "173.245.48.0/20", "103.21.244.0/22", "103.22.200.0/22", "103.31.4.0/22",
        "141.101.64.0/18", "108.162.192.0/18", "190.93.240.0/20", "188.114.96.0/20",
        "197.234.240.0/22", "198.41.128.0/17", "162.158.0.0/15", "104.16.0.0/13",
        "104.24.0.0/14", "172.64.0.0/13", "131.0.72.0/22",
        "2400:cb00::/32", "2606:4700::/32", "2803:f800::/32", "2405:b500::/32",
        "2405:8100::/32", "2a06:98c0::/29", "2c0f:f248::/32",
    ].map(Network.init)

    struct Network {
        let prefix: IPAddress
        let length: Int

        /// For the literals above; crashes on a malformed one.
        init(_ cidr: String) {
            let parts = cidr.split(separator: "/")
            prefix = IPAddress(String(parts[0]))!
            length = Int(parts[1])!
        }

        func contains(_ address: IPAddress) -> Bool {
            guard address.bytes.count == prefix.bytes.count else { return false }
            let fullBytes = length / 8
            guard address.bytes[..<fullBytes] == prefix.bytes[..<fullBytes] else { return false }
            let remainingBits = length % 8
            guard remainingBits > 0 else { return true }
            let mask = UInt8(0xff) << (8 - remainingBits)
            return address.bytes[fullBytes] & mask == prefix.bytes[fullBytes] & mask
        }
    }
}
