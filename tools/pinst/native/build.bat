@echo off
rem Builds pinst_fast.dll beside this file with the Visual Studio build tools.
setlocal enabledelayedexpansion
set "VSW=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
for /f "usebackq delims=" %%i in (`"!VSW!" -latest -products * -property installationPath`) do set "VS=%%i"
call "!VS!\VC\Auxiliary\Build\vcvars64.bat" >nul
cd /d "%~dp0"
cl /nologo /O2 /fp:precise /LD ampfast.c codecfast.c memfast.c metricfast.c /Fe:pinst_fast.dll
del ampfast.obj codecfast.obj memfast.obj metricfast.obj pinst_fast.lib pinst_fast.exp 2>nul
