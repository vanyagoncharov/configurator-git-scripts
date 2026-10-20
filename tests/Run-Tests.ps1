<#
.SYNOPSIS
Проверки без платформы 1С: план загрузки, перевод путей в объекты, изменения между коммитами на настоящем git.
Запуск: powershell -File tests\Run-Tests.ps1
#>
$ErrorActionPreference = 'Stop'
$scripts = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts'
Import-Module (Join-Path $scripts 'GitConfigurator.psm1') -Force

$failed = 0
function Check([string] $Name, $Actual, $Expected) {
    if ("$Actual" -ceq "$Expected") { Write-Host "ok   $Name" }
    else { Write-Host "FAIL $Name`n     ожидалось: $Expected`n     получено:  $Actual" -ForegroundColor Red; $script:failed++ }
}
function C([string] $Status, [string] $Path) { [pscustomobject]@{ Status = $Status; Path = $Path } }

# --- путь → объект
Check 'форма документа' ((ConvertTo-MetadataObject 'Documents/ЧекККМ/Forms/ФормаДокумента/Ext/Form.xml') | ForEach-Object { "$($_.Object) / $($_.Part)" }) 'Документ.ЧекККМ / форма ФормаДокумента'
Check 'модуль менеджера' ((ConvertTo-MetadataObject 'Catalogs/КартыЛояльности/Ext/ManagerModule.bsl').Part) 'модуль менеджера'
Check 'общий модуль' ((ConvertTo-MetadataObject 'CommonModules/Скидки/Ext/Module.bsl').Object) 'ОбщийМодуль.Скидки'
Check 'описание объекта' ((ConvertTo-MetadataObject 'Catalogs/Товары.xml') | ForEach-Object { "$($_.Object) / $($_.Part)" }) 'Справочник.Товары / описание'
Check 'корень' ((ConvertTo-MetadataObject 'Configuration.xml').Object) 'Конфигурация'

# --- план загрузки
Check 'нет коммита' (Get-LoadPlan -Changes $null).Kind 'Full'
Check 'нет изменений' (Get-LoadPlan -Changes @(C 'M' 'ConfigDumpInfo.xml')).Kind 'None'
Check 'модуль — частичная' (Get-LoadPlan -Changes @(C 'M' 'CommonModules/Скидки/Ext/Module.bsl')).Kind 'Partial'
Check 'Configuration.xml — полная' (Get-LoadPlan -Changes @(C 'M' 'Configuration.xml'), (C 'M' 'Catalogs/Товары.xml')).Reason 'изменился Configuration.xml'
Check 'поддержка — полная' (Get-LoadPlan -Changes @(C 'M' 'Ext/ParentConfigurations.bin')).Reason 'изменились настройки поддержки'
$del = Get-LoadPlan -Changes @((C 'D' 'CommonModules/Старый.xml'), (C 'D' 'CommonModules/Старый/Ext/Module.bsl'))
Check 'удаление — полная' $del.Reason 'удалены файлы'
Check 'удаление — какой объект' ($del.Deleted -join ',') 'ОбщийМодуль.Старый'
$many = 1..301 | ForEach-Object { C 'M' "CommonModules/М$_/Ext/Module.bsl" }
Check 'больше порога — полная' (Get-LoadPlan -Changes $many -Threshold 300).Kind 'Full'

# --- git: изменения между коммитами на временном репозитории
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("cgs-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$work = "$tmp\work"
function G { $r = Invoke-Git -Repo $work -Arguments $args; $r.Lines }
function Put([string] $Rel, [string] $Text) {
    $p = Join-Path "$work\src\cf" $Rel
    New-Item -ItemType Directory -Path (Split-Path $p) -Force | Out-Null
    [IO.File]::WriteAllText($p, $Text, (New-Object Text.UTF8Encoding $false))
}
try {
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    & git init -q -b develop $work
    G config core.autocrlf false | Out-Null; G config user.name test | Out-Null; G config user.email test@example.com | Out-Null
    Put 'Configuration.xml' '<cfg/>'
    Put 'Documents/ЧекККМ/Ext/ObjectModule.bsl' "строка 1`nстрока 2`nстрока 3`n"
    Put 'Documents/ЧекККМ/Forms/ФормаДокумента/Ext/Form.xml' "<form/>`n"
    Put 'Catalogs/Товары/Ext/ManagerModule.bsl' "а`n"
    G add -A | Out-Null; G commit -qm 'база' | Out-Null
    $base = @(G rev-parse HEAD)[0]

    G checkout -qb feature/121 | Out-Null
    Put 'Documents/ЧекККМ/Ext/ObjectModule.bsl' "строка 1 — 121`nстрока 2`nстрока 3`n"
    G commit -qam '#121' | Out-Null
    Check 'изменения ветки' ((Get-ConfigChanges -Repo $work -SourceDir 'src/cf' -From $base -To HEAD | ForEach-Object { "$($_.Status) $($_.Path)" }) -join ';') 'M Documents/ЧекККМ/Ext/ObjectModule.bsl'

} finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

if ($failed) { Write-Host "Провалено: $failed" -ForegroundColor Red; exit 1 }
Write-Host 'Все проверки прошли.'
