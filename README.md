# Hotswap

Hot-swap a SQLite database on a running Rails server without restarting the process. Requests queue briefly during the swap, then resume on the new database.

## How it works

Hotswap communicates over a Unix socket (`tmp/sockets/hotswap.sock`). A Rack middleware wraps every request in a mutex. During a swap, the CLI acquires the same mutex — requests queue for microseconds while the database file is atomically renamed, then resume on the new database.

```
Client                                Server
┌──────────────────┐                  ┌────────────────────┐
│ bin/hotswap      │── connect ──────▶│ Socket listener    │
│   sends command  │── "cp ..." ─────▶│   parses args      │
│   pipes stdin    │── bytes ────────▶│   Thor CLI runs    │
│   reads stdout   │◀── output ───────│   IO = socket      │
└──────────────────┘                  └────────────────────┘
```

Pull uses SQLite's backup API for WAL-safe consistent snapshots — no need to stop writes.

## Installation

Add to your Gemfile:

```ruby
gem "hotswap"
```

The railtie auto-configures everything:
- Inserts the swap-lock middleware
- Starts the socket server when the web server boots
- Discovers all SQLite databases from `database.yml` (multi-database supported)
- Sets `Hotswap.logger` to `Rails.logger`

## Usage

### Replace the running database

```bash
bin/hotswap cp ./new.sqlite3 db/production.sqlite3
```

The file is integrity-checked before the swap. If it's corrupt, the running database is untouched.

### Snapshot the running database

```bash
bin/hotswap cp db/production.sqlite3 ./backup.sqlite3
```

Uses SQLite's backup API — safe to run while the app is serving requests, even with WAL mode.

### Pipes

```bash
# Push from stdin
cat new.sqlite3 | bin/hotswap cp - db/production.sqlite3

# Pull to stdout
bin/hotswap cp db/production.sqlite3 - > backup.sqlite3

# Stream between servers
ssh prod 'cd app && bin/hotswap cp db/production.sqlite3 -' | bin/hotswap cp - db/production.sqlite3
```

### Stderr

Errors and status messages go to a separate stderr socket (`tmp/sockets/hotswap.stderr.sock`), so they never mix with binary database output during a pull.

```
$ bin/hotswap cp ./new.sqlite3 db/production.sqlite3
Swapping database...     # ← stderr
OK                       # ← stdout
```

## Logging

Hotswap logs every step of the swap lifecycle. In Rails, logs go through `Rails.logger`. Without Rails, they default to stdout.

```
INFO -- hotswap: command: cp new.sqlite3 db/production.sqlite3
INFO -- hotswap: push started: new.sqlite3 → db/production.sqlite3
INFO -- hotswap: received 8192 bytes, running integrity check
INFO -- hotswap: integrity check passed, acquiring swap lock
INFO -- hotswap: swap lock acquired, requests are queued
INFO -- hotswap: disconnected ActiveRecord
INFO -- hotswap: renamed /tmp/hotswap123.sqlite3 → db/production.sqlite3
INFO -- hotswap: swap lock released, requests resuming
INFO -- hotswap: reconnected ActiveRecord
INFO -- hotswap: push complete: db/production.sqlite3
```

The middleware also logs when requests are queued during a swap:

```
INFO -- hotswap: request queued, waiting for swap to complete: GET /items
INFO -- hotswap: swap complete, resuming request: GET /items
```

To customize the logger:

```ruby
Hotswap.logger = Logger.new("log/hotswap.log")
```

## Why only `cp`?

Hotswap deliberately only supports `cp`. No `ln`, `mv`, or `rm`.

**`cp` is safe.** The new database is written to a temp file, integrity-checked, then atomically renamed into place inside a swap lock. If anything fails, the original database is untouched. Worst case: an orphaned temp file.

**`ln` would bypass safety.** Symlinks mean WAL/SHM files get created next to the link, not the target. The source file stays mutable — modifications happen outside the swap lock with no integrity check. Hard links have similar issues with SQLite's locking model.

**`mv` risks data loss.** The source file is gone after the move. If someone runs `hotswap mv db/production.sqlite3 backup.sqlite3`, they just deleted the running database.

**`rm` is just destructive.** There's no reason to delete a database through the socket server.

The atomic rename that `cp` does under the hood *is* a link/unlink at the filesystem level — but wrapped in an integrity check and swap lock. Exposing link/unlink directly would just be `cp` without the safety.

## Configuration

The railtie configures everything automatically, including multi-database setups. It discovers all SQLite databases from your `database.yml`. To override:

```ruby
# config/application.rb
config.hotswap.database_path = Rails.root.join("db/production.sqlite3")
config.hotswap.socket_path = Rails.root.join("tmp/sockets/hotswap.sock")
config.hotswap.stderr_socket_path = Rails.root.join("tmp/sockets/hotswap.stderr.sock")
```

Or configure without Rails:

```ruby
Hotswap.configure do |c|
  c.database_path = "/path/to/database.sqlite3"
  c.socket_path = "/path/to/hotswap.sock"
  c.stderr_socket_path = "/path/to/hotswap.stderr.sock"
end
```

## CLI Reference

| Command | Description |
|---|---|
| `hotswap cp <src> <dst>` | Copy a database to/from the running server |
| `hotswap cp - <db_path>` | Push from stdin |
| `hotswap cp <db_path> -` | Pull to stdout |
| `hotswap version` | Print version |

Either `<src>` or `<dst>` must match a managed database path. Use `-` for stdin/stdout.

## Deployment examples

### SSH

```bash
# Two-step
scp new.sqlite3 server:~/app/tmp/
ssh server 'cd app && bin/hotswap cp tmp/new.sqlite3 db/production.sqlite3'

# One-shot
cat new.sqlite3 | ssh server 'cd app && bin/hotswap cp - db/production.sqlite3'
```

### Fly.io

```bash
# Push
cat new.sqlite3 | fly ssh console -C "/rails/bin/hotswap cp - /rails/db/production.sqlite3"

# Pull
fly ssh console -C "/rails/bin/hotswap cp /rails/db/production.sqlite3 -" > backup.sqlite3
```

## License

MIT
