# frozen_string_literal: true

# Records what Google's google-protobuf 4.36.2 gives for every probe in
# test/differential/probes.txt, into test/differential/google-protobuf-4.36.2.txt.
# Run it outside this gem's bundle, with Google's gem installed:
#
#   gem install google-protobuf -v 4.36.2
#   ruby script/record_differential.rb

abort "run outside bundle exec: Google's gem must be the one loaded" if defined?(Bundler)

gem "google-protobuf", "4.36.2"
root = File.expand_path("..", __dir__)
$LOAD_PATH.unshift(File.join(root, "test/google"))
require_relative "../test/differential/probe"

binding = Differential.setup
abort "loaded #{Google::Protobuf::IMPLEMENTATION}, not Google's gem" if Google::Protobuf::IMPLEMENTATION == :PROTOSTAR
# known differences still run (later probes may rely on them) but are not
# recorded: some of them print addresses or upb's hash order
outputs = Differential.probes.map do |probe|
  output = Differential.run(probe.source, binding)
  probe.difference ? "~ #{probe.difference}" : output
end
File.write(Differential::RECORDED, outputs.join("\n---\n") + "\n")
puts "#{outputs.size} probes recorded"
