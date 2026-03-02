require "spec_helper"
require "socket"
require "json"

RSpec.describe Thor::Socket do
  describe Thor::Socket::Protocol do
    describe ".encode / .decode" do
      it "round-trips a frame" do
        frame = Thor::Socket::Protocol.encode(1, "hello")
        io = StringIO.new(frame)
        channel, data = Thor::Socket::Protocol.decode(io)
        expect(channel).to eq(1)
        expect(data).to eq("hello")
      end

      it "handles binary data" do
        binary = (0..255).map(&:chr).join
        frame = Thor::Socket::Protocol.encode(0, binary)
        io = StringIO.new(frame)
        channel, data = Thor::Socket::Protocol.decode(io)
        expect(channel).to eq(0)
        expect(data.bytes).to eq(binary.bytes)
      end

      it "handles empty payload" do
        frame = Thor::Socket::Protocol.encode(3, "")
        io = StringIO.new(frame)
        channel, data = Thor::Socket::Protocol.decode(io)
        expect(channel).to eq(3)
        expect(data).to eq("")
      end

      it "returns nil on EOF" do
        io = StringIO.new("")
        expect(Thor::Socket::Protocol.decode(io)).to be_nil
      end

      it "decodes multiple frames in sequence" do
        frames = Thor::Socket::Protocol.encode(1, "first") +
                 Thor::Socket::Protocol.encode(2, "second") +
                 Thor::Socket::Protocol.encode(3, '{"exit":0}')
        io = StringIO.new(frames)

        ch1, d1 = Thor::Socket::Protocol.decode(io)
        ch2, d2 = Thor::Socket::Protocol.decode(io)
        ch3, d3 = Thor::Socket::Protocol.decode(io)

        expect([ch1, d1]).to eq([1, "first"])
        expect([ch2, d2]).to eq([2, "second"])
        expect([ch3, d3]).to eq([3, '{"exit":0}'])
        expect(Thor::Socket::Protocol.decode(io)).to be_nil
      end
    end
  end

  describe Thor::Socket::FramedWriter do
    it "encodes writes as frames" do
      io = StringIO.new
      writer = Thor::Socket::FramedWriter.new(io, Thor::Socket::Protocol::CHANNEL_STDOUT)
      writer.write("hello")
      writer.write(" world")

      io.rewind
      ch1, d1 = Thor::Socket::Protocol.decode(io)
      ch2, d2 = Thor::Socket::Protocol.decode(io)

      expect(ch1).to eq(Thor::Socket::Protocol::CHANNEL_STDOUT)
      expect(d1).to eq("hello")
      expect(d2).to eq(" world")
    end

    it "supports puts" do
      io = StringIO.new
      writer = Thor::Socket::FramedWriter.new(io, Thor::Socket::Protocol::CHANNEL_STDERR)
      writer.puts("error message")

      io.rewind
      _, data = Thor::Socket::Protocol.decode(io)
      expect(data).to eq("error message\n")
    end
  end

  describe Thor::Socket::FramedReader do
    it "reads stdin frames" do
      io = StringIO.new(
        Thor::Socket::Protocol.encode(Thor::Socket::Protocol::CHANNEL_STDIN, "hello") +
        Thor::Socket::Protocol.encode(Thor::Socket::Protocol::CHANNEL_STDIN, " world")
      )
      reader = Thor::Socket::FramedReader.new(io)
      expect(reader.read).to eq("hello world")
    end

    it "supports gets" do
      io = StringIO.new(
        Thor::Socket::Protocol.encode(Thor::Socket::Protocol::CHANNEL_STDIN, "line1\nline2\n")
      )
      reader = Thor::Socket::FramedReader.new(io)
      expect(reader.gets).to eq("line1\n")
      expect(reader.gets).to eq("line2\n")
    end
  end

  describe "Server + Client integration" do
    let(:tmpdir) { Dir.mktmpdir }
    let(:socket_path) { File.join(tmpdir, "test.sock") }

    # A simple Thor CLI for testing
    let(:test_cli) do
      Class.new(Thor) do
        def self.exit_on_failure? = false

        desc "echo MSG", "Echo a message"
        def echo(msg)
          shell.stdout.write("ECHO: #{msg}\n")
        end

        desc "greet", "Greet on stderr"
        def greet
          shell.stderr.write("Hello from stderr\n")
          shell.stdout.write("Done\n")
        end
      end
    end

    let(:server) { Thor::Socket::Server.new(test_cli, socket_path: socket_path) }

    before { server.start }

    after do
      server.stop
      FileUtils.rm_rf(tmpdir)
    end

    it "routes stdout from server to client" do
      stdout = StringIO.new
      stderr = StringIO.new
      stdin = StringIO.new

      Thor::Socket::Client.connect(
        socket_path,
        args: ["echo", "hi"],
        stdin: stdin,
        stdout: stdout,
        stderr: stderr,
        tty: false
      )

      expect(stdout.string).to eq("ECHO: hi\n")
    end

    it "routes stderr from server to client" do
      stdout = StringIO.new
      stderr = StringIO.new
      stdin = StringIO.new

      Thor::Socket::Client.connect(
        socket_path,
        args: ["greet"],
        stdin: stdin,
        stdout: stdout,
        stderr: stderr,
        tty: false
      )

      expect(stdout.string).to eq("Done\n")
      expect(stderr.string).to eq("Hello from stderr\n")
    end

    it "returns exit code 0 on success" do
      stdout = StringIO.new
      stderr = StringIO.new
      stdin = StringIO.new

      code = Thor::Socket::Client.connect(
        socket_path,
        args: ["echo", "test"],
        stdin: stdin,
        stdout: stdout,
        stderr: stderr,
        tty: false
      )

      expect(code).to eq(0)
    end

    it "handles concurrent connections" do
      results = Array.new(5) { StringIO.new }

      threads = results.map do |out|
        Thread.new do
          Thor::Socket::Client.connect(
            socket_path,
            args: ["echo", "concurrent"],
            stdin: StringIO.new,
            stdout: out,
            stderr: StringIO.new,
            tty: false
          )
        end
      end
      threads.each(&:join)

      results.each do |out|
        expect(out.string).to eq("ECHO: concurrent\n")
      end
    end
  end
end
