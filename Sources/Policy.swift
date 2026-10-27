import Foundation

struct PingReport {
    var received: Int = 0
    var loss: Double = 100
    var average: Double? = nil
    static func parse(_ output: String) -> PingReport {
        func capture(_ expression: String, _ group: Int = 1) -> String? {
            guard let regex = try? NSRegularExpression(pattern: expression),
                  let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in:output)),
                  let range = Range(match.range(at: group), in: output) else { return nil }
            return String(output[range])
        }
        return PingReport(received: Int(capture("(\\d+) packets received") ?? "0") ?? 0,
                          loss: Double(capture("([\\d.]+)% packet loss") ?? "100") ?? 100,
                          average: capture("= [\\d.]+/([\\d.]+)/").flatMap(Double.init))
    }
}

struct LineError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum Policy {
    static func validSubscriptionURL(_ value: String) -> Bool {
        guard value.rangeOfCharacter(from:.controlCharacters) == nil,
              let url = URLComponents(string:value), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return false }
        return true
    }
    static func networkKind(primary: String?, types: [String:String]) -> String {
        guard let primary, !primary.isEmpty else { return "未连接" }
        switch types[primary] { case "IEEE80211": return "Wi-Fi"; case "Ethernet": return "网线"; default: return "其他网络" }
    }
    static func adaptiveConfig(_ base: [String:Any]) throws -> [String:Any] {
        var result = base
        guard var providers = result["proxy-providers"] as? [String:[String:Any]],
              providers["relay-lxy"] != nil, providers["wired-relay"] != nil,
              let originalGroups = result["proxy-groups"] as? [[String:Any]] else {
            throw LineError("缺少现有的中转或目的地订阅，原线路保持不变。")
        }
        for name in ["lan","wifi","relay-lxy"] where providers[name] != nil {
            var provider = providers[name]!
            var override = provider["override"] as? [String:Any] ?? [:]
            override.removeValue(forKey:"interface-name")
            provider["override"] = override
            providers[name] = provider
        }
        providers["relay-lxy"]?.removeValue(forKey:"filter")
        providers["wired-relay"]?.removeValue(forKey:"filter")
        if var relay=providers["relay-lxy"] {
            let information="剩余流量|距离下次重置|套餐到期|订阅到期|官网地址"
            let previous=relay["exclude-filter"] as? String ?? ""
            if !previous.contains(information) { relay["exclude-filter"] = previous.isEmpty ? information : "(?:\(previous))|(?:\(information))" }
            var health=relay["health-check"] as? [String:Any] ?? [:]
            health["interval"] = 300; health["lazy"] = true
            relay["health-check"] = health
            providers["relay-lxy"] = relay
        }
        result["proxy-providers"] = providers
        if var nodes = result["proxies"] as? [[String:Any]] {
            for index in nodes.indices where ["fetch-lan","fetch-wifi"].contains(nodes[index]["name"] as? String ?? "") {
                nodes[index].removeValue(forKey:"interface-name")
            }
            result["proxies"] = nodes
        }
        var groups = originalGroups.filter{!["Codex","Wired-Relay","Auto-Destination","Auto-Relay"].contains($0["name"] as? String ?? "")}
        groups += [
            ["name":"Codex","type":"select","proxies":["Auto-Destination"],"use":["wired-relay"]],
            ["name":"Auto-Destination","type":"fallback","url":"https://www.gstatic.com/generate_204","interval":30,"use":["wired-relay"]],
            ["name":"Wired-Relay","type":"select","proxies":["Auto-Relay"],"use":["relay-lxy"]],
            ["name":"Auto-Relay","type":"fallback","url":"https://www.gstatic.com/generate_204","interval":30,"use":["relay-lxy"]]
        ]
        result["proxy-groups"] = groups
        var profile = result["profile"] as? [String:Any] ?? [:]
        profile["store-selected"] = true
        result["profile"] = profile
        return result
    }
    static func validHost(_ host: String) -> Bool {
        !host.isEmpty && host.count <= 253 && host.range(of: "^[A-Za-z0-9][A-Za-z0-9.:-]*$", options:.regularExpression) != nil
    }
    static func processPattern(_ path: String) throws -> String {
        guard path.hasPrefix("/"), path.hasSuffix(".app"), !path.contains(","),
              !path.contains("\n"), !path.contains("\r") else { throw LineError("应用路径不适合生成分流规则，请把应用放到不含逗号的文件夹。") }
        return "^" + NSRegularExpression.escapedPattern(for: path) + "/"
    }
    static func config(_ base: [String: Any], applications: [String], enabled: Bool) throws -> [String: Any] {
        var result = base
        result["mode"] = "rule"
        result["find-process-mode"] = "always"
        result["ipv6"] = true
        result["allow-lan"] = false
        result["bind-address"] = "127.0.0.1"
        result["listeners"] = [["name":"line-health", "type":"mixed", "listen":"127.0.0.1", "port":18798, "udp":false]]
        var rules = ["IN-NAME,line-health,Codex"]
        for block in ["127.0.0.0/8","10.0.0.0/8","172.16.0.0/12","192.168.0.0/16","169.254.0.0/16","224.0.0.0/4"] {
            rules.append("IP-CIDR,\(block),DIRECT,no-resolve")
        }
        rules += ["IP-CIDR6,::1/128,DIRECT,no-resolve", "IP-CIDR6,fc00::/7,DIRECT,no-resolve", "IP-CIDR6,fe80::/10,DIRECT,no-resolve"]
        if enabled {
            for path in Set(applications).sorted() { rules.append("PROCESS-PATH-REGEX,\(try processPattern(path)),Codex") }
        }
        rules.append("MATCH,DIRECT")
        result["rules"] = rules
        result["tun"] = ["enable":enabled, "stack":"mixed", "auto-route":true,
                         "auto-detect-interface":true, "dns-mode":"native", "dns-hijack":["any:53","tcp://any:53"],
                         "strict-route":false, "mtu":1500, "inet6-address":["fdfe:dcba:9876::1/126"]]
        result["dns"] = ["enable":true, "listen":"127.0.0.1:1053", "ipv6":false, "enhanced-mode":"fake-ip",
                         "fake-ip-range":"198.18.0.1/16", "fake-ip-filter":["*.local","*.lan","localhost"],
                         "default-nameserver":["223.5.5.5","119.29.29.29"],
                         "nameserver":["https://dns.alidns.com/dns-query","https://doh.pub/dns-query"],
                         "proxy-server-nameserver":["https://dns.alidns.com/dns-query"]]
        return result
    }
}
