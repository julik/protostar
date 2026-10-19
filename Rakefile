# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"
require "standard/rake"

TEST_FILES = FileList["test/**/*_test.rb"].exclude("test/corpus/**/*")

Rake::TestTask.new("test:serial") do |t|
  t.description = "Run the tests in one process (TEST=file, TESTOPTS=... work as for rake test)"
  t.libs << "test"
  t.libs << "lib"
  t.test_files = TEST_FILES
  t.warning = false
end

desc "Run the tests in a worker process per core (JOBS=N); PARALLEL=0, or TEST= naming one file, runs them in one"
task :test do
  files = ENV["TEST"] ? FileList[ENV["TEST"]] : TEST_FILES
  if ENV["PARALLEL"] == "0" || files.size == 1
    Rake::Task["test:serial"].invoke
  else
    ruby "-Ilib", "-Itest", "test/parallel.rb", *files, "--", *ENV["TESTOPTS"].to_s.split
  end
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

namespace :examples do
  desc "Regenerate examples/**/*_pb.rb with protostar compile"
  task :regenerate do
    ruby "script/examples.rb", "regenerate"
  end

  desc "Fail when examples/**/*_pb.rb differ from what protostar compile writes"
  task :check do
    ruby "script/examples.rb", "check"
  end
end

namespace :test do
  desc "Run the suite in parallel and then serially, and fail unless both report the same counts"
  task :parity do
    require "open3"
    counts = %w[1 0].to_h do |parallel|
      out, = Open3.capture2e({"PARALLEL" => parallel}, "bundle", "exec", "rake", "test")
      line = out[/^\d+ runs, \d+ assertions, \d+ failures, \d+ errors, \d+ skips$/] || abort("no summary from PARALLEL=#{parallel}:\n#{out}")
      puts "PARALLEL=#{parallel}: #{line}"
      [parallel, line]
    end
    abort "the parallel and serial runs differ" unless counts.values.uniq.size == 1
  end

  desc "Run the tests in one process with RUBYOPT=-w and fail on any warning from lib/ or the code it generates"
  task :warnings do
    ruby "script/warnings.rb"
  end
end

namespace :types do
  desc "Write sig/ and rbi/protostar.rbi from the inline RBS in lib/ and sig/protostar_manual.rbs"
  task :generate do
    ruby "script/types.rb", "generate"
  end

  desc "Fail when sig/ or rbi/protostar.rbi differ from what lib/ generates"
  task :check do
    ruby "script/types.rb", "check"
  end
end

namespace :rbs do
  desc "Check sig/ (generated from lib/, and the well-known types) with rbs validate"
  task :validate do
    sh "rbs", "-I", "sig", "validate"
  end
end

desc "Typecheck lib/ against the signatures in sig/ with Steep (Steepfile; Ruby 3.3 and later)"
task :steep do
  sh "steep", "check"
end

namespace :shim do
  desc "Run the google-protobuf shim's tests from its directory, with its own bundle"
  task :test do
    Bundler.with_unbundled_env do
      Dir.chdir(File.join(__dir__, "shims/google-protobuf")) do
        sh "bundle check > /dev/null || bundle install"
        sh "bundle exec rake generate:check test"
      end
    end
  end

  desc "Run cheddar-me/pbbuilder's own test suite with google-protobuf replaced by the shim (clones into tmp/)"
  task :pbbuilder do
    ruby "script/pbbuilder_suite.rb", "shim"
  end
end

namespace :builder do
  desc "Run pbbuilder's own test suite on Protostar::Builder, with llm/outputs/ws9-pbbuilder.patch applied"
  task :pbbuilder do
    ruby "script/pbbuilder_suite.rb", "builder", "--fresh"
  end
end

desc "Build the API documentation into doc/ (options in .yardopts), failing on any YARD warning"
task :yard do
  sh "yard", "doc", "--fail-on-warning"
end

desc "Run every benchmark in bench/ and print one table (WRITE=1 also puts it into docs/benchmarks.md)"
task :bench do
  Bundler.with_unbundled_env do
    ruby "bench/run.rb", *(ENV["WRITE"] ? ["--write"] : [])
  end
end

task default: %i[test standard]
