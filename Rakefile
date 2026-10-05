# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"
require "standard/rake"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/**/*_test.rb"].exclude("test/corpus/**/*")
  t.warning = false
end

namespace :corpus do
  desc "Fetch the pinned protobuf sources into test/corpus (needs git)"
  task :fetch do
    ruby "script/corpus.rb", "fetch"
  end

  desc "Regenerate protoc goldens for every corpus .proto (needs protoc and the google-protobuf gem)"
  task :goldens do
    ruby "script/corpus.rb", "goldens"
  end
end

namespace :protoc do
  desc "Download the pinned protoc into ~/.cache/protostar"
  task :install do
    ruby "script/corpus.rb", "protoc"
  end
end

namespace :bootstrap do
  desc "Fail when lib/protostar/google/protobuf/*_pb.rb differ from what the compiler generates"
  task :check do
    ruby "script/bootstrap.rb", "check"
  end

  desc "Regenerate lib/protostar/google/protobuf/*_pb.rb with the compiler"
  task :regenerate do
    ruby "script/bootstrap.rb", "regenerate"
  end
end

namespace :conformance do
  desc "Build protobuf's conformance_test_runner into ~/.cache/protostar (needs CMake and a C++ toolchain)"
  task :build do
    ruby "script/conformance.rb", "build"
  end

  desc "Run the binary, JSON and text-format conformance suites against conformance/run_testee"
  task :run do
    ruby "script/conformance.rb", "run"
  end

  desc "Regenerate conformance/generated/*_pb.rb with protostar compile"
  task :regenerate do
    ruby "script/conformance.rb", "regenerate"
  end

  desc "Fail when conformance/generated/*_pb.rb differ from what protostar compile writes"
  task :check do
    ruby "script/conformance.rb", "check"
  end
end

task default: %i[test standard]
