# fastget

Multi-connection file downloader.

fastget wraps aria2c to download a file over many parallel connections (16 by default) and saves it to a chosen directory.

## Installation

### From Launchpad PPA (Recommended)

```bash
sudo add-apt-repository ppa:awesomeshot5051/fastget
sudo apt update
sudo apt install fastget
```

Or install every script at once with the bundle: `sudo apt install sysadmin-scripts`.

### Manual Installation

```bash
sudo install -m 755 fastget-pkg/usr/local/bin/fastget /usr/local/bin/fastget
```

### Dependencies

Required: bash, aria2

## Usage

Run `fastget --help` for usage and options.

## License

Licensed under the Apache License 2.0. See LICENSE for details.
