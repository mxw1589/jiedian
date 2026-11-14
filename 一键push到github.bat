@echo off
setlocal

cd /d "%~dp0"
if errorlevel 1 goto :failed

git rev-parse --is-inside-work-tree >nul 2>&1
if errorlevel 1 goto :failed

git add -A -- .
if errorlevel 1 goto :failed

git diff --cached --quiet -- .
if errorlevel 2 goto :failed
if errorlevel 1 (
    git commit -m "Update files" -- .
    if errorlevel 1 goto :failed
)

git pull --rebase origin main
if errorlevel 1 goto :failed

git push -u origin main
if errorlevel 1 goto :failed

echo Done.
exit /b 0

:failed
echo Upload failed. Check the Git error above.
exit /b 1
