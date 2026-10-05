# frozen_string_literal: true

# Run in a fresh process: loads generated `_pb.rb` files and reports what
# they built, as a Marshal dump on stdout.
#
#   ruby generated_loader.rb DIR REQUEST_FILE
#
# The request is a Marshal dump of `{targets: [file names], files: [file
# names], namespaces: {file name => module path}}`. The answer has, per file
# name, `to_h` of the file in the generated pool, the source the native
# emitter writes for it again, and the constants that are missing or wrong.
dir, request_path = ARGV
$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__), dir)
warnings = []
Warning.singleton_class.prepend(Module.new { define_method(:warn) { |m, **| warnings << m } })
require "protostar"
request = Marshal.load(File.binread(request_path))
naming = Protostar::Compiler::Emitters::Naming
emitter = Protostar::Compiler::Emitters::Ruby.new(namespaces: request[:namespaces])
errors = []
request[:targets].each do |name|
  require emitter.require_path(name)
rescue Exception => e # rubocop:disable Lint/RescueException
  errors << "#{name}: #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
end
answer = {warnings: warnings, errors: errors, files: {}}
request[:files].each do |name|
  file = Protostar.generated_pool.file(name)
  unless file
    answer[:files][name] = {missing: true}
    next
  end
  modules = naming.module_path(file, request[:namespaces][name])
  wrong = []
  check = lambda do |descriptor|
    path = (modules + [naming.relative_constant(descriptor)]).join("::")
    found = begin
      Object.const_get(path)
    rescue NameError
      nil
    end
    wrong << path unless found&.equal?(Protostar::Types.find(descriptor.full_name))
  end
  file.all_messages.each { |m| check.call(m) unless m.map_entry? }
  file.all_enums.each { |e| check.call(e) }
  answer[:files][name] = {to_h: file.to_h, source: emitter.file(file), wrong_constants: wrong,
                          shareable: Ractor.shareable?(file)}
end
$stdout.binmode
$stdout.write(Marshal.dump(answer))
