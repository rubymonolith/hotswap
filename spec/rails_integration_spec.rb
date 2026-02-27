require "spec_helper"
require "net/http"
require "socket"
require "sqlite3"
require "securerandom"
require "json"

RSpec.describe "Rails integration: boot app, cp, verify", :rails do
  let(:fixture_dir) { File.expand_path("../tmp/rails_#{Process.pid}", __dir__) }
  let(:db_path) { File.join(fixture_dir, "test.sqlite3") }
  let(:socket_path) { File.join(fixture_dir, "hotswap.sock") }
  let(:stderr_socket_path) { File.join(fixture_dir, "hotswap.stderr.sock") }
  let(:port) { 9293 + rand(100) }
  let(:app_script) { File.expand_path("fixture_app/app.rb", __dir__) }

  before do
    FileUtils.mkdir_p(File.join(fixture_dir, "config"))
    FileUtils.mkdir_p(File.join(fixture_dir, "tmp"))

    db = SQLite3::Database.new(db_path)
    db.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT)")
    db.execute("INSERT INTO items (name) VALUES ('alpha')")
    db.execute("INSERT INTO items (name) VALUES ('bravo')")
    db.close

    @pid = spawn(
      {
        "HOTSWAP_FIXTURE_DIR" => fixture_dir,
        "HOTSWAP_DB_PATH" => db_path,
        "PORT" => port.to_s,
        "LOG_LEVEL" => "fatal",
      },
      RbConfig.ruby, app_script,
      out: "/dev/null",
      err: "/dev/null",
    )

    wait_for_server!
  end

  after do
    Process.kill("TERM", @pid) rescue nil
    Process.wait(@pid) rescue nil
    FileUtils.rm_rf(fixture_dir)
  end

  def wait_for_server!(timeout: 10)
    deadline = Time.now + timeout
    loop do
      Net::HTTP.get(URI("http://127.0.0.1:#{port}/health"))
      return
    rescue Errno::ECONNREFUSED, Errno::EADDRNOTAVAIL, Net::ReadTimeout
      raise "Server didn't start within #{timeout}s" if Time.now > deadline
      sleep 0.1
    end
  end

  def get_items
    body = Net::HTTP.get(URI("http://127.0.0.1:#{port}/items"))
    JSON.parse(body)
  end

  def cp_push(new_db_path)
    stderr_sock = UNIXSocket.new(stderr_socket_path)
    sleep 0.05

    sock = UNIXSocket.new(socket_path)
    sock.write("cp #{new_db_path} #{db_path}\n")
    sock.close_write

    stdout = sock.read
    stderr_out = stderr_sock.read
    sock.close
    stderr_sock.close

    { stdout: stdout, stderr: stderr_out }
  end

  def cp_pull(destination)
    stderr_sock = UNIXSocket.new(stderr_socket_path)
    sleep 0.05

    sock = UNIXSocket.new(socket_path)
    sock.write("cp #{db_path} #{destination}\n")
    sock.close_write

    stdout = sock.read
    stderr_out = stderr_sock.read
    sock.close
    stderr_sock.close

    { stdout: stdout, stderr: stderr_out }
  end

  def cp_pull_stdout
    stderr_sock = UNIXSocket.new(stderr_socket_path)
    sleep 0.05

    sock = UNIXSocket.new(socket_path)
    sock.write("cp #{db_path} -\n")
    sock.close_write

    stdout = sock.read
    stderr_sock.close
    sock.close

    stdout
  end

  def make_db(fixture_dir, rows)
    path = File.join(fixture_dir, "new_#{SecureRandom.hex(4)}.sqlite3")
    db = SQLite3::Database.new(path)
    db.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT)")
    rows.each { |name| db.execute("INSERT INTO items (name) VALUES (?)", [name]) }
    db.close
    path
  end

  it "serves the original data" do
    expect(get_items).to eq(["alpha", "bravo"])
  end

  it "swaps the database via cp and serves new data" do
    expect(get_items).to eq(["alpha", "bravo"])

    new_db = make_db(fixture_dir, ["charlie", "delta"])
    result = cp_push(new_db)

    expect(result[:stdout].strip).to eq("OK")
    expect(result[:stderr]).to include("Swapping")

    expect(get_items).to eq(["charlie", "delta"])
  end

  it "pulls the current database via cp to stdout" do
    bytes = cp_pull_stdout
    pulled_path = File.join(fixture_dir, "pulled.sqlite3")
    File.binwrite(pulled_path, bytes)

    db = SQLite3::Database.new(pulled_path)
    rows = db.execute("SELECT name FROM items ORDER BY name")
    db.close

    expect(rows).to eq([["alpha"], ["bravo"]])
  end

  it "pulls the current database via cp to a file" do
    pulled_path = File.join(fixture_dir, "pulled.sqlite3")
    result = cp_pull(pulled_path)
    expect(result[:stderr]).to include("OK")

    db = SQLite3::Database.new(pulled_path)
    rows = db.execute("SELECT name FROM items ORDER BY name")
    db.close

    expect(rows).to eq([["alpha"], ["bravo"]])
  end

  it "round-trips: pull, push different, pull again" do
    original_bytes = cp_pull_stdout

    new_db = make_db(fixture_dir, ["echo", "foxtrot"])
    result = cp_push(new_db)
    expect(result[:stdout].strip).to eq("OK")

    expect(get_items).to eq(["echo", "foxtrot"])

    swapped_bytes = cp_pull_stdout
    expect(swapped_bytes).not_to eq(original_bytes)

    pulled_path = File.join(fixture_dir, "round_trip.sqlite3")
    File.binwrite(pulled_path, swapped_bytes)
    db = SQLite3::Database.new(pulled_path)
    rows = db.execute("SELECT name FROM items ORDER BY name")
    db.close
    expect(rows).to eq([["echo"], ["foxtrot"]])
  end

  it "rejects a corrupt push and keeps serving original data" do
    expect(get_items).to eq(["alpha", "bravo"])

    stderr_sock = UNIXSocket.new(stderr_socket_path)
    sleep 0.05

    sock = UNIXSocket.new(socket_path)
    sock.write("cp - #{db_path}\n")
    sock.write("this is not a sqlite database")
    sock.close_write

    stdout = sock.read
    stderr_out = stderr_sock.read
    sock.close
    stderr_sock.close

    expect(stderr_out).to include("ERROR")

    expect(get_items).to eq(["alpha", "bravo"])
  end

  it "handles multiple sequential swaps" do
    ["golf", "hotel", "india"].each do |name|
      new_db = make_db(fixture_dir, [name])
      result = cp_push(new_db)
      expect(result[:stdout].strip).to eq("OK")
      expect(get_items).to eq([name])
    end
  end
end
