# RustDesk 内网定制版 - 安装脚本
# 用法(管理员 PowerShell):
#   被控端: .\install.ps1                          (包内含 custom.txt 即自动识别为被控端)
#   全功能: .\install.ps1                          (全功能包不含 custom.txt)
#   可选参数: -OpsSubnet "172.16.100.0/24"  -Password "你的密码"
param(
    [string]$OpsSubnet = "LocalSubnet",
    [string]$Password = "dlyy123456"
)
$ErrorActionPreference = "Stop"

# 1. 必须管理员
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "[错误] 请以管理员身份运行本脚本" -ForegroundColor Red
    exit 1
}

$src = $PSScriptRoot
$dst = Join-Path $env:ProgramFiles "RustDesk"
$exe = Join-Path $dst "rustdesk.exe"
$isHost = Test-Path (Join-Path $src "custom.txt")
Write-Host "=== RustDesk 内网定制版安装 (模式: $(if ($isHost) { '被控端' } else { '全功能端' })) ==="

# 2. 停止旧进程与旧服务
Write-Host "[1/5] 停止旧进程/服务..."
Get-Process rustdesk -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
if (Test-Path $exe) {
    & $exe --uninstall-service 2>$null
}
Stop-Service "RustDesk Service" -Force -ErrorAction SilentlyContinue
sc.exe delete "RustDesk Service" 2>$null | Out-Null
Start-Sleep -Seconds 1

# 3. 拷贝程序文件
Write-Host "[2/5] 复制文件到 $dst ..."
New-Item -ItemType Directory -Force -Path $dst | Out-Null
Copy-Item (Join-Path $src "*") $dst -Recurse -Force

# 4. 静默安装服务(注册并启动)
Write-Host "[3/5] 注册系统服务..."
$proc = Start-Process -FilePath $exe -ArgumentList "--silent-install" -Wait -PassThru
if ($proc.ExitCode -ne 0) {
    Write-Host "[警告] --silent-install 退出码 $($proc.ExitCode)，继续尝试配置" -ForegroundColor Yellow
}
Start-Sleep -Seconds 3

# 5. 设置固定密码(免弹窗无人值守)
Write-Host "[4/5] 设置固定密码..."
& $exe --password $Password
Start-Sleep -Seconds 1

# 6. 防火墙: 仅放行指定来源访问直连端口(网络层收口)
Write-Host "[5/5] 配置防火墙 (来源: $OpsSubnet)..."
netsh advfirewall firewall delete rule name="RustDesk-Internal-TCP" 2>$null | Out-Null
netsh advfirewall firewall delete rule name="RustDesk-Internal-UDP" 2>$null | Out-Null
netsh advfirewall firewall add rule name="RustDesk-Internal-TCP" dir=in action=allow protocol=TCP localport=39744 remoteip="$OpsSubnet" | Out-Null
netsh advfirewall firewall add rule name="RustDesk-Internal-UDP" dir=in action=allow protocol=UDP localport=39747 remoteip="$OpsSubnet" | Out-Null

Write-Host ""
Write-Host "=== 安装完成 ===" -ForegroundColor Green
Write-Host "  直连端口 : TCP 39744 (被控监听)"
Write-Host "  局域网发现: UDP 39747"
Write-Host "  固定密码 : $Password"
Write-Host "  服务状态 : $(Get-Service 'RustDesk Service' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Status)"
Write-Host "被控端连接方式: 对端输入本机 IP 即可 (端口已内置,无需加端口号)"
