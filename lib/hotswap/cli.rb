require "thor"

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

    desc "cp SRC DST", "Copy a database to/from the running server"
    long_desc <<~DESC
      Copy a SQLite database to or from the running server.

      If SRC or DST matches a managed database path, hotswap treats it as
      the live database. Use '-' for stdin/stdout.

      Examples:

        hotswap cp ./new.sqlite3 db/production.sqlite3   # push
        hotswap cp db/production.sqlite3 ./backup.sqlite3 # pull
        hotswap cp - db/production.sqlite3                # push from stdin
        hotswap cp db/production.sqlite3 -                # pull to stdout
    DESC
    def cp(src, dst)
      src_db = resolve_database(src)
      dst_db = resolve_database(dst)

      if src_db && dst_db
        io_err.write("ERROR: source and destination can't both be managed databases\n")
        return
      end

      if dst_db
        source = (src == "-") ? io_in : src
        dst_db.push(source, stdout: io_out, stderr: io_err)
      elsif src_db
        destination = (dst == "-") ? io_out : dst
        src_db.pull(destination, stderr: io_err)
      else
        paths = Hotswap.databases.map(&:path).join(", ")
        io_err.write("ERROR: neither path matches a managed database (#{paths})\n")
      end
    end

desc "version", "Print the hotswap version"
    def version
      io_out.write("hotswap #{Hotswap::VERSION}\n")
    end

    private

    def io_in  = Thread.current[:hotswap_stdin]  || $stdin
    def io_out = Thread.current[:hotswap_stdout] || $stdout
    def io_err = Thread.current[:hotswap_stderr] || $stderr

    def resolve_database(path)
      return nil if path == "-"
      Hotswap.find_database(path) || (path == "database" && Hotswap.databases.first)
    end
  end
end
