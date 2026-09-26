@echo off
setlocal
title Crear build de Reto Lulu
cd /d "%~dp0"

set /p RETOLULU_VERSION=Version nueva (ejemplo 1.0.0):
if "%RETOLULU_VERSION%"=="" exit /b 1

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Crear_Build_RetoLulu.ps1" -Version "%RETOLULU_VERSION%" -Publish
set "RETOLULU_EXIT=%ERRORLEVEL%"

echo.
pause
exit /b %RETOLULU_EXIT%
