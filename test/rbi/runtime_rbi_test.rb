# frozen_string_literal: true

require "test_helper"

# rbi/protostar.rbi (for Sorbet) and sig/protostar.rbs (for RBS) describe
# the same public API: the same modules and classes, the same methods on each
class RuntimeRbiTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  RBS_FILE = File.join(ROOT, "sig/protostar.rbs")
  RBI_FILE = File.join(ROOT, "rbi/protostar.rbi")

  def setup
    require "rbs"
    require "prism"
  rescue LoadError => e
    skip "#{e.message} (Prism is Ruby 3.3 and later)"
  end

  def test_the_rbi_and_the_rbs_name_the_same_methods
    rbs = rbs_methods
    rbi = rbi_methods.reject { |m| m.start_with?("IO::") }
    assert_equal [[], []], [rbs - rbi, rbi - rbs], "only in the RBS, only in the RBI"
  end

  def test_the_rbi_and_the_rbs_name_the_same_constants
    rbs = rbs_constants
    rbi = rbi_constants.reject { |c| c.start_with?("IO") || c.end_with?("::Elem") }
    assert_equal [[], []], [rbs - rbi, rbi - rbs], "only in the RBS, only in the RBI"
  end

  def test_the_gem_ships_the_rbi
    spec = Gem::Specification.load(File.join(ROOT, "protostar.gemspec"))
    assert_includes spec.files, "rbi/protostar.rbi"
    assert_includes spec.files, "rbi/protostar/google/protobuf/timestamp_pb.rbi"
  end

  private

  def rbs_decls
    _, _, decls = RBS::Parser.parse_signature(File.read(RBS_FILE))
    decls
  end

  # ["Protostar::Message.decode", "Protostar::Message#encode", ...]
  def rbs_methods
    out = []
    walk = lambda do |decl, prefix|
      name = [prefix, decl.name.to_s].compact.join("::")
      decl.members.each do |m|
        case m
        when RBS::AST::Declarations::Class, RBS::AST::Declarations::Module then walk.call(m, name)
        when RBS::AST::Members::MethodDefinition
          out << "#{name}#{(m.kind == :singleton) ? "." : "#"}#{m.name}"
        when RBS::AST::Members::AttrReader then out << "#{name}##{m.name}"
        when RBS::AST::Members::AttrWriter then out << "#{name}##{m.name}="
        when RBS::AST::Members::AttrAccessor then out.push("#{name}##{m.name}", "#{name}##{m.name}=")
        end
      end
    end
    rbs_decls.each { |d| walk.call(d, nil) }
    out.sort
  end

  def rbs_constants
    out = []
    walk = lambda do |decl, prefix|
      name = [prefix, decl.name.to_s].compact.join("::")
      out << name
      decl.members.each do |m|
        case m
        when RBS::AST::Declarations::Class, RBS::AST::Declarations::Module then walk.call(m, name)
        when RBS::AST::Declarations::Constant, RBS::AST::Declarations::ClassAlias, RBS::AST::Declarations::ModuleAlias
          out << "#{name}::#{m.respond_to?(:new_name) ? m.new_name : m.name}"
        end
      end
    end
    rbs_decls.each { |d| walk.call(d, nil) }
    out.sort
  end

  def rbi_walk
    walk = lambda do |node, prefix|
      node.compact_child_nodes.each do |child|
        case child
        when Prism::ClassNode, Prism::ModuleNode
          name = [prefix, child.constant_path.slice].compact.join("::")
          yield :scope, name, child
          walk.call(child.body, name) if child.body
        when Prism::DefNode then yield :def, prefix, child
        when Prism::ConstantWriteNode then yield :constant, "#{prefix}::#{child.name}", child
        else walk.call(child, prefix)
        end
      end
    end
    walk.call(Prism.parse_file(RBI_FILE).value, nil)
  end

  def rbi_methods
    out = []
    rbi_walk do |kind, scope, node|
      out << "#{scope}#{node.receiver ? "." : "#"}#{node.name}" if kind == :def
    end
    out.sort
  end

  def rbi_constants
    out = []
    rbi_walk { |kind, name, _| out << name unless kind == :def }
    out.sort
  end
end
