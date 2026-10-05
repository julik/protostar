# frozen_string_literal: true

# protoc's parser output, the `FileDescriptorProto` before linking, derived
# from a parsed AST so the parser tests can compare it with what
# parser_unittest.cc expects
module AstHash
  module_function

  def file(ast)
    h = {}
    put(h, :name, ast.name)
    put(h, :package, ast.package)
    h[:dependency] = ast.dependency.dup unless ast.dependency.empty?
    h[:public_dependency] = ast.public_dependency.dup unless ast.public_dependency.empty?
    h[:weak_dependency] = ast.weak_dependency.dup unless ast.weak_dependency.empty?
    h[:option_dependency] = ast.option_dependency.dup unless ast.option_dependency.empty?
    list(h, :message_type, ast.message_type) { |m| message(m) }
    list(h, :enum_type, ast.enum_type) { |e| enum(e) }
    list(h, :service, ast.service) { |s| service(s) }
    list(h, :extension, ast.extension) { |f| field(f) }
    put(h, :options, ast.options && options(ast.options))
    put(h, :syntax, ast.syntax)
    put(h, :edition, ast.edition)
    h
  end

  def options(options)
    h = options.known.dup
    unless options.uninterpreted.empty?
      h[:uninterpreted_option] = options.uninterpreted.map do |o|
        option = {name: o.name.map { |part, ext| {name_part: part, is_extension: ext} }}
        option[o.value_kind] = o.value if o.value_kind
        option
      end
    end
    h
  end

  def message(m)
    h = {}
    put(h, :name, m.name)
    list(h, :field, m.field) { |f| field(f) }
    list(h, :extension, m.extension) { |f| field(f) }
    list(h, :nested_type, m.nested_type) { |n| message(n) }
    list(h, :enum_type, m.enum_type) { |e| enum(e) }
    list(h, :extension_range, m.extension_range) { |r| range(r) }
    list(h, :oneof_decl, m.oneof_decl) { |o| named(o) }
    put(h, :options, m.options && options(m.options))
    list(h, :reserved_range, m.reserved_range) { |r| range(r) }
    h[:reserved_name] = m.reserved_name.dup unless m.reserved_name.empty?
    put(h, :visibility, m.visibility)
    h
  end

  def field(f)
    h = {}
    put(h, :name, f.name)
    put(h, :extendee, f.extendee)
    put(h, :number, f.number)
    put(h, :label, f.label)
    put(h, :type, f.type)
    put(h, :type_name, f.type_name)
    put(h, :default_value, f.default_value)
    put(h, :options, f.options && options(f.options))
    put(h, :oneof_index, f.oneof_index)
    put(h, :json_name, f.json_name)
    h[:proto3_optional] = true if f.proto3_optional
    h
  end

  def named(node)
    h = {}
    put(h, :name, node.name)
    put(h, :options, node.options && options(node.options))
    h
  end

  def range(r)
    h = {}
    put(h, :start, r.start)
    put(h, :end, r.end)
    put(h, :options, r.options && options(r.options))
    h
  end

  def enum(e)
    h = {}
    put(h, :name, e.name)
    list(h, :value, e.value) do |v|
      value = {}
      put(value, :name, v.name)
      put(value, :number, v.number)
      put(value, :options, v.options && options(v.options))
      value
    end
    put(h, :options, e.options && options(e.options))
    list(h, :reserved_range, e.reserved_range) { |r| range(r) }
    h[:reserved_name] = e.reserved_name.dup unless e.reserved_name.empty?
    put(h, :visibility, e.visibility)
    h
  end

  def service(s)
    h = {}
    put(h, :name, s.name)
    list(h, :method, s.rpcs) do |m|
      method = {}
      put(method, :name, m.name)
      put(method, :input_type, m.input_type)
      put(method, :output_type, m.output_type)
      put(method, :options, m.options && options(m.options))
      method[:client_streaming] = true if m.client_streaming
      method[:server_streaming] = true if m.server_streaming
      method
    end
    put(h, :options, s.options && options(s.options))
    h
  end

  def put(h, key, value)
    h[key] = value unless value.nil?
  end

  def list(h, key, items, &block)
    h[key] = items.map(&block) unless items.empty?
  end
end
