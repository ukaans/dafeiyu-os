@echo off
chcp 65001 >nul
echo ============================================
echo  Big Fish Desktop System - Install
echo ============================================
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
echo.
echo Done. Press any key to close.
pause >nul
