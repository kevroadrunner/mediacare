# MediaCare

MediaCare is a small Docker container that periodically maintains a video archive:
- removes files older than the configured retention period;
- enforces a maximum directory size by deleting the oldest files first;
- remuxes eligible MP4 files without re-encoding;
- records successfully processed files in a persistent repair index;
- publishes the result of the latest run as JSON.

The container uses FFmpeg, FFprobe, Bash and Supercronic. Runtime logs are written to stdout/stderr and are available through `docker logs`.

## Build

Build on the Unraid host (or another Docker host):

```bash
docker build -t mediacare:latest .
```

The Dockerfile supports `amd64` and `arm64` BuildKit target architectures.

## Unraid container configuration

| Setting        | Value                            |
|----------------|----------------------------------|
| Name           | `mediacare`                      |
| Repository     | `kevroadrunner/mediacare:latest` |
| Network        | Bridge (no ports required)       |
| Restart policy | Unless stopped                   |
| `/data`        | `/mnt/user/media_files`          |
| `/app`         | `/mnt/user/appdata/mediacare`    |

Add these environment variables:

| Variable         | Default         | Description                        |
|------------------|-----------------|------------------------------------|
| `TZ`             | `Europe/Berlin` | Container timezone                 |
| `CRON_SCHEDULE`  | `0 */2 * * *`   | Cron schedule                      |
| `LIMIT_GB`       | `100`           | Maximum archive size in GiB        |
| `MAX_DAYS`       | `7`             | File retention age in days         |
| `REPAIR_MINUTES` | `20`            | Minimum file age before repair     |
| `RUN_ON_START`   | `false`         | Run once when the container starts |

No ports are exposed. (Maybe in the future with a fancy web UI 😉)

## Persistent application data

The `/app` mount contains:

```text
/app/
├── last_run.json
└── state/
    ├── repair.lock
    └── repair_index.log
```

`repair.lock` is a `flock` lock file. It is expected to remain on disk; the kernel lock is automatically released when the process exits.

## Logs

```bash
docker logs -f mediacare
```

For bounded Docker logs, configure log rotation on the Docker host. For example:

```text
max-size=10m
max-file=3
```

## Manual run

Start a maintenance run inside the running container:

```bash
docker exec -it mediacare /usr/local/bin/run-once.sh
```

The same lock is used by scheduled and manual runs, so a second run will be skipped while another one is active.

## Latest run status

The latest completed run is written atomically to:

```text
/app/last_run.json
```

Possible status values:
- `success`: the run completed without reported errors;
- `warning`: one or more individual MP4 repairs failed;
- `failed`: a fatal maintenance or status-writing error occurred.

A run skipped because another run holds the lock does not overwrite the last-run status.

## Notes

- The data volume is mounted read/write because MediaCare deletes and replaces files.
- MP4 repair is a stream-copy remux. It does not re-encode video or audio.
- FFprobe validation confirms that the output container can be parsed; it is not a full decode/integrity test of every media packet.
- The repair index stores paths relative to `/data`.
- Keep `/app` persistent. Removing it resets the repair history.
