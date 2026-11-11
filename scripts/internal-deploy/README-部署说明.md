# RustDesk 内网定制版 - 部署说明

基于 RustDesk 1.5.3 二次开发的**内网专用版**：无公网服务器、纯内网 IP 直连、固定密码免确认、非默认端口。

## 包说明

| 包 | 用途 | 安装对象 |
|---|---|---|
| `rustdesk-internal-host-windows-x64.zip` | **被控端**（无连接入口，只能被连） | 普通员工电脑 |
| `rustdesk-internal-full-windows-x64.zip` | **全功能版**（可连别人也可被连） | 运维人员电脑 |

两个包的 exe 完全相同，区别仅在于被控端包内含 `custom.txt`（运行时锁定为"仅被控"模式）。

## 安装

解压后在管理员 PowerShell 中运行：

```powershell
.\install.ps1                                  # 默认：防火墙放行 LocalSubnet
.\install.ps1 -OpsSubnet "172.16.100.0/24"     # 指定只允许运维网段连接（推荐）
```

脚本自动完成：停旧服务 → 装文件 → 注册系统服务 → 设固定密码 → 配防火墙。
如机器装过官方 RustDesk，先从"应用和功能"里卸载官方版再运行本脚本。

## 运维使用方法

1. 运维机安装**全功能版**
2. 主界面地址栏直接输入对方**内网 IP**（例如 `172.16.100.30`），点连接
3. 首次连接输入固定密码并勾选**记住密码**，以后一键直连
4. 被控端全程无弹窗、无确认，等同于 Radmin 的无感体验

## 关键参数

| 项 | 值 |
|---|---|
| 被控监听端口 | TCP **39744**（官方默认 21118，已改，防扫描） |
| 局域网发现端口 | UDP **39747**（主界面"局域网"标签可自动发现同网段主机） |
| 固定密码 | `dlyy123456`（可用 `install.ps1 -Password xxx` 覆盖） |
| ID/中继服务器 | 已禁用（指向 127.0.0.1），零公网流量 |
| 自动更新 | 已禁用（不会自更新成官方版） |

## 与官方版差异（源码层）

- `src/common.rs`：`DIRECT_ACCESS_PORT=39744`、loopback 检测、custom.txt 签名公钥
- `src/client.rs` / `src/rendezvous_mediator.rs` / `src/lan.rs`：端口与直连默认值
- `src/rendezvous_mediator.rs`：直连默认开启（仅 `N` 关闭）；loopback 时停泊注册循环；禁自动更新
- `libs/hbb_common`（fork: hogan-hong/hbb_common）：默认 rendezvous 服务器 → 127.0.0.1
- `tools/custom-client/`：custom.txt 签名工具（含私钥，**仓库为私有，勿转公开**）

## 卸载

```powershell
& "C:\Program Files\RustDesk\rustdesk.exe" --uninstall-service
Remove-Item "C:\Program Files\RustDesk" -Recurse -Force
netsh advfirewall firewall delete rule name="RustDesk-Internal-TCP"
netsh advfirewall firewall delete rule name="RustDesk-Internal-UDP"
```

## 重新生成 custom.txt（如需调整被控端锁定配置）

```bash
cd tools/custom-client
python3 generate.py host.json host-custom.txt   # 需 pynacl
```

当前锁定配置：`conn-type=incoming`（仅被控）、`disable-ab=Y`（隐藏地址簿）。
