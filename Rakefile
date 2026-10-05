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

task default: %i[test standard]
