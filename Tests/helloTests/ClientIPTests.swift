@testable import hello
import Testing

@Suite("Client IP")
struct ClientIPTests {
    private func resolve(_ forwardedFor: [String], cf: String? = nil, remote: String? = "10.1.2.3") -> String {
        ClientIP.resolve(forwardedFor: forwardedFor, cfConnectingIP: cf, remoteAddress: remote)
    }

    @Test("Without proxy headers the socket address is the client")
    func direct() {
        #expect(resolve([], remote: "198.51.100.4") == "198.51.100.4")
    }

    @Test("Entries the client wrote in front of the proxies' are ignored")
    func forgedEntriesIgnored() {
        #expect(resolve(["1.2.3.4, 203.0.113.9"]) == "203.0.113.9")
        #expect(resolve(["1.2.3.4", "203.0.113.9, 10.0.0.2"]) == "203.0.113.9")
        #expect(resolve(["not-an-ip, 203.0.113.9"]) == "203.0.113.9")
    }

    @Test("Through Cloudflare, CF-Connecting-IP is the client")
    func throughCloudflare() {
        #expect(resolve(["1.2.3.4, 203.0.113.9, 172.70.1.1, 10.0.0.2"], cf: "203.0.113.9") == "203.0.113.9")
        // A WARP user's own address is in Cloudflare's ranges too.
        #expect(resolve(["1.2.3.4, 104.28.5.6, 172.70.1.1"], cf: "104.28.5.6") == "104.28.5.6")
        #expect(resolve(["1.2.3.4, 203.0.113.9, 162.158.3.4"]) == "203.0.113.9")
    }

    @Test("CF-Connecting-IP is ignored when the request did not come through Cloudflare")
    func forgedCloudflareHeaderIgnored() {
        #expect(resolve(["203.0.113.9"], cf: "1.2.3.4") == "203.0.113.9")
        #expect(resolve(["203.0.113.9, 172.70.1.1"], cf: "garbage") == "203.0.113.9")
    }

    @Test("IPv6 and IPv4-mapped addresses")
    func ipv6() {
        #expect(resolve(["1.2.3.4, 2001:db8::7, 2606:4700::1"], cf: "2001:db8::7") == "2001:db8::7")
        #expect(resolve(["203.0.113.9, ::ffff:10.0.0.1"]) == "203.0.113.9")
        #expect(resolve(["2001:db8::7, fd00::1"]) == "2001:db8::7")
    }

    @Test("Only private addresses: the request came from inside the network")
    func allPrivate() {
        #expect(resolve(["10.0.0.5, 10.0.0.2"]) == "10.0.0.5")
    }

    @Test("Network ranges match by prefix bits")
    func networks() {
        let cloudflare = IPAddress.Network("104.16.0.0/13")
        #expect(cloudflare.contains(IPAddress("104.23.255.255")!))
        #expect(!cloudflare.contains(IPAddress("104.24.0.0")!))
        #expect(!cloudflare.contains(IPAddress("2606:4700::1")!))
        #expect(IPAddress("2a06:98c7::1")?.isCloudflare == true)
        #expect(IPAddress("2a06:98c8::1")?.isCloudflare == false)
        #expect(IPAddress("172.31.255.1")?.isPrivate == true)
        #expect(IPAddress("172.32.0.1")?.isPrivate == false)
        #expect(IPAddress("300.1.1.1") == nil)
    }
}
