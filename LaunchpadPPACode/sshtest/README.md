# sshtest

Wait for a host to come up and accept SSH logins.

sshtest polls a host until it accepts SSH logins, with adjustable verbosity. Uses sshpass for password checks when available.

## Installation

### From Launchpad PPA (Recommended)

```bash
sudo add-apt-repository ppa:awesomeshot5051/sshtest
sudo apt update
sudo apt install sshtest
```

Or install every script at once with the bundle: `sudo apt install sysadmin-scripts`.

### Manual Installation

```bash
sudo install -m 755 sshtest-pkg/usr/local/bin/sshtest /usr/local/bin/sshtest
```

### Dependencies

Required: bash, openssh-client

Optional: sshpass

## Usage

Run `sshtest --help` for usage and options.

## License

Licensed under the Apache License 2.0. See LICENSE for details.
