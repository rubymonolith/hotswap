require "socket"

module Hotswap
  class SocketServer
    attr_reader :socket_path, :stderr_socket_path

    def initialize(socket_path: Hotswap.socket_path, stderr_socket_path: Hotswap.stderr_socket_path)
      @socket_path = socket_path
      @stderr_socket_path = stderr_socket_path
      @server = nil
      @stderr_server = nil
      @thread = nil
      @stderr_clients = {}
      @stderr_mutex = Mutex.new
    end

    def start
      cleanup_stale_socket(@socket_path)
      cleanup_stale_socket(@stderr_socket_path)

      @server = UNIXServer.new(@socket_path)
      @stderr_server = UNIXServer.new(@stderr_socket_path)

      @thread = Thread.new { accept_loop }
      @thread.report_on_exception = false
      self
    end

    def stop
      @server&.close
      @stderr_server&.close
      @thread&.kill
      @stderr_mutex.synchronize { @stderr_clients.each_value(&:close) rescue nil }
      [@socket_path, @stderr_socket_path].each do |path|
        File.delete(path) if path && File.exist?(path)
      end
    end

    private

    def accept_loop
      ios = [@server, @stderr_server]
      loop do
        readable, = IO.select(ios)
        readable.each do |server|
          client = server.accept
          if server == @stderr_server
            register_stderr_client(client)
          else
            Thread.new(client) { |sock| handle_connection(sock) }
          end
        end
      end
    rescue IOError, Errno::EBADF
      # Server was closed, exit gracefully
    end

    def register_stderr_client(client)
      # stderr client sends its PID on first line so we can match it
      line = client.gets
      return client.close unless line
      key = line.strip
      @stderr_mutex.synchronize { @stderr_clients[key] = client }
    end

    def take_stderr_client(key)
      @stderr_mutex.synchronize { @stderr_clients.delete(key) }
    end

    def handle_connection(socket)
      # First line is the command args
      line = socket.gets
      return unless line

      parts = line.strip.split(/\s+/)
      # Last part may be --stderr-key=<key>
      stderr_key = nil
      parts.reject! do |p|
        if p.start_with?("--stderr-key=")
          stderr_key = p.split("=", 2).last
          true
        end
      end

      # Wait briefly for the stderr client to connect
      stderr_io = nil
      if stderr_key
        5.times do
          stderr_io = take_stderr_client(stderr_key)
          break if stderr_io
          sleep 0.01
        end
      end

      # Wire the socket as stdin/stdout and stderr socket as stderr for the CLI
      old_stdin = $stdin
      old_stdout = $stdout
      old_stderr = $stderr
      begin
        $stdin = socket
        $stdout = socket
        $stderr = stderr_io || $stderr
        Hotswap::CLI.start(parts)
      ensure
        $stdin = old_stdin
        $stdout = old_stdout
        $stderr = old_stderr
      end
    rescue => e
      socket.write("ERROR: #{e.message}\n") rescue nil
    ensure
      stderr_io&.close rescue nil
      socket.close rescue nil
    end

    def cleanup_stale_socket(path)
      return unless File.exist?(path)
      begin
        test = UNIXSocket.new(path)
        test.close
        raise Hotswap::Error, "Socket #{path} is already in use"
      rescue Errno::ECONNREFUSED, Errno::ENOENT
        File.delete(path)
      end
    end
  end
end
