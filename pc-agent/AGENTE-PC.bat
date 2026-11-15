@echo off
title Agente de Limpeza e Performance do PC
cd /d "%~dp0"
:menu
cls
echo ==============================================================
echo    AGENTE DE LIMPEZA E PERFORMANCE DO PC
echo ==============================================================
echo.
echo    1 - Diagnostico (so analisa, nao altera nada)
echo    2 - Simular limpeza (mostra quanto seria liberado)
echo    3 - Limpeza
echo    4 - Otimizacao
echo    5 - COMPLETO (diagnostico + limpeza + otimizacao)
echo    6 - COMPLETO + reparo do Windows (SFC/DISM, demora)
echo    0 - Sair
echo.
set /p op=Escolha uma opcao: 
set "ps=powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Otimizar-PC.ps1""
if "%op%"=="1" %ps% -Modo Diagnostico
if "%op%"=="2" %ps% -Modo Limpeza -Simular
if "%op%"=="3" %ps% -Modo Limpeza
if "%op%"=="4" %ps% -Modo Otimizacao
if "%op%"=="5" %ps% -Modo Completo
if "%op%"=="6" %ps% -Modo Completo -Reparar
if "%op%"=="0" exit /b
goto menu
