# frozen_string_literal: true

# Writes protostar's shipped signatures from the inline RBS in lib/: an `.rbs`
# under sig/ for every file in lib/ (rbs-inline), and rbi/protostar.rbi for
# Sorbet, translated from those plus sig/protostar_manual.rbs. The well-known
# types' signatures under sig/protostar/google/ and rbi/protostar/google/ come
# from script/bootstrap.rb instead.
#
#   ruby script/types.rb generate  # rewrites the files
#   ruby script/types.rb check     # fails on any difference
require "prism"
require "rbs"
require "rbs/inline"
require "stringio"
require "fileutils"
require "tmpdir"

module TypesGen
  ROOT = File.expand_path("..", __dir__)
  RBI = "rbi/protostar.rbi"
  GENERATED = /\A# Generated from (lib\/\S+\.rb) by script\/types\.rb/

  module_function

  def sources
    Dir.glob("lib/**/*.rb", base: ROOT).reject { |f| f.start_with?("lib/protostar/google/") }.sort
  end

  # Path under ROOT to contents, for every file this writes
  def generate
    ruby = RubyFacts.new
    out = {}
    sources.each do |source|
      parsed = Prism.parse_file(File.join(ROOT, source))
      ruby.read(parsed)
      rbs = Sig.new(source, parsed).to_s or next
      out[source.sub(/\Alib\//, "sig/").sub(/\.rb\z/, ".rbs")] = rbs
    end
    out[RBI] = Dir.mktmpdir do |dir|
      FileUtils.cp_r(File.join(ROOT, "sig"), dir)
      sig = File.join(dir, "sig")
      stale(out).each { |f| File.delete(File.join(dir, f)) }
      out.each do |path, text|
        next unless path.start_with?("sig/")
        FileUtils.mkdir_p(File.dirname(File.join(dir, path)))
        File.write(File.join(dir, path), text)
      end
      Rbi.new(sig, ruby).to_s
    end
    out
  end

  # Generated sig/ files whose lib/ file is gone
  def stale(out)
    Dir.glob("sig/**/*.rbs", base: ROOT).select { |f| File.read(File.join(ROOT, f))[GENERATED] && !out.key?(f) }
  end

  def differences
    out = generate
    out.reject { |path, text| File.file?(File.join(ROOT, path)) && File.read(File.join(ROOT, path)) == text }.keys + stale(out)
  end

  def write
    out = generate
    stale(out).each { |f| File.delete(File.join(ROOT, f)) }
    out.each do |path, text|
      full = File.join(ROOT, path)
      next if File.file?(full) && File.read(full) == text
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, text)
    end
  end

  # The RBS of one lib/ file: what rbs-inline makes of it, plus the two
  # things it leaves out, `alias_method` and attributes under `class << self`
  class Sig
    def initialize(source, parsed)
      @source = source
      @parsed = parsed
    end

    def to_s
      uses, decls, rbs_decls = RBS::Inline::Parser.parse(@parsed, opt_in: false) || (return nil)
      raise "#{@source}: `# @rbs use` is not supported here" unless uses.empty?
      rbs = []
      writer = RBS::Inline::Writer.new
      decls.each { |d| writer.translate_decl(d, rbs) }
      rbs.concat(rbs_decls)
      fix(rbs)
      io = StringIO.new
      io.puts "# Generated from #{@source} by script/types.rb. Do not edit."
      io.puts
      RBS::Writer.new(out: io).write(rbs)
      # the annotations themselves, which rbs-inline copies into the docs
      io.string.lines.reject { |l| l.match?(/\A\s*# (: |@rbs\b|:stopdoc:|:startdoc:)/) }.join
    end

    private

    def fix(rbs)
      by_name = {}
      index = lambda do |decls, prefix|
        decls.each do |d|
          next unless d.is_a?(RBS::AST::Declarations::Class) || d.is_a?(RBS::AST::Declarations::Module)
          name = [prefix, d.name.to_s].compact.join("::")
          by_name[name] ||= d
          index.call(d.members, name)
        end
      end
      index.call(rbs, nil)
      RubyFacts.each_in(@parsed) do |scope, singleton, node|
        decl = by_name[scope] or next
        case node.name
        when :alias_method
          new_name, old_name = node.arguments.arguments.map { |a| a.unescaped.to_sym }
          decl.members << RBS::AST::Members::Alias.new(new_name: new_name, old_name: old_name, kind: singleton ? :singleton : :instance,
            annotations: [], location: nil, comment: nil)
        when :attr_reader, :attr_writer, :attr_accessor
          next unless singleton
          names = node.arguments.arguments.map { |a| a.unescaped.to_sym }
          decl.members.map! do |m|
            next m unless m.is_a?(RBS::AST::Members::Attribute) && m.kind == :instance && names.include?(m.name)
            m.class.new(name: m.name, type: m.type, ivar_name: m.ivar_name, kind: :singleton, annotations: m.annotations,
              location: nil, comment: m.comment, visibility: m.visibility)
          end
        end
      end
    end
  end

  # What only the Ruby source knows: parameter names, for the RBI
  class RubyFacts
    # yields [scope, singleton?, CallNode] for alias_method and attr_* in class bodies
    def self.each_in(parsed, &block)
      walk(parsed.value, nil, false, &block)
    end

    def self.walk(node, scope, singleton, &block)
      case node
      when Prism::ModuleNode, Prism::ClassNode
        inner = [scope, node.constant_path.slice.delete_prefix("::")].compact.join("::")
        walk(node.body, inner, false, &block) if node.body
      when Prism::SingletonClassNode
        walk(node.body, scope, true, &block) if node.body
      when Prism::CallNode
        if scope && node.receiver.nil? && %i[alias_method attr_reader attr_writer attr_accessor].include?(node.name) &&
            node.arguments&.arguments&.all?(Prism::SymbolNode)
          yield scope, singleton, node
        end
      when Prism::DefNode
        yield scope, singleton || node.receiver.is_a?(Prism::SelfNode), node if scope
      when Prism::ProgramNode, Prism::StatementsNode, Prism::BeginNode, Prism::IfNode, Prism::ElseNode, Prism::UnlessNode
        node.compact_child_nodes.each { |c| walk(c, scope, singleton, &block) }
      end
    end

    def initialize
      @params = {}
    end

    def read(parsed)
      self.class.each_in(parsed) do |scope, singleton, node|
        next unless node.is_a?(Prism::DefNode)
        @params["#{scope}#{singleton ? "." : "#"}#{node.name}"] ||= params_of(node)
      end
    end

    # [[kind, name], ...] with kind one of :req :opt :rest :post :key :keyreq :keyrest :block
    def params(key) = @params[key]

    private

    def params_of(node)
      p = node.parameters or return []
      out = []
      p.requireds.each_with_index { |r, i| out << [:req, r.respond_to?(:name) ? r.name.to_s : "arg#{i}"] }
      p.optionals.each { |o| out << [:opt, o.name.to_s] }
      case p.rest
      when Prism::RestParameterNode then out << [:rest, (p.rest.name || :args).to_s]
      end
      p.posts.each_with_index { |r, i| out << [:post, r.respond_to?(:name) ? r.name.to_s : "post#{i}"] }
      p.keywords.each { |k| out << [k.is_a?(Prism::RequiredKeywordParameterNode) ? :keyreq : :key, k.name.to_s] }
      case p.keyword_rest
      when Prism::KeywordRestParameterNode then out << [:keyrest, (p.keyword_rest.name || :kwargs).to_s]
      when Prism::ForwardingParameterNode then out.push([:rest, "args"], [:keyrest, "kwargs"], [:block, "blk"])
      end
      out << [:block, (p.block.name || :blk).to_s] if p.block
      out
    end
  end

  # rbi/protostar.rbi: every class, module and public method in the generated
  # sig/ files and the manual one, names resolved, types in Sorbet's terms.
  # Overloads become one sig, since Sorbet takes several only for its own
  # stdlib: each parameter takes what any overload gives it.
  class Rbi
    GENERICS = {
      "::Array" => "T::Array", "::Hash" => "T::Hash", "::Set" => "T::Set", "::Range" => "T::Range",
      "::Enumerable" => "T::Enumerable", "::Enumerator" => "T::Enumerator"
    }.freeze
    # Types Sorbet's own RBI lacks
    UNKNOWN = {"::JSON::State" => "T.untyped"}.freeze
    PRELUDE = "class IO\n  class Buffer; end\nend\n"

    def initialize(sig_dir, ruby)
      @sig_dir = sig_dir.to_s + "/"
      @ruby = ruby
      loader = RBS::EnvironmentLoader.new
      loader.add(path: Pathname(sig_dir))
      loader.add(library: "json")
      @env = RBS::Environment.from_loader(loader).resolve_type_names
    end

    def to_s
      out = +"# typed: strict\n\n"
      out << "# Generated by script/types.rb from the inline RBS in lib/ and sig/protostar_manual.rbs. Do not edit.\n"
      out << "# Message classes compiled with `protostar compile --ruby_out=...` get their own `_pb.rbi`;\n"
      out << "# the well-known types' are under rbi/protostar/google/protobuf/.\n"
      @env.class_decls.select { |_, e| e.each_decl.any? { |d| ours?(d) } }.sort_by { |name, _| name.to_s }.each do |name, entry|
        out << "\n" << klass(name, entry)
      end
      @env.class_alias_decls.select { |_, e| ours?(e.decl) }.sort_by { |name, _| name.to_s }.each do |name, entry|
        out << "\n#{plain(name)} = #{plain(entry.decl.old_name)}\n"
      end
      out << "\n" << PRELUDE
    end

    private

    def ours?(decl)
      buffer = decl.location&.buffer&.name.to_s
      rel = buffer.delete_prefix(@sig_dir)
      rel != buffer && !rel.start_with?("protostar/google/")
    end

    def plain(name) = name.to_s.delete_prefix("::")

    def klass(name, entry)
      decls = entry.each_decl.select { |d| ours?(d) }
      @owner = name
      @module = !decls.first.is_a?(RBS::AST::Declarations::Class)
      super_class = decls.filter_map { |d| d.super_class if d.is_a?(RBS::AST::Declarations::Class) }.first
      head = "#{@module ? "module" : "class"} #{plain(name)}"
      head += " < #{plain(super_class.name)}" if super_class && super_class.name.to_s != "::Object"
      body = decls.flat_map { |d| d.members.flat_map { |m| member(m) } }
      body.shift while body.first == ""
      return "#{head}; end\n" if body.empty?
      "#{head}\n#{body.map { |l| l.empty? ? "\n" : "  #{l}\n" }.join}end\n"
    end

    def member(m)
      case m
      when RBS::AST::Members::MethodDefinition
        return [] if m.visibility == :private && m.name != :initialize
        method(m.name, m.kind != :instance, m.overloads.map(&:method_type))
      when RBS::AST::Members::Attribute
        return [] if m.visibility == :private
        prefix = (m.kind == :singleton) ? "self." : ""
        type = context(m.kind == :singleton, true) { type(m.type) }
        lines = []
        lines.push("", "sig { returns(#{type}) }", "def #{prefix}#{m.name}; end") unless m.is_a?(RBS::AST::Members::AttrWriter)
        lines.push("", "sig { params(value: #{type}).returns(#{type}) }", "def #{prefix}#{m.name}=(value); end") unless m.is_a?(RBS::AST::Members::AttrReader)
        lines
      when RBS::AST::Members::Alias
        line = "alias_method :#{m.new_name}, :#{m.old_name}"
        ["", (m.kind == :singleton) ? "class << self; #{line}; end" : line]
      when RBS::AST::Members::Include, RBS::AST::Members::Extend
        return [] if m.name.interface?
        lines = ["#{m.is_a?(RBS::AST::Members::Include) ? "include" : "extend"} #{plain(m.name)}"]
        if m.name.to_s == "::Enumerable" && m.is_a?(RBS::AST::Members::Include)
          elem = m.args.first ? context(false, true) { type(m.args.first) } : "T.untyped"
          lines.push("extend T::Generic", "", "Elem = type_member { {fixed: #{elem}} }")
        end
        lines
      when RBS::AST::Declarations::Constant
        ["", "#{m.name.name} = T.let(T.unsafe(nil), #{context(false, true) { type(m.type) }})"]
      when RBS::AST::Members::Public, RBS::AST::Members::Private, RBS::AST::Declarations::Base,
        RBS::AST::Members::InstanceVariable, RBS::AST::Members::ClassInstanceVariable
        []
      else
        raise "#{@owner}: #{m.class} is not handled"
      end
    end

    def context(singleton, out)
      @singleton = singleton
      @out = out
      yield
    end

    def method(name, singleton, overloads)
      ruby = @ruby.params("#{plain(@owner)}#{singleton ? "." : "#"}#{name}")
      params = if overloads.size == 1 && overloads.first.type.is_a?(RBS::Types::Function)
        params_from(overloads.first, ruby || [])
      else
        ruby || params_from(overloads.first, [])
      end
      params += [[:block, "blk"]] if overloads.any?(&:block) && params.none? { |k, _| k == :block }
      sig_params = params.map do |kind, pname|
        types = context(singleton, false) { overloads.map { |o| param_type(o, params, kind, pname) } }
        t = union(types.compact.empty? ? ["T.untyped"] : types.compact)
        t = union([t, "NilClass"]) if types.include?(nil) && kind != :block
        "#{pname}: #{t}"
      end
      returns = overloads.map { |o| o.type.return_type }
      ret = if name == :initialize || returns.all?(RBS::Types::Bases::Void)
        "void"
      else
        "returns(#{context(singleton, true) { union(returns.map { |r| type(r) }) }})"
      end
      tparams = overloads.flat_map { |o| o.type_params.map(&:name) }.uniq
      sig = +""
      sig << "type_parameters(#{tparams.map { |t| ":#{t}" }.join(", ")})." unless tparams.empty?
      sig << "params(#{sig_params.join(", ")})." unless sig_params.empty?
      sig << ret
      args = params.map { |k, n| ruby_param(k, n) }
      head = singleton ? "def self.#{name}" : "def #{name}"
      head += "(#{args.join(", ")})" unless args.empty?
      ["", "sig { #{sig} }", "#{head}; end"]
    end

    def ruby_param(kind, name)
      case kind
      when :req, :post then name
      when :opt then "#{name} = T.unsafe(nil)"
      when :rest then "*#{name}"
      when :keyreq then "#{name}:"
      when :key then "#{name}: T.unsafe(nil)"
      when :keyrest then "**#{name}"
      when :block then "&#{name}"
      end
    end

    # The parameters as the signature has them, named as in the Ruby source
    # where it has a name for that position
    def params_from(method_type, ruby)
      f = method_type.type
      return [[:rest, "args"], [:keyrest, "kwargs"]] unless f.is_a?(RBS::Types::Function)
      positional = ruby.filter_map { |k, n| n if k == :req || k == :opt || k == :post }
      keywords = f.required_keywords.keys + f.optional_keywords.keys
      taken = keywords.map(&:to_s)
      i = -1
      name = lambda do |param, fallback|
        i += 1
        n = [positional[i], param.name&.to_s, fallback].compact.find { |c| !taken.include?(c) } || "arg#{i}"
        taken << n
        n
      end
      out = []
      f.required_positionals.each { |p| out << [:req, name.call(p, "arg#{i + 1}")] }
      f.optional_positionals.each { |p| out << [:opt, name.call(p, "arg#{i + 1}")] }
      out << [:rest, f.rest_positionals.name&.to_s || ruby.find { |k, _| k == :rest }&.last || "args"] if f.rest_positionals
      f.trailing_positionals.each { |p| out << [:post, name.call(p, "arg#{i + 1}")] }
      keywords.each { |k| out << [f.required_keywords.key?(k) ? :keyreq : :key, k.to_s] }
      out << [:keyrest, f.rest_keywords.name&.to_s || ruby.find { |k, _| k == :keyrest }&.last || "kwargs"] if f.rest_keywords
      out << [:block, ruby.find { |k, _| k == :block }&.last || "blk"] if method_type.block
      out
    end

    # The type an overload gives one Ruby parameter, nil when it has none
    def param_type(overload, params, kind, pname)
      if kind == :block
        b = overload.block or return nil
        return b.required ? proc_type(b.type) : "T.nilable(#{proc_type(b.type)})"
      end
      f = overload.type
      return "T.untyped" unless f.is_a?(RBS::Types::Function)
      t = case kind
      when :req, :opt
        idx = params.filter_map { |k, n| n if k == :req || k == :opt }.index(pname)
        (f.required_positionals + f.optional_positionals)[idx]&.type || f.rest_positionals&.type
      when :rest then f.rest_positionals&.type
      when :post
        idx = params.filter_map { |k, n| n if k == :post }.index(pname)
        f.trailing_positionals[idx]&.type
      when :keyreq, :key
        (f.required_keywords[pname.to_sym] || f.optional_keywords[pname.to_sym])&.type || f.rest_keywords&.type
      when :keyrest then f.rest_keywords&.type
      end
      t && type(t)
    end

    def proc_type(fn)
      return "T.proc.params(args: T.untyped).returns(T.untyped)" unless fn.is_a?(RBS::Types::Function)
      i = -1
      ps = (fn.required_positionals + fn.optional_positionals).map { |p| "#{p.name || "arg#{i += 1}"}: #{type(p.type)}" }
      ps << "#{fn.rest_positionals.name || "rest"}: #{type(fn.rest_positionals.type)}" if fn.rest_positionals
      ret = fn.return_type.is_a?(RBS::Types::Bases::Void) ? "void" : "returns(#{type(fn.return_type)})"
      ps.empty? ? "T.proc.#{ret}" : "T.proc.params(#{ps.join(", ")}).#{ret}"
    end

    def union(types)
      types = types.uniq
      return "T.untyped" if types.include?("T.untyped")
      nilable = types.delete("NilClass")
      types = types.map do |t|
        next t unless t.start_with?("T.nilable(")
        nilable = true
        t.delete_prefix("T.nilable(").delete_suffix(")")
      end.uniq
      return "NilClass" if types.empty?
      inner = (types.size == 1) ? types.first : "T.any(#{types.join(", ")})"
      nilable ? "T.nilable(#{inner})" : inner
    end

    def type(t, depth = 0)
      case t
      when RBS::Types::Bases::Any, RBS::Types::Interface, RBS::Types::UntypedFunction, RBS::Types::Bases::Class then "T.untyped"
      when RBS::Types::Bases::Bool then "T::Boolean"
      when RBS::Types::Bases::Void, RBS::Types::Bases::Top then "T.anything"
      when RBS::Types::Bases::Bottom then "T.noreturn"
      when RBS::Types::Bases::Nil then "NilClass"
      # Sorbet allows these in returns only
      when RBS::Types::Bases::Self then @out ? "T.self_type" : plain(@owner)
      when RBS::Types::Bases::Instance
        if @module then "T.untyped"
        elsif @singleton && @out then "T.attached_class"
        else plain(@owner)
        end
      when RBS::Types::Variable then "T.type_parameter(:#{t.name})"
      when RBS::Types::Optional then union([type(t.type, depth), "NilClass"])
      when RBS::Types::Union then union(t.types.map { |x| type(x, depth) })
      when RBS::Types::Intersection then "T.all(#{t.types.map { |x| type(x, depth) }.join(", ")})"
      when RBS::Types::Literal
        case t.literal
        when Symbol then "Symbol"
        when String then "String"
        when Integer then "Integer"
        when true then "TrueClass"
        when false then "FalseClass"
        else "T.untyped"
        end
      when RBS::Types::Tuple then "[#{t.types.map { |x| type(x, depth) }.join(", ")}]"
      when RBS::Types::Record
        fields = t.all_fields.map do |k, (v, required)|
          "#{k}: #{required ? type(v, depth) : union([type(v, depth), "NilClass"])}"
        end
        "{#{fields.join(", ")}}"
      when RBS::Types::Proc then proc_type(t.type)
      when RBS::Types::ClassSingleton then "T.class_of(#{plain(t.name)})"
      when RBS::Types::Alias
        raise "type alias #{t.name} is too deep" if depth > 20
        type(@env.type_alias_decls.fetch(t.name).decl.type, depth + 1)
      when RBS::Types::ClassInstance
        name = t.name.to_s
        return UNKNOWN[name] if UNKNOWN.key?(name)
        return "T::Class[T.anything]" if name == "::Class"
        return "T::Module[T.anything]" if name == "::Module"
        generic = GENERICS[name] or return plain(name)
        args = t.args.map { |a| type(a, depth) }
        args = args.first(1) if name == "::Enumerator"
        args = ["T.untyped"] * ((name == "::Hash") ? 2 : 1) if args.empty?
        "#{generic}[#{args.join(", ")}]"
      else
        raise "#{t.class} is not handled"
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  case ARGV.first
  when "check"
    stale = TypesGen.differences
    unless stale.empty?
      abort "Signatures differ from what the inline RBS in lib/ generates:\n  #{stale.join("\n  ")}\n" \
        "Run `rake types:generate`."
    end
    puts "sig/ and rbi/protostar.rbi are up to date."
  when "generate"
    TypesGen.write
  else
    abort "usage: ruby script/types.rb check|generate"
  end
end
