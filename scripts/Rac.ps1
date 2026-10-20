# Вызовы rac для Lock-Infobase.ps1 и Unlock-Infobase.ps1. Подключается точкой: . .\Rac.ps1

Import-Module (Join-Path $PSScriptRoot 'GitConfigurator.psm1') -Force

function ConvertFrom-RacOutput {
    <# Вывод rac — блоки «ключ : значение», разделённые пустой строкой. Значения в кавычках раскавычиваются. #>
    param([string[]] $Lines)
    $blocks = New-Object System.Collections.Generic.List[object]
    $current = $null
    foreach ($line in $Lines) {
        if (-not $line.Trim()) { if ($current) { $blocks.Add($current); $current = $null }; continue }
        $i = $line.IndexOf(':')
        if ($i -lt 0) { continue }
        if (-not $current) { $current = @{} }
        $value = $line.Substring($i + 1).Trim()
        if ($value.Length -ge 2 -and $value.StartsWith('"') -and $value.EndsWith('"')) { $value = $value.Substring(1, $value.Length - 2) -replace '""', '"' }
        $current[$line.Substring(0, $i).Trim()] = $value
    }
    if ($current) { $blocks.Add($current) }
    # Блоки по одному в конвейер; вызывающий собирает их в массив через @().
    $blocks.ToArray()
}

function Invoke-Rac {
    param([Parameter(Mandatory)] $Ctx, [Parameter(Mandatory)][string[]] $Arguments)
    $prev = [Console]::OutputEncoding
    [Console]::OutputEncoding = [Text.Encoding]::UTF8
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $Ctx.Rac @Arguments $Ctx.Ras 2>&1 | ForEach-Object { "$_" }
        $code = $LASTEXITCODE
    } finally { [Console]::OutputEncoding = $prev }
    if ($code -ne 0) { throw "rac $($Arguments[0..1] -join ' ') завершился с кодом $code`n$($out -join "`n")" }
    ConvertFrom-RacOutput $out
}

function New-RacContext {
    param([string] $Rac, [string] $Ras, [int] $ClusterPort, [string] $ClusterUser, [string] $ClusterPassword,
          [string] $Infobase, [string] $InfobaseUser, [string] $InfobasePassword)
    if (-not $Rac) { $Rac = Find-OneCTool 'rac.exe' }
    $ctx = [pscustomobject]@{ Rac = $Rac; Ras = $Ras; Cluster = $null; ClusterAuth = @(); Infobase = $null; InfobaseAuth = @() }
    if ($ClusterUser) { $ctx.ClusterAuth = @("--cluster-user=$ClusterUser", "--cluster-pwd=$ClusterPassword") }
    if ($InfobaseUser) { $ctx.InfobaseAuth = @("--infobase-user=$InfobaseUser", "--infobase-pwd=$InfobasePassword") }

    $clusters = @(Invoke-Rac $ctx @('cluster', 'list'))
    if ($ClusterPort) { $clusters = @($clusters | Where-Object { $_['port'] -eq "$ClusterPort" }) }
    if (@($clusters).Count -ne 1) { throw "Кластеров найдено: $(@($clusters).Count). Укажите -ClusterPort." }
    $ctx.Cluster = $clusters[0]['cluster']

    $bases = @(Invoke-Rac $ctx (@('infobase', 'summary', 'list', "--cluster=$($ctx.Cluster)") + $ctx.ClusterAuth))
    $found = @($bases | Where-Object { $_['name'] -eq $Infobase })
    if ($found.Count -ne 1) { throw "База «$Infobase» в кластере не найдена." }
    $ctx.Infobase = $found[0]['infobase']
    $ctx
}

function Get-RacInfobaseArgs($Ctx) {
    @("--cluster=$($Ctx.Cluster)") + $Ctx.ClusterAuth + @("--infobase=$($Ctx.Infobase)") + $Ctx.InfobaseAuth
}

function Get-RacSessions($Ctx) {
    @(Invoke-Rac $Ctx (@('session', 'list', "--cluster=$($Ctx.Cluster)") + $Ctx.ClusterAuth + @("--infobase=$($Ctx.Infobase)")))
}
