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
      source_label = source.is_a?(String) ? source : "stdin"
      logger.info "push started: #{source_label} → #{@path}"

      input = source.is_a?(String) ? File.open(source, "rb") : source

      dir = File.dirname(@path)
      temp = Tempfile.new(["hotswap", ".sqlite3"], dir)
      begin
        IO.copy_stream(input, temp)
        temp.close
        logger.info "received #{File.size(temp.path)} bytes, running integrity check"

        db = SQLite3::Database.new(temp.path)
        result = db.execute("PRAGMA integrity_check")
        db.close
        unless result == [["ok"]]
          logger.error "integrity check failed for #{source_label}"
          stderr.write("ERROR: integrity check failed\n")
          return false
        end

        logger.info "integrity check passed, acquiring swap lock"
        stderr.write("Swapping database...\n")

        Middleware::SWAP_LOCK.synchronize do
          if defined?(ActiveRecord::Base)
            ActiveRecord::Base.connection_handler.clear_all_connections!
            logger.info "disconnected ActiveRecord"
          end
          File.rename(temp.path, @path)
          logger.info "renamed #{temp.path} → #{@path}"
        end

        if defined?(ActiveRecord::Base)
          ActiveRecord::Base.establish_connection
          logger.info "reconnected ActiveRecord"
        end

        logger.info "push complete: #{@path}"
        stdout.write("OK\n")
        true
      rescue => e
        logger.error "push failed: #{e.message}"
        stderr.write("ERROR: #{e.message}\n")
        false
      ensure
        input.close if source.is_a?(String) && input.is_a?(File)
        temp.unlink if temp && File.exist?(temp.path)
      end
    end

    # Pull the database to an IO stream or file path
    def pull(destination, stderr: $stderr)
      dest_label = destination.is_a?(String) ? destination : "stdout"
      logger.info "pull started: #{@path} → #{dest_label}"

      unless File.exist?(@path)
        logger.error "database file not found at #{@path}"
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
        logger.info "backup complete: #{File.size(temp.path)} bytes"

        if destination.is_a?(String)
          FileUtils.cp(temp.path, destination)
          logger.info "pull complete: #{@path} → #{destination}"
          stderr.write("OK\n")
        else
          File.open(temp.path, "rb") { |f| IO.copy_stream(f, destination) }
          logger.info "pull complete: #{@path} → stdout"
        end
        true
      rescue => e
        logger.error "pull failed: #{e.message}"
        stderr.write("ERROR: #{e.message}\n")
        false
      ensure
        temp.unlink if temp && File.exist?(temp.path)
      end
    end

    private

    def logger = Hotswap.logger
  end
end
