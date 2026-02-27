require "socket"
require "shellwords"

module Hotswap
  class SocketServer
    attr_reader :socket_path, :stderr_socket_path

    CONNECTION_TIMEOUT = 10

    def initialize(socket_path: Hotswap.socket_path, stderr_socket_path: Hotswap.stderr_socket_path)
      @socket_path = socket_path
      @stderr_socket_path = stderr_socket_path
      @server = nil
      @stderr_server = nil
      @thread = nil
      @stderr_client = nil
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
      @stderr_mutex.synchronize do
        @stderr_client&.close rescue nil
        @stderr_client = nil
      end
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
            @stderr_mutex.synchronize do
              @stderr_client&.close rescue nil
              @stderr_client = client
            end
          else
            Thread.new(client) { |sock| handle_connection(sock) }
          end
        end
      end
    rescue IOError, Errno::EBADF
      # Server was closed, exit gracefully
    end

    def take_stderr_client
      @stderr_mutex.synchronize do
        client = @stderr_client
        @stderr_client = nil
        client
      end
    end

    def handle_connection(socket)
      unless IO.select([socket], nil, nil, CONNECTION_TIMEOUT)
        socket.write("ERROR: connection timeout\n") rescue nil
        return
      end

      line = socket.gets
      return unless line

      parts = Shellwords.split(line.strip)
      return if parts.empty?

      # Grab the stderr socket if one is waiting
      stderr_io = take_stderr_client

      Hotswap::CLI.run(
        parts,
        stdin: socket,
        stdout: socket,
        stderr: stderr_io || $stderr
      )
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
