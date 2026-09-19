# Pi Agent Sandbox (`pi-sandbox`)

A secure, lightweight sandbox environment built with [Bubblewrap](https://github.com/containers/bubblewrap) (`bwrap`) for running local coding agents. 

This wrapper protects your host system from unintended modifications by executing the agent in a restricted namespace. It mounts your host filesystem (and sensitive configuration files) as read-only, while providing a dedicated, isolated workspace for the agent to write and execute code.

## 🛡️ Security Features

* **Read-Only Host OS:** System binaries (`/usr`, `/etc`, `/bin`) are mounted strictly read-only.
* **Protected Secrets:** Your `~/.pi` directory (containing API keys and base config) is mounted read-only to prevent credential tampering.
* **Targeted State Management:** A specific read-write hole is punched for `~/.pi/agent/` to allow the agent to manage its internal session history and lockfiles without breaking the read-only rule for the parent directory.
* **Flexible Workspaces:** By default, isolates agent outputs to a volatile `/tmp` directory. Easily attach persistent project directories using the `-w` flag.
* **Secure Privilege Dropping:** Utilizes Linux user namespaces (or SUID) to ensure the agent runs entirely as your standard, unprivileged user.

## ⚙️ Prerequisites & Permissions

You will need a Linux host environment with the `bubblewrap` package installed:
```bash
# Debian/Ubuntu
sudo apt install bubblewrap

# Fedora/RHEL
sudo dnf install bubblewrap

```

### The SUID Requirement (Hardened Kernels)

Many modern Linux distributions heavily restrict unprivileged user namespaces. If you encounter a `Permission denied` error when starting the sandbox, you must set the **SUID (Set Owner User ID) bit** on the Bubblewrap binary.

This safely allows `bwrap` to briefly elevate privileges to construct the isolated namespace before dropping back to your standard user to run the agent.

```bash
sudo chmod u+s $(which bwrap)

```

*(Verify the change by running `ls -l $(which bwrap)`. The output should include an `s`, like `-rwsr-xr-x`.)*

## 🚀 Installation

1. Save the `pi-sandbox.sh` script to a location in your PATH (e.g., `~/.local/bin/pi-sandbox` or `~/bin/pi-sandbox`).
2. Make the script executable:
3. 
```bash
chmod +x ~/.local/bin/pi-sandbox
```

3. *(Optional)* Add an alias to your `~/.bashrc` or `~/.zshrc` for quick access:
4. 
```bash
   alias pi-sandbox='~/.local/bin/pi-sandbox'
```

## 💻 Usage

### 1. Default Interactive Sandbox

Drop into an interactive, sandboxed terminal. The agent's workspace will be mapped to a temporary folder (`/tmp/pi-agent-workspace`) on your host machine.

```bash
pi-sandbox

```

### 2. Custom Project Workspace

Mount an existing project directory into the sandbox. The script automatically converts relative paths to absolute paths and mounts the folder read-write at `/workspace` inside the sandbox.

```bash
pi-sandbox -w ~/projects/my-app

```

### 3. Direct Agent Execution

Run the agent directly inside a specific workspace without dropping into an interactive shell first. You can pass the workspace flag followed by standard agent commands.

```bash
pi-sandbox -w ./src pi

```

## 🏗️ Architecture Details

Inside the sandbox, the filesystem hierarchy is heavily restricted:

* `/workspace` ➡️ The active, read-write project directory.
* `/usr`, `/etc`, `/bin` ➡️ Standard read-only host mounts.
* `/dev`, `/proc`, `/tmp` ➡️ Virtualized minimal filesystems required for standard Linux process execution.
* `/home/user/.pi` ➡️ Read-only mount of your primary agent configuration.
* `/home/user/.pi/agent` ➡️ Read-write overlay specifically for session and lockfile management.

*Note: Any host directories not explicitly bound in the `bwrap` execution script (such as the rest of your `~` directory) are completely invisible and inaccessible to the agent.*

