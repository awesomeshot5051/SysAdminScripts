# nasmv

Fast move or copy of files to a file server.

nasmv moves (or copies) files to a file server using rsync, tuned for a gigabit LAN. The source is deleted only after each file is confirmed transferred.

## Installation

### From Launchpad PPA (Recommended)

```bash
sudo add-apt-repository ppa:awesomeshot5051/nasmv
sudo apt update
sudo apt install nasmv
```

Or install every script at once with the bundle: `sudo apt install sysadmin-scripts`.

### Manual Installation

```bash
sudo install -m 755 nasmv-pkg/usr/local/bin/nasmv /usr/local/bin/nasmv
```

### Dependencies

Required: bash, rsync

## Usage

Run `nasmv --help` for usage and options.

## License

Licensed under the Apache License 2.0. See LICENSE for details.
