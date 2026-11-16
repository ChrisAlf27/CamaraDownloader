@echo off
rem Abre la app desde el codigo fuente (sin instalar). Para usarla normalmente, instalar dist\CamaraDownloader-Setup.exe
start "" powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0src\CamaraDownloader.ps1"
