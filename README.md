webtorrent-fuse
===============

This program allows mounting a torrent, as streamed by [WebTorrent](https://github.com/webtorrent/webtorrent-cli) over HTTP, in a filesystem directory (using FUSE).

For some reason, the HTTP URLs exposed by WebTorrent have a flat, numbered layout, and do not correspond to the torrent's original directory structure. This program maps those URLs to files following the original directory structure.

In effect, this does roughly the same as [btfs](https://github.com/johang/btfs), but uses WebTorrent for streaming the torrent data.


Building
--------

- Install [a D compiler](https://dlang.org/download.html)
- Install [Dub](https://github.com/dlang/dub), if it wasn't included with your D compiler
- Run `dub build -b release`


Usage
-----

```shell
# 1. Start WebTorrent
$ webtorrent https://.../my-data.torrent

# 2. Create a directory where webtorrent-fuse will be mounted
$ mkdir ~/my-data

# 3. Run webtorrent-fuse
$ webtorrent-fuse ~/my-data
```

By default, `webtorrent-fuse` will mount data at the default WebTorrent URL (`http://127.0.0.1:8000`), but this can be overridden - run with `--help` for details.
