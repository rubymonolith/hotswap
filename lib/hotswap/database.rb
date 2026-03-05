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
    def push(source, stdout: $stdout, stderr: $stderr, skip_integrity_check: false, skip_schema_check: false)
      source_label = source.is_a?(String) ? source : "stdin"
      logger.info "push started: #{source_label} → #{@path}"

      input = source.is_a?(String) ? File.open(source, "rb") : source

      dir = File.dirname(@path)
      temp = Tempfile.new(["hotswap", ".sqlite3"], dir)
      begin
        IO.copy_stream(input, temp)
        temp.close
        logger.info "received #{File.size(temp.path)} bytes"

        unless skip_integrity_check
          logger.info "running integrity check"
          db = SQLite3::Database.new(temp.path)
          result = db.execute("PRAGMA integrity_check")
          db.close
          unless result == [["ok"]]
            logger.error "integrity check failed for #{source_label}"
            stderr.write("ERROR: integrity check failed\n")
            return false
          end
          logger.info "integrity check passed"
        end

        unless skip_schema_check
          logger.info "running schema check"
          new_db = SQLite3::Database.new(temp.path)
          cur_db = SQLite3::Database.new(@path)
          new_schema = new_db.execute("SELECT sql FROM sqlite_master WHERE sql IS NOT NULL ORDER BY type, name").flatten
          cur_schema = cur_db.execute("SELECT sql FROM sqlite_master WHERE sql IS NOT NULL ORDER BY type, name").flatten
          new_db.close
          cur_db.close

          if new_schema != cur_schema
            logger.error "schema mismatch for #{source_label}"
            diff_lines = []
            (cur_schema - new_schema).each { |s| diff_lines << "- #{s}" }
            (new_schema - cur_schema).each { |s| diff_lines << "+ #{s}" }
            stderr.write("ERROR: schema mismatch\n#{diff_lines.join("\n")}\n")
            return false
          end
          logger.info "schema check passed"
        end

        logger.info "acquiring swap lock"
        stderr.write("Swapping database...\n")

        Middleware::SWAP_LOCK.synchronize do
          logger.info "swap lock acquired, requests are queued"
          ActiveRecord::Base.connection_handler.clear_all_connections!
          logger.info "disconnected ActiveRecord"
          File.rename(temp.path, @path)
          logger.info "renamed #{temp.path} → #{@path}"
        end
        logger.info "swap lock released, requests resuming"
        ActiveRecord::Base.establish_connection
        logger.info "reconnected ActiveRecord"

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
