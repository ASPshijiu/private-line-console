import Foundation
import AppKit
import Darwin
import SystemConfiguration

struct CommandResult { let code: Int32; let output: String }

enum Command {
    static func run(_ executable: String, _ arguments: [String], input: Data? = nil, timeout: TimeInterval = 20) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        for key in ["HTTP_PROXY","HTTPS_PROXY","ALL_PROXY","http_proxy","https_proxy","all_proxy"] { environment.removeValue(forKey: key) }
        environment["LC_ALL"] = "C"
        process.environment = environment
        let output = Pipe(), incoming = Pipe()
        process.standardOutput = output; process.standardError = output
        process.standardInput = incoming
        try process.run()
        if let input { incoming.fileHandleForWriting.write(input) }
        try? incoming.fileHandleForWriting.close()
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler {
            if process.isRunning {
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline:.now()+2) { if process.isRunning { kill(process.processIdentifier,SIGKILL) } }
            }
        }
        timer.resume()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit(); timer.cancel()
        return CommandResult(code: process.terminationStatus, output: String(decoding:data, as:UTF8.self))
    }
}

struct ApplicationItem: Identifiable, Hashable {
    var id: String { path }
    let name: String
    let path: String
    let bundleID: String
}

struct LinePreferences: Codable {
    var selected: [String] = ["/Applications/ChatGPT.app", "/Applications/Telegram.app"]
    var enabled: Bool = true
    var customApplications: [String]? = nil
}

struct ConnectionInfo: Identifiable {
    let id: String
    let path: String
    let process: String
    let destination: String
    let viaLine: Bool
    let bytes: Double
}

struct Snapshot {
    var online = false
    var managed = false
    var tun = false
    var route = "等待连接"
    var relay = ""
    var relayChoice = ""
    var destinationChoice = ""
    var relayOptions: [String] = []
    var destinationOptions: [String] = []
    var adaptive = false
    var network = NetworkStatus()
    var connections: [ConnectionInfo] = []
    var delays: [(String, Int, Bool)] = []
    var version = ""
    var message = ""
}

struct NetworkStatus {
    var interface: String? = nil
    var kind: String = "未连接"
}

struct CheckResult: Identifiable {
    let id: String
    let title: String
    let value: String
    let detail: String
    let state: String
}

final class LineService {
    static let label = "local.private-line.core"
    let base: URL
    let file: URL
    let preferencesFile: URL
    var corePath: String { FileManager.default.fileExists(atPath:"/Library/PrivilegedHelperTools/local.private-line.mihomo") ? "/Library/PrivilegedHelperTools/local.private-line.mihomo" : base.appendingPathComponent("mihomo").path }
    var managed: Bool { FileManager.default.fileExists(atPath:"/Library/LaunchDaemons/\(Self.label).plist") }

    init(base: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Codex Private Proxy")) {
        self.base = base; file = base.appendingPathComponent("config.yaml")
        preferencesFile = base.appendingPathComponent("control-preferences.json")
    }
    func readConfig() throws -> [String:Any] {
        let data = try Data(contentsOf:file)
        guard let value = try JSONSerialization.jsonObject(with:data) as? [String:Any] else { throw LineError("配置格式无法读取。") }
        return value
    }
    func preferences() -> LinePreferences {
        guard let data = try? Data(contentsOf:preferencesFile), let value = try? JSONDecoder().decode(LinePreferences.self, from:data) else { return LinePreferences() }
        return value
    }
    func savePreferences(_ value: LinePreferences) throws { try privateWrite(JSONEncoder().encode(value), to:preferencesFile) }
    func privateWrite(_ data: Data, to url: URL) throws {
        try data.write(to:url, options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600], ofItemAtPath:url.path)
    }
    func networkStatus() -> NetworkStatus {
        let ipv4 = SCDynamicStoreCopyValue(nil,"State:/Network/Global/IPv4" as CFString) as? [String:Any] ?? [:]
        let ipv6 = SCDynamicStoreCopyValue(nil,"State:/Network/Global/IPv6" as CFString) as? [String:Any] ?? [:]
        let primary = ipv4["PrimaryInterface"] as? String ?? ipv6["PrimaryInterface"] as? String
        var types:[String:String] = [:]
        for item in SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? [] {
            if let name = SCNetworkInterfaceGetBSDName(item) as String?, let type = SCNetworkInterfaceGetInterfaceType(item) as String? { types[name] = type }
        }
        return NetworkStatus(interface:primary,kind:Policy.networkKind(primary:primary,types:types))
    }
    func api(_ path: String, method: String = "GET", body: [String:Any]? = nil, limit: Int = 10) throws -> Any {
        let config = try readConfig()
        guard let socket = config["external-controller-unix"] as? String, let secret = config["secret"] as? String else { throw LineError("控制连接缺少配置。") }
        return try coreAPI(socket:socket,secret:secret,path:path,method:method,body:body,limit:limit)
    }
    func coreAPI(socket: String, secret: String, path: String, method: String = "GET", body: [String:Any]? = nil, limit: Int = 10) throws -> Any {
        func quote(_ value:String) -> String { "\"" + value.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"\"",with:"\\\"").replacingOccurrences(of:"\n",with:"\\n") + "\"" }
        let auth = "header = \(quote("Authorization: Bearer " + secret))\n"
        var args = ["--config","-","--noproxy","*","--silent","--show-error","--unix-socket",socket,"--max-time",String(limit),"--request",method,"--write-out","\n%{http_code}","http://localhost" + path]
        if let body {
            args += ["--header","Content-Type: application/json","--data-binary",String(decoding:try JSONSerialization.data(withJSONObject:body),as:UTF8.self)]
        }
        let response = try Command.run("/usr/bin/curl",args,input:Data(auth.utf8),timeout:TimeInterval(limit + 3))
        guard response.code == 0, let split = response.output.lastIndex(of:"\n"), let status = Int(response.output[response.output.index(after:split)...]), (200..<300).contains(status) else { throw LineError("后台服务暂时不可用，或本次请求未成功。") }
        let content = Data(response.output[..<split].utf8)
        return content.isEmpty ? [:] : try JSONSerialization.jsonObject(with:content)
    }
    func snapshot() -> Snapshot {
        var result = Snapshot(); result.managed = managed; result.network = networkStatus()
        do {
            let version = try api("/version") as? [String:Any] ?? [:]
            result.version = version["version"] as? String ?? ""
            result.online = true
            let configuration = try api("/configs") as? [String:Any] ?? [:]
            result.tun = (configuration["tun"] as? [String:Any])?["enable"] as? Bool ?? false
            let route = try api("/proxies/Codex") as? [String:Any] ?? [:]
            result.destinationChoice = route["now"] as? String ?? ""
            result.destinationOptions = route["all"] as? [String] ?? []
            result.route = result.destinationChoice.isEmpty ? "未选择" : result.destinationChoice
            let relay = try? api("/proxies/Wired-Relay") as? [String:Any]
            result.relayChoice = relay?["now"] as? String ?? ""
            result.relayOptions = relay?["all"] as? [String] ?? []
            result.relay = result.relayChoice
            result.adaptive = (route["type"] as? String == "Selector") && (relay?["type"] as? String == "Selector")
            if result.destinationChoice == "Auto-Destination", let nested = try? api("/proxies/Auto-Destination") as? [String:Any] { result.route = nested["now"] as? String ?? result.route }
            if result.relayChoice == "Auto-Relay", let nested = try? api("/proxies/Auto-Relay") as? [String:Any] { result.relay = nested["now"] as? String ?? result.relay }
            let connections = try api("/connections") as? [String:Any] ?? [:]
            result.connections = (connections["connections"] as? [[String:Any]] ?? []).map { item in
                let metadata = item["metadata"] as? [String:Any] ?? [:]
                let chains = item["chains"] as? [String] ?? []
                return ConnectionInfo(id:item["id"] as? String ?? UUID().uuidString,
                                      path:metadata["processPath"] as? String ?? "", process:metadata["process"] as? String ?? "",
                                      destination:(metadata["host"] as? String).flatMap{$0.isEmpty ? nil : $0} ?? metadata["destinationIP"] as? String ?? "",
                                      viaLine:chains.contains("Codex"), bytes:(item["upload"] as? Double ?? 0)+(item["download"] as? Double ?? 0))
            }
            let providers = try api("/providers/proxies") as? [String:Any] ?? [:]
            for name in (result.adaptive ? ["wired-relay","relay-lxy"] : ["lan","wired-relay","wifi"]) {
                let item = (providers["providers"] as? [String:[String:Any]])?[name] ?? [:]
                for node in item["proxies"] as? [[String:Any]] ?? [] {
                    let last = (node["history"] as? [[String:Any]])?.last
                    result.delays.append((node["name"] as? String ?? name,last?["delay"] as? Int ?? 0,node["alive"] as? Bool ?? false))
                }
            }
        } catch { result.message = error.localizedDescription }
        return result
    }
    func validate(_ config: [String:Any]) throws -> Data {
        let data = try JSONSerialization.data(withJSONObject:config,options:[.prettyPrinted,.sortedKeys,.withoutEscapingSlashes])
        let temporary = base.appendingPathComponent("validate-\(UUID().uuidString).json")
        try privateWrite(data,to:temporary)
        defer { try? FileManager.default.removeItem(at:temporary) }
        let response = try Command.run(corePath,["-t","-d",base.path,"-f",temporary.path],timeout:12)
        guard response.code == 0 else { throw LineError("新配置未通过内核检查，原配置已保留。") }
        return data
    }
    func selectRoutes(relay: String, destination: String) throws {
        let before = snapshot()
        guard before.adaptive, before.relayOptions.contains(relay), before.destinationOptions.contains(destination) else { throw LineError("节点列表已变化，请刷新后再试。") }
        do {
            _ = try api("/proxies/Wired-Relay",method:"PUT",body:["name":relay])
            _ = try api("/proxies/Codex",method:"PUT",body:["name":destination])
            // Recreate the outbound proxies when the relay changes; TUIC can otherwise reuse its old tunnel.
            if relay != before.relayChoice { _ = try api("/configs?force=false",method:"PUT",body:["path":file.path]) }
            let after = snapshot()
            guard after.relayChoice == relay, after.destinationChoice == destination else { throw LineError("线路选择未能保存。") }
            guard lineCheck().state == "good" else { throw LineError("选中的中转和目的地未通过连接检测。") }
        } catch {
            let failure=error
            do {
                _ = try api("/proxies/Wired-Relay",method:"PUT",body:["name":before.relayChoice])
                _ = try api("/proxies/Codex",method:"PUT",body:["name":before.destinationChoice])
                if relay != before.relayChoice { _ = try api("/configs?force=false",method:"PUT",body:["path":file.path]) }
                let restored=snapshot()
                guard restored.relayChoice == before.relayChoice, restored.destinationChoice == before.destinationChoice else { throw LineError("选择未恢复") }
            } catch { throw LineError("线路切换失败，自动恢复也未完成，请检查控制台状态。") }
            throw LineError("\(failure.localizedDescription) 已恢复原线路。")
        }
    }
    func migrateAdaptive() throws {
        let before = snapshot()
        guard before.online && managed else { throw LineError("后台服务未运行，无法更新线路。") }
        let oldData = try Data(contentsOf:file)
        let oldConfig = try readConfig()
        let data = try validate(Policy.adaptiveConfig(oldConfig))
        let backup = base.appendingPathComponent("config.before-adaptive-line.yaml")
        if !FileManager.default.fileExists(atPath:backup.path) { try privateWrite(oldData,to:backup) }
        try privateWrite(data,to:file)
        do {
            _ = try api("/configs?force=false",method:"PUT",body:["path":file.path])
            let migrated = snapshot()
            guard migrated.adaptive else { throw LineError("线路选择器未启动。") }
            let suffix = before.route.replacingOccurrences(of:"^(LAN-Relay-|WiFi-|LAN-)",with:"",options:.regularExpression)
            let equivalent = "LAN-Relay-" + suffix
            let destination = before.adaptive && migrated.destinationOptions.contains(before.destinationChoice) ? before.destinationChoice : (migrated.destinationOptions.contains(equivalent) ? equivalent : "Auto-Destination")
            let relay = before.adaptive && migrated.relayOptions.contains(before.relayChoice) ? before.relayChoice : "Auto-Relay"
            try selectRoutes(relay:relay,destination:destination)
            guard exitCheck().state == "good" else { throw LineError("更新后无法验证出口。") }
        } catch {
            let failure=error
            do {
                try privateWrite(oldData,to:file)
                _ = try api("/configs?force=false",method:"PUT",body:["path":file.path])
                guard snapshot().adaptive == before.adaptive else { throw LineError("旧配置未恢复") }
            } catch { throw LineError("新线路更新失败，自动恢复也未完成，请检查控制台状态。") }
            throw LineError("新线路验证失败，已恢复原配置。\(failure.localizedDescription)")
        }
    }
    func downloadSubscription(_ address: String, to file: URL) throws {
        guard Policy.validSubscriptionURL(address) else { throw LineError("订阅链接必须是有效的 HTTPS 地址。") }
        let escaped = address.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"\"",with:"\\\"")
        let response = try Command.run("/usr/bin/curl",["--config","-","--proxy","http://127.0.0.1:18798","--noproxy","", "--proto","=https","--proto-redir","=https","--connect-timeout","6","--max-time","25","--max-filesize","10485760","--silent","--show-error","--fail","--location","--output",file.path],input:Data("url = \"\(escaped)\"\n".utf8),timeout:28)
        guard response.code == 0, let size = (try? file.resourceValues(forKeys:[.fileSizeKey]))?.fileSize, size > 0, size <= 10485760 else { throw LineError("订阅下载失败，请检查链接和当前网络。") }
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
    }
    func previewSubscriptions(_ incoming: [String:URL], folder: URL, previous: Snapshot) throws -> (String,String) {
        let manager = FileManager.default
        let caches = base.appendingPathComponent("providers")
        if manager.fileExists(atPath:caches.path) { try manager.copyItem(at:caches,to:folder.appendingPathComponent("providers")) }
        var config = try Policy.adaptiveConfig(readConfig())
        guard var providers = config["proxy-providers"] as? [String:[String:Any]] else { throw LineError("订阅配置不可用。") }
        for (name,url) in incoming {
            guard var item = providers[name] else { throw LineError("订阅配置不可用。") }
            item["type"] = "file"; item["path"] = url.path
            item.removeValue(forKey:"url"); item.removeValue(forKey:"proxy")
            providers[name] = item
        }
        config["proxy-providers"] = providers
        config["tun"] = ["enable":false]; config["dns"] = ["enable":false]
        config["mixed-port"] = 0; config["listeners"] = []
        config["rules"] = ["MATCH,Codex"]
        config["external-controller"] = ""
        let socket = folder.appendingPathComponent("controller.sock").path
        let secret = UUID().uuidString
        config["external-controller-unix"] = socket; config["secret"] = secret
        let configFile = folder.appendingPathComponent("preview.json")
        try privateWrite(JSONSerialization.data(withJSONObject:config,options:[.withoutEscapingSlashes]),to:configFile)
        let process = Process(); process.executableURL=URL(fileURLWithPath:corePath)
        process.arguments=["-d",folder.path,"-f",configFile.path]
        process.standardOutput=FileHandle.nullDevice; process.standardError=FileHandle.nullDevice
        var environment=ProcessInfo.processInfo.environment
        for key in ["HTTP_PROXY","HTTPS_PROXY","ALL_PROXY","http_proxy","https_proxy","all_proxy"] { environment.removeValue(forKey:key) }
        process.environment=environment
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        var ready=false
        for _ in 0..<80 {
            if !process.isRunning { break }
            if (try? coreAPI(socket:socket,secret:secret,path:"/version",limit:1)) != nil { ready=true; break }
            Thread.sleep(forTimeInterval:0.1)
        }
        guard ready else { throw LineError("订阅格式无法被代理内核读取，请检查链接内容。") }
        let relayGroup = try coreAPI(socket:socket,secret:secret,path:"/proxies/Wired-Relay") as? [String:Any] ?? [:]
        let destinationGroup = try coreAPI(socket:socket,secret:secret,path:"/proxies/Codex") as? [String:Any] ?? [:]
        let relayEntries = (relayGroup["all"] as? [String] ?? []).filter{$0 != "Auto-Relay"}
        let usefulRelays = relayEntries.filter { name in !["剩余流量","距离下次重置","套餐到期","订阅到期","官网地址"].contains(where:name.contains) }
        let relays = usefulRelays.isEmpty ? relayEntries : usefulRelays
        let destinations = (destinationGroup["all"] as? [String] ?? []).filter{$0 != "Auto-Destination"}
        guard !relays.isEmpty, !destinations.isEmpty else { throw LineError("订阅里没有可用的中转或目的地节点。") }
        func firstChoices(_ values:[String], _ preferred:String, _ limit:Int) -> [String] {
            var items=values
            if let index=items.firstIndex(of:preferred) { items.remove(at:index); items.insert(preferred,at:0) }
            return Array(items.prefix(limit))
        }
        let deadline=Date().addingTimeInterval(35)
        for relay in firstChoices(relays,previous.relay == "" ? previous.relayChoice : previous.relay,3) {
            _ = try coreAPI(socket:socket,secret:secret,path:"/proxies/Wired-Relay",method:"PUT",body:["name":relay])
            _ = try coreAPI(socket:socket,secret:secret,path:"/configs?force=false",method:"PUT",body:["path":configFile.path])
            let applied = try coreAPI(socket:socket,secret:secret,path:"/proxies/Wired-Relay") as? [String:Any] ?? [:]
            guard applied["now"] as? String == relay else { throw LineError("无法验证所选中转节点。") }
            for destination in firstChoices(destinations,previous.route,4) {
                if Date() > deadline { break }
                _ = try coreAPI(socket:socket,secret:secret,path:"/proxies/Codex",method:"PUT",body:["name":destination])
                let delay = try? coreAPI(socket:socket,secret:secret,path:"/proxies/Codex/delay?timeout=4000&url=https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204",limit:6) as? [String:Any]
                if let value=delay?["delay"] as? Int, value > 0 { return (relay,destination) }
            }
        }
        throw LineError("订阅已下载，但中转和目的地没有通过连接检测，原线路保持不变。")
    }
    func updateSubscriptions(relay: String, destination: String) throws {
        let relay = relay.trimmingCharacters(in:.whitespacesAndNewlines)
        let destination = destination.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !relay.isEmpty || !destination.isEmpty else { throw LineError("请先填写要更换的订阅链接。") }
        for value in [relay,destination] where !value.isEmpty {
            guard Policy.validSubscriptionURL(value) else { throw LineError("订阅链接必须是有效的 HTTPS 地址。") }
        }
        let before=snapshot()
        guard before.adaptive else { throw LineError("请先启用线路选择功能。") }
        let manager=FileManager.default
        let folder=URL(fileURLWithPath:"/tmp",isDirectory:true).appendingPathComponent("pl-" + String(UUID().uuidString.prefix(8)),isDirectory:true)
        try manager.createDirectory(at:folder,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        defer { try? manager.removeItem(at:folder) }
        var incoming:[String:URL] = [:]
        if !relay.isEmpty { let file=folder.appendingPathComponent("relay.yaml"); try downloadSubscription(relay,to:file); incoming["relay-lxy"]=file }
        if !destination.isEmpty { let file=folder.appendingPathComponent("destination.yaml"); try downloadSubscription(destination,to:file); incoming["wired-relay"]=file }
        let selected=try previewSubscriptions(incoming,folder:folder,previous:before)
        let oldData=try Data(contentsOf:file)
        var config=try readConfig()
        guard var providers=config["proxy-providers"] as? [String:[String:Any]] else { throw LineError("订阅配置不可用。") }
        var updates:[URL:Data] = [:], oldCaches:[URL:Data] = [:]
        for (name,newURL,source) in [("relay-lxy",relay,incoming["relay-lxy"]),("lan",destination,incoming["wired-relay"]),("wifi",destination,incoming["wired-relay"]),("wired-relay",destination,incoming["wired-relay"])] where !newURL.isEmpty {
            guard var item=providers[name], let path=item["path"] as? String, let source else { throw LineError("订阅配置不可用。") }
            item["url"]=newURL; providers[name]=item
            let cache=URL(fileURLWithPath:path,relativeTo:base).standardizedFileURL
            guard cache.path.hasPrefix(base.appendingPathComponent("providers").path + "/") else { throw LineError("订阅缓存位置无效。") }
            if manager.fileExists(atPath:cache.path) { oldCaches[cache]=try Data(contentsOf:cache) }
            updates[cache]=try Data(contentsOf:source)
        }
        config["proxy-providers"]=providers
        let next=try validate(config)
        do {
            for (cache,data) in updates { try privateWrite(data,to:cache) }
            try privateWrite(next,to:file)
            _ = try api("/configs?force=false",method:"PUT",body:["path":file.path])
            try selectRoutes(relay:selected.0,destination:selected.1)
        } catch {
            do {
                for (cache,_) in updates {
                    if let data=oldCaches[cache] { try privateWrite(data,to:cache) }
                    else if manager.fileExists(atPath:cache.path) { try manager.removeItem(at:cache) }
                }
                try privateWrite(oldData,to:file)
                _ = try api("/configs?force=false",method:"PUT",body:["path":file.path])
                _ = try api("/proxies/Wired-Relay",method:"PUT",body:["name":before.relayChoice])
                _ = try api("/proxies/Codex",method:"PUT",body:["name":before.destinationChoice])
                _ = try api("/configs?force=false",method:"PUT",body:["path":file.path])
                let restored=snapshot()
                guard restored.relayChoice == before.relayChoice, restored.destinationChoice == before.destinationChoice else { throw LineError("选择未恢复") }
            } catch { throw LineError("更新失败，自动恢复也未完成，请检查控制台状态。") }
            throw LineError("更新未完成，已恢复原订阅和线路。")
        }
    }
    func apply(_ preferences: LinePreferences, reconnectPaths: [String] = []) throws {
        if !managed { try savePreferences(preferences); return }
        let oldData = try Data(contentsOf:file), oldConfig = try readConfig()
        let config = try Policy.config(oldConfig,applications:preferences.selected,enabled:preferences.enabled)
        let data = try validate(config)
        let before = snapshot()
        try privateWrite(data,to:file)
        do {
            _ = try api("/configs?force=\(before.tun == preferences.enabled ? "false" : "true")",method:"PUT",body:["path":file.path])
            let applied = try api("/configs") as? [String:Any] ?? [:]
            guard ((applied["tun"] as? [String:Any])?["enable"] as? Bool ?? false) == preferences.enabled else { throw LineError("系统接管状态未生效，已恢复旧设置。") }
            try savePreferences(preferences)
            for connection in before.connections where reconnectPaths.contains(where:{connection.path.hasPrefix($0 + "/")}) {
                _ = try? api("/connections/" + connection.id,method:"DELETE")
            }
        } catch {
            try? privateWrite(oldData,to:file)
            _ = try? api("/configs?force=true",method:"PUT",body:["path":file.path])
            throw error
        }
    }
    func install(_ preferences: LinePreferences) throws {
        let old = try Data(contentsOf:file)
        let backup = base.appendingPathComponent("config.before-control-app.yaml")
        if !FileManager.default.fileExists(atPath:backup.path) { try privateWrite(old,to:backup) }
        try privateWrite(old,to:base.appendingPathComponent("config.activation-backup.yaml"))
        let next = try Policy.adaptiveConfig(Policy.config(readConfig(),applications:preferences.selected,enabled:preferences.enabled))
        let data = try validate(next)
        guard let script = Bundle.main.url(forResource:"install-helper",withExtension:"sh"), let core = Bundle.main.url(forResource:"mihomo",withExtension:nil) else { throw LineError("应用缺少安装文件，请重新构建。") }
        try privateWrite(data,to:file)
        do {
            let command = ["/bin/bash",script.path,"install",FileManager.default.homeDirectoryForCurrentUser.path,String(getuid()),core.path].map(shellQuote).joined(separator:" ")
            let appleScript = "do shell script " + appleQuote(command) + " with administrator privileges with prompt \"专线控制台需要安装网络服务，以便只让勾选的应用走专线。\""
            let response = try Command.run("/usr/bin/osascript",["-e",appleScript],timeout:180)
            guard response.code == 0 else { throw LineError(response.output.contains("-128") ? "已取消管理员授权，原线路保持不变。" : "网络服务安装未完成，已恢复原配置。") }
            guard snapshot().tun else { throw LineError("后台服务已安装，但系统接管未启动。可再次点击启用或恢复原配置。") }
            try savePreferences(preferences)
        } catch {
            try? privateWrite(old,to:file)
            _ = try? api("/configs?force=true",method:"PUT",body:["path":file.path])
            throw error
        }
    }
    func restore() throws {
        guard let script = Bundle.main.url(forResource:"install-helper",withExtension:"sh") else { throw LineError("找不到恢复工具。") }
        let command = ["/bin/bash",script.path,"restore",FileManager.default.homeDirectoryForCurrentUser.path,String(getuid())].map(shellQuote).joined(separator:" ")
        let result = try Command.run("/usr/bin/osascript",["-e","do shell script " + appleQuote(command) + " with administrator privileges with prompt \"恢复安装控制台之前的独立代理服务。\""],timeout:180)
        guard result.code == 0 else { throw LineError("恢复操作未完成或已取消。") }
    }
    func shellQuote(_ value:String) -> String { "'" + value.replacingOccurrences(of:"'",with:"'\\''") + "'" }
    func appleQuote(_ value:String) -> String { "\"" + value.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"\"",with:"\\\"") + "\"" }
    func discoverApplications() -> [ApplicationItem] {
        var found:[ApplicationItem] = []
        func append(_ url:URL) {
            guard let bundle = Bundle(url:url), let id = bundle.bundleIdentifier, id != "local.private-line.control" else { return }
            let name = id == "com.openai.codex" ? "Codex" : (bundle.object(forInfoDictionaryKey:"CFBundleDisplayName") as? String ?? bundle.object(forInfoDictionaryKey:"CFBundleName") as? String ?? url.deletingPathExtension().lastPathComponent)
            found.append(ApplicationItem(name:name,path:url.path,bundleID:id))
        }
        for root in [URL(fileURLWithPath:"/Applications"),FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),URL(fileURLWithPath:"/System/Applications")] {
            guard let enumerator = FileManager.default.enumerator(at:root,includingPropertiesForKeys:[.isDirectoryKey],options:[.skipsHiddenFiles,.skipsPackageDescendants]) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "app" {
                append(url)
            }
        }
        let saved = preferences()
        for path in Set((saved.customApplications ?? []) + saved.selected) {
            append(URL(fileURLWithPath:path))
        }
        return Array(Set(found)).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    func ping(_ host: String, interface: String?, title:String) -> CheckResult {
        guard Policy.validHost(host) else { return CheckResult(id:"ping",title:title,value:"地址无效",detail:"填写 IP 或域名，不含 https://。",state:"bad") }
        guard let interface else { return CheckResult(id:"ping",title:title,value:"网络未连接",detail:"没有检测到当前网络接口。",state:"warn") }
        do {
            let response = try Command.run("/sbin/ping",["-n","-b",interface,"-c","3","-i","0.3","-W","1000","-t","5",host],timeout:7)
            guard response.output.contains("packets transmitted") else { throw LineError("Ping 未能启动") }
            let parsed = PingReport.parse(response.output)
            let value = parsed.average.map{String(format:"%.0f ms",$0)} ?? "未收到回应"
            return CheckResult(id:"ping",title:title,value:value,detail:parsed.received > 0 ? "丢包率 \(String(format:"%.0f",parsed.loss))% · 3 次采样 · \(interface)" : "ICMP 无回应；请结合下面的代理检测判断。",state:parsed.received == 0 ? "warn" : parsed.loss > 0 ? "warn" : "good")
        } catch { return CheckResult(id:"ping",title:title,value:"检测失败",detail:"网卡不可用或检测超时。",state:"warn") }
    }
    func lineCheck() -> CheckResult {
        do {
            let data = try api("/proxies/Codex/delay?timeout=8000&url=https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204",limit:10) as? [String:Any] ?? [:]
            guard let delay = data["delay"] as? Int, delay > 0 else { throw LineError("无法建立连接") }
            return CheckResult(id:"line",title:"代理线路",value:"\(delay) ms",detail:"经过当前选中的完整代理链路，HTTPS 验证成功。",state:"good")
        } catch { return CheckResult(id:"line",title:"代理线路",value:"连接失败",detail:"代理链路未通过检测，请查看线路状态或重试。",state:"bad") }
    }
    func exitCheck() -> CheckResult {
        do {
            let configuration = try readConfig()
            let port = configuration["listeners"] != nil ? 18798 : 18797
            let result = try Command.run("/usr/bin/curl",["--noproxy","","--proxy","http://127.0.0.1:\(port)","--connect-timeout","5","--max-time","12","--silent","--show-error","--fail","https://www.cloudflare.com/cdn-cgi/trace"],timeout:15)
            let fields = Dictionary(result.output.split(separator:"\n").compactMap { row -> (String,String)? in
                let pair = row.split(separator:"=",maxSplits:1); return pair.count == 2 ? (String(pair[0]),String(pair[1])) : nil
            },uniquingKeysWith:{$1})
            guard result.code == 0, let ip = fields["ip"] else { throw LineError("出口验证失败") }
            return CheckResult(id:"exit",title:"出口 IP",value:ip,detail:"地区：\(fields["loc"] ?? "未知") · 当前选中线路的实际出口",state:"good")
        } catch { return CheckResult(id:"exit",title:"出口 IP",value:"获取失败",detail:"无法通过代理完成 HTTPS 请求。",state:"bad") }
    }
}
