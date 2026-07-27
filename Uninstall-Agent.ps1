<#
.SYNOPSIS
    kalitka: полное удаление агента с этого компьютера (Windows).

.DESCRIPTION
    Снимает задачу планировщика, останавливает процесс и стирает всё, что
    положил установщик: frpc.exe, конфигурацию с секретами и логи.

.EXAMPLE
    .\Uninstall-Agent.ps1
    .\Uninstall-Agent.ps1 -DryRun
#>
[CmdletBinding()]
param([switch]$DryRun)

$ErrorActionPreference = 'Continue'

function Say  { param($m) Write-Host "[kalitka] $m" -ForegroundColor Cyan }
function Warn { param($m) Write-Host "[kalitka] $m" -ForegroundColor Yellow }

if ($DryRun) { Say "пробный запуск, ничего не удаляю" }

function Drop {
    param([string]$Path)
    if (Test-Path $Path) {
        if ($DryRun) { Write-Host "   would remove: $Path" }
        else {
            Remove-Item -Recurse -Force $Path -ErrorAction SilentlyContinue
            Say "удалено: $Path"
        }
    }
}

# ── задача планировщика ─────────────────────────────────────────────────
if (Get-ScheduledTask -TaskName 'kalitka-agent' -ErrorAction SilentlyContinue) {
    Say "снимаю задачу планировщика kalitka-agent"
    if (-not $DryRun) {
        Stop-ScheduledTask -TaskName 'kalitka-agent' -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName 'kalitka-agent' -Confirm:$false -ErrorAction SilentlyContinue
    }
}

# ── процесс ─────────────────────────────────────────────────────────────
$procs = Get-Process -Name frpc -ErrorAction SilentlyContinue
if ($procs) {
    Say "снимаю процессы frpc ($($procs.Count))"
    if (-not $DryRun) { $procs | Stop-Process -Force -ErrorAction SilentlyContinue }
}

# ── файлы ───────────────────────────────────────────────────────────────
Drop (Join-Path $env:ProgramData 'kalitka')
Drop (Join-Path $env:LOCALAPPDATA 'kalitka')

if (-not $DryRun) {
    Say "агент удалён полностью"
    Write-Host ""
    Write-Host "Осталось необязательное:"
    Write-Host "  * туннели этой машины ещё показаны в панели, пока сервер не заметит"
    Write-Host "    обрыв — уберите их кнопкой «Убрать офлайн-туннели»;"
    Write-Host "  * настройки RDP и sshd не трогались — если включали их ради"
    Write-Host "    доступа, выключите вручную."
}
