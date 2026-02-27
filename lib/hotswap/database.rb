require "tempfile"
require "fileutils"
require "sqlite3"

module Hotswap
  class Database
    attr_reader :path

    def initialize(path)
      @path = File.expand_path(path)
    end

    # Push a new database from an IO stream or file path
    def push(source, stdout: $stdout, stderr: $stderr)
      input = source.is_a?(String) ? File.open(source, "rb") : source

      dir = File.dirname(@path)
      temp = Tempfile.new(["hotswap", ".sqlite3"], dir)
      begin
        IO.copy_stream(input, temp)
        temp.close

        db = SQLite3::Database.new(temp.path)
        result = db.execute("PRAGMA integrity_check")
        db.close
        unless result == [["ok"]]
          stderr.write("ERROR: integrity check failed\n")
          return false
        end

        stderr.write("Swapping database...\n")

        Middleware::SWAP_LOCK.synchronize do
          if defined?(ActiveRecord::Base)
            ActiveRecord::Base.connection_handler.clear_all_connections!
          end
          File.rename(temp.path, @path)
        end

        if defined?(ActiveRecord::Base)
          ActiveRecord::Base.establish_connection
        end

        stdout.write("OK\n")
        true
      rescue => e
        stderr.write("ERROR: #{e.message}\n")
        false
      ensure
        input.close if source.is_a?(String) && input.is_a?(File)
        temp.unlink if temp && File.exist?(temp.path)
      end
    end

    # Pull the database to an IO stream or file path
    def pull(destination, stderr: $stderr)
      unless File.exist?(@path)
        stderr.write("ERROR: database file not found at #{@path}\n")
        return false
      end

      dir = File.dirname(@path)
      temp = Tempfile.new(["hotswap-pull", ".sqlite3"], dir)
      begin
        src_db = SQLite3::Database.new(@path)
        dst_db = SQLite3::Database.new(temp.path)
        b = SQLite3::Backup.new(dst_db, "main", src_db, "main")
        b.step(-1)
        b.finish
        dst_db.close
        src_db.close

        if destination.is_a?(String)
          FileUtils.cp(temp.path, destination)
          stderr.write("OK\n")
        else
          File.open(temp.path, "rb") { |f| IO.copy_stream(f, destination) }
        end
        true
      rescue => e
        stderr.write("ERROR: #{e.message}\n")
        false
      ensure
        temp.unlink if temp && File.exist?(temp.path)
      end
    end
  end
end
