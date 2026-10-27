import SwiftUI
import AppKit
import Combine

// The command-line SDK ships the property wrapper but not the new State macro plugin.
typealias ViewState<Value> = SwiftUI.State<Value>

@MainActor final class LineModel: ObservableObject {
    @Published var state = Snapshot()
    @Published var preferences = LinePreferences()
    @Published var applications: [ApplicationItem] = []
    @Published var checks: [CheckResult] = []
    @Published var target = ""
    @Published var busy = false
    @Published var checking = false
    @Published var refreshing = false
    @Published var error: String?
    @Published var lastCheck: Date?
    @Published var lastRefresh: Date?
    @Published var relayDraft = ""
    @Published var destinationDraft = ""
    @Published var routeMessage = ""
    @Published var relaySubscription = ""
    @Published var destinationSubscription = ""
    let service = LineService()
    init() {
        preferences = service.preferences()
        applications = service.discoverApplications()
        refresh()
    }
    var routeTitle: String {
        if !state.online { return "后台未连接" }
        if state.adaptive { return "当前网络 · \(state.network.kind)" }
        if state.route.hasPrefix("LAN-Relay") { return "网线 · 中转线路" }
        if state.route.hasPrefix("LAN-") { return "网线 · 直连服务器" }
        if state.route.hasPrefix("WiFi-") { return "Wi-Fi · 备用线路" }
        return state.route
    }
    var latency: String {
        guard let current = state.delays.first(where:{$0.0 == state.route}), current.2, current.1 > 0 else { return "—" }
        return "\(current.1) ms"
    }
    var lineAvailable: Bool { state.online && state.delays.contains{$0.0 == state.route && $0.2} }
    func flows(_ app:ApplicationItem) -> [ConnectionInfo] { state.connections.filter{$0.path.hasPrefix(app.path + "/")} }
    func refresh() {
        guard !refreshing, !busy else { return }
        refreshing = true
        let service = service
        Task {
            let snapshot = await Task.detached(priority:.utility) { service.snapshot() }.value
            state = snapshot; lastRefresh = Date(); refreshing = false
            if relayDraft.isEmpty { relayDraft = snapshot.relayChoice }
            if destinationDraft.isEmpty { destinationDraft = snapshot.destinationChoice }
        }
    }
    func applyRoutes() {
        guard !busy else { return }
        busy=true; routeMessage=""
        let service=service, relay=relayDraft, destination=destinationDraft
        Task {
            do {
                try await Task.detached { try service.selectRoutes(relay:relay,destination:destination) }.value
                routeMessage="线路已应用并通过连接检测。"
            } catch { self.error=error.localizedDescription; relayDraft=""; destinationDraft="" }
            busy=false; refresh()
        }
    }
    func updateSubscriptions() {
        guard !busy else { return }
        busy=true; routeMessage=""
        let service=service, relay=relaySubscription, destination=destinationSubscription
        Task {
            do {
                try await Task.detached { try service.updateSubscriptions(relay:relay,destination:destination) }.value
                relaySubscription=""; destinationSubscription=""; relayDraft=""; destinationDraft=""
                routeMessage="订阅已更新，线路检测通过。"
            } catch { self.error=error.localizedDescription }
            busy=false; refresh()
        }
    }
    func change(_ app:ApplicationItem, selected:Bool) {
        var next = preferences
        if selected { next.selected = Array(Set(next.selected + [app.path])) } else { next.selected.removeAll{$0 == app.path} }
        perform(next:next, reconnect:[app.path])
    }
    func perform(next:LinePreferences, reconnect:[String] = []) {
        guard !busy else { return }; busy = true
        let service = service
        Task {
            do {
                try await Task.detached { try service.apply(next,reconnectPaths:reconnect) }.value
                preferences = next
            } catch { self.error = error.localizedDescription }
            busy = false; refresh()
        }
    }
    func activate() {
        guard !busy else { return }
        var next = preferences; next.enabled = true
        if state.managed { perform(next:next); return }
        busy = true; let service = service; let wanted = next
        Task {
            do { try await Task.detached { try service.install(wanted) }.value; preferences = wanted }
            catch { self.error = error.localizedDescription }
            busy = false; refresh()
        }
    }
    func deactivate() { var next=preferences; next.enabled=false; perform(next:next,reconnect:preferences.selected) }
    func restore() {
        guard !busy else { return }; busy = true; let service=service
        Task {
            do { try await Task.detached { try service.restore() }.value }
            catch { self.error=error.localizedDescription }
            busy=false; refresh()
        }
    }
    func diagnose() {
        guard !checking else { return }
        let enteredTarget=target.trimmingCharacters(in:.whitespacesAndNewlines)
        guard enteredTarget.isEmpty || Policy.validHost(enteredTarget) else { error="请填写 IP 或域名，不要填写网址；留空会自动使用当前出口 IP。"; return }
        checking=true; checks=[]
        let host=enteredTarget, service=service, network=service.networkStatus()
        Task {
            await withTaskGroup(of:CheckResult.self) { group in
                group.addTask { service.lineCheck() }
                group.addTask { service.exitCheck() }
                if !host.isEmpty { group.addTask { service.ping(host,interface:network.interface,title:"\(network.kind) Ping") } }
                for await result in group {
                    checks.append(result)
                    if result.id == "exit" && host.isEmpty {
                        if result.state == "good" && Policy.validHost(result.value) {
                            let address=result.value
                            group.addTask { service.ping(address,interface:network.interface,title:"\(network.kind) Ping") }
                        } else { checks.append(CheckResult(id:"ping",title:"\(network.kind) Ping",value:"缺少目标",detail:"未能获取当前出口 IP，可手动填写 Ping 目标。",state:"warn")) }
                    }
                }
            }
            checks.sort { ["ping","line","exit"].firstIndex(of:$0.id)! < ["ping","line","exit"].firstIndex(of:$1.id)! }
            checking=false; lastCheck=Date(); refresh()
        }
    }
    func addApplication() {
        guard !busy else { return }
        let panel=NSOpenPanel(); panel.canChooseDirectories=false; panel.canChooseFiles=true
        panel.allowedContentTypes=[.applicationBundle]; panel.allowsMultipleSelection=true
        if panel.runModal() == .OK {
            var next = preferences
            next.customApplications = Array(Set((next.customApplications ?? []) + panel.urls.map{$0.path})).sorted()
            do { try service.savePreferences(next); preferences=next; applications=service.discoverApplications() }
            catch { self.error=error.localizedDescription }
        }
    }
}

enum Page:String,CaseIterable {
    case overview="线路状态", applications="应用分流", diagnostics="网络检测", settings="设置与恢复"
    var symbol:String { switch self { case .overview:"point.3.connected.trianglepath.dotted"; case .applications:"square.grid.2x2"; case .diagnostics:"waveform.path.ecg"; case .settings:"slider.horizontal.3" } }
}

struct Pill:View {
    let title:String
    var color:Color = .accentColor
    var body:some View { Text(title).font(.system(size:11,weight:.medium)).foregroundStyle(color).padding(.horizontal,9).padding(.vertical,5).background(color.opacity(0.10),in:Capsule()) }
}
struct Panel<Content:View>:View {
    @ViewBuilder let content:Content
    var body:some View { VStack(alignment:.leading,spacing:16){content}.padding(22).frame(maxWidth:.infinity,alignment:.leading).background(Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:18)).overlay(RoundedRectangle(cornerRadius:18).strokeBorder(Color.primary.opacity(0.055))) }
}
struct Metric:View {
    let title:String, value:String, detail:String, symbol:String
    var body:some View { Panel { HStack { Text(title).font(.subheadline).foregroundStyle(.secondary); Spacer(); Image(systemName:symbol).foregroundStyle(.indigo) }; Text(value).font(.system(size:25,weight:.semibold,design:.rounded)); Text(detail).font(.caption).foregroundStyle(.secondary) }.frame(maxHeight:.infinity,alignment:.top) }
}

struct ConsoleView:View {
    @ObservedObject var model:LineModel
    @ViewState private var page:Page = .overview
    @ViewState private var query=""
    @ViewState private var onlySelected=false
    @ViewState private var confirmRestore=false
    @ViewState private var showSubscriptions=false
    let timer=Timer.publish(every:5,on:.main,in:.common).autoconnect()
    var body:some View {
        HStack(spacing:0) {
            VStack(alignment:.leading,spacing:26) {
                HStack(spacing:11) { Image(systemName:"point.3.connected.trianglepath.dotted").font(.system(size:29,weight:.semibold)).foregroundStyle(.indigo); VStack(alignment:.leading,spacing:3) { Text("专线控制台").font(.headline); Text("按应用连接，自由掌控").font(.system(size:10)).foregroundStyle(.secondary) } }.padding(.top,24)
                VStack(spacing:7) { ForEach(Page.allCases,id:\.self) { item in Button { page=item } label: { HStack(spacing:11) { Image(systemName:item.symbol).frame(width:20); Text(item.rawValue).font(.system(size:13,weight:page == item ? .semibold:.regular)); Spacer() }.padding(12).background(page == item ? Color.indigo.opacity(0.12):.clear,in:RoundedRectangle(cornerRadius:10)).foregroundStyle(page == item ? Color.indigo:Color.primary) }.buttonStyle(.plain) } }
                Spacer()
                VStack(alignment:.leading,spacing:9) { HStack { Circle().fill(model.state.online ? .green:.orange).frame(width:7,height:7); Text(model.state.online ? "后台正在运行":"后台未连接").font(.caption) }; Text(model.state.tun ? "应用接管已开启":"应用接管尚未开启").font(.caption2).foregroundStyle(.secondary); Text("关闭窗口后，线路继续运行").font(.system(size:10)).foregroundStyle(.tertiary) }.padding(.bottom,18)
            }.padding(.horizontal,18).frame(width:210).background(.ultraThinMaterial)
            Divider()
            VStack(alignment:.leading,spacing:0) {
                HStack(alignment:.center) { VStack(alignment:.leading,spacing:6) { Text(page.rawValue).font(.system(size:25,weight:.bold)); Text(subtitle).font(.system(size:12)).foregroundStyle(.secondary) }; Spacer(); if model.busy { ProgressView().controlSize(.small); Text("正在应用…").font(.caption).foregroundStyle(.secondary) } else { Button { model.refresh() } label:{Image(systemName:"arrow.clockwise")}.buttonStyle(.borderless).help("刷新实际连接状态") } }.padding(28)
                ScrollView {
                    VStack(alignment:.leading,spacing:18) {
                        if !model.state.managed { onboarding }
                        switch page { case .overview:overview; case .applications:applications; case .diagnostics:diagnostics; case .settings:settings }
                    }.padding(.horizontal,28).padding(.bottom,28)
                }
            }.background(Color(nsColor:.windowBackgroundColor))
        }.frame(minWidth:1040,minHeight:720).tint(.indigo)
        .onReceive(timer){_ in model.refresh()}
        .alert("操作未完成",isPresented:Binding(get:{model.error != nil},set:{if !$0 {model.error=nil}})) { Button("知道了"){model.error=nil} } message:{Text(model.error ?? "")}
        .confirmationDialog("恢复之前的独立代理？",isPresented:$confirmRestore,titleVisibility:.visible) { Button("恢复原配置",role:.destructive){model.restore()} } message:{Text("移除系统接管服务，恢复之前 Codex 和 Telegram 使用的本地代理。需要管理员授权。")}
    }
    var subtitle:String { switch page { case .overview:"查看正在使用的线路和真实连接状态"; case .applications:"勾选的应用走专线，其余应用直接联网"; case .diagnostics:"分别检测 Ping、代理链路和最终出口"; case .settings:"管理系统接管、后台服务与原配置恢复" } }
    var onboarding:some View { HStack(alignment:.center,spacing:16) { Image(systemName:"lock.shield").font(.title2).foregroundStyle(.indigo); VStack(alignment:.leading,spacing:5) { Text("先启用应用接管").font(.headline); Text("首次需要管理员授权。现有 Codex、Telegram 代理仍可使用，其他勾选应用在启用后生效。").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true) }; Spacer(); Button("授权并启用"){model.activate()}.buttonStyle(.borderedProminent).disabled(model.busy) }.padding(18).background(Color.indigo.opacity(0.065),in:RoundedRectangle(cornerRadius:14)) }
    var overview:some View {
        Group {
            Panel {
                HStack { HStack(spacing:10) { Circle().fill(model.lineAvailable ? Color.green:Color.orange).frame(width:9,height:9); Text(model.routeTitle).font(.title3.weight(.semibold)) }; Spacer(); Pill(title:!model.state.online ? "后台未连接":!model.lineAvailable ? "线路待检测":model.state.tun ? "应用接管中":"本地代理可用",color:model.lineAvailable ? .green:.orange) }
                HStack(spacing:12) { routeStep("这台 Mac","laptopcomputer"); Image(systemName:"chevron.right").foregroundStyle(.tertiary); routeStep(model.state.network.kind,model.state.network.kind == "Wi-Fi" ? "wifi":"cable.connector"); if model.state.adaptive || model.state.route.hasPrefix("LAN-Relay") { Image(systemName:"chevron.right").foregroundStyle(.tertiary); routeStep("中转节点","arrow.triangle.branch") }; Image(systemName:"chevron.right").foregroundStyle(.tertiary); routeStep("最终目的地","server.rack") }.padding(.vertical,14)
                Divider()
                HStack { Text("当前接口：\(model.state.network.interface ?? "未连接")").font(.caption).foregroundStyle(.secondary); Spacer(); Text("自动跟随系统网络").font(.caption).foregroundStyle(.secondary) }
            }
            if model.state.adaptive {
                Panel {
                    HStack { Text("选择线路").font(.headline); Spacer(); if !model.routeMessage.isEmpty { Text(model.routeMessage).font(.caption).foregroundStyle(.green) } }
                    HStack(alignment:.bottom,spacing:16) {
                        VStack(alignment:.leading,spacing:7) { Text("中转节点").font(.caption).foregroundStyle(.secondary); Picker("中转节点",selection:$model.relayDraft) { ForEach(model.state.relayOptions,id:\.self) { Text(friendlyNode($0)).tag($0) } }.labelsHidden() }.frame(maxWidth:.infinity,alignment:.leading)
                        VStack(alignment:.leading,spacing:7) { Text("最终目的地").font(.caption).foregroundStyle(.secondary); Picker("最终目的地",selection:$model.destinationDraft) { ForEach(model.state.destinationOptions,id:\.self) { Text(friendlyNode($0)).tag($0) } }.labelsHidden() }.frame(maxWidth:.infinity,alignment:.leading)
                        Button("应用选择"){model.applyRoutes()}.buttonStyle(.borderedProminent).disabled(model.busy || model.relayDraft.isEmpty || model.destinationDraft.isEmpty)
                    }
                    Text("当前中转：\(friendlyNode(model.state.relay)) · 当前目的地：\(friendlyNode(model.state.route))").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Text("更改后先检测线路；连接失败会恢复原来的选择。不同协议不一定支持中转。").font(.caption).foregroundStyle(.secondary)
                    Divider()
                    DisclosureGroup("更换订阅链接",isExpanded:$showSubscriptions) {
                        VStack(alignment:.leading,spacing:12) {
                            Text("填写需要更换的 HTTPS 订阅；留空的部分保持原样。链接只保存在本机私有配置中。").font(.caption).foregroundStyle(.secondary)
                            SecureField("中转订阅链接（留空保持不变）",text:$model.relaySubscription).textFieldStyle(.roundedBorder)
                            SecureField("最终目的地订阅链接（留空保持不变）",text:$model.destinationSubscription).textFieldStyle(.roundedBorder)
                            HStack { Text("先下载并检测可用线路，通过后才切换。").font(.caption).foregroundStyle(.secondary); Spacer(); Button("更新订阅并检测"){model.updateSubscriptions()}.buttonStyle(.bordered).disabled(model.busy) }
                        }.padding(.top,12)
                    }
                }
            }
            HStack(alignment:.top,spacing:14) { Metric(title:"当前线路延迟",value:model.latency,detail:"来自最近一次链路健康检查",symbol:"waveform.path"); Metric(title:"已勾选应用",value:"\(model.preferences.selected.count)",detail:model.state.tun ? "新连接按应用规则分流":"启用接管后生效",symbol:"square.grid.2x2"); Metric(title:"专线连接",value:"\(model.state.connections.filter{$0.viaLine}.count)",detail:"实际经过专线的当前连接",symbol:"arrow.up.arrow.down") }
            Panel { HStack { Text("当前节点可用性").font(.headline); Spacer(); Button("完整检测"){page = .diagnostics;model.diagnose()}.buttonStyle(.borderless) }; ForEach(Array(model.state.delays.filter{$0.0 == model.state.route || $0.0 == model.state.relay}.enumerated()),id:\.offset) { _,item in HStack { Image(systemName:item.2 ? "checkmark.circle.fill":"minus.circle").foregroundStyle(item.2 ? Color.green:Color.secondary); Text(friendlyNode(item.0)).font(.system(size:12)); Spacer(); Text(item.2 && item.1 > 0 ? "\(item.1) ms":"待检测").font(.system(size:12,design:.monospaced)).foregroundStyle(item.2 ? Color.primary:Color.secondary) } }; if model.state.delays.isEmpty { Text("等待后台返回检测结果").font(.caption).foregroundStyle(.secondary) } }
            Text("网络切换时，新连接会使用系统当前网络；已有连接可能需要重新连接。").font(.caption).foregroundStyle(.tertiary)
        }
    }
    func routeStep(_ name:String,_ symbol:String) -> some View { VStack(spacing:9) { Image(systemName:symbol).font(.system(size:23)).foregroundStyle(.indigo); Text(name).font(.system(size:11,weight:.medium)) }.frame(maxWidth:.infinity) }
    func friendlyNode(_ name:String) -> String { if name == "Auto-Relay" || name == "Auto-Destination" { return "自动选择" }; return name.replacingOccurrences(of:"LAN-Relay-",with:"").replacingOccurrences(of:"LXY-",with:"").replacingOccurrences(of:"LAN-",with:"").replacingOccurrences(of:"WiFi-",with:"") }
    var filtered:[ApplicationItem] { model.applications.filter{(!onlySelected || model.preferences.selected.contains($0.path)) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.bundleID.localizedCaseInsensitiveContains(query))}.sorted { let a=model.preferences.selected.contains($0.path),b=model.preferences.selected.contains($1.path); return a == b ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : a } }
    var applications:some View {
        Group {
            HStack { TextField("搜索应用名称",text:$query).textFieldStyle(.roundedBorder).frame(maxWidth:340); Toggle("只看已勾选",isOn:$onlySelected).toggleStyle(.checkbox); Spacer(); Button("添加应用…"){model.addApplication()} }
            Panel {
                HStack { Text("应用").font(.caption).foregroundStyle(.secondary); Spacer(); Text("实际连接状态").font(.caption).foregroundStyle(.secondary); Text("走专线").font(.caption).foregroundStyle(.secondary).frame(width:62) }
                Divider()
                ForEach(filtered) { app in
                    let flows=model.flows(app)
                    HStack(spacing:12) {
                        Image(nsImage:NSWorkspace.shared.icon(forFile:app.path)).resizable().frame(width:34,height:34)
                        VStack(alignment:.leading,spacing:4) { Text(app.name).font(.system(size:13,weight:.medium)); Text(app.path).font(.system(size:10)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle) }
                        Spacer()
                        if flows.contains(where:{$0.viaLine}) { Pill(title:"专线 · \(flows.filter{$0.viaLine}.count) 个连接",color:.green) }
                        else if !flows.isEmpty { Pill(title:"直连",color:.secondary) }
                        else { Text(model.preferences.selected.contains(app.path) ? (model.state.tun ? "等待新连接":"待启用接管") : "未观察到连接").font(.caption2).foregroundStyle(.tertiary) }
                        Toggle("\(app.name) 走专线",isOn:Binding(get:{model.preferences.selected.contains(app.path)},set:{model.change(app,selected:$0)})).labelsHidden().toggleStyle(.switch).controlSize(.small).frame(width:62).disabled(model.busy)
                    }.padding(.vertical,5)
                    if app.id != filtered.last?.id { Divider().opacity(0.6) }
                }
                if filtered.isEmpty { Text("没有找到应用，试试“添加应用”。").foregroundStyle(.secondary).padding(.vertical,30) }
            }
            Text("切换后会重连该应用的已识别连接。共享网络进程可能无法归属到原应用，请以实际连接状态为准。局域网连接始终直连。").font(.caption).foregroundStyle(.secondary)
        }
    }
    var diagnostics:some View {
        Group {
            Panel {
                HStack { VStack(alignment:.leading,spacing:6) { Text("一键检测").font(.headline); Text("Ping 直接测试目标回应；代理检测会走完整线路。").font(.caption).foregroundStyle(.secondary) }; Spacer(); Button { model.diagnose() } label:{Label(model.checking ? "检测中…":"开始检测",systemImage:"waveform.path.ecg")}.buttonStyle(.borderedProminent).disabled(model.checking) }
                HStack { Text("Ping 目标").font(.caption).foregroundStyle(.secondary); TextField("留空时自动检测当前出口 IP",text:$model.target).textFieldStyle(.roundedBorder).frame(maxWidth:300); Spacer(); if model.checking { ProgressView().controlSize(.small) } }
            }
            if model.checks.isEmpty { Panel { VStack(spacing:14) { Image(systemName:"waveform.path.ecg.rectangle").font(.system(size:42)).foregroundStyle(.indigo.opacity(0.7)); Text(model.checking ? "正在检查网线、Wi-Fi 和代理线路":"点击开始检测，查看实时结果").font(.headline); Text("结果会显示延迟、丢包率与出口地址").font(.caption).foregroundStyle(.secondary) }.frame(maxWidth:.infinity).padding(.vertical,45) } }
            ForEach(model.checks) { check in Panel { HStack(alignment:.top,spacing:15) { Image(systemName:check.state == "good" ? "checkmark.circle.fill":check.state == "bad" ? "xmark.circle.fill":"exclamationmark.circle.fill").font(.title2).foregroundStyle(check.state == "good" ? Color.green:check.state == "bad" ? Color.red:Color.orange); VStack(alignment:.leading,spacing:7) { Text(check.title).font(.headline); Text(check.detail).font(.caption).foregroundStyle(.secondary) }; Spacer(); Text(check.value).font(.system(size:21,weight:.semibold,design:.rounded)).textSelection(.enabled) } } }
            if let time=model.lastCheck { Text("最近检测：\(time.formatted(date:.omitted,time:.standard)) · Ping 不回应不代表代理不可用。").font(.caption).foregroundStyle(.secondary) }
        }
    }
    var settings:some View {
        Group {
            Panel { HStack { VStack(alignment:.leading,spacing:8) { Text("应用接管").font(.headline); Text(model.state.tun ? "只让勾选的应用走专线，其他应用直连。":"开启后，普通启动的应用也能按勾选结果分流。").font(.caption).foregroundStyle(.secondary) }; Spacer(); Button(model.state.tun ? "关闭接管":"开启接管") { if model.state.tun {model.deactivate()} else {model.activate()} }.buttonStyle(.borderedProminent).disabled(model.busy) }; Divider(); LabeledContent("后台服务",value:model.state.managed ? "系统服务 · 开机自动运行":"原独立代理服务"); LabeledContent("本地代理",value:"127.0.0.1:18797"); LabeledContent("内核版本",value:model.state.version.isEmpty ? "未连接":model.state.version) }
            Panel { Text("使用方式").font(.headline); Text("启用系统接管后，直接打开原来的应用即可。退出控制台不会关闭线路；Clash 无需运行。").font(.callout).foregroundStyle(.secondary); Text("需要手动设置代理的应用可使用 SOCKS5 或 HTTP：127.0.0.1，端口 18797。无需填写账号密码。").font(.caption).foregroundStyle(.secondary) }
            Panel { Text("恢复原配置").font(.headline); Text("移除本软件安装的系统接管服务，回到之前的独立代理方式。现有订阅保留。").font(.caption).foregroundStyle(.secondary); Button("恢复安装前的配置…"){confirmRestore=true}.disabled(model.busy || !model.state.managed) }
        }
    }
}

final class AppDelegate:NSObject,NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows:Bool) -> Bool { if !hasVisibleWindows {sender.windows.first?.makeKeyAndOrderFront(nil)}; return true }
}

@main struct PrivateLineApp:App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model=LineModel()
    init() {
        if CommandLine.arguments.contains("--status") { let s=LineService().snapshot(); print("online=\(s.online) managed=\(s.managed) tun=\(s.tun) route=\(s.route) connections=\(s.connections.count)"); exit(s.online ? 0:1) }
        if CommandLine.arguments.contains("--check-config") {
            do { let service=LineService(); _ = try service.validate(Policy.config(service.readConfig(),applications:service.preferences().selected,enabled:true)); print("Application routing configuration accepted by Mihomo"); exit(0) }
            catch { print(error.localizedDescription); exit(1) }
        }
        if CommandLine.arguments.contains("--network") { let network=LineService().networkStatus(); print("\(network.kind) · \(network.interface ?? "none")"); exit(0) }
        if CommandLine.arguments.contains("--migrate-adaptive") { do { try LineService().migrateAdaptive(); print("Adaptive network and selectors active"); exit(0) } catch { print(error.localizedDescription); exit(1) } }
        if CommandLine.arguments.contains("--refresh-current-subscriptions") {
            do { let service=LineService(); let providers=try service.readConfig()["proxy-providers"] as? [String:[String:Any]] ?? [:]; guard let relay=providers["relay-lxy"]?["url"] as? String, let destination=providers["wired-relay"]?["url"] as? String else { throw LineError("订阅不可用。") }; try service.updateSubscriptions(relay:relay,destination:destination); print("Both existing subscriptions refreshed and verified"); exit(0) }
            catch { print(error.localizedDescription); exit(1) }
        }
        if CommandLine.arguments.contains("--diagnose") { let service=LineService(), network=service.networkStatus(), exitResult=service.exitCheck(); let ping=exitResult.state == "good" ? service.ping(exitResult.value,interface:network.interface,title:network.kind) : CheckResult(id:"ping",title:network.kind,value:"缺少目标",detail:"未取得当前出口 IP。",state:"warn"); for r in [ping,service.lineCheck(),exitResult] { print("\(r.id): \(r.state) · \(r.value) · \(r.detail)") }; exit(0) }
    }
    var body:some Scene {
        WindowGroup("专线控制台") { ConsoleView(model:model) }.defaultSize(width:1120,height:780).commands { CommandGroup(replacing:.newItem){} }
        MenuBarExtra("专线控制台",systemImage:model.state.tun ? "network.badge.shield.half.filled":"network") {
            Text(model.routeTitle)
            Button("打开控制台") { NSApp.activate(ignoringOtherApps:true); NSApp.windows.first(where:{$0.canBecomeMain})?.makeKeyAndOrderFront(nil) }
            Button("检测线路"){model.diagnose()}
            Divider()
            Text(model.state.tun ? "应用接管已开启":"应用接管尚未开启")
            Button("退出控制台（保留线路）"){NSApp.terminate(nil)}
        }
    }
}
