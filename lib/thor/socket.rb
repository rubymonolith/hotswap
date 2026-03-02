require "socket"
require "json"
require "thor"

class Thor
  module Socket
    module Protocol
      CHANNEL_STDIN   = 0
      CHANNEL_STDOUT  = 1
      CHANNEL_STDERR  = 2
      CHANNEL_CONTROL = 3

      HEADER_SIZE = 5 # 1 byte channel + 4 bytes length

      def self.encode(channel, data)
        data = data.b
        [channel, data.bytesize].pack("CN") + data
      end

      def self.decode(io)
        header = io.read(HEADER_SIZE)
        return nil if header.nil? || header.bytesize < HEADER_SIZE

        channel, length = header.unpack("CN")
        payload = io.read(length)
        return nil if payload.nil? || payload.bytesize < length

        [channel, payload]
      end
    end

    class FramedWriter
      def initialize(io, channel)
        @io = io
        @channel = channel
        @mutex = Mutex.new
      end

      def write(data)
        data = data.to_s
        return 0 if data.empty?
        frame = Protocol.encode(@channel, data)
        @mutex.synchronize { @io.write(frame) }
        data.bytesize
      end

      def puts(str = "")
        write(str.to_s + "\n")
      end

      def print(str)
        write(str.to_s)
      end

      def flush
        @mutex.synchronize { @io.flush rescue nil }
      end

      def binmode
        self
      end

      def close
        # no-op — the underlying socket is closed by the connection
      end
    end

    class FramedReader
      def initialize(io)
        @io = io
        @buffer = String.new(encoding: Encoding::BINARY)
        @eof = false
      end

      def read(length = nil, buf = nil)
        if length.nil?
          # Read all remaining stdin data
          chunks = []
          chunks << @buffer.dup unless @buffer.empty?
          @buffer.clear
          until @eof
            data = read_next_stdin_frame
            break unless data
            chunks << data
          end
          result = chunks.join
          if buf
            buf.replace(result)
          else
            result
          end
        else
          fill_buffer(length)
          chunk = @buffer.slice!(0, length)
          return nil if chunk.nil? || chunk.empty?
          if buf
            buf.replace(chunk)
          else
            chunk
          end
        end
      end

      def gets
        loop do
          if (idx = @buffer.index("\n"))
            return @buffer.slice!(0, idx + 1)
          end
          return @buffer.slice!(0, @buffer.bytesize) if @eof && !@buffer.empty?
          return nil if @eof
          data = read_next_stdin_frame
          return nil unless data
        end
      end

      def eof?
        @buffer.empty? && @eof
      end

      private

      def fill_buffer(target)
        while @buffer.bytesize < target && !@eof
          data = read_next_stdin_frame
          break unless data
        end
      end

      def read_next_stdin_frame
        return nil if @eof
        result = Protocol.decode(@io)
        if result.nil?
          @eof = true
          return nil
        end
        channel, data = result
        if channel == Protocol::CHANNEL_STDIN && !data.empty?
          @buffer << data
          data
        else
          @eof = true
          nil
        end
      end
    end

    class Shell < Thor::Shell::Basic
      attr_reader :stdout, :stderr

      def initialize(stdout, stderr, tty: false)
        super()
        @stdout = stdout
        @stderr = stderr
        @tty = tty
      end

      def can_display_colors?
        false
      end

      private

      def prepare_message(message, *_color)
        message.to_s
      end
    end

    class Connection
      CONNECTION_TIMEOUT = 10

      def initialize(socket, cli_class, logger: nil)
        @socket = socket
        @cli_class = cli_class
        @logger = logger
      end

      def handle
        unless IO.select([@socket], nil, nil, CONNECTION_TIMEOUT)
          @logger&.warn "connection timed out"
          send_control("error" => "connection timeout")
          return
        end

        result = Protocol.decode(@socket)
        unless result
          @logger&.warn "empty connection"
          return
        end

        channel, data = result
        unless channel == Protocol::CHANNEL_CONTROL
          @logger&.warn "expected control frame, got channel #{channel}"
          return
        end

        control = JSON.parse(data)
        args = control.fetch("args", [])
        tty = control.fetch("tty", false)

        @logger&.info "command: #{args.join(' ')}" unless args.empty?

        stdout_writer = FramedWriter.new(@socket, Protocol::CHANNEL_STDOUT)
        stderr_writer = FramedWriter.new(@socket, Protocol::CHANNEL_STDERR)
        stdin_reader = FramedReader.new(@socket)

        run_cli(args, stdin: stdin_reader, stdout: stdout_writer, stderr: stderr_writer, tty: tty)

        send_control("exit" => 0)
      rescue => e
        @logger&.error "connection error: #{e.message}"
        send_control("exit" => 1, "error" => e.message) rescue nil
      ensure
        @socket.close rescue nil
      end

      private

      def run_cli(args, stdin:, stdout:, stderr:, tty:)
        if @cli_class.respond_to?(:run)
          @cli_class.run(args, stdin: stdin, stdout: stdout, stderr: stderr)
        else
          args = ["help"] if args.empty?
          shell = Shell.new(stdout, stderr, tty: tty)
          @cli_class.start(args, shell: shell)
        end
      rescue SystemExit
        # Thor calls exit on errors — catch it so we don't kill the server
      end

      def send_control(data)
        frame = Protocol.encode(Protocol::CHANNEL_CONTROL, JSON.generate(data))
        @socket.write(frame)
      end
    end

    class Server
      attr_reader :socket_path

      def initialize(cli_class, socket_path:, logger: nil)
        @cli_class = cli_class
        @socket_path = socket_path
        @logger = logger
        @server = nil
        @thread = nil
      end

      def start
        cleanup_stale_socket(@socket_path)
        FileUtils.mkdir_p(File.dirname(@socket_path))
        @server = UNIXServer.new(@socket_path)
        @thread = Thread.new { accept_loop }
        @thread.report_on_exception = false
        @logger&.info "listening on #{@socket_path}"
        self
      end

      def stop
        @logger&.info "shutting down"
        @server&.close
        @thread&.kill
        File.delete(@socket_path) if @socket_path && File.exist?(@socket_path)
      end

      private

      def accept_loop
        loop do
          client = @server.accept
          Thread.new(client) do |sock|
            Connection.new(sock, @cli_class, logger: @logger).handle
          end
        end
      rescue IOError, Errno::EBADF
        # Server was closed, exit gracefully
      end

      def cleanup_stale_socket(path)
        return unless File.exist?(path)
        begin
          test = UNIXSocket.new(path)
          test.close
          raise "Socket #{path} is already in use"
        rescue Errno::ECONNREFUSED, Errno::ENOENT
          File.delete(path)
        end
      end
    end

    class Client
      def self.connect(socket_path, args:, stdin: $stdin, stdout: $stdout, stderr: $stderr, tty: $stdout.tty?)
        new(socket_path, args: args, stdin: stdin, stdout: stdout, stderr: stderr, tty: tty).run
      end

      def initialize(socket_path, args:, stdin:, stdout:, stderr:, tty:)
        @socket_path = socket_path
        @args = args
        @stdin = stdin
        @stdout = stdout
        @stderr = stderr
        @tty = tty
      end

      def run
        sock = UNIXSocket.new(@socket_path)

        # Send control frame
        control = { "args" => @args, "tty" => @tty }
        sock.write(Protocol.encode(Protocol::CHANNEL_CONTROL, JSON.generate(control)))

        # Pipe stdin if '-' is an argument and stdin isn't a tty
        writer = nil
        if @args.include?("-") && !@stdin.tty?
          writer = Thread.new do
            begin
              buf = String.new(capacity: 16384)
              while @stdin.read(16384, buf)
                sock.write(Protocol.encode(Protocol::CHANNEL_STDIN, buf))
              end
            rescue IOError, Errno::EPIPE
              # stdin closed or socket gone
            ensure
              # Send an empty stdin frame to signal EOF, then stop writing
              sock.write(Protocol.encode(Protocol::CHANNEL_STDIN, "")) rescue nil
            end
          end
        end

        # Read frames from server
        exit_code = 0
        loop do
          result = Protocol.decode(sock)
          break unless result

          channel, data = result
          case channel
          when Protocol::CHANNEL_STDOUT
            @stdout.write(data)
          when Protocol::CHANNEL_STDERR
            @stderr.write(data)
          when Protocol::CHANNEL_CONTROL
            ctrl = JSON.parse(data)
            exit_code = ctrl.fetch("exit", 0)
            break
          end
        end

        writer&.join
        sock.close rescue nil
        exit_code
      end
    end
  end
end
