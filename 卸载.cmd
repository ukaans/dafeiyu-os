@echo off
chcp 65001 >nul
echo Uninstall Big Fish Desktop System (files kept; add -Purge to delete)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1" %*
echo.
pause >nul
