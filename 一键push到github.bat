@echo off
setlocal EnableExtensions

rem Push only the four project files to the configured GitHub repository.
rem A temporary clone avoids staging unrelated files or secrets from this folder.
set "REPO_URL=https://github.com/mxw1589/jiedian.git"
set "BRANCH=main"
set "SOURCE_DIR=%~dp0"
for %%I in ("%~f0") do set "BAT_NAME=%%~nxI"
set "TEMP_ROOT=%TEMP%\jiedian-github-push-%RANDOM%-%RANDOM%"

where git >nul 2>&1
if errorlevel 1 (
    echo [ERROR] Git was not found. Install Git for Windows and try again.
    goto :failed
)

if not exist "%SOURCE_DIR%README.md" (
    echo [ERROR] Missing project file: README.md
    goto :failed
)
if not exist "%SOURCE_DIR%index.html" (
    echo [ERROR] Missing project file: index.html
    goto :failed
)
if not exist "%SOURCE_DIR%sb-manager-debian-alpine.sh" (
    echo [ERROR] Missing project file: sb-manager-debian-alpine.sh
    goto :failed
)

mkdir "%TEMP_ROOT%" >nul 2>&1
if errorlevel 1 (
    echo [ERROR] Cannot create temporary directory: "%TEMP_ROOT%"
    goto :failed
)

echo.
echo [1/4] Cloning %REPO_URL% (%BRANCH%)...
git clone --branch "%BRANCH%" --single-branch "%REPO_URL%" "%TEMP_ROOT%\repo"
if errorlevel 1 (
    echo [ERROR] Clone failed. Check the repository URL, network, and GitHub sign-in.
    goto :cleanup_failed
)

echo.
echo [2/4] Copying the four project files...
copy /Y "%SOURCE_DIR%README.md" "%TEMP_ROOT%\repo\README.md" >nul || goto :copy_failed
copy /Y "%SOURCE_DIR%index.html" "%TEMP_ROOT%\repo\index.html" >nul || goto :copy_failed
copy /Y "%SOURCE_DIR%sb-manager-debian-alpine.sh" "%TEMP_ROOT%\repo\sb-manager-debian-alpine.sh" >nul || goto :copy_failed
copy /Y "%~f0" "%TEMP_ROOT%\repo\%BAT_NAME%" >nul || goto :copy_failed

echo.
echo [3/4] Preparing a commit...
git -C "%TEMP_ROOT%\repo" add -- README.md index.html sb-manager-debian-alpine.sh "%BAT_NAME%"
if errorlevel 1 goto :git_failed

git -C "%TEMP_ROOT%\repo" diff --cached --quiet
if errorlevel 2 goto :git_failed
if errorlevel 1 (
    git -C "%TEMP_ROOT%\repo" -c core.quotepath=false commit -m "Update sing-box VPS manager"
    if errorlevel 1 (
        echo [ERROR] Commit failed. Configure git user.name and user.email, then retry.
        goto :cleanup_failed
    )
) else (
    echo No file changes detected; nothing to commit.
)

echo.
echo [4/4] Pushing to GitHub...
git -C "%TEMP_ROOT%\repo" push origin "%BRANCH%"
if errorlevel 1 (
    echo [ERROR] Push failed. No force push was attempted; retry after resolving the Git error.
    goto :cleanup_failed
)

echo.
echo [SUCCESS] Project files pushed to %REPO_URL% (%BRANCH%).
echo GitHub Pages: https://mxw1589.github.io/jiedian/
rd /s /q "%TEMP_ROOT%" >nul 2>&1
pause
exit /b 0

:copy_failed
echo [ERROR] Failed to copy a project file.
goto :cleanup_failed

:git_failed
echo [ERROR] Git staging failed. Review the Git output above.
goto :cleanup_failed

:cleanup_failed
if exist "%TEMP_ROOT%" rd /s /q "%TEMP_ROOT%" >nul 2>&1
:failed
echo.
echo Push did not complete. Your source project files were not modified.
pause
exit /b 1
