# Web interface

The board serves a web interface on its PS Ethernet port. From any browser on the same
network you can:

* see the link state, speed and traffic of the four Ethernet FMC Max ports,
* choose TAP or monitor mode for each port pair,
* start and stop a capture, by hand or after a duration or size limit,
* watch live statistics: frame and bit rates, drops, buffer fill, disk space,
* list, download (as pcapng) and delete captures.

```{warning}
The web interface has **no authentication** and no encryption. Anyone who can reach the
board's address can start and delete captures and download their contents. Keep the
board on a trusted network.
```

## Opening the UI

The image starts the server at boot (`pktrec-web.service`). The PS Ethernet port (`end0`)
gets its address by DHCP. Once it has one, the UART console prints the URL:

```
pktrec web UI: http://192.168.2.110:8080/
```

The login prompt on the UART shows the same line. You can also find the address with
`ip addr show end0`. Then open `http://<board-ip>:8080/` in a browser.

The server listens on `end0` only, so the four Ethernet FMC Max ports never expose it.
The settings are in `/etc/default/pktrec-web`:

| Variable | Default | Meaning |
|----------|---------|---------|
| `PKTREC_WEB_IFACE` | `end0` | Interface to serve on. The server keeps working when DHCP changes the address. |
| `PKTREC_WEB_PORT` | `8080` | TCP port |
| `PKTREC_WEB_ARGS` | - | Extra options, for example `--bind 0.0.0.0` (all interfaces) or `--rec-dir <dir>` |

Run `systemctl restart pktrec-web` after you change them.

The service runs as root. It needs root for the recorder device and its hugepages, for the
register maps of the capture block and the PHYs, and for direct writes to the SSD.

## Using it

**Ports.** There is one card per port. It shows the link state, speed and duplex, the
datapath of the port, frames/s and bits/s, total frames, drops and the high-water mark of
the port's frame FIFO.

**Mode.** Each pair, P0/P1 and P2/P3, has its own mode:

* **TAP.** The two ports forward to each other in the fabric, and both directions are
  captured.
* **Monitor.** The ports only receive.

You can't change the mode while a capture is running.

**Capture.** To start a capture:

1. Tick the ports to capture.
2. Optionally set a snap length (bytes kept per frame, 0 = whole frames).
3. Optionally set a duration or size limit.
4. Optionally name the capture. The default name is `cap-<date>-<time>` (UTC).
5. Click **Start capture**.

The capture is written to `/mnt/rec/captures/<name>.cap` on the SSD. It stops when you
click **Stop** or when it reaches its limit. When it ends, the page says whether it was
lossless. If frames were dropped, it says so and gives the drop counts.

The SSD must be mounted at `/mnt/rec`. If it isn't, the server refuses to start a
capture.

**Captures.** The table lists each capture with its start time, duration, size, ports
and drops. Each row has these actions:

* **pcapng** downloads the capture converted to pcapng. The conversion runs while the file
  downloads, so no second copy is written to the SSD.
* **raw** downloads the `.cap` file itself. You can convert it later with `pktrec-export`.
* **info** shows the capture's header.
* **delete** removes the capture.

## API

The UI uses a small JSON API, which you can also script, for example with `curl`.
Requests and responses are JSON. Errors return `{"error": "<message>"}` with an HTTP status
code:

* 400: bad request
* 404: not found
* 405: wrong method
* 409: conflict, for example a capture is already running
* 503: the SSD is not mounted
* 500: a tool failed

| Method and path | Body | Returns |
|-----------------|------|---------|
| `GET /api/status` | - | `ports[]` (link, speed, duplex, SGMII sync, path, counters), `pairs[]` (mode `tap`, `monitor` or `other`), `capture`, `disk`, `time` (system time, timebase), `version`, `errors` |
| `GET /api/stats` | - | `capture` (state, name, elapsed, file size, live: write MB/s, ring buffers used/total, back-pressure, per-port rates and drops; `last` = result of the previous capture), `counters` (per port: frames, bytes, drops, bad, truncated, FIFO high-water, frames/s, bits/s), `disk`. Poll it once a second. |
| `POST /api/mode` | `{"pair": 0 or 1, "mode": "tap" or "monitor"}` | the new `pairs[]` |
| `POST /api/capture/start` | `{"ports": [0,1,2,3], "snaplen": 0, "duration_s": 60, "size_bytes": 1000000000, "name": "test1"}`; everything optional | 202 and the capture state |
| `POST /api/capture/stop` | - | the capture state, after the capture has stopped (up to 15 s) |
| `GET /api/captures` | - | `captures[]` (name, file size, start time, duration, ports, drops, complete, recording), `disk` |
| `GET /api/captures/<name>/info` | - | header fields and the text of `pktrec-cap info` |
| `GET /api/captures/<name>.pcapng` | - | the pcapng file, streamed (chunked, `Content-Disposition: attachment`) |
| `GET /api/captures/<name>.cap` | - | the raw capture file |
| `DELETE /api/captures/<name>` | - | `{"deleted": "<name>"}` |

Capture names may use letters, digits, `.`, `_` and `-` (up to 64 characters).

Example:

```bash
B=http://192.168.2.110:8080
curl -s $B/api/status | python3 -m json.tool
curl -s -X POST $B/api/mode -d '{"pair": 0, "mode": "tap"}'
curl -s -X POST $B/api/capture/start -d '{"ports": [0, 1], "duration_s": 30, "name": "run1"}'
curl -s $B/api/stats
curl -OJ $B/api/captures/run1.pcapng        # after it has stopped
curl -s -X DELETE $B/api/captures/run1
```

## How it works

`pktrec-web` (`sw/pktrec-web`) is a Python 3 program that uses only the standard library.
It runs a threaded HTTP server and drives the command-line tools as subprocesses:

| Function | Tool |
|----------|------|
| Link state and datapath per port | `pktrec-phy status`. The text output is parsed. |
| TAP / monitor | `pktrec-phy path <port> fwd` for both ports of the pair (TAP), or `idle` (monitor) |
| Counters, timebase, capture block version | `pktrec-cap stats`, at most once every 0.8 s, shared by all clients; the rates come from the difference between two readings |
| Capture | `pktrec-cap record --ports … --snaplen … [--duration …] [--size …] <file>`. Its live statistics on stderr feed `/api/stats`. **Stop** sends it `SIGTERM`, and it then ends the capture cleanly. |
| Capture list | The 4 KB file headers, read directly (format in `include/pktrec_format.h`) |
| Capture info | `pktrec-cap info <file>` |
| pcapng download | `pktrec-export <file> -o -`, piped to the browser in 256 KB chunks |

One capture runs at a time. If the service is stopped or restarted during a capture, the
capture is stopped cleanly first.

To try the UI on a PC without a board, use `pktrec-web --mock`, which stands the tools in
with `sw/pktrec-web/mock_tools.py`. `sw/pktrec-web/test_api.py` exercises every endpoint
against a running server, on the board or in mock mode:

```bash
cd sw/pktrec-apps && make pktrec-export && cd ../..
sw/pktrec-web/pktrec-web --mock --bind 127.0.0.1 --rec-dir /tmp/rec \
    --pktrec-export sw/pktrec-apps/pktrec-export &
sw/pktrec-web/test_api.py --url http://127.0.0.1:8080 --lint
```
