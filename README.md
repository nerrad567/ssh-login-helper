# 🖥️ SSH Login Helper – Smart SSH Menu via PowerShell

![Platform](https://img.shields.io/badge/Platform-Windows%2010%2F11-blue?style=for-the-badge&logo=windows)
![Requires](https://img.shields.io/badge/Requires-PowerShell%205.1%2B-4B275F?style=for-the-badge&logo=powershell)
![Automation](https://img.shields.io/badge/Automation-Config%20Parser%20%2B%20Menu%20Launcher-00BFFF?style=for-the-badge&logo=json)
![Version](https://img.shields.io/badge/Version-1.2-blue?style=for-the-badge)
![Status](https://img.shields.io/badge/Status-Stable%20Release-brightgreen?style=for-the-badge)
![License](https://img.shields.io/badge/License-MIT-yellow?style=for-the-badge)


A **PowerShell** script that parses your **SSH config** (using a companion `conf.json`) to provide a quick interactive menu for connecting to remote hosts.

---

## Description

- **Script Name**: `ssh_login_helper.ps1`
- **Author**: [Darren Gray](https://github.com/nerrad567) (with ChatGPT & GrokAI assistance)
- **Created**: March 28, 2025
- **Version**: 1.2  

This script reads your standard OpenSSH `config` file (path configurable in `conf.json`) and displays an interactive menu of your hosts. It then tries to connect using:
1. **SSH agent keys** first (if loaded).
2. **Specified key** from your SSH config (if any).
3. **Fallback**: searches known SSH keys in directories defined in `conf.json`.

> **Note**: The `conf.json` file is *not* your actual SSH config. It’s an additional metadata/settings file containing:
>
> - Custom host descriptions
> - Default user/port/post-connect command
> - Per-host overrides
> - Path overrides for SSH config directories

---

## Features

- **Automatic Key Discovery**  
  Searches `~/.ssh` or other directories for valid private keys if none is specified in the config.

- **Alias Handling**  
  If your SSH config has multiple `Host` entries with duplicate aliases, it suffixes them with `(#N - hostname)` to differentiate.

- **Menu Interface**  
  Presents hosts in a clear, color-coded list, and prompts you by number.

- **Post-Connect Command**  
  Optionally run commands (e.g., `htop`) automatically upon SSH login.

- **Known Hosts Cleanup**  
  Merges any duplicates from your default known_hosts into one file for convenience.

---

## Quick Start

1. **Clone or Download** this repository.
2. **Edit `conf.json`** to specify:
   - The path to your SSH config and directories (`Paths.SSHConfig`, `Paths.SSHDir`, `Paths.DefaultSSHDir`).
   - Host descriptions (`HostDescriptions`).
   - Default and per-host settings (`Defaults` and `PerHostSettings`).
3. **Open PowerShell** in this repo’s directory (or add this folder to your `$Env:PATH`).
4. **Run**:
   ```powershell
   .\ssh_login_helper.ps1
   ```
5. **Select a Server** from the menu:
   ```plaintext
   ╔═══════════════════════════════════════════════════════╗
   ║                SSH Login Helper                      ║
   ╚═══════════════════════════════════════════════════════╝

   1   my-ec2     [ec2-xx-xxx-xx.compute.amazonaws.com]  (ec2-user)  AWS EC2 instance
   2   my-vps     [123.45.67.89]                         (root)      DigitalOcean VPS

   Q. Quit
   ```

   - **Enter** `1` to connect to `my-ec2` or `2` for `my-vps`, etc.

---

## Example `conf.json`

```json
{
  "//": "This file is NOT your SSH config. It stores optional metadata & launch settings for the SSH Login Helper.",
  "Paths": {
    "SSHConfig": "%USERPROFILE%\\OneDrive\\.ssh\\config",
    "SSHDir": "%USERPROFILE%\\OneDrive\\.ssh",
    "DefaultSSHDir": "%USERPROFILE%\\.ssh"
  },
  "HostDescriptions": {
    "my-ec2": "AWS EC2 instance",
    "my-vps": "DigitalOcean VPS"
  },
  "Defaults": {
    "Port": 22,
    "PostConnectCommand": "",
    "User": "your-username",
    "WorkingDirectory": "~"
  },
  "PerHostSettings": {
    "my-ec2": {
      "Port": 2222,
      "User": "ec2-user"
    },
    "my-vps": {
      "PostConnectCommand": "htop",
      "User": "root"
    }
  }
}
```

Change the `HostDescriptions` or `PerHostSettings` to match your own hosts, or remove them if you don’t need special overrides.

---

## Requirements

- **PowerShell 5.1+**  
  (Works on Windows 10/11; can be adapted for PowerShell Core on Linux/macOS with small tweaks.)
- **OpenSSH Client**  
  Ensure `ssh.exe` is installed/available. On Windows, you can enable it via *Manage Optional Features*.
- **A Valid SSH config**  
  Typically at `~/.ssh/config` or as defined in `conf.json`.

---

## Contributing

Feel free to **fork** this repo and submit a **pull request** if you have improvements:
- Enhanced logging
- Additional key-handling logic
- Error-handling or UX improvements

---

## License

This project is licensed under the [MIT License](./LICENSE).  
You are free to use, modify, and distribute this script under MIT terms.

---

### Author

**Darren Gray**  
Repo: [nerrad567](https://github.com/nerrad567)  
(Assisted by ChatGPT & GrokAI)

*Thanks for checking out **SSH Login Helper**! If you find it useful, consider giving the repo a ⭐ or opening an issue for feedback.*
```
