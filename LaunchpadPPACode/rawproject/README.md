# rawproject

Raw-footage project folders on a file server or local btrfs disk.

rawproject creates, finishes and lists raw-footage project folders on a file server over ssh, or on a local btrfs disk with snapper snapshots.

## Installation

### From Launchpad PPA (Recommended)

```bash
sudo add-apt-repository ppa:awesomeshot5051/rawproject
sudo apt update
sudo apt install rawproject
```

Or install every script at once with the bundle: `sudo apt install sysadmin-scripts`.

### Manual Installation

```bash
sudo install -m 755 rawproject-pkg/usr/local/bin/rawproject /usr/local/bin/rawproject
```

### Dependencies

Required: bash, openssh-client

Optional: btrfs-progs, snapper

## Usage

Run `rawproject --help` for usage and options.

## License

Licensed under the Apache License 2.0. See LICENSE for details.
