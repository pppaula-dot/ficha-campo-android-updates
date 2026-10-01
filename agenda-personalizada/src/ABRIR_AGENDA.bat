@echo off
cd /d "%~dp0"
start "Agenda Personalizada" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0Agenda_Personalizada.ps1"
exit
