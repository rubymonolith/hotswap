# Hotswap

Hot-swap a SQLite database on a running Rails server without restarting the process. Requests queue briefly during the swap, then resume on the new database.

## How it works

Hotswap communicates over a Unix socket (`tmp/sqlite3.sock`). A Rack middleware wraps every request in a mutex. During a swap, the CLI acquires the same mutex — requests queue for microseconds while the database file is renamed, then resume on the new database.

```
Client                               Server
┌───────────────────┐  Unix Socket  ┌───────────────────────┐
│ bin/hotswap        │──connect────▶│ Socket listener        │
│  sends command     │──"cp ..."──▶│  parses args           │
│  pipes stdin       │──bytes─────▶│  Thor CLI runs         │
│  reads stdout      │◀─output────│  IO = socket            │
└───────────────────┘              └───────────────────────┘
```

Pull uses SQLite's backup API for WAL-safe consistent snapshots — no need to stop writes.

## Installation

Add to your Gemfile:

```ruby
gem "hotswap"
```

The railtie auto-configures everything:
- Inserts the swap-lock middleware
- Starts the socket server on boot
- Detects your SQLite database path from `database.yml`

## Usage

### Replace the running database

```bash
bin/hotswap cp ./new.sqlite3 database
```

The file is integrity-checked before the swap. If it's corrupt, the running database is untouched.

### Snapshot the running database

```bash
bin/hotswap cp database ./backup.sqlite3
```

Uses SQLite's backup API — safe to run while the app is serving requests, even with WAL mode.

### Pipes work too

```bash
# Push from stdin
cat new.sqlite3 | bin/hotswap push

# Pull to stdout
bin/hotswap pull > backup.sqlite3

# Stream directly between servers
ssh prod 'cd app && bin/hotswap pull' | bin/hotswap push
```

### Stderr

Errors and status messages go to a separate stderr socket (`tmp/sqlite3.stderr.sock`), so they never mix with binary database output during a pull.

```
$ bin/hotswap cp ./new.sqlite3 database
Swapping database...     # ← stderr
OK                       # ← stdout
```

## Configuration

The railtie configures everything automatically. To override:

```ruby
# config/application.rb
config.hotswap.database_path = Rails.root.join("db/production.sqlite3")
config.hotswap.socket_path = Rails.root.join("tmp/sqlite3.sock")
config.hotswap.stderr_socket_path = Rails.root.join("tmp/sqlite3.stderr.sock")
```

Or configure without Rails:

```ruby
Hotswap.configure do |c|
  c.database_path = "/path/to/database.sqlite3"
  c.socket_path = "/path/to/sqlite3.sock"
  c.stderr_socket_path = "/path/to/sqlite3.stderr.sock"
end
```

## CLI Reference

| Command | Description |
|---|---|
| `hotswap cp <src> database` | Replace the running database from a file |
| `hotswap cp database <dst>` | Snapshot the running database to a file |
| `hotswap cp - database` | Replace from stdin |
| `hotswap cp database -` | Snapshot to stdout |
| `hotswap push` | Shortcut for `cp - database` |
| `hotswap pull` | Shortcut for `cp database -` |
| `hotswap version` | Print version |

## Deployment example

```bash
# Build a new database locally, push it to production
sqlite3 new.sqlite3 < schema.sql
scp new.sqlite3 server:~/app/tmp/
ssh server 'cd app && bin/hotswap cp tmp/new.sqlite3 database'
```

Or in one shot:

```bash
ssh server 'cd app && bin/hotswap push' < new.sqlite3
```

## License

MIT
