# sysadmin-scripts

A meta-package that installs the whole script collection in one step. It contains no files of its
own, only dependencies on: `catdir`, `fastget`, `hostsync`, `nasmv`, `rawproject`, `screenson`, `sshtest`, `tovinci`, `ytdownload`.

## Installation

```bash
sudo add-apt-repository ppa:awesomeshot5051/sysadmin-scripts
sudo apt update
sudo apt install sysadmin-scripts
```

Each script is also published and installable on its own (`sudo apt install tovinci`, etc.).

## Publishing note

Each script has its own PPA (`ppa:awesomeshot5051/<name>`), and this bundle has its own too. The
bundle depends on the others by name, so either add every script's PPA before installing, or in the
bundle PPA's Launchpad page use "Edit PPA dependencies" to add each script's PPA so apt can resolve
them automatically. Upload the individual packages first, then the bundle.

## License

Licensed under the Apache License 2.0. See LICENSE for details.
