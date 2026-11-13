@echo off
rem Builds p5enc.dll (the PINST5 C encoder) beside this file with the Visual Studio
rem build tools, the same flags as tools\pinst\native\build.bat. Reuses, unedited:
rem   native\trackfast.c (track_assign), native\codecfast.c (keyframes, steer_keys,
rem   st_tracks), p5\native\p5rc.c (the range coder).
rem Usage: build.bat [out.dll]   (default p5enc.dll here)
setlocal enabledelayedexpansion
set "VSW=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
for /f "usebackq delims=" %%i in (`"!VSW!" -latest -products * -property installationPath`) do set "VS=%%i"
call "!VS!\VC\Auxiliary\Build\vcvars64.bat" >nul
cd /d "%~dp0"
set "OUT=%~1"
if "%OUT%"=="" set "OUT=p5enc.dll"
set "OBJ=%TEMP%\p5enc_obj_%RANDOM%"
mkdir "%OBJ%"
cl /nologo /O2 /fp:precise /MD /LD /W3 /Fo"%OBJ%\\" *.c ..\native\trackfast.c ..\native\codecfast.c ..\p5\native\p5rc.c /Fe:"%OUT%" /link /NOIMPLIB /NOEXP
set "RC=%ERRORLEVEL%"
rmdir /s /q "%OBJ%"
exit /b %RC%
