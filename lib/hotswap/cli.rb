require "thor"
require "tempfile"
require "fileutils"
require "sqlite3"

module Hotswap
  class CLI < Thor
    def self.exit_on_failure?
      false
    end

    class Shell < Thor::Shell::Basic
      def initialize(stdout, stderr)
        super()
        @_stdout = stdout
        @_stderr = stderr
      end

      def stdout = @_stdout
      def stderr = @_stderr
    end

    # Thread-safe IO: each connection gets its own IO via thread-local storage
    # instead of swapping global $stdin/$stdout/$stderr.
    def self.run(args, stdin: $stdin, stdout: $stdout, stderr: $stderr)
      Thread.current[:hotswap_stdin] = stdin
      Thread.current[:hotswap_stdout] = stdout
      Thread.current[:hotswap_stderr] = stderr

      args = ["help"] if args.empty?
      start(args, shell: Shell.new(stdout, stderr))
    rescue SystemExit
      # Thor calls exit on errors — catch it so we don't kill the server
    ensure
      Thread.current[:hotswap_stdin] = nil
      Thread.current[:hotswap_stdout] = nil
      Thread.current[:hotswap_stderr] = nil
    end

    desc "cp SRC DST", "Copy a database to/from the running server. Use 'database' to refer to the running database."
    long_desc <<~DESC
      Copy a SQLite database to or from the running server.

      Use 'database' as a placeholder for the running server's database.
      Use '-' for stdin/stdout.

      Examples:

        hotswap cp ./new.sqlite3 database     # replace the running database
        hotswap cp database ./backup.sqlite3   # snapshot the running database
        hotswap cp - database                  # read from stdin
        hotswap cp database -                  # write to stdout
    DESC
    def cp(src, dst)
      db_path = Hotswap.database_path
      unless db_path
        io_err.write("ERROR: database_path not configured\n")
        return
      end

      if src == "database" && dst == "database"
        io_err.write("ERROR: source and destination can't both be 'database'\n")
        return
      end

      if dst == "database"
        push_database(src, db_path)
      elsif src == "database"
        pull_database(dst, db_path)
      else
        io_err.write("ERROR: one of src/dst must be 'database'\n")
      end
    end

    desc "push", "Replace the running database from stdin"
    def push
      cp("-", "database")
    end

    desc "pull", "Snapshot the running database to stdout"
    def pull
      cp("database", "-")
    end

    desc "version", "Print the hotswap version"
    def version
      io_out.write("hotswap #{Hotswap::VERSION}\n")
    end

    private

    def io_in  = Thread.current[:hotswap_stdin]  || $stdin
    def io_out = Thread.current[:hotswap_stdout] || $stdout
    def io_err = Thread.current[:hotswap_stderr] || $stderr

    def push_database(src, db_path)
      input = (src == "-") ? io_in : File.open(src, "rb")

      dir = File.dirname(db_path)
      temp = Tempfile.new(["hotswap", ".sqlite3"], dir)
      begin
        IO.copy_stream(input, temp)
        temp.close

        db = SQLite3::Database.new(temp.path)
        result = db.execute("PRAGMA integrity_check")
        db.close
        unless result == [["ok"]]
          io_err.write("ERROR: integrity check failed\n")
          return
        end

        io_err.write("Swapping database...\n")

        Middleware::SWAP_LOCK.synchronize do
          if defined?(ActiveRecord::Base)
            ActiveRecord::Base.connection_handler.clear_all_connections!
          end
          File.rename(temp.path, db_path)
        end

        if defined?(ActiveRecord::Base)
          ActiveRecord::Base.establish_connection
        end

        io_out.write("OK\n")
      rescue => e
        io_err.write("ERROR: #{e.message}\n")
      ensure
        input.close if input.is_a?(File)
        temp.unlink if temp && File.exist?(temp.path)
      end
    end

    def pull_database(dst, db_path)
      unless File.exist?(db_path)
        io_err.write("ERROR: database file not found\n")
        return
      end

      dir = File.dirname(db_path)
      temp = Tempfile.new(["hotswap-pull", ".sqlite3"], dir)
      begin
        src_db = SQLite3::Database.new(db_path)
        dst_db = SQLite3::Database.new(temp.path)
        b = SQLite3::Backup.new(dst_db, "main", src_db, "main")
        b.step(-1)
        b.finish
        dst_db.close
        src_db.close

        if dst == "-"
          File.open(temp.path, "rb") { |f| IO.copy_stream(f, io_out) }
        else
          FileUtils.cp(temp.path, dst)
          io_err.write("OK\n")
        end
      rescue => e
        io_err.write("ERROR: #{e.message}\n")
      ensure
        temp.unlink if temp && File.exist?(temp.path)
      end
    end
  end
end
