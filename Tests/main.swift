import Foundation

var failures = 0
func check(_ value: Bool, _ title: String) {
    if value { print("PASS \(title)") } else { print("FAIL \(title)"); failures += 1 }
}
let example = "3 packets transmitted, 2 packets received, 33.3% packet loss\nround-trip min/avg/max/stddev = 12.200/15.500/18.800/3.300 ms"
let ping = PingReport.parse(example)
check(ping.received == 2 && ping.loss == 33.3 && ping.average == 15.5, "partial packet loss retains actual latency")
let failed = PingReport.parse("3 packets transmitted, 0 packets received, 100.0% packet loss")
check(failed.received == 0 && failed.loss == 100 && failed.average == nil, "no ICMP response is not a made-up latency")
check(Policy.validHost("203.0.113.5") && Policy.validHost("example.com") && !Policy.validHost("-c 100") && !Policy.validHost("https://example.com"), "diagnostic host rejects options and URLs")
let pattern = try Policy.processPattern("/Applications/Example+.app")
let regex = try NSRegularExpression(pattern: pattern)
func matches(_ path: String) -> Bool { regex.firstMatch(in: path, range: NSRange(path.startIndex..., in:path)) != nil }
check(matches("/Applications/Example+.app/Contents/Frameworks/Helper") && !matches("/Applications/ExampleX.app/Contents/MacOS/Main") && !matches("/Applications/Example+.app-backup/Contents/MacOS/Main"), "application matching includes helpers but not neighboring bundles")
let base: [String:Any] = ["secret":"test-only", "proxy-providers":["existing":["type":"inline", "payload":[]]], "proxy-groups":[["name":"Codex", "type":"select", "proxies":["DIRECT"]]]]
let enabled = try Policy.config(base, applications:["/Applications/Example+.app"], enabled:true)
let rules = enabled["rules"] as? [String] ?? []
check(rules.last == "MATCH,DIRECT" && rules.contains(where:{$0.hasPrefix("PROCESS-PATH-REGEX,") && $0.hasSuffix(",Codex")}), "only selected applications are routed to the line")
check(enabled["secret"] as? String == "test-only" && enabled["proxy-providers"] != nil, "configuration preserves credentials and providers")
let disabled = try Policy.config(base, applications:["/Applications/Example+.app"], enabled:false)
check((disabled["tun"] as? [String:Any])?["enable"] as? Bool == false && !(disabled["rules"] as? [String] ?? []).contains(where:{$0.hasPrefix("PROCESS-PATH")}), "disabled mode releases system routing and app rules")
do { _ = try Policy.processPattern("/Applications/bad,rule.app"); check(false,"invalid rule path rejected") } catch { check(true,"invalid rule path rejected") }
// Catch a regression where a changed adapter name is shown as the wrong network.
let interfaces = ["en7":"Ethernet", "en3":"IEEE80211", "utun4":"VPN"]
check(Policy.networkKind(primary:"en7",types:interfaces) == "网线" && Policy.networkKind(primary:"en3",types:interfaces) == "Wi-Fi", "network label follows the active physical interface")
check(Policy.networkKind(primary:nil,types:interfaces) == "未连接" && Policy.networkKind(primary:"utun4",types:interfaces) == "其他网络", "missing or unknown interfaces are not mislabeled")
let oldRoute: [String:Any] = ["rules":["MATCH,DIRECT"], "secret":"test-only", "tun":["enable":true],
  "proxies":[["name":"fetch-lan","type":"direct","interface-name":"en5"], ["name":"unrelated","type":"direct","interface-name":"en9"]],
  "proxy-providers":["relay-lxy":["url":"https://relay.example/sub", "filter":"old", "override":["interface-name":"en5","additional-prefix":"LXY-"]],
                     "wired-relay":["url":"https://end.example/sub", "filter":"old", "override":["dialer-proxy":"Wired-Relay"]],
                     "wifi":["url":"https://end.example/sub", "override":["interface-name":"en0"]],
                     "lan":["url":"https://end.example/sub", "override":["interface-name":"en5"]]],
  "proxy-groups":[["name":"Codex","type":"fallback"],["name":"Wired-Relay","type":"fallback"]]]
let adaptive=try Policy.adaptiveConfig(oldRoute)
let providers=adaptive["proxy-providers"] as? [String:[String:Any]] ?? [:]
let groups=adaptive["proxy-groups"] as? [[String:Any]] ?? []
check((providers["relay-lxy"]?["override"] as? [String:Any])?["interface-name"] == nil && (providers["wifi"]?["override"] as? [String:Any])?["interface-name"] == nil, "relay and destination follow the active network")
check(providers["relay-lxy"]?["url"] as? String == "https://relay.example/sub" && providers["wired-relay"]?["url"] as? String == "https://end.example/sub" && adaptive["secret"] as? String == "test-only", "migration retains subscription sources and credentials")
check(groups.contains(where:{$0["name"] as? String == "Codex" && $0["type"] as? String == "select"}) && groups.contains(where:{$0["name"] as? String == "Wired-Relay" && $0["type"] as? String == "select"}), "relay and destination are independently selectable")
check((adaptive["rules"] as? [String]) == ["MATCH,DIRECT"] && (adaptive["tun"] as? [String:Any])?["enable"] as? Bool == true, "migration preserves existing app routing")
let excluded=providers["relay-lxy"]?["exclude-filter"] as? String ?? ""
let filter=try NSRegularExpression(pattern:excluded)
func isExcluded(_ name:String) -> Bool { filter.firstMatch(in:name,range:NSRange(name.startIndex...,in:name)) != nil }
check(isExcluded("剩余流量：500 GB") && !isExcluded("🇭🇰香港高速01|BGP|CMCU"), "subscription notices are not treated as relay nodes")
check(Policy.validSubscriptionURL("https://example.com/sub?token=private") && !Policy.validSubscriptionURL("http://example.com/sub") && !Policy.validSubscriptionURL("https://") && !Policy.validSubscriptionURL("https://example.com/\nheader"), "subscription updates require a valid HTTPS URL")
exit(failures == 0 ? 0 : 1)
