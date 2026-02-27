require "spec_helper"
require "sqlite3"

RSpec.describe Hotswap::CLI do
  let(:tmpdir) { Dir.mktmpdir }
  let(:db_path) { File.join(tmpdir, "test.sqlite3") }

  before do
    db = SQLite3::Database.new(db_path)
    db.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT)")
    db.execute("INSERT INTO items (name) VALUES ('original')")
    db.close
    Hotswap.database_path = db_path
  end

  after do
    FileUtils.rm_rf(tmpdir)
    Hotswap.database_path = nil
  end

  describe "cp" do
    context "file → database path (push)" do
      it "replaces the database when dst matches the running db path" do
        new_db_path = File.join(tmpdir, "new.sqlite3")
        db = SQLite3::Database.new(new_db_path)
        db.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT)")
        db.execute("INSERT INTO items (name) VALUES ('replaced')")
        db.close

        output = StringIO.new
        err_output = StringIO.new

        Hotswap::CLI.run(["cp", new_db_path, db_path], stdout: output, stderr: err_output)

        expect(output.string).to eq("OK\n")
        expect(err_output.string).to include("Swapping")

        db = SQLite3::Database.new(db_path)
        rows = db.execute("SELECT name FROM items")
        db.close
        expect(rows).to eq([["replaced"]])
      end
    end

    context "database path → file (pull)" do
      it "snapshots the database when src matches the running db path" do
        pulled_path = File.join(tmpdir, "pulled.sqlite3")
        err_output = StringIO.new

        Hotswap::CLI.run(["cp", db_path, pulled_path], stderr: err_output)

        expect(err_output.string).to include("OK")

        db = SQLite3::Database.new(pulled_path)
        rows = db.execute("SELECT name FROM items")
        db.close
        expect(rows).to eq([["original"]])
      end
    end

    context "stdin → database path" do
      it "replaces the database from stdin" do
        new_db_path = File.join(tmpdir, "new.sqlite3")
        db = SQLite3::Database.new(new_db_path)
        db.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT)")
        db.execute("INSERT INTO items (name) VALUES ('from-stdin')")
        db.close

        output = StringIO.new
        err_output = StringIO.new
        input = File.open(new_db_path, "rb")

        Hotswap::CLI.run(["cp", "-", db_path], stdin: input, stdout: output, stderr: err_output)

        expect(output.string).to eq("OK\n")

        db = SQLite3::Database.new(db_path)
        rows = db.execute("SELECT name FROM items")
        db.close
        expect(rows).to eq([["from-stdin"]])
      end
    end

    context "database path → stdout" do
      it "streams the database to stdout" do
        output = StringIO.new
        output.binmode

        Hotswap::CLI.run(["cp", db_path, "-"], stdout: output)

        pulled_path = File.join(tmpdir, "pulled.sqlite3")
        File.binwrite(pulled_path, output.string)

        db = SQLite3::Database.new(pulled_path)
        rows = db.execute("SELECT name FROM items")
        db.close
        expect(rows).to eq([["original"]])
      end
    end

    context "'database' keyword still works" do
      it "accepts 'database' as an alias for the running db" do
        pulled_path = File.join(tmpdir, "pulled.sqlite3")
        err_output = StringIO.new

        Hotswap::CLI.run(["cp", "database", pulled_path], stderr: err_output)

        expect(err_output.string).to include("OK")

        db = SQLite3::Database.new(pulled_path)
        rows = db.execute("SELECT name FROM items")
        db.close
        expect(rows).to eq([["original"]])
      end
    end

    context "neither arg is the database" do
      it "returns an error" do
        err_output = StringIO.new

        Hotswap::CLI.run(["cp", "/tmp/a.db", "/tmp/b.db"], stderr: err_output)

        expect(err_output.string).to include("ERROR")
      end
    end

    context "corrupt file → database" do
      it "rejects a corrupt database" do
        corrupt_file = File.join(tmpdir, "corrupt.db")
        File.write(corrupt_file, "this is not a sqlite database")

        output = StringIO.new
        err_output = StringIO.new

        Hotswap::CLI.run(["cp", corrupt_file, db_path], stdout: output, stderr: err_output)

        expect(err_output.string).to include("ERROR")

        db = SQLite3::Database.new(db_path)
        rows = db.execute("SELECT name FROM items")
        db.close
        expect(rows).to eq([["original"]])
      end
    end
  end

  describe "version" do
    it "prints the version" do
      output = StringIO.new

      Hotswap::CLI.run(["version"], stdout: output)

      expect(output.string).to eq("hotswap #{Hotswap::VERSION}\n")
    end
  end

  describe "help (no args)" do
    it "prints help to stdout" do
      output = StringIO.new

      Hotswap::CLI.run([], stdout: output)

      expect(output.string).to include("cp SRC DST")
      expect(output.string).to include("version")
    end
  end

  describe "unknown command" do
    it "prints error without crashing" do
      output = StringIO.new
      err_output = StringIO.new

      Hotswap::CLI.run(["bogus"], stdout: output, stderr: err_output)

      combined = output.string + err_output.string
      expect(combined).to include("Could not find")
    end
  end

  describe "thread safety" do
    it "handles concurrent CLI calls without clobbering IO" do
      results = Array.new(5) { StringIO.new }

      threads = results.map do |out|
        Thread.new do
          Hotswap::CLI.run(["version"], stdout: out)
        end
      end
      threads.each(&:join)

      results.each do |out|
        expect(out.string).to eq("hotswap #{Hotswap::VERSION}\n")
      end
    end
  end
end
