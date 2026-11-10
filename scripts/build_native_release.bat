@echo off
setlocal enabledelayedexpansion

set "ROOT=%~dp0.."
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "%VSWHERE%" (
    echo vswhere.exe not found.
    exit /b 1
)

set "VSPATH="
for /f "usebackq tokens=*" %%i in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VSPATH=%%i"
if "%VSPATH%"=="" (
    echo Visual Studio with MSVC tools not found.
    exit /b 1
)

set "CMAKE=%VSPATH%\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"
if not exist "%CMAKE%" (
    echo CMake not found in Visual Studio installation.
    exit /b 1
)

set "BUILD_DIR=%ROOT%\out\build\windows\release"

powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\scripts\ensure_deps.ps1"
if errorlevel 1 exit /b 1

"%CMAKE%" -S "%ROOT%" -B "%BUILD_DIR%" -G "Visual Studio 17 2022" -A x64 -DGODOTCPP_TARGET=template_release
if errorlevel 1 exit /b 1

"%CMAKE%" --build "%BUILD_DIR%" --config Release --parallel
if errorlevel 1 exit /b 1

set "SRC=%BUILD_DIR%\Release\leanclr_godot.dll"
if not exist "%SRC%" (
    echo Missing build output: %SRC%
    exit /b 1
)
if not exist "%ROOT%\out\bin\windows" mkdir "%ROOT%\out\bin\windows"
copy /Y "%SRC%" "%ROOT%\out\bin\windows\leanclr_godot.release.dll" >nul
if errorlevel 1 exit /b 1

powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\scripts\deploy_native.ps1" -Platform windows -Configuration Release
if errorlevel 1 exit /b 1

echo Build completed: out\build\windows\release to godot_project\bin\leanclr_godot.release.dll
exit /b 0
