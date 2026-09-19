@echo off
rem Doppelklick zum Entfernen (fordert Administratorrechte an)
powershell -NoProfile -Command "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','\"%~dp0Install-WGIdleGuard.ps1\"','-Uninstall'"
