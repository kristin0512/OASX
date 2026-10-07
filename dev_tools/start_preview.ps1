param([string]$Python = 'python')
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$executable = Join-Path $projectRoot 'dist\preview\oasx.exe'
if (-not (Test-Path -LiteralPath $executable)) { throw 'Build first with dev_tools/build_windows.ps1 -Preview.' }
$pythonExecutable = (Get-Command $Python -ErrorAction Stop).Source
function Test-Demo {
    try {
        $reply = Invoke-RestMethod 'http://127.0.0.1:22391/' -TimeoutSec 2
        return $reply.kind -eq 'oasx-azurtian-preview'
    } catch { return $false }
}
if (-not (Test-Demo)) {
    if (Get-NetTCPConnection -LocalPort 22391 -State Listen -ErrorAction SilentlyContinue) {
        throw 'Preview port is occupied by another service.'
    }
    $logs = Join-Path $projectRoot 'log'
    New-Item -ItemType Directory -Path $logs -Force | Out-Null
    $fixture = Join-Path $PSScriptRoot 'ui_preview_server.py'
    $server = Start-Process -FilePath $pythonExecutable -ArgumentList @('-B', ('"' + $fixture + '"')) `
        -WorkingDirectory $projectRoot -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput (Join-Path $logs 'preview.stdout.log') `
        -RedirectStandardError (Join-Path $logs 'preview.stderr.log')
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        if (Test-Demo) { break }
        Start-Sleep -Milliseconds 250
    }
    if (-not (Test-Demo)) { throw 'Preview service did not start; inspect log/preview.stderr.log.' }
}
& (Join-Path $projectRoot 'Start-OASX.ps1') -Preview
