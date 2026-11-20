@echo off
setlocal EnableExtensions DisableDelayedExpansion

set "REPO_URL=https://github.com/mxw1589/jiedian.git"
set "REPO_SSH=git@github.com:mxw1589/jiedian.git"
set "RESULT=1"
set "IN_REPO="

where git >nul 2>&1 || (
    echo [ERROR] Install Git for Windows and try again.
    goto :finish
)

pushd "%~dp0" || goto :wrong_repo
set "IN_REPO=1"
if not exist ".git" goto :wrong_repo

set "CURRENT_REF="
for /f "delims=" %%B in ('git symbolic-ref --quiet HEAD') do set "CURRENT_REF=%%B"
if not "%CURRENT_REF%"=="refs/heads/main" (
    echo [ERROR] Switch this checkout to main before pushing.
    goto :finish
)

set "HAS_PUSH_URL="
for /f "delims=" %%U in ('git remote get-url --push --all origin 2^>nul') do (
    if defined HAS_PUSH_URL goto :wrong_remote
    if not "%%U"=="%REPO_URL%" if not "%%U"=="%REPO_SSH%" goto :wrong_remote
    set "HAS_PUSH_URL=1"
)
if not defined HAS_PUSH_URL goto :wrong_remote

for /f "delims=" %%P in ('git rev-parse --git-path MERGE_HEAD') do if exist "%%P" (
    echo [ERROR] Finish or abort the current merge before pushing.
    goto :finish
)

echo [1/3] Staging all repository changes...
git add -A -- . || goto :stage_failed

echo [2/3] Committing changes...
git diff --cached --quiet --
if errorlevel 2 goto :stage_failed
if errorlevel 1 (
    git commit -m "Update repository files" || goto :commit_failed
) else (
    echo No new changes to commit.
)

echo [3/3] Pushing main to GitHub...
git push -u origin refs/heads/main:refs/heads/main || goto :push_failed
echo [SUCCESS] GitHub main is up to date.
set "RESULT=0"
goto :finish

:wrong_repo
echo [ERROR] Run this batch file from the root of the Git checkout.
goto :finish

:wrong_remote
echo [ERROR] The only origin push URL must be %REPO_URL% or %REPO_SSH%.
goto :finish

:stage_failed
echo [ERROR] Could not stage changes. See the Git output above.
goto :finish

:commit_failed
echo [ERROR] Commit failed. Check the Git output and try again.
goto :finish

:push_failed
echo [ERROR] Push failed. Local commits are kept; no force push was attempted.
echo Check network and GitHub permissions. If GitHub main has newer commits, integrate them before retrying.

:finish
if defined IN_REPO popd
if /i not "%~1"=="--no-pause" pause
exit /b %RESULT%
