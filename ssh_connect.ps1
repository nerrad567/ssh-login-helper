#requires -Version 5.1
<#
.SYNOPSIS
    SSH Login Helper - A PowerShell tool utilizing an SSH config file.
.DESCRIPTION
    This script parses your SSH config file (located at a path defined in conf.json)
    to build a list of servers, then displays a menu to allow you to connect.

    A separate JSON configuration file (conf.json) is used to hold metadata such as:
    - Paths (to your SSH config and directories)
    - Host descriptions (friendly labels)
    - Default connection settings (user, port, post-connect command)
    - Per-host overrides for connection settings.
    
    IMPORTANT: This JSON file is not your SSH config; it’s a companion file that
    allows you to easily modify settings for the SSH Login Helper. Edit it to describe hosts (HostDescriptions), 
    set default connection settings (Defaults: User, Port, PostConnectCommand), and override settings per host 
    (PerHostSettings: User, Port, PostConnectCommand). SSH config settings (HostName, User, IdentityFile, Port) 
    take highest priority, followed by PerHostSettings, then Defaults.
.NOTES
    Authors: Darren Gray assisted by ChatGPT & GrokAI
    Created: March 28, 2025
    Version: 1.2
#>

# Define a class for holding server configuration information.
class ServerConfig {
    [string]$Alias          # The friendly name from the "Host" directive.
    [string]$RemoteAddress  # The actual IP address or FQDN specified by the "HostName" directive.
    [string]$User           # The SSH user.
    [string]$IdentityFile   # The path to the SSH private key.
    [string]$Description    # A friendly description for this host.
}

# -------------------------------------------------------------------------
# Function: Initialize-ConfigFile
#
# Checks for the existence of the config file at the specified path.
# If not found, it creates a default JSON config with placeholder values.
# -------------------------------------------------------------------------

function Initialize-ConfigFile {
    param (
        [string]$Path
    )

    $needsDefault = $false

    if (-not (Test-Path $Path)) {
        Write-Host "Creating default config at: $Path"
        $needsDefault = $true
    }
    else {
        try {
            $content = Get-Content $Path -Raw -ErrorAction Stop
            if (-not $content.Trim()) {
                Write-Host "Config file is empty, populating with defaults at: $Path"
                $needsDefault = $true
            }
            else {
                $null = $content | ConvertFrom-Json -ErrorAction Stop
            }
        }
        catch {
            Write-Host "Invalid config file detected, recreating with defaults at: $Path"
            $needsDefault = $true
        }
    }

    if ($needsDefault) {
        $defaultConf = [ordered]@{
            "//"      = "This file is NOT your SSH config. It contains optional metadata and launch settings for your SSH tool."
            "//_info" = "Edit this to describe hosts (HostDescriptions), set default connection settings (Defaults: User, Port, PostConnectCommand), and override settings per host (PerHostSettings: User, Port, PostConnectCommand). SSH config settings (HostName, User, IdentityFile, Port) take highest priority, followed by PerHostSettings, then Defaults."
            "Paths" = @{
                "SSHConfig"      = "%USERPROFILE%\OneDrive\.ssh\config"
                "SSHDir"         = "%USERPROFILE%\OneDrive\.ssh"
                "DefaultSSHDir"  = "%USERPROFILE%\.ssh"
            }
            "HostDescriptions" = [ordered]@{
                "example-host-1" = "Your description here"
                "example-host-2" = "Another example"
            }
            "Defaults" = @{
                "Port"             = 22
                "PostConnectCommand" = ""
                "User"             = "your-username"
                "WorkingDirectory" = "~"
            }
            "PerHostSettings" = @{
                "example-host-1" = @{
                    "Port"             = 2222
                    "PostConnectCommand" = "htop"
                    "User"             = "root"
                    "WorkingDirectory" = "/home/root"
                }
            }
        }

        $defaultConf | ConvertTo-Json -Depth 10 | Out-File -FilePath $Path -Encoding UTF8 -Force
    }

    try {
        return Get-Content $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Failed to load config file at $Path after creation: $_"
    }
}

# -------------------------------------------------------------------------
# Function: Find-SSHKeys
#
# Searches the provided SSH directories for potential SSH key files.
# Excludes public key files (.pub) and files named "config" or "known_hosts".
# For files that aren't obviously keys by name, if they're small (<=10KB),
# their contents are checked for the marker "-----BEGIN OPENSSH PRIVATE KEY-----".
# -------------------------------------------------------------------------
function Find-SSHKeys {
    # Search in both configured SSH directories.
    $keyPaths = @($SSHDir, $DefaultSSHDir) | Where-Object { Test-Path $_ }
    $keys = @()

    foreach ($path in $keyPaths) {
        # Get all files in the directory, excluding obvious non-key files.
        $items = Get-ChildItem -Path $path -File |
            Where-Object {
                $_.Extension -notin @('.pub') -and
                $_.Name -notmatch '^(config|known_hosts)$'
            }
        
        foreach ($item in $items) {
            $include = $false
    
            # Automatically include files whose name starts with "id_" or ends with ".key".
            if ($item.Name -match '^id_' -or $item.Name -match '\.key$') {
                $include = $true
            }
            else {
                # For other files, check if they are small (max 10KB) to avoid reading huge files.
                if ($item.Length -le 10KB) {
                    try {
                        # Read file content as a single string.
                        $content = Get-Content -Path $item.FullName -Raw
                        if ($content -match '-----BEGIN OPENSSH PRIVATE KEY-----') {
                            $include = $true
                        }
                    }
                    finally {
                        # Clear the sensitive variable after use.
                        $content = $null
                    }
                }
            }
            
            if ($include) {
                $keys += $item.FullName
            }
        }
    }
    
    # Return unique key paths.
    return $keys | Sort-Object -Unique
}

# -------------------------------------------------------------------------
# Function: Get-SSHConfig
#
# Reads the user's SSH config file (defined in the config) and parses it
# into an array of ServerConfig objects.
# -------------------------------------------------------------------------
function Get-SSHConfig {
    if (-not (Test-Path $SSHConfigPath)) {
        throw "SSH config file not found at: $SSHConfigPath"
    }

    $script:Servers = @()
    $lines = Get-Content $SSHConfigPath | Where-Object { $_ -match '\S' -and $_ -notmatch '^\s*#' }
    $currentConfig = $null
    $inAliasBlock = $false
    $aliasCount = @{}  # Track occurrences of each alias

    foreach ($line in $lines) {
        $line = $line.Trim()
        if ($line -match '^Host\s+(.+)') {
            $aliases = ,($matches[1].Split()) | Where-Object { $_ -notmatch '\*' }
            if ($aliases) {
                if ($inAliasBlock -and $currentConfig) {
                    $script:Servers += $currentConfig
                }
                $currentConfig = [ServerConfig]::new()
                $currentConfig.Alias = $aliases[0]
                
                # Track duplicate aliases
                if ($aliasCount.ContainsKey($currentConfig.Alias)) {
                    $aliasCount[$currentConfig.Alias]++
                } else {
                    $aliasCount[$currentConfig.Alias] = 1
                }
                $inAliasBlock = $true
            } else {
                $inAliasBlock = $false
            }
        } elseif ($inAliasBlock -and $currentConfig) {
            switch -Regex ($line) {
                '^HostName\s+(.+)' { $currentConfig.RemoteAddress = $matches[1] }
                '^User\s+(.+)' { $currentConfig.User = $matches[1] }
                '^IdentityFile\s+(.+)' { 
                    $identity = $matches[1] -replace '~', $env:USERPROFILE
                    $currentConfig.IdentityFile = $identity
                }
            }
        }
    }

    if ($inAliasBlock -and $currentConfig) {
        $script:Servers += $currentConfig
    }

    # Apply descriptions with duplicate handling
    $indexMap = @{}  # Map alias to next index for duplicates
    foreach ($server in $script:Servers) {
        $baseAlias = $server.Alias
        if ($aliasCount[$baseAlias] -gt 1) {
            if (-not $indexMap.ContainsKey($baseAlias)) {
                $indexMap[$baseAlias] = 1
            }
            $index = $indexMap[$baseAlias]++
            $suffix = " (#$index - $($server.RemoteAddress))"
            if ($HostDescriptions.PSObject.Properties[$baseAlias]) {
                $server.Description = "$($HostDescriptions.$baseAlias)$suffix"
            } else {
                $server.Description = "No description available$suffix"
            }
        } else {
            $server.Description = if ($HostDescriptions.PSObject.Properties[$baseAlias]) { 
                $HostDescriptions.$baseAlias 
            } else { 
                "No description available" 
            }
        }
    }

    if (-not $script:Servers) {
        throw "No valid Host entries found in SSH config"
    }
}

# -------------------------------------------------------------------------
# Function: Show-Menu
#
# Displays the list of available SSH hosts in a menu format.
# -------------------------------------------------------------------------
function Show-Menu {
    if (-not $script:Servers -or $script:Servers.Count -eq 0) {
        Write-Warning "No servers available to display. Check your SSH config and conf.json."
        return
    }

    # Calculate maximum lengths with null handling
    $maxAliasLength  = ($script:Servers | ForEach-Object { if ($_.Alias) { $_.Alias.Length } else { 3 } } | Measure-Object -Maximum).Maximum
    $maxRemoteLength = ($script:Servers | ForEach-Object { if ($_.RemoteAddress) { $_.RemoteAddress.Length } else { 3 } } | Measure-Object -Maximum).Maximum
    # We'll compute user length based on resolved values below
    $maxDescLength   = ($script:Servers | ForEach-Object { if ($_.Description) { $_.Description.Length } else { 13 } } | Measure-Object -Maximum).Maximum

    # Padding and initial table width (user length will be adjusted)
    $padAlias  = $maxAliasLength  + 3
    $padRemote = $maxRemoteLength + 3
    $padUser   = 3  # Placeholder, will be updated
    $padDesc   = $maxDescLength

    # Resolve usernames for all servers to match Connect-Server logic
    $resolvedUsers = @()
    foreach ($server in $script:Servers) {
        $alias = $server.Alias
        $user = if ($server.User) { $server.User } else { $Defaults.User }
        if ($PerHost.PSObject.Properties[$alias] -and -not $server.User) {
            $settings = $PerHost.$alias
            if ($settings.User) { $user = $settings.User }
        }
        $resolvedUsers += $user
    }
    $maxUserLength = ($resolvedUsers | ForEach-Object { if ($_) { $_.Length } else { 3 } } | Measure-Object -Maximum).Maximum
    $padUser = $maxUserLength + 3

    # Compute final table width
    $tableWidth = 3 + $padAlias + $padRemote + 2 + $padUser + 2 + $padDesc

    # Build header
    $topBorder    = "╔" + ("═" * $tableWidth) + "╗"
    $bottomBorder = "╚" + ("═" * $tableWidth) + "╝"
    $title        = "SSH Login Helper"
    $leftPad = [Math]::Floor(($tableWidth - $title.Length) / 2)
    if ($leftPad -lt 0) { $leftPad = 0 }
    $titleCentered = "║" + (" " * $leftPad) + $title + (" " * ($tableWidth - $leftPad - $title.Length)) + "║"

    # Output header
    #Clear-Host
    Write-Host $topBorder -ForegroundColor Cyan
    Write-Host $titleCentered -ForegroundColor Cyan
    Write-Host $bottomBorder -ForegroundColor Cyan
    Write-Host ""

    # Display servers with resolved usernames
    for ($i = 0; $i -lt $script:Servers.Count; $i++) {
        $server = $script:Servers[$i]
        $alias = if ($server.Alias) { $server.Alias } else { "N/A" }
        $remote = if ($server.RemoteAddress) { $server.RemoteAddress } else { "N/A" }
        $desc = if ($server.Description) { $server.Description } else { "No description" }

        # Resolve username exactly as Connect-Server does
        $user = if ($server.User) { $server.User } else { $Defaults.User }
        if ($PerHost.PSObject.Properties[$server.Alias] -and -not $server.User) {
            $settings = $PerHost.$($server.Alias)
            if ($settings.User) { $user = $settings.User }
        }
        $user = if ($user) { $user } else { "N/A" }  # Final fallback for display

        $indexStr  = ($i + 1).ToString().PadRight(3)
        $aliasStr  = $alias.PadRight($padAlias)
        $remoteStr = "[$remote]".PadRight($padRemote + 2)
        $userStr   = "($user)".PadRight($padUser + 2)
        $descStr   = $desc

        Write-Host $indexStr -ForegroundColor Yellow -NoNewline
        Write-Host $aliasStr -ForegroundColor Green -NoNewline
        Write-Host $remoteStr -ForegroundColor Gray -NoNewline
        Write-Host $userStr -ForegroundColor Magenta -NoNewline
        Write-Host $descStr -ForegroundColor DarkGray
    }

    Write-Host ""
    Write-Host "Q. Quit" -ForegroundColor Red
    Write-Host ""
}


# -------------------------------------------------------------------------
# Function: Test-KeyPath
#
# Validates the existence of an SSH key file at a given path.
# -------------------------------------------------------------------------
function Test-KeyPath {
    param ([string]$Path)
    if (-not (Test-Path $Path)) {
        Write-Warning "SSH key not found at: $Path"
        return $false
    }
    return $true
}



# -------------------------------------------------------------------------
# Function: Connect-Server
#
# Attempts to establish an SSH connection to the selected server.
# Tries the specified IdentityFile or searches for available keys.
# -------------------------------------------------------------------------








function Connect-Server {
    param (
        [int]$Selection
    )
    
    $server = $script:Servers[$Selection - 1]
    Write-Host "Connecting to $($server.Alias) [$($server.RemoteAddress)]..." -ForegroundColor Cyan

    $sshPath = "ssh"
    if (-not (Get-Command $sshPath -ErrorAction SilentlyContinue)) {
        throw "SSH client not found. Please ensure OpenSSH is installed."
    }

    # Determine SSH keys
    $keys = @()
    if ($server.IdentityFile -and (Test-Path $server.IdentityFile -PathType Leaf)) {
        $keys = @($server.IdentityFile)
    }
    else {
        $keys = Find-SSHKeys | Where-Object { Test-Path $_ -PathType Leaf }
        if (-not $keys) {
            Write-Host "No SSH keys found in $SSHDir or $DefaultSSHDir." -ForegroundColor Red
            Pause
            return
        }
    }

    # Determine settings with priority: SSH config > PerHostSettings > Defaults
    $alias = $server.Alias
    $currentUser = if ($server.User) { $server.User } elseif ($PerHost.PSObject.Properties[$alias] -and $PerHost.$alias.User) { $PerHost.$alias.User } else { $Defaults.User }
    $currentPort = if ($PerHost.PSObject.Properties[$alias] -and $PerHost.$alias.Port) { $PerHost.$alias.Port } else { $Defaults.Port }
    $postCmd = if ($PerHost.PSObject.Properties[$alias] -and $PerHost.$alias.PostConnectCommand) { $PerHost.$alias.PostConnectCommand } else { $Defaults.PostConnectCommand }

    # Combine and clean known_hosts into $SSHDir\known_hosts
    $sshDirKnownHosts = Join-Path $SSHDir "known_hosts"
    $defaultDirKnownHosts = Join-Path $DefaultSSHDir "known_hosts"
    $knownHostsContent = @()
    
    if (Test-Path $sshDirKnownHosts -PathType Leaf) {
        $knownHostsContent += Get-Content $sshDirKnownHosts
    }
    if (Test-Path $defaultDirKnownHosts -PathType Leaf) {
        $knownHostsContent += Get-Content $defaultDirKnownHosts
    }
    
    if ($knownHostsContent) {
        $cleanedEntries = $knownHostsContent | 
            Where-Object { $_ -match "^\S+\s+\S+\s+\S+" } | 
            ForEach-Object { $_.Trim() } | 
            Group-Object { $_.Split()[0,1] -join " " } | 
            ForEach-Object { $_.Group | Select-Object -First 1 }
        $cleanedEntries | Out-File $sshDirKnownHosts -Encoding UTF8
    }
    else {
        if (-not (Test-Path $SSHDir)) { New-Item -Path $SSHDir -ItemType Directory -Force }
        if (-not (Test-Path $sshDirKnownHosts)) { New-Item -Path $sshDirKnownHosts -ItemType File -Force }
    }

    # Base SSH arguments
    $baseArguments = "-o ServerAliveInterval=60 -o ServerAliveCountMax=3 -o UserKnownHostsFile=`"$sshDirKnownHosts`" -o GlobalKnownHostsFile=NUL -p $currentPort $currentUser@$($server.RemoteAddress)"
    if ($postCmd) { $baseArguments += " '$postCmd'" }

    # Try agent keys first
    Write-Host "Trying agent keys..." -ForegroundColor Gray
    & $sshPath $baseArguments.Split()
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Connected with agent key" -ForegroundColor Green
        return
    }
    else {
        Write-Host "Agent keys failed to authenticate." -ForegroundColor Yellow
    }

    # Try specified keys with IdentitiesOnly=yes
    foreach ($key in $keys) {
        Write-Host "Trying key: $key" -ForegroundColor Gray
        & $sshPath -i "$key" -o IdentitiesOnly=yes $baseArguments.Split()
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Connected with key: $key" -ForegroundColor Green
            return
        }
        else {
            Write-Host "Key $key failed to authenticate." -ForegroundColor Yellow
        }
    }

    Write-Host "Failed to connect. Ensure a valid key is in $SSHDir or loaded in ssh-agent." -ForegroundColor Red
    Pause
}










# -------------------------------------------------------------------------
# Function: Start-SSHHelper
#
# Main entry point: loads SSH config, displays the menu, and processes user input.
# -------------------------------------------------------------------------
function Start-SSHHelper {
    Get-SSHConfig
    
    while ($true) {
        Show-Menu
        
        $choice = Read-Host "Select a server (1-$($script:Servers.Count)) or Q to quit"
        
        if ($choice -eq 'q' -or $choice -eq 'Q') {
            Write-Host "Exiting SSH Helper..." -ForegroundColor Cyan
            # Start-Sleep -Seconds 1
            break
        }
        
        if ($choice -match "^[1-$($script:Servers.Count)]$") {
            Connect-Server -Selection ([int]$choice)
        }
        else {
            Write-Warning "Invalid selection. Please choose 1-$($script:Servers.Count) or Q"
            Start-Sleep -Seconds 2
        }
    }
}

# -------------------------------------------------------------------------
# Load and ensure the configuration file exists.
# The config file holds metadata and defaults for our tool.
# -------------------------------------------------------------------------

# Set the path to the configuration file (conf.json) relative to the script's location.
$ConfPath = Join-Path $PSScriptRoot 'conf.json'

# Initialize-ConfigFile will create a default config if one does not exist.
$config = Initialize-ConfigFile -Path $ConfPath

# Extract sections of the config for easy access.
$HostDescriptions = $config.HostDescriptions
$Defaults         = $config.Defaults
$PerHost          = $config.PerHostSettings

# If the Paths object keys contain the placeholder "%USERPROFILE%", it will be replaced by $env:USERPROFILE.
# To use a custom path, update the value in the config file so that it does not contain "%USERPROFILE%".
$SSHConfigPath    = $config.Paths.SSHConfig -replace '%USERPROFILE%', $env:USERPROFILE
$SSHDir           = $config.Paths.SSHDir -replace '%USERPROFILE%', $env:USERPROFILE
$DefaultSSHDir    = $config.Paths.DefaultSSHDir -replace '%USERPROFILE%', $env:USERPROFILE

# -------------------------------------------------------------------------
# Main script execution:
# Start the SSH Login Helper, and catch any unexpected errors.
# -------------------------------------------------------------------------
try {
    Start-SSHHelper
}
catch {
    Write-Error "An unexpected error occurred: $_"
}
finally {
    Write-Host "Thank you for using SSH Login Helper!" -ForegroundColor Cyan
}


# SIG # Begin signature block
# MIIcEQYJKoZIhvcNAQcCoIIcAjCCG/4CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCMW+xcJxO9pApg
# FXZCH3fo00fYKcraUswY1KkUzz7Yj6CCFlQwggMWMIIB/qADAgECAhB1x/6LChc9
# kU2cYcHvlKX5MA0GCSqGSIb3DQEBCwUAMCMxITAfBgNVBAMMGERhcnJlbiBHcmF5
# IENvZGUgU2lnbmluZzAeFw0yNTA3MDIxMzI4MzJaFw0yNjA3MDIxMzM3NTZaMCMx
# ITAfBgNVBAMMGERhcnJlbiBHcmF5IENvZGUgU2lnbmluZzCCASIwDQYJKoZIhvcN
# AQEBBQADggEPADCCAQoCggEBAL7TXiUiHUpWNNiaInb6X7+737yrTzYbBaFH9UY4
# NY5GALcsdH+D5CcFZQcU3y6TUZHd6mda15OG/bh0ZEirRvZ7/C663CD5H1RME2Df
# 0mGxmkMNxIrHnNyEVIcIX7Wkua7395jQ+nVqDXqNrlK78LqHWYCNzPs8hrHcPmjS
# MfpzzJxhFHe7prd39vfw6D2wsS6L8LfXzhKczFjlijzqdUd2hY0Nor97F+6YBDNl
# Wb3p8F2265XgV50pVgVdZlGzQg6Gs0tPkoMgBEjmQ/bqEQfL6PK/vlq14XByYxud
# HRaTBPb0yG7u7OVNVkR1xS6SgH+WmJMXWpjPstUXsWF/bjcCAwEAAaNGMEQwDgYD
# VR0PAQH/BAQDAgeAMBMGA1UdJQQMMAoGCCsGAQUFBwMDMB0GA1UdDgQWBBT/gTFW
# MGDQ5FTS0kv45pa19jtdIzANBgkqhkiG9w0BAQsFAAOCAQEAMbMKM4vwU6h5AtEX
# hCJnEeUw/deB3kTGO+PKeoeRNrAT87Uc++iUP6GzHNVHU04kSaRIECDI6N+Fld5G
# 9lMfq9Y6YnjPwiwqU13SjYcCZBXI1/oGj2tKeZSKAWEc+asvN2WLh/gPCg9V/IUB
# PXrPySM0FTg9merRaO2VcZpHvF0uMA0e35ZnPxoeePRtGm3MqW370Y4fi5bqdIu0
# FXoHKzQK//R+Srr1q/pCJLRL/HtZEaASCAYxYg00t4I4fCpJPmFGSsQPCt2k649B
# M591t6hy6GQo8El+YJivs4W5HK+JGB7jYdUTplk9otV/0CBDGuR6EjlAGWwBTEvX
# Y7aiHDCCBY0wggR1oAMCAQICEA6bGI750C3n79tQ4ghAGFowDQYJKoZIhvcNAQEM
# BQAwZTELMAkGA1UEBhMCVVMxFTATBgNVBAoTDERpZ2lDZXJ0IEluYzEZMBcGA1UE
# CxMQd3d3LmRpZ2ljZXJ0LmNvbTEkMCIGA1UEAxMbRGlnaUNlcnQgQXNzdXJlZCBJ
# RCBSb290IENBMB4XDTIyMDgwMTAwMDAwMFoXDTMxMTEwOTIzNTk1OVowYjELMAkG
# A1UEBhMCVVMxFTATBgNVBAoTDERpZ2lDZXJ0IEluYzEZMBcGA1UECxMQd3d3LmRp
# Z2ljZXJ0LmNvbTEhMB8GA1UEAxMYRGlnaUNlcnQgVHJ1c3RlZCBSb290IEc0MIIC
# IjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAv+aQc2jeu+RdSjwwIjBpM+zC
# pyUuySE98orYWcLhKac9WKt2ms2uexuEDcQwH/MbpDgW61bGl20dq7J58soR0uRf
# 1gU8Ug9SH8aeFaV+vp+pVxZZVXKvaJNwwrK6dZlqczKU0RBEEC7fgvMHhOZ0O21x
# 4i0MG+4g1ckgHWMpLc7sXk7Ik/ghYZs06wXGXuxbGrzryc/NrDRAX7F6Zu53yEio
# ZldXn1RYjgwrt0+nMNlW7sp7XeOtyU9e5TXnMcvak17cjo+A2raRmECQecN4x7ax
# xLVqGDgDEI3Y1DekLgV9iPWCPhCRcKtVgkEy19sEcypukQF8IUzUvK4bA3VdeGbZ
# OjFEmjNAvwjXWkmkwuapoGfdpCe8oU85tRFYF/ckXEaPZPfBaYh2mHY9WV1CdoeJ
# l2l6SPDgohIbZpp0yt5LHucOY67m1O+SkjqePdwA5EUlibaaRBkrfsCUtNJhbesz
# 2cXfSwQAzH0clcOP9yGyshG3u3/y1YxwLEFgqrFjGESVGnZifvaAsPvoZKYz0YkH
# 4b235kOkGLimdwHhD5QMIR2yVCkliWzlDlJRR3S+Jqy2QXXeeqxfjT/JvNNBERJb
# 5RBQ6zHFynIWIgnffEx1P2PsIV/EIFFrb7GrhotPwtZFX50g/KEexcCPorF+CiaZ
# 9eRpL5gdLfXZqbId5RsCAwEAAaOCATowggE2MA8GA1UdEwEB/wQFMAMBAf8wHQYD
# VR0OBBYEFOzX44LScV1kTN8uZz/nupiuHA9PMB8GA1UdIwQYMBaAFEXroq/0ksuC
# MS1Ri6enIZ3zbcgPMA4GA1UdDwEB/wQEAwIBhjB5BggrBgEFBQcBAQRtMGswJAYI
# KwYBBQUHMAGGGGh0dHA6Ly9vY3NwLmRpZ2ljZXJ0LmNvbTBDBggrBgEFBQcwAoY3
# aHR0cDovL2NhY2VydHMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0QXNzdXJlZElEUm9v
# dENBLmNydDBFBgNVHR8EPjA8MDqgOKA2hjRodHRwOi8vY3JsMy5kaWdpY2VydC5j
# b20vRGlnaUNlcnRBc3N1cmVkSURSb290Q0EuY3JsMBEGA1UdIAQKMAgwBgYEVR0g
# ADANBgkqhkiG9w0BAQwFAAOCAQEAcKC/Q1xV5zhfoKN0Gz22Ftf3v1cHvZqsoYcs
# 7IVeqRq7IviHGmlUIu2kiHdtvRoU9BNKei8ttzjv9P+Aufih9/Jy3iS8UgPITtAq
# 3votVs/59PesMHqai7Je1M/RQ0SbQyHrlnKhSLSZy51PpwYDE3cnRNTnf+hZqPC/
# Lwum6fI0POz3A8eHqNJMQBk1RmppVLC4oVaO7KTVPeix3P0c2PR3WlxUjG/voVA9
# /HYJaISfb8rbII01YBwCA8sgsKxYoA5AY8WYIsGyWfVVa88nq2x2zm8jLfR+cWoj
# ayL/ErhULSd+2DrZ8LaHlv1b0VysGMNNn3O3AamfV6peKOK5lDCCBrQwggScoAMC
# AQICEA3HrFcF/yGZLkBDIgw6SYYwDQYJKoZIhvcNAQELBQAwYjELMAkGA1UEBhMC
# VVMxFTATBgNVBAoTDERpZ2lDZXJ0IEluYzEZMBcGA1UECxMQd3d3LmRpZ2ljZXJ0
# LmNvbTEhMB8GA1UEAxMYRGlnaUNlcnQgVHJ1c3RlZCBSb290IEc0MB4XDTI1MDUw
# NzAwMDAwMFoXDTM4MDExNDIzNTk1OVowaTELMAkGA1UEBhMCVVMxFzAVBgNVBAoT
# DkRpZ2lDZXJ0LCBJbmMuMUEwPwYDVQQDEzhEaWdpQ2VydCBUcnVzdGVkIEc0IFRp
# bWVTdGFtcGluZyBSU0E0MDk2IFNIQTI1NiAyMDI1IENBMTCCAiIwDQYJKoZIhvcN
# AQEBBQADggIPADCCAgoCggIBALR4MdMKmEFyvjxGwBysddujRmh0tFEXnU2tjQ2U
# tZmWgyxU7UNqEY81FzJsQqr5G7A6c+Gh/qm8Xi4aPCOo2N8S9SLrC6Kbltqn7SWC
# WgzbNfiR+2fkHUiljNOqnIVD/gG3SYDEAd4dg2dDGpeZGKe+42DFUF0mR/vtLa4+
# gKPsYfwEu7EEbkC9+0F2w4QJLVSTEG8yAR2CQWIM1iI5PHg62IVwxKSpO0XaF9DP
# fNBKS7Zazch8NF5vp7eaZ2CVNxpqumzTCNSOxm+SAWSuIr21Qomb+zzQWKhxKTVV
# gtmUPAW35xUUFREmDrMxSNlr/NsJyUXzdtFUUt4aS4CEeIY8y9IaaGBpPNXKFifi
# nT7zL2gdFpBP9qh8SdLnEut/GcalNeJQ55IuwnKCgs+nrpuQNfVmUB5KlCX3ZA4x
# 5HHKS+rqBvKWxdCyQEEGcbLe1b8Aw4wJkhU1JrPsFfxW1gaou30yZ46t4Y9F20HH
# fIY4/6vHespYMQmUiote8ladjS/nJ0+k6MvqzfpzPDOy5y6gqztiT96Fv/9bH7mQ
# yogxG9QEPHrPV6/7umw052AkyiLA6tQbZl1KhBtTasySkuJDpsZGKdlsjg4u70Ew
# gWbVRSX1Wd4+zoFpp4Ra+MlKM2baoD6x0VR4RjSpWM8o5a6D8bpfm4CLKczsG7Zr
# IGNTAgMBAAGjggFdMIIBWTASBgNVHRMBAf8ECDAGAQH/AgEAMB0GA1UdDgQWBBTv
# b1NK6eQGfHrK4pBW9i/USezLTjAfBgNVHSMEGDAWgBTs1+OC0nFdZEzfLmc/57qY
# rhwPTzAOBgNVHQ8BAf8EBAMCAYYwEwYDVR0lBAwwCgYIKwYBBQUHAwgwdwYIKwYB
# BQUHAQEEazBpMCQGCCsGAQUFBzABhhhodHRwOi8vb2NzcC5kaWdpY2VydC5jb20w
# QQYIKwYBBQUHMAKGNWh0dHA6Ly9jYWNlcnRzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2Vy
# dFRydXN0ZWRSb290RzQuY3J0MEMGA1UdHwQ8MDowOKA2oDSGMmh0dHA6Ly9jcmwz
# LmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydFRydXN0ZWRSb290RzQuY3JsMCAGA1UdIAQZ
# MBcwCAYGZ4EMAQQCMAsGCWCGSAGG/WwHATANBgkqhkiG9w0BAQsFAAOCAgEAF877
# FoAc/gc9EXZxML2+C8i1NKZ/zdCHxYgaMH9Pw5tcBnPw6O6FTGNpoV2V4wzSUGvI
# 9NAzaoQk97frPBtIj+ZLzdp+yXdhOP4hCFATuNT+ReOPK0mCefSG+tXqGpYZ3ess
# BS3q8nL2UwM+NMvEuBd/2vmdYxDCvwzJv2sRUoKEfJ+nN57mQfQXwcAEGCvRR2qK
# tntujB71WPYAgwPyWLKu6RnaID/B0ba2H3LUiwDRAXx1Neq9ydOal95CHfmTnM4I
# +ZI2rVQfjXQA1WSjjf4J2a7jLzWGNqNX+DF0SQzHU0pTi4dBwp9nEC8EAqoxW6q1
# 7r0z0noDjs6+BFo+z7bKSBwZXTRNivYuve3L2oiKNqetRHdqfMTCW/NmKLJ9M+Mt
# ucVGyOxiDf06VXxyKkOirv6o02OoXN4bFzK0vlNMsvhlqgF2puE6FndlENSmE+9J
# GYxOGLS/D284NHNboDGcmWXfwXRy4kbu4QFhOm0xJuF2EZAOk5eCkhSxZON3rGlH
# qhpB/8MluDezooIs8CVnrpHMiD2wL40mm53+/j7tFaxYKIqL0Q4ssd8xHZnIn/7G
# ELH3IdvG2XlM9q7WP/UwgOkw/HQtyRN62JK4S1C8uw3PdBunvAZapsiI5YKdvlar
# Evf8EA+8hcpSM9LHJmyrxaFtoza2zNaQ9k+5t1wwggbtMIIE1aADAgECAhAKgO8Y
# S43xBYLRxHanlXRoMA0GCSqGSIb3DQEBCwUAMGkxCzAJBgNVBAYTAlVTMRcwFQYD
# VQQKEw5EaWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBH
# NCBUaW1lU3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTEwHhcNMjUwNjA0
# MDAwMDAwWhcNMzYwOTAzMjM1OTU5WjBjMQswCQYDVQQGEwJVUzEXMBUGA1UEChMO
# RGlnaUNlcnQsIEluYy4xOzA5BgNVBAMTMkRpZ2lDZXJ0IFNIQTI1NiBSU0E0MDk2
# IFRpbWVzdGFtcCBSZXNwb25kZXIgMjAyNSAxMIICIjANBgkqhkiG9w0BAQEFAAOC
# Ag8AMIICCgKCAgEA0EasLRLGntDqrmBWsytXum9R/4ZwCgHfyjfMGUIwYzKomd8U
# 1nH7C8Dr0cVMF3BsfAFI54um8+dnxk36+jx0Tb+k+87H9WPxNyFPJIDZHhAqlUPt
# 281mHrBbZHqRK71Em3/hCGC5KyyneqiZ7syvFXJ9A72wzHpkBaMUNg7MOLxI6E9R
# aUueHTQKWXymOtRwJXcrcTTPPT2V1D/+cFllESviH8YjoPFvZSjKs3SKO1QNUdFd
# 2adw44wDcKgH+JRJE5Qg0NP3yiSyi5MxgU6cehGHr7zou1znOM8odbkqoK+lJ25L
# CHBSai25CFyD23DZgPfDrJJJK77epTwMP6eKA0kWa3osAe8fcpK40uhktzUd/Yk0
# xUvhDU6lvJukx7jphx40DQt82yepyekl4i0r8OEps/FNO4ahfvAk12hE5FVs9HVV
# WcO5J4dVmVzix4A77p3awLbr89A90/nWGjXMGn7FQhmSlIUDy9Z2hSgctaepZTd0
# ILIUbWuhKuAeNIeWrzHKYueMJtItnj2Q+aTyLLKLM0MheP/9w6CtjuuVHJOVoIJ/
# DtpJRE7Ce7vMRHoRon4CWIvuiNN1Lk9Y+xZ66lazs2kKFSTnnkrT3pXWETTJkhd7
# 6CIDBbTRofOsNyEhzZtCGmnQigpFHti58CSmvEyJcAlDVcKacJ+A9/z7eacCAwEA
# AaOCAZUwggGRMAwGA1UdEwEB/wQCMAAwHQYDVR0OBBYEFOQ7/PIx7f391/ORcWMZ
# UEPPYYzoMB8GA1UdIwQYMBaAFO9vU0rp5AZ8esrikFb2L9RJ7MtOMA4GA1UdDwEB
# /wQEAwIHgDAWBgNVHSUBAf8EDDAKBggrBgEFBQcDCDCBlQYIKwYBBQUHAQEEgYgw
# gYUwJAYIKwYBBQUHMAGGGGh0dHA6Ly9vY3NwLmRpZ2ljZXJ0LmNvbTBdBggrBgEF
# BQcwAoZRaHR0cDovL2NhY2VydHMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0VHJ1c3Rl
# ZEc0VGltZVN0YW1waW5nUlNBNDA5NlNIQTI1NjIwMjVDQTEuY3J0MF8GA1UdHwRY
# MFYwVKBSoFCGTmh0dHA6Ly9jcmwzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydFRydXN0
# ZWRHNFRpbWVTdGFtcGluZ1JTQTQwOTZTSEEyNTYyMDI1Q0ExLmNybDAgBgNVHSAE
# GTAXMAgGBmeBDAEEAjALBglghkgBhv1sBwEwDQYJKoZIhvcNAQELBQADggIBAGUq
# rfEcJwS5rmBB7NEIRJ5jQHIh+OT2Ik/bNYulCrVvhREafBYF0RkP2AGr181o2YWP
# oSHz9iZEN/FPsLSTwVQWo2H62yGBvg7ouCODwrx6ULj6hYKqdT8wv2UV+Kbz/3Im
# ZlJ7YXwBD9R0oU62PtgxOao872bOySCILdBghQ/ZLcdC8cbUUO75ZSpbh1oipOhc
# UT8lD8QAGB9lctZTTOJM3pHfKBAEcxQFoHlt2s9sXoxFizTeHihsQyfFg5fxUFEp
# 7W42fNBVN4ueLaceRf9Cq9ec1v5iQMWTFQa0xNqItH3CPFTG7aEQJmmrJTV3Qhtf
# parz+BW60OiMEgV5GWoBy4RVPRwqxv7Mk0Sy4QHs7v9y69NBqycz0BZwhB9WOfOu
# /CIJnzkQTwtSSpGGhLdjnQ4eBpjtP+XB3pQCtv4E5UCSDag6+iX8MmB10nfldPF9
# SVD7weCC3yXZi/uuhqdwkgVxuiMFzGVFwYbQsiGnoa9F5AaAyBjFBtXVLcKtapnM
# G3VH3EmAp/jsJ3FVF3+d1SVDTmjFjLbNFZUWMXuZyvgLfgyPehwJVxwC+UpX2MSe
# y2ueIu9THFVkT+um1vshETaWyQo8gmBto/m3acaP9QsuLj3FNwFlTxq25+T4QwX9
# xa6ILs84ZPvmpovq90K8eWyG2N01c4IhSOxqt81nMYIFEzCCBQ8CAQEwNzAjMSEw
# HwYDVQQDDBhEYXJyZW4gR3JheSBDb2RlIFNpZ25pbmcCEHXH/osKFz2RTZxhwe+U
# pfkwDQYJYIZIAWUDBAIBBQCggYQwGAYKKwYBBAGCNwIBDDEKMAigAoAAoQKAADAZ
# BgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAcBgorBgEEAYI3AgELMQ4wDAYKKwYB
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQggAStUqdTBgXFRwJ05GgWX2xxpliQR8JG
# mrjHNXJylycwDQYJKoZIhvcNAQEBBQAEggEAPO9hRkN9oXWtZcwmgj+WJ7tijWTM
# wwg4IWZb4tsxha0HdBFF3Cs/AgVFjSEVa3aOY91v8ePH75eNt/aMsESw2rgj7sfL
# 7xtAXu2tLhXCabkZPiFRx/i5eFfoZQEKdayxqBL3Ki/mdbc9rW6Hk1Yp28GTE9yO
# pIO3B33ZWYnJ7mFkWru3QOqKQhtqdmrzSp9IIbGXKKaJ6Cf+uTkVtHsnDAdfJh+X
# KH7sVBU5kSxGEiGZCGb4yCqrCkIufSEgvgyn/0v1h04WubJ9FkhA9JM2samqIbfa
# MoOUnnp8TQSsDz4Z9ZQosAmIPg79f22CtUyl/emSKnDGNtYvMaebB9CHy6GCAyYw
# ggMiBgkqhkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYD
# VQQKEw5EaWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBH
# NCBUaW1lU3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAqA7xhLjfEF
# gtHEdqeVdGgwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcN
# AQcBMBwGCSqGSIb3DQEJBTEPFw0yNTA5MjIxOTQzMTNaMC8GCSqGSIb3DQEJBDEi
# BCDpEfX9npC/7AqXnaX66Vm3DRpQp9bjh2l3/uXFjHRlYDANBgkqhkiG9w0BAQEF
# AASCAgBem0OllO8t4QS8naABlmEji/0EHhjDkNqdpWOnM7H91S7wMUMsIpMyYuPQ
# CwVJnxr+Q5BBFyGOUkJt/co6wTFN9l/CugkYoyWx8yS40cJkC1dNLoLXr8eamLk/
# cRnpxLChWtEG79Q8mY0U2LZ2/WF3r6oKwRtNeZBNsUBtB03tGJWs8Caf6sLoX4tw
# usFcdlOnh9GDeDt+wR3uw6vBDen0ALg85UeDT7/Da2/z3UJgZFNSrM3q49W+XlNK
# asiGZdgiMLTUFHk3RfR1If+rEb3RM0qW5pRMGqiX15WWTKj+iX9m8p606R7E7TpJ
# 0q4+x9islSlpAhyNEqipF9SW5pHxl5oQEUpBFgC3n/G2p9oMIwhkFb2UHTMHtGxj
# rXwJBocZ4N/93iSYCoGOOLX7Bs4hspntCyyU6VCWkDS7KP8ZX28c7dvH6zosLBwg
# rnDMv6A7R30uhz9y5Q5r8FGcuG+2C0/T/v3EGfvYIim39s9rcK4wixYzyCOjF2+u
# 1qu6VkXT49lR3DhdebVlQknISedrjDPukYUoocLrooDTdZ3QUGuMJYHHWAkU8DlT
# fr3CgbthKinG/miBSO/GzcIVA7XVlFdvF/EF+Bj8BAG2OpyFQmGwjsZAujym4plU
# qIaeYQ0Zx3iapVdfd8H7MVEVvnzZ6jKfY8ROZ1441ECSCyQDhg==
# SIG # End signature block
