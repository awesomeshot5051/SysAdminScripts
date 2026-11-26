# screenson

Reset monitor brightness to 100% over DDC/CI.

screenson uses ddcutil to reset the hardware brightness of displays 1 to 3 to 100%. It must be run as root.

## Installation

### From Launchpad PPA (Recommended)

```bash
sudo add-apt-repository ppa:awesomeshot5051/screenson
sudo apt update
sudo apt install screenson
```

Or install every script at once with the bundle: `sudo apt install sysadmin-scripts`.

### Manual Installation

```bash
sudo install -m 755 screenson-pkg/usr/local/bin/screenson /usr/local/bin/screenson
```

### Dependencies

Required: bash, ddcutil

## Usage

Run `screenson --help` for usage and options.

## License

Licensed under the Apache License 2.0. See LICENSE for details.
