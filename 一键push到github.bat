@echo off
setlocal EnableExtensions DisableDelayedExpansion

set "REPO_URL=https://github.com/mxw1589/jiedian.git"
set "REPO_SSH=git@github.com:mxw1589/jiedian.git"
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

set "PUSH_URL="
for /f "delims=" %%U in ('git remote get-url --push --all origin 2^>nul') do (
    if defined PUSH_URL goto :wrong_remote
    if not "%%U"=="%REPO_URL%" if not "%%U"=="%REPO_SSH%" goto :wrong_remote
    set "PUSH_URL=%%U"
)
if not defined PUSH_URL goto :wrong_remote

for /f "delims=" %%P in ('git rev-parse --git-path MERGE_HEAD') do if exist "%%P" (
    echo [ERROR] Finish or abort the current merge before pushing.
    goto :finish
)

echo [1/4] Staging all repository changes...
git add -A -- . || goto :stage_failed

echo [2/4] Committing changes...
git diff --cached --quiet --
if errorlevel 2 goto :stage_failed
if errorlevel 1 (
    git commit -m "Update repository files" || goto :commit_failed
) else (
    echo No new changes to commit.
)

echo [3/4] Synchronizing with GitHub main...
set "GIT_NETWORK_OPTIONS="
git fetch --no-tags "%PUSH_URL%" refs/heads/main && goto :merge_fetched
echo [WARN] Fetch failed. Retrying once...
if "%PUSH_URL%"=="%REPO_URL%" set "GIT_NETWORK_OPTIONS=-c http.version=HTTP/1.1 -c protocol.version=0"
git %GIT_NETWORK_OPTIONS% fetch --no-tags "%PUSH_URL%" refs/heads/main || goto :fetch_failed

:merge_fetched
set "PUSH_OK="
(
    git merge --no-edit --no-overwrite-ignore FETCH_HEAD
    if errorlevel 1 (
        git rev-parse --verify --quiet MERGE_HEAD >nul && (
            git merge --abort || echo [ERROR] Could not abort the merge. Check git status.
        )
        echo [ERROR] Could not merge GitHub main. Local commits are kept. Resolve the Git error and retry.
    ) else (
        echo [4/4] Pushing main to GitHub...
        git %GIT_NETWORK_OPTIONS% push -u origin refs/heads/main:refs/heads/main
        if errorlevel 1 (
            echo [ERROR] Push failed. Local commits are kept; no force push was attempted.
            echo Check the Git output above. If GitHub main changed during the push, run this file again.
        ) else (
            echo [SUCCESS] GitHub main is up to date.
            set "PUSH_OK=1"
        )
    )
    popd
    if /i not "%~1"=="--no-pause" pause
    if defined PUSH_OK exit /b 0
    exit /b 1
)

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

:fetch_failed
echo [ERROR] Could not fetch GitHub main after two attempts. No push was attempted; local commits are kept.
echo If the connection was reset or timed out, check GitHub connectivity and your Git proxy settings, then try again.

:finish
if defined IN_REPO popd
if /i not "%~1"=="--no-pause" pause
exit /b 1
