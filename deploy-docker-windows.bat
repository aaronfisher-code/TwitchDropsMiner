@echo off
setlocal EnableExtensions DisableDelayedExpansion

rem Twitch Drops Miner Docker deployment for Windows.
rem This folder is a managed deployment checkout. Do not make edits inside it.

if not defined REPOSITORY_URL set "REPOSITORY_URL=https://github.com/aaronfisher-code/TwitchDropsMiner.git"
if not defined FORK_BRANCH set "FORK_BRANCH=master"
if not defined UPSTREAM_BRANCH set "UPSTREAM_BRANCH=master"
if not defined DEPLOY_DIR if defined WORKSPACE set "DEPLOY_DIR=%WORKSPACE%\TwitchDropsMiner-deploy"
if not defined DEPLOY_DIR set "DEPLOY_DIR=%~dp0TwitchDropsMiner-deploy"

if not defined CONTAINER_NAME set "CONTAINER_NAME=twitch-drops-miner"
if not defined IMAGE_NAME set "IMAGE_NAME=twitch-drops-miner:latest"
if not defined DATA_VOLUME set "DATA_VOLUME=twitch-drops-data"
if not defined BIND_ADDRESS set "BIND_ADDRESS=127.0.0.1"
if not defined WEBUI_PORT set "WEBUI_PORT=18473"
if not defined NOVNC_PORT set "NOVNC_PORT=6080"
if not defined WEBUI_USERNAME set "WEBUI_USERNAME=admin"
if not defined TIMEZONE set "TIMEZONE=Australia/Melbourne"
if not defined TDM_UID set "TDM_UID=1000"
if not defined TDM_GID set "TDM_GID=1000"

rem WEBUI_PASSWORD and VNC_PASSWORD may be set before running this script.
rem Empty passwords are permitted only while both interfaces bind to localhost.
if /I not "%BIND_ADDRESS%"=="127.0.0.1" if /I not "%BIND_ADDRESS%"=="localhost" (
    if not defined WEBUI_PASSWORD goto :missing_passwords
    if not defined VNC_PASSWORD goto :missing_passwords
)

where git >nul 2>&1 || goto :missing_git
where docker >nul 2>&1 || goto :missing_docker
docker version >nul 2>&1 || goto :docker_unavailable

echo.
echo Updating source checkout...
if exist "%DEPLOY_DIR%\.git" goto :update_checkout
if exist "%DEPLOY_DIR%" goto :invalid_checkout

git -c core.autocrlf=false clone --no-tags --single-branch --branch "%FORK_BRANCH%" "%REPOSITORY_URL%" "%DEPLOY_DIR%"
if errorlevel 1 goto :clone_failed
git -C "%DEPLOY_DIR%" config core.autocrlf false
if errorlevel 1 goto :source_failed
goto :checkout_ready

:update_checkout
git -C "%DEPLOY_DIR%" remote set-url origin "%REPOSITORY_URL%"
if errorlevel 1 goto :source_failed
git -C "%DEPLOY_DIR%" config core.autocrlf false
if errorlevel 1 goto :source_failed
git -C "%DEPLOY_DIR%" fetch --prune origin "+refs/heads/%FORK_BRANCH%:refs/remotes/origin/%FORK_BRANCH%"
if errorlevel 1 goto :source_failed
git -C "%DEPLOY_DIR%" checkout --force -B docker-deploy "origin/%FORK_BRANCH%"
if errorlevel 1 goto :source_failed
git -C "%DEPLOY_DIR%" clean -ffdx
if errorlevel 1 goto :source_failed

:checkout_ready
git -C "%DEPLOY_DIR%" remote get-url upstream >nul 2>&1
if errorlevel 1 (
    git -C "%DEPLOY_DIR%" remote add upstream https://github.com/DevilXD/TwitchDropsMiner.git
) else (
    git -C "%DEPLOY_DIR%" remote set-url upstream https://github.com/DevilXD/TwitchDropsMiner.git
)
if errorlevel 1 goto :source_failed

git -C "%DEPLOY_DIR%" fetch --no-tags upstream "+refs/heads/%UPSTREAM_BRANCH%:refs/remotes/upstream/%UPSTREAM_BRANCH%"
if errorlevel 1 goto :upstream_failed
git -C "%DEPLOY_DIR%" -c user.name=Docker-Deploy -c user.email=docker-deploy@localhost merge --no-edit "upstream/%UPSTREAM_BRANCH%"
if errorlevel 1 goto :merge_failed

set "SOURCE_TREE="
for /f "usebackq delims=" %%I in (`git -C "%DEPLOY_DIR%" rev-parse "HEAD^{tree}"`) do set "SOURCE_TREE=%%I"
if not defined SOURCE_TREE goto :source_hash_failed

for %%F in (Dockerfile requirements.txt webui.py webui.html constants.py gui.py inventory.py main.py twitch.py) do (
    if not exist "%DEPLOY_DIR%\%%F" (
        echo ERROR: Required file is missing from your fork: %%F
        goto :failed
    )
)
if not exist "%DEPLOY_DIR%\docker\entrypoint.sh" (
    echo ERROR: Required file is missing from your fork: docker\entrypoint.sh
    goto :failed
)

echo.
echo Building Docker image from source tree %SOURCE_TREE%...
docker build --pull ^
    --build-arg "TDM_UID=%TDM_UID%" ^
    --build-arg "TDM_GID=%TDM_GID%" ^
    --build-arg "SOURCE_TREE=%SOURCE_TREE%" ^
    --tag "%IMAGE_NAME%" ^
    "%DEPLOY_DIR%"
if errorlevel 1 goto :build_failed
echo Docker image built successfully.

echo.
echo Stopping existing Docker container...
docker container inspect "%CONTAINER_NAME%" >nul 2>&1
if errorlevel 1 goto :run_container
docker stop --timeout 30 "%CONTAINER_NAME%"
if errorlevel 1 goto :stop_failed
docker rm "%CONTAINER_NAME%"
if errorlevel 1 goto :remove_failed

:run_container
echo Preparing persistent application data...
for /f "usebackq delims=" %%C in (`docker ps --filter "volume=%DATA_VOLUME%" --format "{{.Names}}"`) do (
    echo ERROR: Docker volume %DATA_VOLUME% is still used by running container %%C.
    echo Stop that container before running this deployment.
    goto :failed
)
docker run --rm --user root --entrypoint /bin/sh ^
    --mount "type=volume,source=%DATA_VOLUME%,target=/data" ^
    "%IMAGE_NAME%" ^
    -c "set -e; install -d /data; chown -R --no-dereference %TDM_UID%:%TDM_GID% /data; rm -f /data/lock.file"
if errorlevel 1 goto :volume_failed

echo Starting replacement Docker container...
docker run --name "%CONTAINER_NAME%" --detach ^
    --restart unless-stopped ^
    --stop-timeout 30 ^
    --shm-size 256m ^
    --label "com.tdm.source-tree=%SOURCE_TREE%" ^
    --env "DISPLAY_WIDTH=1280" ^
    --env "DISPLAY_HEIGHT=800" ^
    --env "TZ=%TIMEZONE%" ^
    --env "VNC_PASSWORD=%VNC_PASSWORD%" ^
    --env "TDM_WEBUI_HOST=0.0.0.0" ^
    --env "TDM_WEBUI_PORT=18473" ^
    --env "TDM_WEBUI_USERNAME=%WEBUI_USERNAME%" ^
    --env "TDM_WEBUI_PASSWORD=%WEBUI_PASSWORD%" ^
    --env "TDM_NOVNC_PORT=%NOVNC_PORT%" ^
    --publish "%BIND_ADDRESS%:%NOVNC_PORT%:6080" ^
    --publish "%BIND_ADDRESS%:%WEBUI_PORT%:18473" ^
    --mount "type=volume,source=%DATA_VOLUME%,target=/data" ^
    "%IMAGE_NAME%"
if errorlevel 1 goto :run_failed

echo Waiting for the container health check...
for /L %%N in (1,1,90) do (
    for /f "usebackq delims=" %%R in (`docker container inspect --format "{{.RestartCount}}" "%CONTAINER_NAME%" 2^>nul`) do (
        if not "%%R"=="0" goto :container_restarting
    )
    for /f "usebackq delims=" %%S in (`docker container inspect --format "{{.State.Status}}" "%CONTAINER_NAME%" 2^>nul`) do (
        if /I not "%%S"=="running" if /I not "%%S"=="restarting" goto :container_stopped
    )
    for /f "usebackq delims=" %%H in (`docker container inspect --format "{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}" "%CONTAINER_NAME%" 2^>nul`) do (
        echo Container health: %%H
        if /I "%%H"=="healthy" goto :healthy
    )
    rem PING provides a Jenkins-safe delay; TIMEOUT requires an interactive console.
    ping -n 3 127.0.0.1 >nul
)

echo ERROR: The container did not become healthy within three minutes.
docker container inspect --format "{{range .State.Health.Log}}{{println .End .ExitCode .Output}}{{end}}" "%CONTAINER_NAME%"
docker logs --tail 100 "%CONTAINER_NAME%"
goto :failed

:container_restarting
echo ERROR: The container restarted because its main process exited.
echo Container application logs:
docker logs --tail 200 "%CONTAINER_NAME%"
goto :failed

:container_stopped
echo ERROR: The container stopped before becoming healthy.
echo Container application logs:
docker logs --tail 200 "%CONTAINER_NAME%"
goto :failed

:healthy
echo.
echo Deployment completed successfully.
echo Dashboard: http://%BIND_ADDRESS%:%WEBUI_PORT%
echo Desktop:   http://%BIND_ADDRESS%:%NOVNC_PORT%/vnc.html
exit /b 0

:missing_passwords
echo ERROR: Set both WEBUI_PASSWORD and VNC_PASSWORD before publishing beyond localhost.
goto :failed

:missing_git
echo ERROR: Git is not installed or is not available in PATH.
goto :failed

:missing_docker
echo ERROR: Docker is not installed or is not available in PATH.
goto :failed

:docker_unavailable
echo ERROR: Docker is not running. Start Docker Desktop in Linux container mode.
goto :failed

:invalid_checkout
echo ERROR: "%DEPLOY_DIR%" exists but is not the managed Git checkout.
echo Move or rename that directory, then run this script again.
goto :failed

:clone_failed
echo ERROR: Unable to clone %REPOSITORY_URL%.
goto :failed

:source_failed
echo ERROR: Unable to update the fork checkout.
goto :failed

:upstream_failed
echo ERROR: Unable to fetch updates from the parent repository.
goto :failed

:merge_failed
git -C "%DEPLOY_DIR%" merge --abort >nul 2>&1
echo ERROR: Parent updates conflict with your fork.
echo Merge DevilXD/TwitchDropsMiner into your fork manually and resolve the conflicts.
goto :failed

:source_hash_failed
echo ERROR: Unable to calculate the merged source tree hash.
goto :failed

:build_failed
echo ERROR: Docker image build failed. The existing container was not changed.
goto :failed

:stop_failed
echo ERROR: The existing container could not be stopped.
goto :failed

:remove_failed
echo ERROR: The stopped container could not be removed.
goto :failed

:run_failed
echo ERROR: The replacement container could not be started.
goto :failed

:volume_failed
echo ERROR: The persistent application data could not be prepared.
goto :failed

:failed
exit /b 1
