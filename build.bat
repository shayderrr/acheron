@echo off
setlocal EnableDelayedExpansion

set "ROOT=%~dp0"
if "%ROOT:~-1%"=="\" set "ROOT=%ROOT:~0,-1%"

set "CONFIG=MinSizeRel"
set "BUILD_DIR=build"
set "QT_VERSION=6.10.2"
set "CURL_IMPERSONATE_VERSION=v2.0.0"
set "FFMPEG_RELEASE_TAG=autobuild-2026-07-31-14-10"
set "FFMPEG_WINDOWS_BUILD=ffmpeg-n8.1.2-34-g9b6c8969e0-win64-lgpl-shared-8.1"
set "FFMPEG_WINDOWS_SHA256=c222a490dde4e7059f45495deef6bfb98dbcacc2b43df5b607546252037aa95c"

if not "%~1"=="" echo Usage: build.bat & exit /b 1

if "!BUILD_DIR:~1,1!"==":" goto :have_abs_builddir
if "!BUILD_DIR:~0,1!"=="\" goto :have_abs_builddir
set "BUILD_DIR=!ROOT!\!BUILD_DIR!"
:have_abs_builddir

set "CURL_IMP_DIR=!ROOT!\curl-impersonate"
set "FFMPEG_DIR=!ROOT!\ffmpeg"

set "MISSING="
set "COUNT=0"
set "NEED_GIT=0"
set "NEED_CMAKE=0"
set "NEED_PYTHON=0"
set "NEED_MSVC=0"
set "NEED_QT=0"
set "NEED_CURLIMP=0"
set "NEED_FFMPEG=0"
set "NEED_SUBMODULES=0"

where git >nul 2>nul
if errorlevel 1 call :add_missing "git" NEED_GIT

where cmake >nul 2>nul
if errorlevel 1 call :add_missing "cmake" NEED_CMAKE

where python >nul 2>nul
if errorlevel 1 call :add_missing "python" NEED_PYTHON

call :check_msvc
call :check_qt

set "CURLIMP_OK=0"
if exist "!CURL_IMP_DIR!\include\curl\curl.h" if exist "!CURL_IMP_DIR!\lib\libcurl-impersonate_imp.lib" set "CURLIMP_OK=1"
if "!CURLIMP_OK!"=="0" call :add_missing "curl-impersonate" NEED_CURLIMP

if not exist "!FFMPEG_DIR!\include\libavcodec\avcodec.h" call :add_missing "ffmpeg" NEED_FFMPEG

if not exist "!ROOT!\vendor\vcpkg\scripts\buildsystems\vcpkg.cmake" call :add_missing "git submodules" NEED_SUBMODULES

if not defined MISSING goto :deps_ok
if "!COUNT!"=="1" echo !MISSING! is not currently installed on your system.
if "!COUNT!"=="1" goto :ask
echo !MISSING! are not currently installed on your system.
:ask
set "INSTALL="
set /p INSTALL=Do you want to continue? [Y/n]
if not defined INSTALL goto :do_install
if /i "!INSTALL!"=="y" goto :do_install
if /i "!INSTALL!"=="yes" goto :do_install
exit /b 1

:do_install
where winget >nul 2>nul
if errorlevel 1 goto :no_winget

if "!NEED_GIT!"=="1" winget install -e --id Git.Git --silent --accept-package-agreements --accept-source-agreements
if "!NEED_CMAKE!"=="1" winget install -e --id Kitware.CMake --silent --accept-package-agreements --accept-source-agreements
if "!NEED_PYTHON!"=="1" winget install -e --id Python.Python.3.12 --silent --accept-package-agreements --accept-source-agreements
if "!NEED_MSVC!"=="1" winget install -e --id Microsoft.VisualStudio.2022.BuildTools --silent --accept-package-agreements --accept-source-agreements --override "--quiet --wait --add Microsoft.VisualStudio.Workload.NativeDesktop --includeRecommended"

set "RECHECK=0"
if "!NEED_GIT!"=="1" where git >nul 2>nul || set "RECHECK=1"
if "!NEED_CMAKE!"=="1" where cmake >nul 2>nul || set "RECHECK=1"
if "!NEED_PYTHON!"=="1" where python >nul 2>nul || set "RECHECK=1"
if "!RECHECK!"=="1" goto :need_restart

call :check_msvc_confirm
if errorlevel 1 goto :need_restart

if "!NEED_QT!"=="1" goto :install_qt
goto :after_qt
:install_qt
python -m pip install --quiet aqtinstall
if errorlevel 1 exit /b 1
pushd "!TEMP!"
python -m aqt install-qt windows desktop !QT_VERSION! win64_msvc2022_64 -m qtimageformats -O "!ROOT!\Qt"
if not errorlevel 1 goto :aqt_ok
popd
exit /b 1
:aqt_ok
popd
set "QT_ROOT_DIR=!ROOT!\Qt\!QT_VERSION!\msvc2022_64"
if not exist "!QT_ROOT_DIR!\bin\qmake.exe" echo Qt install failed. & exit /b 1
:after_qt

if "!NEED_CURLIMP!"=="1" goto :install_curlimp
goto :after_curlimp
:install_curlimp
curl.exe -fSL -o "!TEMP!\libcurl-impersonate.tar.gz" "https://github.com/lexiforest/curl-impersonate/releases/download/!CURL_IMPERSONATE_VERSION!/libcurl-impersonate-!CURL_IMPERSONATE_VERSION!.x86_64-win32.tar.gz"
if errorlevel 1 exit /b 1
if exist "!CURL_IMP_DIR!" rmdir /s /q "!CURL_IMP_DIR!"
mkdir "!CURL_IMP_DIR!"
tar -xzf "!TEMP!\libcurl-impersonate.tar.gz" -C "!CURL_IMP_DIR!"
if errorlevel 1 exit /b 1
del "!TEMP!\libcurl-impersonate.tar.gz"
:after_curlimp

if "!NEED_FFMPEG!"=="1" goto :install_ffmpeg
goto :after_ffmpeg
:install_ffmpeg
curl.exe -fSL -o "!TEMP!\ffmpeg.zip" "https://github.com/BtbN/FFmpeg-Builds/releases/download/!FFMPEG_RELEASE_TAG!/!FFMPEG_WINDOWS_BUILD!.zip"
if errorlevel 1 exit /b 1
set "ACTUAL="
for /f %%H in ('certutil -hashfile "!TEMP!\ffmpeg.zip" SHA256 ^| findstr /r "^[0-9a-f][0-9a-f]*$"') do if not defined ACTUAL set "ACTUAL=%%H"
if /i not "!ACTUAL!"=="!FFMPEG_WINDOWS_SHA256!" echo ffmpeg checksum mismatch. & exit /b 1
if exist "!FFMPEG_DIR!" rmdir /s /q "!FFMPEG_DIR!"
tar -xf "!TEMP!\ffmpeg.zip" -C "!ROOT!"
if errorlevel 1 exit /b 1
set "FFMPEG_INNER="
for /d %%F in ("!ROOT!\ffmpeg-n*") do if not defined FFMPEG_INNER set "FFMPEG_INNER=%%F"
move "!FFMPEG_INNER!" "!FFMPEG_DIR!" >nul
del "!TEMP!\ffmpeg.zip"
:after_ffmpeg

if "!NEED_SUBMODULES!"=="1" git submodule update --init --recursive
if "!NEED_SUBMODULES!"=="1" if errorlevel 1 exit /b 1
if exist "!ROOT!\vendor\vcpkg\vcpkg.exe" goto :vcpkg_done
call "!ROOT!\vendor\vcpkg\bootstrap-vcpkg.bat"
if errorlevel 1 exit /b 1
:vcpkg_done
goto :deps_ok

:deps_ok

call :resolve_qt
if errorlevel 1 exit /b 1
set "PATH=!QT_ROOT_DIR!\bin;!PATH!"

cmake -S "!ROOT!" -B "!BUILD_DIR!" -G "Visual Studio 17 2022" -A x64 "-DCMAKE_BUILD_TYPE=!CONFIG!" -DVCPKG_TARGET_TRIPLET=x64-windows-static-md "-DCMAKE_PREFIX_PATH=!QT_ROOT_DIR!;!FFMPEG_DIR!" "-DCURL_INCLUDE_DIR=!CURL_IMP_DIR!\include" "-DCURL_LIBRARY=!CURL_IMP_DIR!\lib\libcurl-impersonate_imp.lib" -DBUILD_TESTS=ON
if errorlevel 1 exit /b 1

cmake --build "!BUILD_DIR!" --config "!CONFIG!" --parallel
if errorlevel 1 exit /b 1

ctest --test-dir "!BUILD_DIR!" -C "!CONFIG!" --output-on-failure
if errorlevel 1 exit /b 1

:deploy
set "BIN=!BUILD_DIR!\!CONFIG!"
windeployqt --no-translations --no-opengl-sw --no-system-d3d-compiler "!BIN!\acheron.exe"
if errorlevel 1 exit /b 1
copy /y "!CURL_IMP_DIR!\lib\*.dll" "!BIN!\" >nul
del /q "!BIN!\Test*.exe" "!BIN!\*.pdb" "!BIN!\*.lib" "!BIN!\*.exp" 2>nul
rmdir /s /q "!BIN!\styles" 2>nul
rmdir /s /q "!BIN!\generic" 2>nul
for %%F in ("!BIN!\sqldrivers\*.dll") do if /i not "%%~nxF"=="qsqlite.dll" del "%%F" 2>nul

echo Build complete: !BIN!\acheron.exe
exit /b 0

:add_missing
if not defined MISSING goto :add_first
set "MISSING=!MISSING!, %~1"
goto :add_flag
:add_first
set "MISSING=%~1"
:add_flag
if not "%~2"=="" set "%~2=1"
set /a COUNT+=1
exit /b 0

:check_msvc
where cl >nul 2>nul
if not errorlevel 1 exit /b 0
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "!VSWHERE!" goto :msvc_missing
set "VS_PATH="
for /f "delims=" %%V in ('"!VSWHERE!" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2^>nul') do if not defined VS_PATH set "VS_PATH=%%V"
if defined VS_PATH exit /b 0
:msvc_missing
call :add_missing "MSVC Build Tools" NEED_MSVC
exit /b 0

:check_msvc_confirm
where cl >nul 2>nul
if not errorlevel 1 exit /b 0
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "!VSWHERE!" exit /b 1
set "VS_PATH="
for /f "delims=" %%V in ('"!VSWHERE!" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2^>nul') do if not defined VS_PATH set "VS_PATH=%%V"
if defined VS_PATH exit /b 0
exit /b 1

:check_qt
if defined QT_ROOT_DIR if exist "%QT_ROOT_DIR%\bin\qmake.exe" exit /b 0
set "FOUND_QMAKE="
for /f "delims=" %%Q in ('where qmake 2^>nul') do if not defined FOUND_QMAKE set "FOUND_QMAKE=%%Q"
if defined FOUND_QMAKE exit /b 0
for /d %%D in ("!ROOT!\Qt\6.*") do if exist "%%D\msvc2022_64\bin\qmake.exe" exit /b 0
for /d %%D in ("C:\Qt\6.*") do if exist "%%D\msvc2022_64\bin\qmake.exe" exit /b 0
call :add_missing "Qt 6" NEED_QT
exit /b 0

:resolve_qt
if defined QT_ROOT_DIR if exist "%QT_ROOT_DIR%\bin\qmake.exe" exit /b 0
set "QMAKE_PATH="
for /f "delims=" %%Q in ('where qmake 2^>nul') do if not defined QMAKE_PATH set "QMAKE_PATH=%%Q"
if defined QMAKE_PATH goto :qt_from_path
for /d %%D in ("!ROOT!\Qt\6.*") do if exist "%%D\msvc2022_64\bin\qmake.exe" set "QT_ROOT_DIR=%%D\msvc2022_64"
if defined QT_ROOT_DIR if exist "%QT_ROOT_DIR%\bin\qmake.exe" exit /b 0
for /d %%D in ("C:\Qt\6.*") do if exist "%%D\msvc2022_64\bin\qmake.exe" set "QT_ROOT_DIR=%%D\msvc2022_64"
if defined QT_ROOT_DIR if exist "%QT_ROOT_DIR%\bin\qmake.exe" exit /b 0
echo Qt not found. Set QT_ROOT_DIR or re-run build.bat.
exit /b 1
:qt_from_path
for %%B in ("!QMAKE_PATH!\..\..") do set "QT_ROOT_DIR=%%~fB"
if exist "!QT_ROOT_DIR!\bin\qmake.exe" exit /b 0
echo Qt not found. Set QT_ROOT_DIR or re-run build.bat.
exit /b 1

:no_winget
echo winget is required to install dependencies automatically.
exit /b 1

:need_restart
echo Some tools were just installed and are not on PATH in this terminal yet. Close it, open a new one, and re-run build.bat.
exit /b 1
