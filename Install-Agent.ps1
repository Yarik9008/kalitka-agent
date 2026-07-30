<#
.SYNOPSIS
    gatelink: установка агента на Windows-компьютер, к которому нужно подключаться.

.DESCRIPTION
    Агент (frpc) держит одно исходящее соединение до сервера — через SOCKS
    вашего VPN-клиента. Портов на этой машине наружу не открывается, проброс
    на роутере не нужен.

    Ничего не публикуется само: какие локальные порты станут доступны, задаётся
    параметрами. Это осознанно — раньше RDP публиковался по умолчанию, и
    установка агента молча открывала к нему доступ.

.EXAMPLE
    .\Install-Agent.ps1 -Enroll 'eyJzZXJ2...' -RdpPort 3389

.EXAMPLE
    .\Install-Agent.ps1 -Enroll '...' -HttpPort 3000 -SshPort 22
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Enroll,
    [string]$Name,
    [int]$RdpPort = 0,
    [int]$SshPort = 0,
    [int]$VncPort = 0,
    [int]$HttpPort = 0,
    [string]$Socks,
    [ValidateSet('auto', 'vpn', 'direct')][string]$Mode = 'auto',
    [switch]$Direct,
    [string]$FrpVersion = "",
    [switch]$NoService
)
if ($Direct) { $Mode = 'direct' }

$ErrorActionPreference = 'Stop'

function Say  { param($m) Write-Host "[gatelink] $m" -ForegroundColor Cyan }
function Warn { param($m) Write-Host "[gatelink] $m" -ForegroundColor Yellow }
function Die  { param($m) Write-Host "[gatelink] ОШИБКА: $m" -ForegroundColor Red; exit 1 }

$IsAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# ── строка подключения ──────────────────────────────────────────────────
try {
    $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Enroll.Trim()))
    $cfg = $json | ConvertFrom-Json
} catch {
    Die "строка подключения не разбирается — скопирована не целиком?"
}
if (-not $cfg.token) { Die "в строке подключения нет token" }
if (-not $cfg.server -and -not $cfg.gate) { Die "в строке подключения нет ни server, ни gate" }
if (-not $cfg.secret) { Die "в строке подключения нет секрета приватных туннелей" }

# ── имя машины ──────────────────────────────────────────────────────────
# Имя приходит в строке подключения: секрет этой машины выведен именно из него
# (HMAC от имени), поэтому переименовать машину здесь нельзя — секрет перестанет
# совпадать с тем, что посчитает визитор. Нужно другое имя — новая строка:
# server/enroll.py agent --name ДРУГОЕ-ИМЯ
if ($cfg.name) {
    if ($Name -and $Name -ne $cfg.name) {
        Die "строка подключения выдана на имя «$($cfg.name)», а -Name задаёт «$Name».
Секрет этой машины выведен из имени, поэтому имя менять здесь нельзя.
Возьмите строку для нужного имени: server/enroll.py agent --name $Name"
    }
    $Name = $cfg.name
} else {
    if (-not $Name) { $Name = $env:COMPUTERNAME }
    Warn "строка подключения старого формата — секрет общий для всех машин."
    Warn "Перевыпустите её на сервере: server/enroll.py agent --name ИМЯ"
}
$Name = ($Name.ToLower() -replace '[^a-z0-9-]', '-').Trim('-')
if (-not $Name) { Die "не удалось определить имя машины, задайте -Name" }
if ($Name.Length -gt 31) { Die "имя длиннее 31 символа: $Name" }
Say "имя этой машины в туннелях: $Name"

# ── SOCKS VPN-клиента ───────────────────────────────────────────────────
function Test-Port {
    param([string]$TargetHost, [int]$Port)
    try {
        $c = New-Object Net.Sockets.TcpClient
        $ok = $c.ConnectAsync($TargetHost, $Port).Wait(1500)
        $c.Close()
        return $ok
    } catch { return $false }
}

if (-not $Socks -and $Mode -ne 'direct') {
    foreach ($p in 10808, 2080, 12334, 7890, 1080, 1081, 10801) {
        if (Test-Port '127.0.0.1' $p) { $Socks = "127.0.0.1:$p"; break }
    }
}

# auto: есть SOCKS — идём через VPN, нет — прямым режимом по HTTPS.
switch ($Mode) {
    'vpn' {
        if (-not $Socks) { Die "режим vpn выбран, но SOCKS-прокси не найден — укажите -Socks HOST:PORT" }
        if (-not $cfg.server) { Die "в строке подключения нет адреса для режима vpn" }
    }
    'direct' {
        if (-not $cfg.gate) { Die "в строке подключения нет gate — прямой режим недоступен" }
    }
    'auto' {
        if ($Socks -and $cfg.server) { $Mode = 'vpn' }
        elseif ($cfg.gate)           { $Mode = 'direct' }
        else { Die "не нашёл ни SOCKS для режима vpn, ни gate для прямого режима" }
    }
}
if ($Mode -eq 'vpn') { Say "режим: через VPN (SOCKS $Socks)" }
else { Say "режим: прямой — websocket по HTTPS на $($cfg.gate):$($cfg.gatePort), VPN не нужен" }

# ── куда ставить ────────────────────────────────────────────────────────
$Root = if ($IsAdmin) { Join-Path $env:ProgramData 'gatelink' }
        else { Join-Path $env:LOCALAPPDATA 'gatelink' }
$BinDir = Join-Path $Root 'bin'
$LogFile = Join-Path $Root 'agent.log'
New-Item -ItemType Directory -Force -Path $BinDir | Out-Null

# ── frpc ────────────────────────────────────────────────────────────────
$FrpcExe = Join-Path $BinDir 'frpc.exe'
if (-not (Test-Path $FrpcExe)) {
    # Версия зафиксирована намеренно. Раньше здесь запрашивался «latest» из
    # GitHub API, и каждая машина получала то, что оказалось актуальным в момент
    # установки. Архив сверяется с frp_sha256_checksums.txt из того же релиза:
    # HTTPS говорит лишь «файл пришёл от github», но не «файл тот, что ожидали».
    if (-not $FrpVersion) { $FrpVersion = '0.70.1' }
    $arch = if ([Environment]::Is64BitOperatingSystem) {
        if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'amd64' }
    } else { '386' }

    $archive = "frp_${FrpVersion}_windows_${arch}.zip"
    $base = "https://github.com/fatedier/frp/releases/download/v$FrpVersion"
    $url = "$base/$archive"
    $zip = Join-Path $env:TEMP $archive
    $sums = Join-Path $env:TEMP "frp_${FrpVersion}_sha256.txt"
    Say "скачиваю frp $FrpVersion для windows/$arch"
    try {
        Invoke-WebRequest -Uri $url -OutFile $zip -TimeoutSec 180 -UseBasicParsing
        Invoke-WebRequest -Uri "$base/frp_sha256_checksums.txt" -OutFile $sums `
            -TimeoutSec 60 -UseBasicParsing
    } catch {
        # Invoke-WebRequest не умеет SOCKS, поэтому через VPN отсюда не зайти.
        Die "не удалось скачать frp. Скачайте $url вручную, распакуйте frpc.exe в $BinDir и запустите скрипт снова."
    }

    $want = (Select-String -Path $sums -Pattern ([regex]::Escape($archive) + '$') `
        | Select-Object -First 1).Line
    if (-not $want) { Die "в списке контрольных сумм нет строки для $archive" }
    $want = ($want -split '\s+')[0].ToLower()
    $got = (Get-FileHash -Path $zip -Algorithm SHA256).Hash.ToLower()
    if ($want -ne $got) {
        Remove-Item -Force $zip, $sums -ErrorAction SilentlyContinue
        Die "контрольная сумма не совпала для $archive`n  ожидалось: $want`n  получено:  $got`nАрхив НЕ распакован."
    }
    Say "sha256 совпал"

    $tmp = Join-Path $env:TEMP "frp_extract_$FrpVersion"
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    Expand-Archive -Path $zip -DestinationPath $tmp -Force
    Copy-Item (Get-ChildItem -Recurse -Path $tmp -Filter 'frpc.exe' | Select-Object -First 1).FullName $FrpcExe -Force
    Remove-Item -Recurse -Force $tmp, $zip, $sums -ErrorAction SilentlyContinue
}
Say "frpc: $FrpcExe"

# ── конфигурация ────────────────────────────────────────────────────────
$Conf = Join-Path $Root 'frpc.toml'
$sb = [Text.StringBuilder]::new()
$null = $sb.AppendLine(@"
# Конфигурация агента gatelink. Сгенерирована Install-Agent.ps1.
# Содержит секреты — не копируйте в общие папки.
"@)

if ($Mode -eq 'direct') {
    $null = $sb.AppendLine(@"

# Прямой режим: управляющий канал идёт как websocket поверх обычного HTTPS
# на :443 и приходит на сервер через тот же Caddy, что обслуживает сайт.
# VPN не нужен; снаружи это неотличимо от запроса к сайту.
serverAddr = "$($cfg.gate)"
serverPort = $($cfg.gatePort)
transport.protocol = "wss"
"@)
} else {
    $null = $sb.AppendLine(@"

# Режим через VPN: адрес сервера резолвится не здесь, а на стороне VPS —
# правило роутинга Xray перенаправляет его на управляющий порт frps,
# висящий на лупбэке.
serverAddr = "$($cfg.server)"
serverPort = $($cfg.port)
transport.proxyURL = "socks5://$Socks"
"@)
}

$null = $sb.AppendLine(@"

auth.method = "token"
auth.token = "$($cfg.token)"

transport.tls.enable = true
transport.poolCount = 3
transport.heartbeatInterval = 20
transport.heartbeatTimeout = 60

loginFailExit = false

log.to = "$($LogFile -replace '\\', '\\\\')"
log.level = "info"
log.maxDays = 7
"@)

function Add-Stcp {
    param([string]$Suffix, [int]$Port)
    $null = $sb.AppendLine(@"

[[proxies]]
name = "$Name-$Suffix"
type = "stcp"
secretKey = "$($cfg.secret)"
localIP = "127.0.0.1"
localPort = $Port
"@)
}

if ($RdpPort -gt 0) { Add-Stcp 'rdp' $RdpPort }
if ($SshPort -gt 0) { Add-Stcp 'ssh' $SshPort }
if ($VncPort -gt 0) { Add-Stcp 'vnc' $VncPort }

if ($HttpPort -gt 0) {
    $null = $sb.AppendLine(@"

# Публичный HTTP-туннель: https://$Name.$($cfg.sub)
[[proxies]]
name = "$Name-web"
type = "http"
subdomain = "$Name"
localIP = "127.0.0.1"
localPort = $HttpPort
"@)
}

Set-Content -Path $Conf -Value $sb.ToString() -Encoding UTF8
Say "конфигурация: $Conf"

if ($RdpPort -le 0 -and $SshPort -le 0 -and $VncPort -le 0 -and $HttpPort -le 0) {
    Warn "не указано ни одного порта — агент подключится к серверу, но ничего не опубликует."
    Warn "Чтобы открыть доступ по RDP, перезапустите с параметром: -RdpPort 3389"
}

# ── автозапуск ──────────────────────────────────────────────────────────
if ($NoService) {
    Say "автозапуск не ставился. Запуск вручную: `"$FrpcExe`" -c `"$Conf`""
    exit 0
}

$TaskName = 'gatelink-agent'
$action = New-ScheduledTaskAction -Execute $FrpcExe -Argument "-c `"$Conf`""
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit ([TimeSpan]::Zero)

Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

if ($IsAdmin) {
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Description 'gatelink agent (frpc)' | Out-Null
    Say "задача $TaskName зарегистрирована, запускается при старте системы"
} else {
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
        -Settings $settings -Description 'gatelink agent (frpc)' | Out-Null
    Warn "запуск без прав администратора: агент стартует при входе в систему, а не при загрузке"
}
Start-ScheduledTask -TaskName $TaskName
Start-Sleep -Seconds 2

Write-Host ""
Write-Host "──────────────────────────────────────────────────────────────────────────"
Write-Host " Агент установлен. Что теперь доступно:"
Write-Host ""
if ($RdpPort -gt 0)  { Write-Host "   RDP:   на машине-клиенте  .\GateLink.ps1 rdp $Name" }
if ($SshPort -gt 0)  { Write-Host "   SSH:   .\GateLink.ps1 ssh $Name" }
if ($VncPort -gt 0)  { Write-Host "   VNC:   .\GateLink.ps1 add $Name-vnc 5900" }
if ($HttpPort -gt 0) { Write-Host "   Веб:   https://$Name.$($cfg.sub)" }
if ($RdpPort -le 0 -and $SshPort -le 0 -and $VncPort -le 0 -and $HttpPort -le 0) {
    Write-Host "   ничего не опубликовано — см. предупреждение выше"
}
Write-Host ""
Write-Host " Лог агента: $LogFile"
Write-Host " Состояние:  Get-ScheduledTask gatelink-agent"
Write-Host "──────────────────────────────────────────────────────────────────────────"
