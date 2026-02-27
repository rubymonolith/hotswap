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
    context "file → database (push)" do
      it "replaces the database from a file path" do
        new_db_path = File.join(tmpdir, "new.sqlite3")
        db = SQLite3::Database.new(new_db_path)
        db.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT)")
        db.execute("INSERT INTO items (name) VALUES ('replaced')")
        db.close

        output = StringIO.new
        err_output = StringIO.new

        Hotswap::CLI.run(["cp", new_db_path, "database"], stdout: output, stderr: err_output)

        expect(output.string).to eq("OK\n")
        expect(err_output.string).to include("Swapping")

        db = SQLite3::Database.new(db_path)
        rows = db.execute("SELECT name FROM items")
        db.close
        expect(rows).to eq([["replaced"]])
      end
    end

    context "database → file (pull)" do
      it "snapshots the database to a file path" do
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

    context "stdin → database" do
      it "replaces the database from stdin" do
        new_db_path = File.join(tmpdir, "new.sqlite3")
        db = SQLite3::Database.new(new_db_path)
        db.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT)")
        db.execute("INSERT INTO items (name) VALUES ('from-stdin')")
        db.close

        output = StringIO.new
        err_output = StringIO.new
        input = File.open(new_db_path, "rb")

        Hotswap::CLI.run(["cp", "-", "database"], stdin: input, stdout: output, stderr: err_output)

        expect(output.string).to eq("OK\n")

        db = SQLite3::Database.new(db_path)
        rows = db.execute("SELECT name FROM items")
        db.close
        expect(rows).to eq([["from-stdin"]])
      end
    end

    context "database → stdout" do
      it "streams the database to stdout" do
        output = StringIO.new
        output.binmode

        Hotswap::CLI.run(["cp", "database", "-"], stdout: output)

        pulled_path = File.join(tmpdir, "pulled.sqlite3")
        File.binwrite(pulled_path, output.string)

        db = SQLite3::Database.new(pulled_path)
        rows = db.execute("SELECT name FROM items")
        db.close
        expect(rows).to eq([["original"]])
      end
    end

    context "corrupt file → database" do
      it "rejects a corrupt database" do
        corrupt_file = File.join(tmpdir, "corrupt.db")
        File.write(corrupt_file, "this is not a sqlite database")

        output = StringIO.new
        err_output = StringIO.new

        Hotswap::CLI.run(["cp", corrupt_file, "database"], stdout: output, stderr: err_output)

        expect(err_output.string).to include("ERROR")

        db = SQLite3::Database.new(db_path)
        rows = db.execute("SELECT name FROM items")
        db.close
        expect(rows).to eq([["original"]])
      end
    end
  end

  describe "push (delegates to cp)" do
    it "replaces the database from stdin" do
      new_db_path = File.join(tmpdir, "new.sqlite3")
      db = SQLite3::Database.new(new_db_path)
      db.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT)")
      db.execute("INSERT INTO items (name) VALUES ('pushed')")
      db.close

      output = StringIO.new
      err_output = StringIO.new
      input = File.open(new_db_path, "rb")

      Hotswap::CLI.run(["push"], stdin: input, stdout: output, stderr: err_output)

      expect(output.string).to eq("OK\n")

      db = SQLite3::Database.new(db_path)
      rows = db.execute("SELECT name FROM items")
      db.close
      expect(rows).to eq([["pushed"]])
    end
  end

  describe "pull (delegates to cp)" do
    it "streams the database to stdout" do
      output = StringIO.new
      output.binmode

      Hotswap::CLI.run(["pull"], stdout: output)

      pulled_path = File.join(tmpdir, "pulled.sqlite3")
      File.binwrite(pulled_path, output.string)

      db = SQLite3::Database.new(pulled_path)
      rows = db.execute("SELECT name FROM items")
      db.close
      expect(rows).to eq([["original"]])
    end
  end

  describe "version" do
    it "prints the version" do
      output = StringIO.new

      Hotswap::CLI.run(["version"], stdout: output)

      expect(output.string).to eq("hotswap #{Hotswap::VERSION}\n")
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
