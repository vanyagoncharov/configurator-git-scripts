<#
.SYNOPSIS
Загружает в файловую базу только то, что изменилось в git между двумя коммитами, и обновляет конфигурацию БД.

.DESCRIPTION
Иллюстрация к статье: какой коммит сейчас в базе, указываете вы (-From). Изменения между -From и -To решают,
какой будет загрузка:
  - изменился Configuration.xml, настройки поддержки, есть удаления, файлов больше порога — полная;
  - иначе частичная, только изменённые файлы (ibcmd config import files --partial).

Только файловые базы: ibcmd config import в серверную базу на 8.3.27 завершается «успешно»,
но оставляет «Нарушена целостность структуры конфигурации».

.EXAMPLE
.\Import-GitDiff.ps1 -Repo D:\repo -DbPath D:\bases\dev -From 3f9c2a11 -WhatIf
Показывает план: что изменилось и будет ли загрузка частичной.

.EXAMPLE
.\Import-GitDiff.ps1 -Repo D:\repo -DbPath D:\bases\dev -From 3f9c2a11
Загружает разницу между 3f9c2a11 и текущим состоянием ветки.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    # Корень git-репозитория.
    [Parameter(Mandatory)][string] $Repo,
    # Файловая база — каталог.
    [Parameter(Mandatory)][string] $DbPath,
    # Коммит, который сейчас загружен в базу.
    [Parameter(Mandatory)][string] $From,
    # Что загружать. По умолчанию — текущее состояние ветки.
    [string] $To = 'HEAD',
    # Каталог XML-выгрузки основной конфигурации внутри репозитория.
    [string] $SourceDir = 'src/cf',
    [int] $Threshold = 300,
    [string] $User,
    [string] $Password,
    # Путь к ibcmd.exe; по умолчанию — самая свежая версия из Program Files\1cv8 (или ONEC_ROOT).
    [string] $Ibcmd
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'GitConfigurator.psm1') -Force

$Repo = (Resolve-Path $Repo).Path
$source = Join-Path $Repo $SourceDir
if (-not (Test-Path (Join-Path $source 'Configuration.xml'))) { throw "В «$source» нет Configuration.xml — это не каталог выгрузки." }

# ibcmd читает файлы с диска, а не из git: рабочая копия должна совпадать с тем, что грузим.
$toCommit = @((Invoke-Git -Repo $Repo -Arguments @('rev-parse', '--verify', "$To^{commit}")).Lines)[0]
$head = @((Invoke-Git -Repo $Repo -Arguments @('rev-parse', 'HEAD')).Lines)[0]
if ($head -ne $toCommit) { throw "Сейчас в каталоге $($head.Substring(0,8)), а грузить нужно $($toCommit.Substring(0,8)). Сначала git checkout." }
$dirty = @((Invoke-Git -Repo $Repo -Arguments @('status', '--porcelain', '--', $SourceDir)).Lines | Where-Object { $_ })
if ($dirty.Count) { Write-Warning "В «$SourceDir» есть незакоммиченные изменения: они тоже попадут в базу." }

$changes = @(Get-ConfigChanges -Repo $Repo -SourceDir $SourceDir -From $From -To $toCommit)
$plan = Get-LoadPlan -Changes $changes -Threshold $Threshold

Write-Host "Из $($From.Substring(0, [Math]::Min(8, $From.Length))) в $($toCommit.Substring(0, 8))"
Write-Host "План: $(@{ Full = 'полная загрузка'; Partial = 'частичная загрузка'; None = 'загружать нечего' }[$plan.Kind]) — $($plan.Reason)"
foreach ($d in $plan.Deleted) { Write-Warning "Удаляется $d" }
if ($plan.Kind -eq 'Partial') {
    $plan.Files | ForEach-Object { ConvertTo-MetadataObject $_ } | Group-Object Object | Sort-Object Name | ForEach-Object {
        Write-Host ("  {0}: {1}" -f $_.Name, (($_.Group | Select-Object -ExpandProperty Part -Unique) -join ', '))
    }
}
if ($plan.Kind -eq 'None' -or -not $PSCmdlet.ShouldProcess($DbPath, $plan.Kind)) { return }

if (-not $Ibcmd) { $Ibcmd = Find-OneCTool 'ibcmd.exe' }
$db = @("--db-path=$DbPath")
if ($User) { $db += "--user=$User" }
if ($Password) { $db += "--password=$Password" }

function Invoke-Ibcmd([string] $Title, [string[]] $Arguments) {
    Write-Host "→ $Title"
    $sw = [Diagnostics.Stopwatch]::StartNew()
    & $Ibcmd @Arguments | ForEach-Object { Write-Host "  $_" }
    $code = $LASTEXITCODE
    Write-Host ("  {0:mm\:ss}, код {1}" -f $sw.Elapsed, $code)
    if ($code -ne 0) { throw "$Title завершилась с кодом $code" }
}

if ($plan.Kind -eq 'Full') {
    Invoke-Ibcmd 'Полная загрузка' (@('config', 'import') + $db + @($source))
} else {
    # Пути — позиционными аргументами (Unicode, кириллица не ломается), пакетами в пределах длины командной строки.
    $batches = New-Object System.Collections.Generic.List[object]
    $batch = New-Object System.Collections.Generic.List[string]
    $length = 0
    foreach ($f in $plan.Files) {
        if ($batch.Count -gt 0 -and $length + $f.Length + 3 -gt 24000) { $batches.Add($batch.ToArray()); $batch.Clear(); $length = 0 }
        $batch.Add($f); $length += $f.Length + 3
    }
    if ($batch.Count -gt 0) { $batches.Add($batch.ToArray()) }
    $i = 0
    foreach ($b in $batches) {
        $i++
        $title = if ($batches.Count -gt 1) { "Частичная загрузка, пакет $i из $($batches.Count)" } else { 'Частичная загрузка' }
        Invoke-Ibcmd $title (@('config', 'import', 'files') + $db + @("--base-dir=$source", '--partial') + $b)
    }
}
Invoke-Ibcmd 'Обновление конфигурации базы данных' (@('config', 'apply') + $db + @('--force'))
Write-Host "Готово: в базе $($toCommit.Substring(0, 8))."
