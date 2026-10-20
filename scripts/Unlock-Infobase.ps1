<#
.SYNOPSIS
Возвращает блокировку серверной базы к значениям, сохранённым Lock-Infobase.ps1.

.DESCRIPTION
Запускайте всегда после загрузки — и после успешной, и после упавшей (try/finally в своём сценарии).
Если файл с прежними значениями пережил перезапуск машины, скрипт вернёт блокировку и по нему.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $Infobase,
    [string] $Ras = 'localhost:1545',
    [int] $ClusterPort,
    [string] $ClusterUser,
    [string] $ClusterPassword,
    [string] $InfobaseUser,
    [string] $InfobasePassword,
    [string] $StateFile = (Join-Path $env:LOCALAPPDATA "infobase-locks\$Infobase.json"),
    [string] $Rac
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Rac.ps1')

if (-not (Test-Path $StateFile)) { Write-Host "Сохранённой блокировки нет ($StateFile) — возвращать нечего."; return }
$previous = Get-Content $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json

$ctx = New-RacContext -Rac $Rac -Ras $Ras -ClusterPort $ClusterPort -ClusterUser $ClusterUser -ClusterPassword $ClusterPassword `
    -Infobase $Infobase -InfobaseUser $InfobaseUser -InfobasePassword $InfobasePassword

$update = @('infobase', 'update') + (Get-RacInfobaseArgs $ctx) + @(
    "--sessions-deny=$(if ($previous.SessionsDeny) { 'on' } else { 'off' })",
    "--scheduled-jobs-deny=$(if ($previous.ScheduledJobsDeny) { 'on' } else { 'off' })")
# Пустые прежние сообщение и код не передаём: при снятой блокировке они ни на что не влияют,
# а пустое значение rac может не принять — и база осталась бы закрытой.
if ($previous.DeniedMessage) { $update += "--denied-message=$($previous.DeniedMessage)" }
if ($previous.PermissionCode) { $update += "--permission-code=$($previous.PermissionCode)" }
Invoke-Rac $ctx $update | Out-Null

Remove-Item $StateFile
Write-Host ("Блокировка возвращена: вход {0}, регламентные задания {1}." -f `
    $(if ($previous.SessionsDeny) { 'запрещён' } else { 'разрешён' }), $(if ($previous.ScheduledJobsDeny) { 'запрещены' } else { 'разрешены' }))
