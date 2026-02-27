require "spec_helper"
require "socket"
require "sqlite3"

RSpec.describe Hotswap::SocketServer do
  let(:tmpdir) { Dir.mktmpdir }
  let(:socket_path) { File.join(tmpdir, "test.sock") }
  let(:stderr_socket_path) { File.join(tmpdir, "test.stderr.sock") }
  let(:db_path) { File.join(tmpdir, "test.sqlite3") }
  let(:server) { Hotswap::SocketServer.new(socket_path: socket_path, stderr_socket_path: stderr_socket_path) }

  before do
    db = SQLite3::Database.new(db_path)
    db.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT)")
    db.execute("INSERT INTO items (name) VALUES ('original')")
    db.close
    Hotswap.database_path = db_path
    server.start
  end

  after do
    server.stop
    Hotswap.database_path = nil
    FileUtils.rm_rf(tmpdir)
  end

  describe "no args (help)" do
    it "returns help output over the socket" do
      sock = UNIXSocket.new(socket_path)
      sock.write("\n")
      sock.close_write
      output = sock.read
      sock.close
      expect(output).to include("cp SRC DST")
      expect(output).to include("version")
    end
  end

  describe "version command (stdout only)" do
    it "returns the version over the socket" do
      sock = UNIXSocket.new(socket_path)
      sock.write("version\n")
      sock.close_write
      output = sock.read
      sock.close
      expect(output).to eq("hotswap #{Hotswap::VERSION}\n")
    end
  end

  describe "push command with stderr socket" do
    it "swaps the database and sends stderr separately" do
      new_db_path = File.join(tmpdir, "new.sqlite3")
      db = SQLite3::Database.new(new_db_path)
      db.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT)")
      db.execute("INSERT INTO items (name) VALUES ('swapped')")
      db.close

      # Connect stderr socket first, then main socket
      stderr_sock = UNIXSocket.new(stderr_socket_path)
      sleep 0.05 # let the server register the stderr client

      sock = UNIXSocket.new(socket_path)
      sock.write("push\n")
      File.open(new_db_path, "rb") { |f| IO.copy_stream(f, sock) }
      sock.close_write

      stdout_output = sock.read
      stderr_output = stderr_sock.read

      sock.close
      stderr_sock.close

      expect(stdout_output.strip).to eq("OK")
      expect(stderr_output).to include("Swapping")

      db = SQLite3::Database.new(db_path)
      rows = db.execute("SELECT name FROM items")
      db.close
      expect(rows).to eq([["swapped"]])
    end
  end

  describe "push command without stderr socket" do
    it "still works with stdout only" do
      new_db_path = File.join(tmpdir, "new.sqlite3")
      db = SQLite3::Database.new(new_db_path)
      db.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT)")
      db.execute("INSERT INTO items (name) VALUES ('no-stderr')")
      db.close

      sock = UNIXSocket.new(socket_path)
      sock.write("push\n")
      File.open(new_db_path, "rb") { |f| IO.copy_stream(f, sock) }
      sock.close_write

      output = sock.read
      sock.close

      expect(output.strip).to eq("OK")

      db = SQLite3::Database.new(db_path)
      rows = db.execute("SELECT name FROM items")
      db.close
      expect(rows).to eq([["no-stderr"]])
    end
  end

  describe "pull command" do
    it "streams the database file over the socket" do
      sock = UNIXSocket.new(socket_path)
      sock.write("pull\n")
      sock.close_write

      pulled_path = File.join(tmpdir, "pulled.sqlite3")
      File.open(pulled_path, "wb") { |f| IO.copy_stream(sock, f) }
      sock.close

      db = SQLite3::Database.new(pulled_path)
      rows = db.execute("SELECT name FROM items")
      db.close
      expect(rows).to eq([["original"]])
    end
  end

  describe "concurrent requests during push" do
    it "queues rack requests while swapping" do
      app = Hotswap::Middleware.new(->(env) {
        db = SQLite3::Database.new(db_path)
        rows = db.execute("SELECT name FROM items")
        db.close
        [200, {}, [rows.first.first]]
      })

      new_db_path = File.join(tmpdir, "concurrent.sqlite3")
      db = SQLite3::Database.new(new_db_path)
      db.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT)")
      db.execute("INSERT INTO items (name) VALUES ('concurrent')")
      db.close

      sock = UNIXSocket.new(socket_path)
      sock.write("push\n")
      File.open(new_db_path, "rb") { |f| IO.copy_stream(f, sock) }
      sock.close_write
      sock.read
      sock.close

      status, _, body = app.call(Rack::MockRequest.env_for("/"))
      expect(status).to eq(200)
      expect(body.first).to eq("concurrent")
    end
  end
end
