param([switch]$Preview, [string]$Flutter = 'flutter')
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$command = Get-Command $Flutter -ErrorAction Stop
$flutterExecutable = $command.Source
$flavor = if ($Preview) { 'preview' } else { 'release' }
$output = Join-Path $projectRoot ('dist\' + $flavor)
$executable = Join-Path $output 'oasx.exe'
$running = @(Get-Process -Name oasx -ErrorAction SilentlyContinue | Where-Object Path -eq $executable)
if ($running.Count -gt 0) { throw "Close $executable before replacing this build." }
Push-Location $projectRoot
try {
    & $flutterExecutable pub get --enforce-lockfile
    if ($LASTEXITCODE -ne 0) { throw 'Flutter dependency restore failed.' }
    $previewDefine = 'OASX_PREVIEW=' + $Preview.IsPresent.ToString().ToLowerInvariant()
    & $flutterExecutable build windows --release --no-pub "--dart-define=$previewDefine"
    if ($LASTEXITCODE -ne 0) { throw 'Flutter Windows build failed.' }
    $release = Join-Path $projectRoot 'build\windows\x64\runner\Release'
    if (-not (Test-Path -LiteralPath $release)) {
        $release = Join-Path $projectRoot 'build\windows\runner\Release'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $release 'oasx.exe'))) { throw 'Flutter release output is missing.' }
    New-Item -ItemType Directory -Path $output -Force | Out-Null
    Get-ChildItem -LiteralPath $release | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $output -Recurse -Force
    }
    Write-Output "Built $executable"
} finally { Pop-Location }
