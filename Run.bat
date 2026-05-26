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
echo     [1]  Measure only          (changes nothing - see where you stand)
echo     [2]  Optimize speed        (apply tweaks + show before/after)
echo     [3]  Optimize + Gaming     (also lowers latency for games/voice)
echo     [4]  Undo / Revert         (restore your previous settings)
echo     [5]  Exit
echo.
set "choice="
set /p "choice=  Type a number and press Enter: "

if "%choice%"=="1" ( %PS%          & goto done )
if "%choice%"=="2" ( %PS% -Apply   & goto done )
if "%choice%"=="3" ( %PS% -Apply -Gaming & goto done )
if "%choice%"=="4" ( %PS% -Revert  & goto done )
if "%choice%"=="5" ( exit /b )
echo.
echo   Please type 1, 2, 3, 4 or 5.
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
