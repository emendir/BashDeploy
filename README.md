# Project Installer

An extensible drop-in installer script written in bash for software projects.

`install.sh` is a single-file, minimal installer designed to be dropped into the root of your project.
It copies your project into a deployment directory (locally or on a remote machine), installs systemd units (system & user), and runs optional hooks so project-specific setup can be performed.

It's Lightweight alternative to configuration management tools — no libraries, frameworks or runtimes required.
Depends only on `bash`, `rsync` and optionally `ssh` (for remote installs)

## Features

* Local or remote installation over SSH
* Copying of full source code for installation
* OPTIONAL Automatic systemd unit installation (services, timers, etc.)
* OPTIONAL Hooks for user-defined setup scripts
* Customisable default options, hook paths and systemd unit paths
* All in a **single Bash script**, with no dependencies beyond `ssh`, `rsync`, and `systemd`.

## Requirements & Compatibility

* Linux OS (with extra features for systems running `systemd`)
* `bash` and GNU `coreutils` (`readlink -f` is used)
* `rsync`
* `ssh` for remote installs.
* `sudo` available for actions that require root.

## Repository Layout

In its simplest form, it's just the `installer.sh` script in the project root.

In a full-blown setup with custom hooks, systemd units and an exclusion list, the default project structure looks like this:

```
.
├── deployment/
│   ├── hooks/
│   │   ├── post_copy.d/
│   │   ├── post_systemd.d/
│   │   ├── post_copy.sh
│   │   └── post_systemd.sh
│   └── systemd_units/
│       ├── system/
│       └── user/
├── install.sh
├── installer.conf
└── .gitignore
```

## Quick Start

### Implementation

1. Copy the `install.sh` script from this repo into the root of your project.
2. OPTIONAL: run `./install.sh --make-templates` to create the template for the full-blown setup described above.


### Install Your Project Locally

```bash
./install.sh --dir /opt/MyProject
```
1. copies project files to the specified directory (ignoring files from ignored patterns list file)
2. runs `deployment/post_copy` scripts (if available)
3. installs systemd units
4. runs `deployment/post_systemd` scripts (if available)

### Install Your Project on Remote Host

```bash
./install.sh --remote user@$IP_ADDR --dir /opt/MyProject
```
1. copies project files to the specified directory on the remote machine (ignoring files from ignored patterns list file)
2. runs `deployment/post_copy` scripts (if available)
3. installs systemd units
4. runs `deployment/post_systemd` scripts (if available)

## Common Options
```
--remote <user@host>     Install on remote machine via SSH
--dir <path>             Installation directory (default: /opt/<project>)
--exclude-from <path>    Installation directory (default: $DEF_EXCLUDE_FILE)
--with-systemd           Install systemd units (default: true)
--no-systemd             Skip systemd unit installation
--enable-units           Enable and start units after install (default: true)
--no-enable-units        Do not enable/start units after install
--help                   Show this help

```

## Documentation
- [Parameters](./docs/Parameters.md): all the CLI parameters
- [Hooks](./docs/Hooks.md): adding custom installation scripts
- [Systemd Units](./docs/SystemdUnits.md): all about working with auto-installed systemd units
- [Configuration](./docs/Parameters.md): configurable options via environment variables and installer.conf script


## Safety & security

**Read this before you run installers from untrusted sources.**

- The installer executes hook scripts and `installer.conf` as shell code — **treat them as executable code**.
- The installer uses `sudo` for system tasks; a malicious hook or unit can escalate privileges.
- `rsync --delete` will remove files in the target directory not present in the source — do not install into a directory that contains unrelated important files.
- Recommended caution:
    - Review hooks, `installer.conf`, and unit files before running.
    - Run the installer in a disposable VM/container for unknown sources.
    - Use signed releases and verify checksums / signatures.


👉 **In short:** treat all project files (hooks, configs, units) as trusted code. Audit before installing, especially when running with `sudo` or enabling services.


## Contributing

### Get Involved

- GitHub Discussions: if you want to share ideas
- GitHub Issues: if you find bugs, other issues, or would like to submit feature requests
- GitHub Merge Requests: if you think you know what you're doing, you're very welcome!

### Donations

To support me in my work on this and other projects, you can make donations with the following currencies:

- **Bitcoin:** `BC1Q45QEE6YTNGRC5TSZ42ZL3MWV8798ZEF70H2DG0`
- **Ethereum:** `0xA32C3bBC2106C986317f202B3aa8eBc3063323D4`
- [**Fiat** (via Credit or Debit Card, Apple Pay, Google Pay, Revolut Pay)](https://checkout.revolut.com/pay/4e4d24de-26cf-4e7d-9e84-ede89ec67f32)

Donations help me:
- dedicate more time to developing and maintaining open-source projects
- cover costs for IT infrastructure
- finance projects requiring additional hardware & compute

## About the Developer

This project is developed by a human one-man team, publishing under the name _Emendir_.  
I build open technologies trying to improve our world;
learning, working and sharing under the principle:

> _Freely I have received, freely I give._

Feel welcome to join in with code contributions, discussions, ideas and more!

## Open-Source in the Public Domain

I dedicate this project to the public domain.
It is open source and free to use, share, modify, and build upon without restrictions or conditions.

I make no patent or trademark claims over this project.  

Formally, you may use this project under either the: 
- [MIT No Attribution (MIT-0)](https://choosealicense.com/licenses/mit-0/) or
- [Creative Commons Zero (CC0)](https://choosealicense.com/licenses/cc0-1.0/)
licence at your choice.  

