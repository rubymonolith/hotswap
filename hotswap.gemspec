require_relative "lib/hotswap/version"

Gem::Specification.new do |spec|
  spec.name = "hotswap"
  spec.version = Hotswap::VERSION
  spec.authors = ["Brad Gessler"]
  spec.summary = "Hot-swap SQLite databases on a running Rails server"
  spec.description = "Swap a SQLite database on a running Rails server without restart. Requests queue briefly during the swap, then resume on the new database."
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.0"

  spec.files = Dir["lib/**/*", "exe/*", "LICENSE"]
  spec.bindir = "exe"
  spec.executables = ["hotswap"]

  spec.add_dependency "thor", "~> 1.0"
  spec.add_dependency "sqlite3"

  spec.add_development_dependency "rspec", "~> 3.0"
  spec.add_development_dependency "rack-test", "~> 2.0"
  spec.add_development_dependency "rack"
  spec.add_development_dependency "rake"
  spec.add_development_dependency "railties"
  spec.add_development_dependency "activerecord"
  spec.add_development_dependency "actionpack"
  spec.add_development_dependency "webrick"
end
