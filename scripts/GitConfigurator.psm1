# Общие функции скриптов: изменения между коммитами, план загрузки, перевод путей выгрузки в объекты метаданных, поиск утилит платформы.
# Windows PowerShell 5.1 и PowerShell 7. Файл в UTF-8 с BOM: иначе 5.1 читает кириллицу в ANSI.

Set-StrictMode -Version 2.0

# Каталог выгрузки → тип объекта метаданных (как в дереве Конфигуратора).
$script:MetadataTypes = @{
    'AccountingRegisters'         = 'РегистрБухгалтерии'
    'AccumulationRegisters'       = 'РегистрНакопления'
    'BusinessProcesses'           = 'БизнесПроцесс'
    'CalculationRegisters'        = 'РегистрРасчета'
    'Catalogs'                    = 'Справочник'
    'ChartsOfAccounts'            = 'ПланСчетов'
    'ChartsOfCalculationTypes'    = 'ПланВидовРасчета'
    'ChartsOfCharacteristicTypes' = 'ПланВидовХарактеристик'
    'CommandGroups'               = 'ГруппаКоманд'
    'CommonAttributes'            = 'ОбщийРеквизит'
    'CommonCommands'              = 'ОбщаяКоманда'
    'CommonForms'                 = 'ОбщаяФорма'
    'CommonModules'               = 'ОбщийМодуль'
    'CommonPictures'              = 'ОбщаяКартинка'
    'CommonTemplates'             = 'ОбщийМакет'
    'Constants'                   = 'Константа'
    'DataProcessors'              = 'Обработка'
    'DefinedTypes'                = 'ОпределяемыйТип'
    'DocumentJournals'            = 'ЖурналДокументов'
    'DocumentNumerators'          = 'НумераторДокументов'
    'Documents'                   = 'Документ'
    'Enums'                       = 'Перечисление'
    'EventSubscriptions'          = 'ПодпискаНаСобытие'
    'ExchangePlans'               = 'ПланОбмена'
    'ExternalDataSources'         = 'ВнешнийИсточникДанных'
    'FilterCriteria'              = 'КритерийОтбора'
    'FunctionalOptions'           = 'ФункциональнаяОпция'
    'FunctionalOptionsParameters' = 'ПараметрФункциональныхОпций'
    'HTTPServices'                = 'HTTPСервис'
    'InformationRegisters'        = 'РегистрСведений'
    'IntegrationServices'         = 'СервисИнтеграции'
    'Languages'                   = 'Язык'
    'Reports'                     = 'Отчет'
    'Roles'                       = 'Роль'
    'ScheduledJobs'               = 'РегламентноеЗадание'
    'Sequences'                   = 'Последовательность'
    'SessionParameters'           = 'ПараметрСеанса'
    'SettingsStorages'            = 'ХранилищеНастроек'
    'StyleItems'                  = 'ЭлементСтиля'
    'Styles'                      = 'Стиль'
    'Subsystems'                  = 'Подсистема'
    'Tasks'                       = 'Задача'
    'WebServices'                 = 'WebСервис'
    'WSReferences'                = 'WSСсылка'
    'XDTOPackages'                = 'ПакетXDTO'
}

$script:ModuleKinds = @{
    'ObjectModule.bsl'         = 'модуль объекта'
    'ManagerModule.bsl'        = 'модуль менеджера'
    'RecordSetModule.bsl'      = 'модуль набора записей'
    'ValueManagerModule.bsl'   = 'модуль менеджера значения'
    'CommandModule.bsl'        = 'модуль команды'
    'Module.bsl'               = 'модуль'
}

function Invoke-Git {
    <# git с путями «как есть» (без восьмеричного экранирования кириллицы) и выводом в UTF-8. #>
    param([Parameter(Mandatory)][string] $Repo, [Parameter(Mandatory)][string[]] $Arguments, [switch] $AllowFail)
    $prev = [Console]::OutputEncoding
    [Console]::OutputEncoding = [Text.Encoding]::UTF8
    # Предупреждения git идут в stderr; в Windows PowerShell 5.1 при Stop они стали бы исключениями.
    $ErrorActionPreference = 'Continue'
    try {
        $out = & git -C $Repo -c core.quotepath=off -c i18n.logOutputEncoding=utf-8 @Arguments 2>&1
        $code = $LASTEXITCODE
    } finally {
        [Console]::OutputEncoding = $prev
    }
    $lines = @($out | ForEach-Object { "$_" })
    if ($code -ne 0 -and -not $AllowFail) {
        throw "git $($Arguments -join ' ') завершился с кодом $code`n$($lines -join "`n")"
    }
    [pscustomobject]@{ ExitCode = $code; Lines = $lines }
}

function Get-ConfigChanges {
    <#
    Изменения выгрузки между коммитами: [pscustomobject]@{ Status = 'M'|'A'|'D'; Path = путь относительно каталога выгрузки }.
    Переименования не склеиваются (--no-renames): для 1С это удаление старого объекта и появление нового.
    #>
    param(
        [Parameter(Mandatory)][string] $Repo,
        [Parameter(Mandatory)][string] $SourceDir,
        [Parameter(Mandatory)][string] $From,
        [string] $To = 'HEAD'
    )
    $prefix = ($SourceDir -replace '\\', '/').Trim('/')
    $r = Invoke-Git -Repo $Repo -Arguments @('diff', '--name-status', '--no-renames', $From, $To, '--', $prefix)
    foreach ($line in $r.Lines) {
        if (-not $line) { continue }
        $parts = $line -split "`t"
        $path = $parts[-1]
        if ($prefix -and $path.StartsWith("$prefix/")) { $path = $path.Substring($prefix.Length + 1) }
        [pscustomobject]@{ Status = $parts[0].Substring(0, 1); Path = $path }
    }
}

function Test-IgnoredPath {
    # ConfigDumpInfo.xml у каждой базы свой и в git не хранится; служебные файлы git к конфигурации не относятся.
    param([string] $Path)
    $name = Split-Path $Path -Leaf
    return $name -eq 'ConfigDumpInfo.xml' -or $name -like '.git*'
}

function Get-LoadPlan {
    <#
    Решает, можно ли загрузить в базу только изменённые файлы. Правила по порядку:
    нет известного загруженного коммита, изменился Configuration.xml, изменились настройки поддержки,
    есть удаления, файлов больше порога — полная загрузка; иначе частичная.
    #>
    param(
        [AllowNull()][object[]] $Changes,
        [int] $Threshold = 300
    )
    if ($null -eq $Changes) {
        return [pscustomobject]@{ Kind = 'Full'; Reason = 'в базу ещё не загружался известный коммит'; Files = @(); Deleted = @() }
    }
    $relevant = @($Changes | Where-Object { -not (Test-IgnoredPath $_.Path) })
    if ($relevant.Count -eq 0) {
        return [pscustomobject]@{ Kind = 'None'; Reason = 'изменений нет'; Files = @(); Deleted = @() }
    }
    $deleted = @($relevant | Where-Object { $_.Status -eq 'D' -and ($_.Path -split '/').Count -eq 2 -and $_.Path -like '*.xml' } |
        ForEach-Object { ConvertTo-MetadataObject $_.Path } | Select-Object -ExpandProperty Object -Unique)

    $full = $null
    if ($relevant | Where-Object { $_.Path -eq 'Configuration.xml' }) { $full = 'изменился Configuration.xml' }
    elseif ($relevant | Where-Object { $_.Path -like '*ParentConfigurations*' }) { $full = 'изменились настройки поддержки' }
    elseif ($relevant | Where-Object { $_.Status -eq 'D' }) { $full = 'удалены файлы' }
    elseif ($relevant.Count -gt $Threshold) { $full = "изменено $($relevant.Count) файлов (порог $Threshold)" }

    if ($full) { return [pscustomobject]@{ Kind = 'Full'; Reason = $full; Files = @(); Deleted = $deleted } }
    [pscustomobject]@{
        Kind    = 'Partial'
        Reason  = "изменено файлов: $($relevant.Count)"
        Files   = @($relevant | Select-Object -ExpandProperty Path)
        Deleted = @()
    }
}

function ConvertTo-MetadataObject {
    <#
    Путь файла выгрузки → объект метаданных и что в нём изменилось:
    Documents/ЧекККМ/Forms/ФормаДокумента/Ext/Form.xml → Документ.ЧекККМ, «форма ФормаДокумента».
    #>
    param([Parameter(Mandatory)][string] $Path)
    $p = ($Path -replace '\\', '/').Split('/')
    if ($p.Count -lt 2 -or -not $script:MetadataTypes.ContainsKey($p[0])) {
        return [pscustomobject]@{ Object = 'Конфигурация'; Part = $Path }
    }
    $name = $p[1] -replace '\.xml$', ''
    $object = "$($script:MetadataTypes[$p[0]]).$name"
    $part = 'описание'
    if ($p.Count -ge 4 -and $p[2] -eq 'Forms') { $part = "форма $($p[3] -replace '\.xml$', '')" }
    elseif ($p.Count -ge 4 -and $p[2] -eq 'Templates') { $part = "макет $($p[3] -replace '\.xml$', '')" }
    elseif ($p.Count -ge 4 -and $p[2] -eq 'Commands') { $part = "команда $($p[3])" }
    elseif ($p.Count -ge 4 -and $p[2] -eq 'Ext' -and $script:ModuleKinds.ContainsKey($p[-1])) { $part = $script:ModuleKinds[$p[-1]] }
    elseif ($p.Count -ge 3 -and $p[2] -eq 'Ext') { $part = $p[-1] }
    [pscustomobject]@{ Object = $object; Part = $part }
}

function Find-OneCTool {
    <# Самый свежий ibcmd.exe / 1cv8.exe / rac.exe из стандартных каталогов установки платформы. #>
    param([Parameter(Mandatory)][string] $Name, [string] $Version)
    # ONEC_ROOT — каталог установки, если платформа стоит не в Program Files (например, E:\Programs\1C\1cv8).
    $roots = @($env:ONEC_ROOT, "$env:ProgramFiles\1cv8", "${env:ProgramFiles(x86)}\1cv8") | Where-Object { $_ -and (Test-Path $_) }
    $found = foreach ($root in $roots) {
        Get-ChildItem -Path $root -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^\d+\.\d+\.\d+\.\d+$' -and (-not $Version -or $_.Name -eq $Version) } |
            ForEach-Object { Join-Path $_.FullName "bin\$Name" } | Where-Object { Test-Path $_ }
    }
    $best = $found | Sort-Object { [version](Split-Path (Split-Path (Split-Path $_ -Parent) -Parent) -Leaf) } -Descending | Select-Object -First 1
    if (-not $best) { throw "Не найден $Name в «Program Files\1cv8». Укажите путь параметром или задайте ONEC_ROOT." }
    $best
}

Export-ModuleMember -Function Invoke-Git, Get-ConfigChanges, Get-LoadPlan, ConvertTo-MetadataObject, Find-OneCTool, Test-IgnoredPath
