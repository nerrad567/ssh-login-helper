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
    $baseArguments = "-o UserKnownHostsFile=`"$sshDirKnownHosts`" -o GlobalKnownHostsFile=NUL -p $currentPort $currentUser@$($server.RemoteAddress)"
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
