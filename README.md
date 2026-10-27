# 专线控制台 · Private Line Console

一款原生 macOS 工具，用来管理已有的 Mihomo 代理线路：按应用分流、选择中转与最终目的地，并查看实际连接和网络检测结果。

> **项目状态：开发版。** 当前版本建立在一套已有的本机代理配置之上，尚不支持在一台全新电脑上从零创建线路配置。使用前请先阅读下方的环境要求和限制。

## 功能

- 按应用启用代理，支持搜索和手动添加应用；局域网流量保持直连。
- 自动识别当前 Wi-Fi 或网线，线路使用系统当前网络接口。
- 从现有订阅中分别选择中转和最终目的地，也可以更换 HTTPS 订阅链接。更改会先检测，失败时尝试恢复原设置。
- 检测当前网络的 Ping、代理 HTTPS 延迟和实际出口 IP；Ping 目标可以手动指定。
- 控制台退出后后台服务仍运行；设置中提供恢复安装前配置的入口。

## 环境要求

- Apple Silicon Mac，macOS 14 或更新版本，已安装 Xcode Command Line Tools。
- 已有一套运行中的兼容 Mihomo 配置及本地服务，配置保存在 `~/Library/Application Support/Codex Private Proxy`。当前实现依赖该配置中的 `Codex`、`Wired-Relay` 策略组和 `lan`、`wifi`、`relay-lxy`、`wired-relay` 代理提供者。
- 上述目录中已有名为 `mihomo` 的内核文件，以及 `~/Library/LaunchAgents/local.codex.private-proxy.plist`。安装脚本会校验内核的固定 SHA-256；使用其他内核版本前，需要审阅并更新校验值。

首次启用应用分流需要 macOS 管理员授权，以安装后台 LaunchDaemon 和启用 TUN。请只在理解代码和配置的情况下运行。内核单独从 [Mihomo](https://github.com/MetaCubeX/mihomo) 获取，本仓库不包含其可执行文件。

## 构建

```sh
bash build.sh
open .build/专线控制台.app
```

构建使用系统 Swift 和框架，不下载依赖；脚本会从上述本机目录复制已有内核到应用包。产物是本地临时签名的应用，未经过 Apple 公证。

只运行不依赖用户订阅的规则测试：

```sh
mkdir -p .build
xcrun swiftc -swift-version 5 Sources/Policy.swift Tests/main.swift -o .build/policy-tests
.build/policy-tests
```

`Tests/isolated-chain.py` 等网络集成测试需要本机已有的配置、节点和运行中的服务；它们会产生网络流量，不适合在没有兼容配置的机器上直接运行。设置 `PRIVATE_LINE_EXPECTED_EXIT_IP` 可额外校验出口地址；`PRIVATE_LINE_TEST_RELAY` 可指定测试中转。

## 配置与隐私

订阅地址、代理凭据和本机控制信息保存在本地私有目录，不属于仓库内容。更换订阅时先在临时内核中尝试连接，再更新正式配置。请勿提交本机配置、订阅文件、测试日志或构建产物。

应用依赖 macOS 的进程归属信息：共享系统网络进程可能无法识别为原应用，应以界面里的实际连接状态为准。切换网络或线路时，已经建立的连接可能需要重新连接；Ping 不响应也不一定意味着代理不可用。

## 许可证

本项目源码采用 [MIT License](LICENSE)。Mihomo 等第三方组件由其各自的项目和许可证管理。
