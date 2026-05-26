@echo off
setlocal
title Internet Optimizer

:: ── Auto-elevate to Administrator ────────────────────────────────────────────
net session >nul 2>&1
if %errorlevel% neq 0 (
  echo Requesting Administrator access...
  powershell -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)

cd /d "%~dp0"
set "PS=powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Optimize-Internet.ps1""

:menu
cls
echo ============================================
echo            INTERNET OPTIMIZER
echo ============================================
echo.
echo   What do you want to do?
echo.
echo     [1]  AUTO  (recommended)    read speed, find problems, fix only those, re-test
echo     [2]  Measure only          (changes nothing - just see where you stand)
echo     [3]  Optimize ALL          (apply every tweak, not just the broken ones)
echo     [4]  Optimize ALL + Gaming (also lowers latency for games/voice)
echo     [5]  Watchdog (monitor)    log every drop with timestamps (Ctrl+C to stop)
echo     [6]  Watchdog + auto-reset (also auto-resets the adapter on a long outage)
echo     [7]  Undo / Revert         (restore your previous settings)
echo     [8]  Exit
echo.
set "choice="
set /p "choice=  Type a number and press Enter: "

if "%choice%"=="1" ( %PS% -Auto   & goto done )
if "%choice%"=="2" ( %PS%         & goto done )
if "%choice%"=="3" ( %PS% -Apply  & goto done )
if "%choice%"=="4" ( %PS% -Apply -Gaming & goto done )
if "%choice%"=="5" ( %PS% -Watch  & goto done )
if "%choice%"=="6" ( %PS% -Watch -AutoReset & goto done )
if "%choice%"=="7" ( %PS% -Revert & goto done )
if "%choice%"=="8" ( exit /b )
echo.
echo   Please type a number from 1 to 8.
timeout /t 2 >nul
goto menu

:done
echo.
echo ============================================
echo   Finished. Read the results above.
echo ============================================
echo.
pause
goto menu
