# tovinci

Convert media into DaVinci Resolve friendly formats.

tovinci converts video to DNxHR, ProRes or H.264, audio to WAV and images to JPEG using ffmpeg. It can combine clips, resume long jobs and estimate output size with a dry run.

## Installation

### From Launchpad PPA (Recommended)

```bash
sudo add-apt-repository ppa:awesomeshot5051/tovinci
sudo apt update
sudo apt install tovinci
```

Or install every script at once with the bundle: `sudo apt install sysadmin-scripts`.

### Manual Installation

```bash
sudo install -m 755 tovinci-pkg/usr/local/bin/tovinci /usr/local/bin/tovinci
```

### Dependencies

Required: python3, ffmpeg

## Usage

Run `tovinci --help` for usage and options.

## License

Licensed under the Apache License 2.0. See LICENSE for details.
