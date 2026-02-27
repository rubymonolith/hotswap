require "spec_helper"
require "socket"
require "sqlite3"
require "net/http"

RSpec.describe "Integration: cp over sockets", :integration do
  let(:fixture_dir) { File.expand_path("../tmp/integration_#{Process.pid}", __dir__) }
  let(:db_path) { File.join(fixture_dir, "test.sqlite3") }
  let(:socket_path) { File.join(fixture_dir, "sqlite3.sock") }
  let(:stderr_socket_path) { File.join(fixture_dir, "sqlite3.stderr.sock") }
  let(:server) { Hotswap::SocketServer.new(socket_path: socket_path, stderr_socket_path: stderr_socket_path) }

  before do
    FileUtils.mkdir_p(fixture_dir)

    db = SQLite3::Database.new(db_path)
    db.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT)")
    db.execute("INSERT INTO items (name) VALUES ('alpha')")
    db.execute("INSERT INTO items (name) VALUES ('bravo')")
    db.close

    Hotswap.database_path = db_path
    Hotswap.socket_path = socket_path
    Hotswap.stderr_socket_path = stderr_socket_path
    server.start
  end

  after do
    server.stop
    Hotswap.database_path = nil
    FileUtils.rm_rf(fixture_dir)
  end

  def run_client(*args, stdin_data: nil)
    stderr_sock = UNIXSocket.new(stderr_socket_path)
    sleep 0.05

    sock = UNIXSocket.new(socket_path)
    sock.write(args.join(" ") + "\n")

    if stdin_data
      sock.write(stdin_data)
      sock.close_write
    else
      sock.close_write
    end

    stdout = sock.read
    stderr = stderr_sock.read
    sock.close
    stderr_sock.close

    { stdout: stdout, stderr: stderr }
  end

  describe "cp round-trip" do
    it "pushes a new database and pulls it back" do
      # Pull via cp
      result = run_client("cp", db_path, "-")
      original_bytes = result[:stdout]
      expect(original_bytes.bytesize).to be > 0

      pulled_path = File.join(fixture_dir, "pulled_original.sqlite3")
      File.binwrite(pulled_path, original_bytes)
      db = SQLite3::Database.new(pulled_path)
      rows = db.execute("SELECT name FROM items ORDER BY name")
      db.close
      expect(rows).to eq([["alpha"], ["bravo"]])

      # Push via cp with stdin
      new_db_path = File.join(fixture_dir, "replacement.sqlite3")
      db = SQLite3::Database.new(new_db_path)
      db.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT)")
      db.execute("INSERT INTO items (name) VALUES ('charlie')")
      db.execute("INSERT INTO items (name) VALUES ('delta')")
      db.close

      new_bytes = File.binread(new_db_path)
      result = run_client("cp", "-", db_path, stdin_data: new_bytes)
      expect(result[:stdout].strip).to eq("OK")
      expect(result[:stderr]).to include("Swapping")

      # Pull again to verify
      result = run_client("cp", db_path, "-")
      pulled_path2 = File.join(fixture_dir, "pulled_swapped.sqlite3")
      File.binwrite(pulled_path2, result[:stdout])
      db = SQLite3::Database.new(pulled_path2)
      rows = db.execute("SELECT name FROM items ORDER BY name")
      db.close
      expect(rows).to eq([["charlie"], ["delta"]])
    end
  end

  describe "cp with file paths" do
    it "pushes from a file path" do
      new_db_path = File.join(fixture_dir, "replacement.sqlite3")
      db = SQLite3::Database.new(new_db_path)
      db.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT)")
      db.execute("INSERT INTO items (name) VALUES ('from-file')")
      db.close

      result = run_client("cp", new_db_path, db_path)
      expect(result[:stdout].strip).to eq("OK")

      db = SQLite3::Database.new(db_path)
      rows = db.execute("SELECT name FROM items")
      db.close
      expect(rows).to eq([["from-file"]])
    end

    it "pulls to a file path" do
      pulled_path = File.join(fixture_dir, "pulled.sqlite3")
      result = run_client("cp", db_path, pulled_path)
      expect(result[:stderr]).to include("OK")

      db = SQLite3::Database.new(pulled_path)
      rows = db.execute("SELECT name FROM items ORDER BY name")
      db.close
      expect(rows).to eq([["alpha"], ["bravo"]])
    end
  end

  describe "cp rejects bad data" do
    it "refuses a corrupt file and leaves the DB intact" do
      result = run_client("cp", "-", db_path, stdin_data: "not a database at all")
      expect(result[:stderr]).to include("ERROR")

      db = SQLite3::Database.new(db_path)
      rows = db.execute("SELECT name FROM items ORDER BY name")
      db.close
      expect(rows).to eq([["alpha"], ["bravo"]])
    end
  end

  describe "version" do
    it "returns the version" do
      result = run_client("version")
      expect(result[:stdout].strip).to eq("hotswap #{Hotswap::VERSION}")
    end
  end

  describe "concurrent cp and rack requests" do
    it "serializes requests through the swap lock" do
      app = Hotswap::Middleware.new(->(env) {
        db = SQLite3::Database.new(db_path)
        rows = db.execute("SELECT name FROM items ORDER BY name")
        db.close
        [200, { "content-type" => "application/json" }, [rows.map(&:first).join(",")]]
      })

      status, _, body = app.call(Rack::MockRequest.env_for("/items"))
      expect(body.first).to eq("alpha,bravo")

      new_db_path = File.join(fixture_dir, "concurrent.sqlite3")
      db = SQLite3::Database.new(new_db_path)
      db.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT)")
      db.execute("INSERT INTO items (name) VALUES ('echo')")
      db.close

      result = run_client("cp", "-", db_path, stdin_data: File.binread(new_db_path))
      expect(result[:stdout].strip).to eq("OK")

      status, _, body = app.call(Rack::MockRequest.env_for("/items"))
      expect(body.first).to eq("echo")
    end
  end

  describe "multiple sequential pushes" do
    it "handles several swaps in a row" do
      3.times do |i|
        new_db_path = File.join(fixture_dir, "seq_#{i}.sqlite3")
        db = SQLite3::Database.new(new_db_path)
        db.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT)")
        db.execute("INSERT INTO items (name) VALUES ('iteration_#{i}')")
        db.close

        result = run_client("cp", new_db_path, db_path)
        expect(result[:stdout].strip).to eq("OK")

        db = SQLite3::Database.new(db_path)
        rows = db.execute("SELECT name FROM items")
        db.close
        expect(rows).to eq([["iteration_#{i}"]])
      end
    end
  end
end
