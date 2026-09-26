$ErrorActionPreference = 'Stop'
$installer = Join-Path $PSScriptRoot 'RetoLulu_Instalador.ps1'

if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) {
    Write-Host 'ERROR: Falta RetoLulu_Instalador.ps1.' -ForegroundColor Red
    exit 1
}

& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $installer -Mode Update
exit $LASTEXITCODE
