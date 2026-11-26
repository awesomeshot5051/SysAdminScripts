# ytdownload

yt-dlp wrapper with mp4, mp3, mov and wav output.

ytdownload downloads video or audio with yt-dlp at the best resolution and can convert the result to MOV or WAV using tovinci.

## Installation

### From Launchpad PPA (Recommended)

```bash
sudo add-apt-repository ppa:awesomeshot5051/ytdownload
sudo apt update
sudo apt install ytdownload
```

Or install every script at once with the bundle: `sudo apt install sysadmin-scripts`.

### Manual Installation

```bash
sudo install -m 755 ytdownload-pkg/usr/local/bin/ytdownload /usr/local/bin/ytdownload
```

### Dependencies

Required: bash, tovinci

Optional: yt-dlp, ffmpeg

## Usage

Run `ytdownload --help` for usage and options.

## License

Licensed under the Apache License 2.0. See LICENSE for details.
