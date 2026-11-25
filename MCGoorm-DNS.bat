@echo off
setlocal DisableDelayedExpansion
set "MCGOORM_FILE=%~f0"
set "MCGOORM_ACTION=%~1"
if not "%~2"=="" goto usage
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -Command "$body=([IO.File]::ReadAllText($env:MCGOORM_FILE) -split '(?m)^:MCGOORM_PS\r?$')[1]; $result = & ([scriptblock]::Create($body)) -FilePath $env:MCGOORM_FILE -Action $env:MCGOORM_ACTION; exit [int]$result"
exit /b %ERRORLEVEL%
:usage
echo Usage: MCGoorm-DNS.bat [ /install ^| /check ^| /remove ]
exit /b 2

:MCGOORM_PS
param([string]$FilePath, [string]$Action, [switch]$KeepOpen)

$ErrorActionPreference = 'Stop'
$domain = 'www.mcgoorm.com'
$server = '192.168.0.245'
$ruleTitle = 'MCGoorm classroom DNS'
$ownerTag = 'Managed by MCGoorm-DNS.bat (leap97/llm_project)'
$pauseAtEnd = $KeepOpen -or [string]::IsNullOrEmpty($Action)
if ([string]::IsNullOrEmpty($Action)) { $Action = '/install' }

function Test-ExactName($rule) {
    foreach ($name in $rule.Namespace) {
        if ($name -and $name.TrimEnd('.') -eq $domain) { return $true }
    }
    return $false
}

function Test-Server($rule) {
    $servers = @(($rule.NameServers -join ' ') -split '[,;\s]+' | Where-Object { $_ })
    return ($servers.Count -eq 1 -and $servers[0] -eq $server)
}

function Test-OurRule($rule) {
    return ($rule.DisplayName -eq $ruleTitle -and $rule.Comment -eq $ownerTag -and
            @($rule.Namespace).Count -eq 1 -and (Test-ExactName $rule) -and (Test-Server $rule))
}

function Get-EffectiveRules {
    Get-DnsClientNrptPolicy -Effective | Where-Object { Test-ExactName $_ }
}

function Assert-Policy($rules) {
    if (@($rules).Count -eq 0) { throw "$domain 전용 유효 DNS 규칙을 찾지 못했습니다. PC의 그룹 정책을 확인하세요." }
    foreach ($rule in $rules) {
        if (!(Test-Server $rule)) { throw "$domain 전용 규칙이 다른 DNS 서버를 지정합니다. 기존 설정을 확인하세요." }
    }
}

function Test-Resolution {
    Assert-Policy @(Get-EffectiveRules)
    Write-Host "[확인] Windows 유효 DNS 정책  $domain -> $server"
    foreach ($mode in 'Kali 직접 조회', 'Windows 기본 조회') {
        $options = @{ Name = $domain; Type = 'A'; DnsOnly = $true; QuickTimeout = $true }
        if ($mode -eq 'Kali 직접 조회') {
            $options.Server = $server
            $options.NoHostsFile = $true
        }
        try {
            $addresses = @(Resolve-DnsName @options |
                Where-Object { $_.Type -eq 'A' -and $_.Section -eq 'Answer' } |
                Select-Object -ExpandProperty IPAddress -Unique)
        } catch {
            throw "$mode 실패. 학원망 연결 및 Kali DNS 서비스를 확인하세요. $($_.Exception.Message)"
        }
        if ($addresses.Count -ne 1 -or $addresses[0] -ne $server) {
            throw "$mode 결과가 예상과 다릅니다. 기대값 $server, 응답 [$($addresses -join ', ')]."
        }
        Write-Host "[확인] $mode  $domain -> $($addresses[0])"
    }
}

function Start-Elevated {
    # EncodedCommand carries a quoted Unicode path across UAC, including spaces.
    $quotedPath = $FilePath.Replace("'", "''")
    $pauseOption = if ($pauseAtEnd) { ' -KeepOpen' } else { '' }
    $bootstrap = @"
`$body = ([IO.File]::ReadAllText('$quotedPath') -split '(?m)^:MCGOORM_PS\r?$')[1]
`$result = & ([scriptblock]::Create(`$body)) -FilePath '$quotedPath' -Action '$Action'$pauseOption
exit [int]`$result
"@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap))
    $child = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -Verb RunAs -Wait -PassThru -ArgumentList @(
        '-NoLogo', '-NoProfile', '-EncodedCommand', $encoded)
    return $child.ExitCode
}

$mutex = $null
$locked = $false
try {
    if ($Action -notin '/install', '/check', '/remove') {
        Write-Host '사용법  MCGoorm-DNS.bat [ /install | /check | /remove ]'
        return 2
    }
    if ($Action -eq '/check') { Test-Resolution; return 0 }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (!$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host 'Windows 관리자 권한 확인 창이 열립니다.'
        $result = Start-Elevated
        $pauseAtEnd = $false
        return $result
    }

    $mutex = [Threading.Mutex]::new($false, 'Global\MCGoorm-DNS-NRPT')
    try { $locked = $mutex.WaitOne(5000) }
    catch [Threading.AbandonedMutexException] { $locked = $true }
    if (!$locked) { throw '다른 MCGoorm DNS 작업이 진행 중입니다. 완료 후 다시 실행하세요.' }
    $local = @(Get-DnsClientNrptRule | Where-Object { Test-ExactName $_ })
    if ($Action -eq '/remove') {
        $owned = @($local | Where-Object { Test-OurRule $_ })
        if ($owned.Count -eq 0) { Write-Host '이 파일로 설치한 규칙이 없습니다.'; return 0 }
        foreach ($rule in $owned) { Remove-DnsClientNrptRule -Name $rule.Name -Force }
        if (@(Get-DnsClientNrptRule | Where-Object { Test-OurRule $_ }).Count -ne 0) {
            throw '규칙 제거가 반영되지 않았습니다.'
        }
        Clear-DnsClientCache
        Write-Host "[완료] 이 파일로 설치한 $domain 규칙을 제거했습니다."
        return 0
    }

    $effective = @(Get-EffectiveRules)
    foreach ($rule in @($local + $effective)) {
        if (!(Test-Server $rule)) { throw "$domain 에 다른 DNS가 이미 지정되어 있어 설치를 중단했습니다." }
    }
    if ($local.Count -eq 0 -and $effective.Count -eq 0) {
        Add-DnsClientNrptRule -Namespace $domain -NameServers $server -DisplayName $ruleTitle -Comment $ownerTag
        Clear-DnsClientCache
        Write-Host "[설치] $domain 전용 로컬 DNS 규칙을 추가했습니다."
    } else {
        Write-Host '기존에 같은 주소를 지정하는 규칙이 있어 이를 사용합니다.'
    }
    try { Test-Resolution }
    catch {
        Write-Host '로컬 규칙은 추가되었거나 기존 규칙을 사용 중입니다. DNS 검증을 마치지 못했습니다.'
        Write-Host '학원망 연결과 Kali DNS를 확인한 뒤 MCGoorm-DNS.bat /check 를 실행하세요.'
        throw
    }
    return 0
} catch {
    Write-Host "[오류] $($_.Exception.Message)" -ForegroundColor Red
    return 1
} finally {
    if ($locked) { $mutex.ReleaseMutex() }
    if ($mutex) { $mutex.Dispose() }
    if ($pauseAtEnd) { [void](Read-Host 'Enter 키를 누르면 창을 닫습니다') }
}
