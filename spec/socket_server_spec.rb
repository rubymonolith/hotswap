require "spec_helper"
require "socket"
require "sqlite3"
require "json"

RSpec.describe Thor::Socket::Server, "with Hotswap::CLI" do
  let(:tmpdir) { Dir.mktmpdir }
  let(:socket_path) { File.join(tmpdir, "test.sock") }
  let(:db_path) { File.join(tmpdir, "test.sqlite3") }
  let(:server) { Thor::Socket::Server.new(Hotswap::CLI, socket_path: socket_path) }

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

  def run_client(*args, stdin_data: nil)
    stdout = StringIO.new
    stderr = StringIO.new
    stdin = stdin_data ? StringIO.new(stdin_data) : StringIO.new

    Thor::Socket::Client.connect(
      socket_path,
      args: args,
      stdin: stdin,
      stdout: stdout,
      stderr: stderr,
      tty: false
    )

    { stdout: stdout.string, stderr: stderr.string }
  end

  describe "no args (help)" do
    it "returns help output over the socket" do
      result = run_client
      expect(result[:stdout]).to include("cp SRC DST")
      expect(result[:stdout]).to include("version")
    end
  end

  describe "version command" do
    it "returns the version over the socket" do
      result = run_client("version")
      expect(result[:stdout]).to eq("hotswap #{Hotswap::VERSION}\n")
    end
  end

  describe "cp push" do
    it "swaps the database and sends stderr separately" do
      new_db_path = File.join(tmpdir, "new.sqlite3")
      db = SQLite3::Database.new(new_db_path)
      db.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT)")
      db.execute("INSERT INTO items (name) VALUES ('swapped')")
      db.close

      result = run_client("cp", "-", db_path, stdin_data: File.binread(new_db_path))

      expect(result[:stdout].strip).to eq("OK")
      expect(result[:stderr]).to include("Swapping")

      db = SQLite3::Database.new(db_path)
      rows = db.execute("SELECT name FROM items")
      db.close
      expect(rows).to eq([["swapped"]])
    end
  end

  describe "cp push from file path" do
    it "still works with stdout only" do
      new_db_path = File.join(tmpdir, "new.sqlite3")
      db = SQLite3::Database.new(new_db_path)
      db.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT)")
      db.execute("INSERT INTO items (name) VALUES ('no-stderr')")
      db.close

      result = run_client("cp", new_db_path, db_path)

      expect(result[:stdout].strip).to eq("OK")

      db = SQLite3::Database.new(db_path)
      rows = db.execute("SELECT name FROM items")
      db.close
      expect(rows).to eq([["no-stderr"]])
    end
  end

  describe "cp pull" do
    it "streams the database file over the socket" do
      stdout = StringIO.new
      stdout.binmode
      stderr = StringIO.new

      Thor::Socket::Client.connect(
        socket_path,
        args: ["cp", db_path, "-"],
        stdin: StringIO.new,
        stdout: stdout,
        stderr: stderr,
        tty: false
      )

      pulled_path = File.join(tmpdir, "pulled.sqlite3")
      File.binwrite(pulled_path, stdout.string)

      db = SQLite3::Database.new(pulled_path)
      rows = db.execute("SELECT name FROM items")
      db.close
      expect(rows).to eq([["original"]])
    end
  end

  describe "concurrent requests during cp" do
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

      result = run_client("cp", new_db_path, db_path)
      expect(result[:stdout].strip).to eq("OK")

      status, _, body = app.call(Rack::MockRequest.env_for("/"))
      expect(status).to eq(200)
      expect(body.first).to eq("concurrent")
    end
  end
end
