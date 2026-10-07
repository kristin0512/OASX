param([switch]$Preview)
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath($PSScriptRoot)
$flavor = if ($Preview) { 'preview' } else { 'release' }
$executable = Join-Path $projectRoot ('dist\' + $flavor + '\oasx.exe')
if (-not (Test-Path -LiteralPath $executable)) { throw 'Build first with dev_tools/build_windows.ps1.' }
$running = @(Get-Process -Name oasx -ErrorAction SilentlyContinue | Where-Object Path -eq $executable)
if ($running.Count -eq 0) {
    Start-Process -FilePath $executable -WorkingDirectory $projectRoot -WindowStyle Hidden
}
