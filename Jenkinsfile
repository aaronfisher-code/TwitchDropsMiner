pipeline {
    agent any

    options {
        buildDiscarder(logRotator(numToKeepStr: '10'))
        disableConcurrentBuilds()
        skipDefaultCheckout(true)
        timestamps()
        timeout(time: 30, unit: 'MINUTES')
    }

    triggers {
        cron('H/5 * * * *')
    }

    parameters {
        string(name: 'FORK_REPOSITORY_URL', defaultValue: '', description: 'Required: HTTPS clone URL for your TwitchDropsMiner fork.')
        string(name: 'FORK_BRANCH', defaultValue: 'master', description: 'Branch in your fork containing the Docker and WebUI files.')
        string(name: 'UPSTREAM_BRANCH', defaultValue: 'master', description: 'Parent repository branch to merge before building.')
        string(name: 'BIND_ADDRESS', defaultValue: '127.0.0.1', description: 'Host address used to publish both web interfaces.')
        string(name: 'WEBUI_PORT', defaultValue: '18473', description: 'Host port for the monitoring dashboard.')
        string(name: 'NOVNC_PORT', defaultValue: '6080', description: 'Host port for the noVNC desktop/login interface.')
        string(name: 'WEBUI_USERNAME', defaultValue: 'admin', description: 'Dashboard Basic Authentication username.')
        password(name: 'WEBUI_PASSWORD', defaultValue: '', description: 'Dashboard password. Leave empty only when bound to localhost.')
        password(name: 'VNC_PASSWORD', defaultValue: '', description: 'noVNC/VNC password. Leave empty only when bound to localhost.')
        string(name: 'TIMEZONE', defaultValue: 'Australia/Melbourne', description: 'Container timezone, for example Australia/Melbourne or UTC.')
        string(name: 'TDM_UID', defaultValue: '1000', description: 'Linux UID used inside the container.')
        string(name: 'TDM_GID', defaultValue: '1000', description: 'Linux GID used inside the container.')
    }

    environment {
        COMPOSE_PROJECT_NAME = 'twitch-drops-miner'
    }

    stages {
        stage('Clone fork') {
            steps {
                // This directory is owned by this job and contains only the disposable clone.
                dir('fork-source') {
                    deleteDir()
                }
                powershell '''
                    $ErrorActionPreference = 'Stop'

                    function Assert-NativeSuccess {
                        param([Parameter(Mandatory = $true)][string] $Message)
                        if ($LASTEXITCODE -ne 0) {
                            throw "$Message (exit code $LASTEXITCODE)."
                        }
                    }

                    if ([string]::IsNullOrWhiteSpace($env:FORK_REPOSITORY_URL)) {
                        throw 'Set FORK_REPOSITORY_URL to the HTTPS clone URL of your fork, then run the job again.'
                    }
                    if ($env:FORK_REPOSITORY_URL -notmatch '^https://[^\\s]+$') {
                        throw 'FORK_REPOSITORY_URL must be an HTTPS clone URL without whitespace.'
                    }
                    if ([string]::IsNullOrWhiteSpace($env:FORK_BRANCH)) {
                        throw 'FORK_BRANCH must not be empty.'
                    }

                    $sourceDir = Join-Path $env:WORKSPACE 'fork-source'
                    git clone --no-tags --single-branch --branch $env:FORK_BRANCH `
                        $env:FORK_REPOSITORY_URL $sourceDir
                    Assert-NativeSuccess 'Unable to clone your fork'

                    $revision = (git -C $sourceDir rev-parse HEAD).Trim()
                    Assert-NativeSuccess 'Unable to read the cloned fork revision'
                    Write-Host "Cloned fork revision $revision."
                '''
            }
        }

        stage('Merge parent updates') {
            steps {
                dir('fork-source') {
                    powershell '''
                        $ErrorActionPreference = 'Stop'
                        $upstreamUrl = 'https://github.com/DevilXD/TwitchDropsMiner.git'

                        function Assert-NativeSuccess {
                            param([Parameter(Mandatory = $true)][string] $Message)
                            if ($LASTEXITCODE -ne 0) {
                                throw "$Message (exit code $LASTEXITCODE)."
                            }
                        }

                        if ([string]::IsNullOrWhiteSpace($env:UPSTREAM_BRANCH)) {
                            throw 'UPSTREAM_BRANCH must not be empty.'
                        }

                        git remote add upstream $upstreamUrl
                        Assert-NativeSuccess 'Unable to configure the parent repository'
                        git fetch --no-tags upstream `
                            "+refs/heads/$($env:UPSTREAM_BRANCH):refs/remotes/upstream/$($env:UPSTREAM_BRANCH)"
                        Assert-NativeSuccess 'Unable to fetch parent repository updates'

                        git -c 'user.name=Jenkins' -c 'user.email=jenkins@localhost' `
                            merge --no-edit "upstream/$($env:UPSTREAM_BRANCH)"
                        if ($LASTEXITCODE -ne 0) {
                            git merge --abort 2>$null
                            throw 'The parent update conflicts with your fork. Merge the parent into your fork manually, resolve the conflicts, and rerun this job.'
                        }

                        $treeHash = (git rev-parse 'HEAD^{tree}').Trim()
                        Assert-NativeSuccess 'Unable to calculate the merged source tree hash'
                        Write-Host "Prepared merged source tree $treeHash."
                    '''
                }
            }
        }

        stage('Validate real files') {
            steps {
                dir('fork-source') {
                    powershell '''
                        $ErrorActionPreference = 'Stop'
                        $requiredFiles = @(
                            'Dockerfile',
                            'compose.yaml',
                            '.dockerignore',
                            'docker/entrypoint.sh',
                            'webui.py',
                            'webui.html',
                            'constants.py',
                            'gui.py',
                            'inventory.py',
                            'main.py',
                            'twitch.py'
                        )
                        $missing = @($requiredFiles | Where-Object {
                            -not (Test-Path -LiteralPath $_ -PathType Leaf)
                        })
                        if ($missing.Count -ne 0) {
                            throw "Your fork is missing required files: $($missing -join ', '). Commit and push this project's Docker/WebUI changes to the configured fork branch."
                        }

                        docker compose config --quiet
                        if ($LASTEXITCODE -ne 0) {
                            throw 'Docker Compose configuration validation failed.'
                        }
                        Write-Host 'All required real files are present and the Compose configuration is valid.'
                    '''
                }
            }
        }

        stage('Build and deploy') {
            steps {
                dir('fork-source') {
                    powershell '''
                        $ErrorActionPreference = 'Stop'
                        $containerName = 'twitch-drops-miner'

                        function Assert-NativeSuccess {
                            param([Parameter(Mandatory = $true)][string] $Message)
                            if ($LASTEXITCODE -ne 0) {
                                throw "$Message (exit code $LASTEXITCODE)."
                            }
                        }

                        function Convert-ToPort {
                            param(
                                [Parameter(Mandatory = $true)][string] $Value,
                                [Parameter(Mandatory = $true)][string] $Name
                            )
                            try {
                                $port = [int]$Value
                            } catch {
                                throw "$Name must be an integer."
                            }
                            if ($port -lt 1 -or $port -gt 65535) {
                                throw "$Name must be between 1 and 65535."
                            }
                            return $port
                        }

                        function Get-Sha256 {
                            param([Parameter(Mandatory = $true)][string] $Value)
                            $algorithm = [System.Security.Cryptography.SHA256]::Create()
                            try {
                                $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
                                return ([System.BitConverter]::ToString(
                                    $algorithm.ComputeHash($bytes)
                                )).Replace('-', '').ToLowerInvariant()
                            } finally {
                                $algorithm.Dispose()
                            }
                        }

                        $webuiPort = Convert-ToPort $env:WEBUI_PORT 'WEBUI_PORT'
                        $novncPort = Convert-ToPort $env:NOVNC_PORT 'NOVNC_PORT'
                        if ($webuiPort -eq $novncPort) {
                            throw 'WEBUI_PORT and NOVNC_PORT must be different.'
                        }
                        if ([string]::IsNullOrWhiteSpace($env:BIND_ADDRESS) -or $env:BIND_ADDRESS -match '\\s') {
                            throw 'BIND_ADDRESS must be a non-empty address without whitespace.'
                        }
                        if ($env:BIND_ADDRESS -notin @('127.0.0.1', 'localhost') -and (
                            [string]::IsNullOrEmpty($env:WEBUI_PASSWORD) -or
                            [string]::IsNullOrEmpty($env:VNC_PASSWORD)
                        )) {
                            throw 'WEBUI_PASSWORD and VNC_PASSWORD are required when publishing beyond localhost.'
                        }

                        $dockerOs = (docker version --format '{{.Server.Os}}').Trim()
                        Assert-NativeSuccess 'Docker is unavailable'
                        if ($dockerOs -ne 'linux') {
                            throw 'Docker must be configured to run Linux containers.'
                        }

                        $treeHash = (git rev-parse 'HEAD^{tree}').Trim()
                        Assert-NativeSuccess 'Unable to calculate the merged source tree hash'
                        $env:SOURCE_TREE = $treeHash
                        $env:TDM_BIND_ADDRESS = $env:BIND_ADDRESS
                        $env:TDM_WEBUI_PORT = "$webuiPort"
                        $env:TDM_WEB_PORT = "$novncPort"
                        $env:TZ = $env:TIMEZONE

                        $deploymentFingerprint = Get-Sha256 ([string]::Join("`n", @(
                            $treeHash,
                            $env:BIND_ADDRESS,
                            "$webuiPort",
                            "$novncPort",
                            $env:WEBUI_USERNAME,
                            $env:WEBUI_PASSWORD,
                            $env:VNC_PASSWORD,
                            $env:TIMEZONE,
                            $env:TDM_UID,
                            $env:TDM_GID
                        )))
                        $env:DEPLOYMENT_FINGERPRINT = $deploymentFingerprint

                        docker compose config --quiet
                        Assert-NativeSuccess 'Docker Compose configuration validation failed with the selected parameters'

                        $deployedFingerprint = docker inspect --format `
                            '{{index .Config.Labels "com.tdm.deployment"}}' `
                            $containerName 2>$null
                        if ($LASTEXITCODE -ne 0) {
                            $deployedFingerprint = ''
                        } else {
                            $deployedFingerprint = "$deployedFingerprint".Trim()
                        }
                        $currentHealth = docker inspect --format `
                            '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' `
                            $containerName 2>$null
                        if ($LASTEXITCODE -ne 0) {
                            $currentHealth = ''
                        } else {
                            $currentHealth = "$currentHealth".Trim()
                        }

                        if ($deploymentFingerprint -eq $deployedFingerprint -and $currentHealth -eq 'healthy') {
                            Write-Host "The fork, parent updates, and deployment are already current ($treeHash)."
                            return
                        }

                        try {
                            docker compose build --pull
                            Assert-NativeSuccess 'Docker image build failed'
                            docker compose up --detach --no-build --remove-orphans
                            Assert-NativeSuccess 'Docker Compose deployment failed'

                            $deadline = (Get-Date).AddMinutes(3)
                            do {
                                Start-Sleep -Seconds 2
                                $health = docker inspect --format `
                                    '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' `
                                    $containerName 2>$null
                                if ($LASTEXITCODE -ne 0) {
                                    $health = 'not available'
                                } else {
                                    $health = "$health".Trim()
                                }
                                Write-Host "Container health: $health"
                                if ($health -eq 'healthy') {
                                    Write-Host "Deployment completed from merged source tree $treeHash."
                                    Write-Host "Dashboard: http://$($env:BIND_ADDRESS):$webuiPort"
                                    Write-Host "Desktop: http://$($env:BIND_ADDRESS):$novncPort/vnc.html"
                                    return
                                }
                            } while ((Get-Date) -lt $deadline)

                            throw 'The container did not become healthy within three minutes.'
                        } catch {
                            Write-Host "Deployment failed: $($_.Exception.Message)"
                            docker compose ps
                            docker compose logs --tail=100 twitch-drops-miner
                            throw
                        }
                    '''
                }
            }
        }
    }
}
