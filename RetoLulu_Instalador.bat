@echo off
setlocal
title Instalador de Reto Lulu
cd /d "%~dp0"

set "RETOLULU_SCRIPT=%~dp0RetoLulu_Instalador.ps1"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$url='https://raw.githubusercontent.com/tecteccruz-dot/Reto-Lulu/main/RetoLulu_Instalador.ps1'; $tmp=$env:RETOLULU_SCRIPT+'.download'; try { Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $tmp; Move-Item -LiteralPath $tmp -Destination $env:RETOLULU_SCRIPT -Force } catch { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue; if (-not (Test-Path -LiteralPath $env:RETOLULU_SCRIPT)) { Write-Host ('ERROR: No se pudo descargar el instalador. '+$_.Exception.Message) -ForegroundColor Red; exit 1 } }"
if errorlevel 1 goto :finish

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%RETOLULU_SCRIPT%" -Mode Install
set "RETOLULU_EXIT=%ERRORLEVEL%"

:finish
if not defined RETOLULU_EXIT set "RETOLULU_EXIT=%ERRORLEVEL%"
echo.
if not "%RETOLULU_EXIT%"=="0" echo La instalacion no pudo completarse.
pause
exit /b %RETOLULU_EXIT%
