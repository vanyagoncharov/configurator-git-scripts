<#
.SYNOPSIS
Закрывает вход в серверную базу перед загрузкой конфигурации: проверка сеансов, запрет входа, повторная проверка.

.DESCRIPTION
Пять шагов загрузки в серверную базу (загрузку и возврат делают Import-GitDiff.ps1 и Unlock-Infobase.ps1):
  1. Кто в базе? Есть сеансы — показываем «кто, где, в чём» и выходим, ничего не меняя.
  2. Прежние значения блокировки сначала пишутся в файл, потом вход и регламентные задания запрещаются
     с кодом разрешения.
  3. Ещё раз: кто в базе? Кто-то мог войти между шагами 1 и 2 — тогда блокировка возвращается как была.
  4. Загрузка Конфигуратором с /UC <код> (Import-GitDiff.ps1 -Method Designer -PermissionCode <код>).
  5. Unlock-Infobase.ps1 возвращает всё как было — и при ошибке загрузки тоже.

Работает через rac и сервер администрирования кластера (ras, по умолчанию localhost:1545).

.EXAMPLE
.\Lock-Infobase.ps1 -Infobase test_erp -InfobaseUser Админ -InfobasePassword *** -PermissionCode 4321
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $Infobase,
    [Parameter(Mandatory)][string] $PermissionCode,
    [string] $Ras = 'localhost:1545',
    # Если кластеров несколько — порт менеджера кластера (1541 по умолчанию).
    [int] $ClusterPort,
    [string] $ClusterUser,
    [string] $ClusterPassword,
    [string] $InfobaseUser,
    [string] $InfobasePassword,
    [string] $Message = 'Обновление конфигурации. Вход временно закрыт.',
    # Куда сохранить прежние значения блокировки. Unlock-Infobase.ps1 читает этот же файл.
    [string] $StateFile = (Join-Path $env:LOCALAPPDATA "infobase-locks\$Infobase.json"),
    [string] $Rac
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Rac.ps1')

if (Test-Path $StateFile) {
    throw "Есть незакрытая блокировка от прошлого запуска: $StateFile. Сначала выполните Unlock-Infobase.ps1 -Infobase $Infobase."
}

$ctx = New-RacContext -Rac $Rac -Ras $Ras -ClusterPort $ClusterPort -ClusterUser $ClusterUser -ClusterPassword $ClusterPassword `
    -Infobase $Infobase -InfobaseUser $InfobaseUser -InfobasePassword $InfobasePassword

function Assert-NoSessions([string] $Step) {
    $sessions = @(Get-RacSessions $ctx)
    if ($sessions.Count -eq 0) { Write-Host "$Step в базе никого нет"; return $true }
    Write-Host "$Step в базе $($sessions.Count) сеанс(ов):"
    $sessions | ForEach-Object { Write-Host ("  {0} — {1}, {2}, с {3}" -f $_['user-name'], $_['app-id'], $_['host'], $_['started-at']) }
    return $false
}

if (-not (Assert-NoSessions '1. Проверка сеансов:')) { exit 1 }

$info = @(Invoke-Rac $ctx (@('infobase', 'info') + (Get-RacInfobaseArgs $ctx)))
$previous = [ordered]@{
    Infobase          = $Infobase
    SessionsDeny      = $info[0]['sessions-deny'] -eq 'on'
    ScheduledJobsDeny = $info[0]['scheduled-jobs-deny'] -eq 'on'
    DeniedMessage     = $info[0]['denied-message']
    PermissionCode    = $info[0]['permission-code']
    LockedAt          = (Get-Date).ToString('s')
}
New-Item -ItemType Directory -Path (Split-Path $StateFile) -Force | Out-Null
$previous | ConvertTo-Json | Set-Content $StateFile -Encoding UTF8
Write-Host "2. Прежние значения сохранены: $StateFile"

Invoke-Rac $ctx (@('infobase', 'update') + (Get-RacInfobaseArgs $ctx) + @(
    '--sessions-deny=on', '--scheduled-jobs-deny=on', "--denied-message=$Message", "--permission-code=$PermissionCode")) | Out-Null
Write-Host '   Вход и регламентные задания запрещены.'

if (-not (Assert-NoSessions '3. Повторная проверка:')) {
    Write-Warning 'Кто-то успел войти — возвращаю блокировку как была.'
    & (Join-Path $PSScriptRoot 'Unlock-Infobase.ps1') -Infobase $Infobase -StateFile $StateFile -Ras $Ras -ClusterPort $ClusterPort `
        -ClusterUser $ClusterUser -ClusterPassword $ClusterPassword -InfobaseUser $InfobaseUser -InfobasePassword $InfobasePassword -Rac $ctx.Rac
    exit 1
}
Write-Host "Можно загружать: Import-GitDiff.ps1 -Method Designer -PermissionCode $PermissionCode, затем Unlock-Infobase.ps1."
