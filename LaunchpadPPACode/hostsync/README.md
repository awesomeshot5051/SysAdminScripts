# hostsync

rsync wrapper for syncing files across many hosts.

hostsync pushes files or directories to one or many hosts over rsync and ssh, with host lists, subnet and domain discovery, and exclusions.

## Installation

### From Launchpad PPA (Recommended)

```bash
sudo add-apt-repository ppa:awesomeshot5051/hostsync
sudo apt update
sudo apt install hostsync
```

Or install every script at once with the bundle: `sudo apt install sysadmin-scripts`.

### Manual Installation

```bash
sudo install -m 755 hostsync-pkg/usr/local/bin/hostsync /usr/local/bin/hostsync
```

### Dependencies

Required: python3, rsync, openssh-client

Optional: sshpass, dnsutils

## Usage

Run `hostsync --help` for usage and options.

## License

Licensed under the Apache License 2.0. See LICENSE for details.
