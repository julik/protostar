# frozen_string_literal: true

# For every lint rule, files that trip it and files that do not. The rule's
# findings on `bad` are pinned in test/lint/goldens/<rule>.txt (rendered,
# plain) and .jsonl (--format json); script/lint_goldens.rb rewrites them.
module LintRuleCases
  # A file that passes every rule, to start the good cases from
  CLEAN = <<~PROTO
    edition = "2023";

    // Users of the shop.
    package acme.users.v1;

    // A person with an account.
    message User {
      // Stable id, never reused.
      string id = 1;
    }
  PROTO

  def self.clean(name = "acme/users/v1/user.proto")
    {name => CLEAN}
  end

  CASES = {
    "FIELD_NOT_REQUIRED" => {
      bad: {"acme/users/v1/user.proto" => <<~PROTO},
        syntax = "proto2";
        package acme.users.v1;
        message User {
          required string id = 1;
          optional string name = 2;
        }
      PROTO
      good: clean
    },
    "NO_GROUPS" => {
      bad: {"acme/users/v1/user.proto" => <<~PROTO},
        syntax = "proto2";
        package acme.users.v1;
        message User {
          repeated group Tag = 1 {
            optional string label = 2;
          }
        }
      PROTO
      good: clean
    },
    "ENUM_ZERO_VALUE_SUFFIX" => {
      bad: {"acme/users/v1/color.proto" => <<~PROTO},
        syntax = "proto3";
        package acme.users.v1;
        enum Color {
          COLOR_RED = 0;
          COLOR_GREEN = 1;
        }
      PROTO
      good: {"acme/users/v1/color.proto" => "syntax = \"proto3\";\npackage acme.users.v1;\nenum Color {\n  COLOR_UNSPECIFIED = 0;\n}\n"}
    },
    "ENUM_FIRST_VALUE_ZERO" => {
      bad: {"acme/users/v1/color.proto" => <<~PROTO},
        syntax = "proto2";
        package acme.users.v1;
        enum Color {
          COLOR_RED = 1;
          COLOR_GREEN = 2;
        }
      PROTO
      good: {"acme/users/v1/color.proto" => "syntax = \"proto2\";\npackage acme.users.v1;\nenum Color {\n  COLOR_UNSPECIFIED = 0;\n}\n"}
    },
    "FIELD_NUMBER_REUSE_RISK" => {
      bad: {"acme/users/v1/user.proto" => <<~PROTO},
        syntax = "proto3";
        package acme.users.v1;
        message User {
          string name = 1;
          string phone = 3;
          string email = 7;
        }
      PROTO
      good: {"acme/users/v1/user.proto" => "syntax = \"proto3\";\npackage acme.users.v1;\nmessage User {\n  reserved 2;\n  string name = 1;\n  string phone = 3;\n}\n"}
    },
    "RESERVED_NAMES_WITH_NUMBERS" => {
      bad: {"acme/users/v1/user.proto" => <<~PROTO},
        syntax = "proto3";
        package acme.users.v1;
        message User {
          reserved 2;
          string name = 1;
        }
        enum Color {
          reserved "COLOR_BLUE";
          COLOR_UNSPECIFIED = 0;
        }
      PROTO
      good: {"acme/users/v1/user.proto" => "syntax = \"proto3\";\npackage acme.users.v1;\nmessage User {\n  reserved 2;\n  reserved \"email\";\n  string name = 1;\n}\n"}
    },
    "PACKAGE_DEFINED" => {
      bad: {"user.proto" => "syntax = \"proto3\";\n\nmessage User {}\n"},
      good: clean
    },
    "IMPORT_NO_PUBLIC" => {
      bad: {
        "acme/users/v1/user.proto" => "syntax = \"proto3\";\npackage acme.users.v1;\nimport public \"google/protobuf/timestamp.proto\";\n"
      },
      good: clean
    },
    "IMPORT_NO_WEAK" => {
      bad: {
        "acme/users/v1/user.proto" => "syntax = \"proto3\";\npackage acme.users.v1;\nimport weak \"google/protobuf/timestamp.proto\";\n"
      },
      good: clean
    },
    "IMPORT_USED" => {
      bad: {
        "acme/users/v1/user.proto" => "syntax = \"proto3\";\npackage acme.users.v1;\n\nimport \"google/protobuf/timestamp.proto\";\n\nmessage User {}\n"
      },
      good: {
        "acme/users/v1/user.proto" => "syntax = \"proto3\";\npackage acme.users.v1;\nimport \"google/protobuf/timestamp.proto\";\nmessage User {\n  google.protobuf.Timestamp at = 1;\n}\n"
      }
    },
    "SYNTAX_SPECIFIED" => {
      bad: {"acme/users/v1/user.proto" => "package acme.users.v1;\n\nmessage User {\n  optional string name = 1;\n}\n"},
      good: clean
    },
    "FILE_LOWER_SNAKE_CASE" => {
      bad: {"acme/users/v1/UserProfile.proto" => "syntax = \"proto3\";\npackage acme.users.v1;\n"},
      good: clean("acme/users/v1/user_profile.proto")
    },
    "PACKAGE_LOWER_SNAKE_CASE" => {
      bad: {"Acme/Users/user.proto" => "syntax = \"proto3\";\npackage Acme.Users;\n"},
      good: clean
    },
    "MESSAGE_PASCAL_CASE" => {
      bad: {"acme/users/v1/user.proto" => "syntax = \"proto3\";\npackage acme.users.v1;\nmessage user_profile {}\n"},
      good: clean
    },
    "FIELD_LOWER_SNAKE_CASE" => {
      bad: {"acme/users/v1/user.proto" => <<~PROTO},
        syntax = "proto3";
        package acme.users.v1;
        message User {
          string firstName = 1;
          string LastName = 2;
        }
      PROTO
      good: clean
    },
    "ONEOF_LOWER_SNAKE_CASE" => {
      bad: {"acme/users/v1/user.proto" => <<~PROTO},
        syntax = "proto3";
        package acme.users.v1;
        message Payment {
          oneof PaymentMethod {
            string card = 1;
            string iban = 2;
          }
        }
      PROTO
      good: {"acme/users/v1/user.proto" => "syntax = \"proto3\";\npackage acme.users.v1;\nmessage Payment {\n  oneof method {\n    string card = 1;\n  }\n  optional string note = 2;\n}\n"}
    },
    "ENUM_PASCAL_CASE" => {
      bad: {"acme/users/v1/user.proto" => "syntax = \"proto3\";\npackage acme.users.v1;\nenum order_status {\n  ORDER_STATUS_UNSPECIFIED = 0;\n}\n"},
      good: {"acme/users/v1/user.proto" => "syntax = \"proto3\";\npackage acme.users.v1;\nenum OrderStatus {\n  ORDER_STATUS_UNSPECIFIED = 0;\n}\n"}
    },
    "ENUM_VALUE_UPPER_SNAKE_CASE" => {
      bad: {"acme/users/v1/color.proto" => "syntax = \"proto3\";\npackage acme.users.v1;\nenum Color {\n  COLOR_UNSPECIFIED = 0;\n  color_red = 1;\n}\n"},
      good: {"acme/users/v1/color.proto" => "syntax = \"proto3\";\npackage acme.users.v1;\nenum Color {\n  COLOR_UNSPECIFIED = 0;\n  COLOR_RED = 1;\n}\n"}
    },
    "ENUM_VALUE_PREFIX" => {
      bad: {"acme/users/v1/color.proto" => <<~PROTO},
        syntax = "proto3";
        package acme.users.v1;
        enum TrafficLight {
          TRAFFIC_LIGHT_UNSPECIFIED = 0;
          RED = 1;
        }
      PROTO
      good: {"acme/users/v1/color.proto" => "syntax = \"proto3\";\npackage acme.users.v1;\nenum TrafficLight {\n  TRAFFIC_LIGHT_UNSPECIFIED = 0;\n  TRAFFIC_LIGHT_RED = 1;\n}\n"}
    },
    "SERVICE_PASCAL_CASE" => {
      bad: {"acme/users/v1/api.proto" => "syntax = \"proto3\";\npackage acme.users.v1;\nservice user_service {}\n"},
      good: {"acme/users/v1/api.proto" => "syntax = \"proto3\";\npackage acme.users.v1;\nservice UserService {}\n"}
    },
    "SERVICE_SUFFIX" => {
      bad: {"acme/users/v1/api.proto" => "syntax = \"proto3\";\npackage acme.users.v1;\nservice Users {}\n"},
      good: {"acme/users/v1/api.proto" => "syntax = \"proto3\";\npackage acme.users.v1;\nservice UsersService {}\n"}
    },
    "RPC_PASCAL_CASE" => {
      bad: {"acme/users/v1/api.proto" => <<~PROTO},
        syntax = "proto3";
        package acme.users.v1;
        message GetUserRequest {}
        message GetUserResponse {}
        service UserService {
          rpc get_user(GetUserRequest) returns (GetUserResponse);
        }
      PROTO
      good: {"acme/users/v1/api.proto" => <<~PROTO}
        syntax = "proto3";
        package acme.users.v1;
        message GetUserRequest {}
        message GetUserResponse {}
        service UserService {
          rpc GetUser(GetUserRequest) returns (GetUserResponse);
        }
      PROTO
    },
    "RPC_REQUEST_STANDARD_NAME" => {
      bad: {"acme/users/v1/api.proto" => <<~PROTO},
        syntax = "proto3";
        package acme.users.v1;
        message UserId {}
        message GetUserResponse {}
        service UserService {
          rpc GetUser(UserId) returns (GetUserResponse);
        }
      PROTO
      good: {"acme/users/v1/api.proto" => <<~PROTO}
        syntax = "proto3";
        package acme.users.v1;
        message UserServiceGetUserRequest {}
        message GetUserResponse {}
        service UserService {
          rpc GetUser(UserServiceGetUserRequest) returns (GetUserResponse);
        }
      PROTO
    },
    "RPC_RESPONSE_STANDARD_NAME" => {
      bad: {"acme/users/v1/api.proto" => <<~PROTO},
        syntax = "proto3";
        package acme.users.v1;
        message GetUserRequest {}
        message User {}
        service UserService {
          rpc GetUser(GetUserRequest) returns (User);
        }
      PROTO
      good: {"acme/users/v1/api.proto" => <<~PROTO}
        syntax = "proto3";
        package acme.users.v1;
        message GetUserRequest {}
        message GetUserResponse {}
        service UserService {
          rpc GetUser(GetUserRequest) returns (GetUserResponse);
        }
      PROTO
    },
    "RPC_REQUEST_RESPONSE_UNIQUE" => {
      bad: {"acme/users/v1/api.proto" => <<~PROTO},
        syntax = "proto3";
        package acme.users.v1;
        message UserRequest {}
        message GetUserResponse {}
        message DeleteUserResponse {}
        service UserService {
          rpc GetUser(UserRequest) returns (GetUserResponse);
          rpc DeleteUser(UserRequest) returns (DeleteUserResponse);
        }
      PROTO
      good: {"acme/users/v1/api.proto" => <<~PROTO}
        syntax = "proto3";
        package acme.users.v1;
        message GetUserRequest {}
        message GetUserResponse {}
        service UserService {
          rpc GetUser(GetUserRequest) returns (GetUserResponse);
        }
      PROTO
    },
    "PACKAGE_DIRECTORY_MATCH" => {
      bad: {"acme/user.proto" => "syntax = \"proto3\";\npackage acme.users.v1;\n"},
      good: clean
    },
    "PACKAGE_SAME_DIRECTORY" => {
      bad: {
        "acme/a.proto" => "syntax = \"proto3\";\npackage acme;\n",
        "acme/b.proto" => "syntax = \"proto3\";\npackage acme.other;\n"
      },
      good: {
        "acme/a.proto" => "syntax = \"proto3\";\npackage acme;\n",
        "acme/b.proto" => "syntax = \"proto3\";\npackage acme;\n"
      }
    },
    "NO_DEPRECATED_FEATURES" => {
      bad: {"acme/users/v1/user.proto" => <<~PROTO},
        edition = "2023";
        package acme.users.v1;
        import "google/protobuf/cpp_features.proto";
        option features.(pb.cpp).legacy_closed_enum = true;
      PROTO
      good: clean
    },
    "PACKAGE_VERSION_SUFFIX" => {
      bad: {"acme/users/user.proto" => "syntax = \"proto3\";\npackage acme.users;\n"},
      good: clean
    },
    "FIELD_NUMBERS_HOT_RANGE" => {
      bad: {"acme/users/v1/event.proto" => <<~PROTO},
        syntax = "proto3";
        package acme.users.v1;
        message Event {
          string id = 1;
          string old = 2 [deprecated = true];
          string payload = 16;
        }
      PROTO
      good: {"acme/users/v1/event.proto" => "syntax = \"proto3\";\npackage acme.users.v1;\nmessage Event {\n  string id = 1;\n  string payload = 2;\n}\n"}
    },
    "COMMENT_MESSAGE" => {
      bad: {"acme/users/v1/user.proto" => "syntax = \"proto3\";\npackage acme.users.v1;\n\nmessage User {}\n"},
      good: clean
    },
    "COMMENT_FIELD" => {
      bad: {"acme/users/v1/user.proto" => <<~PROTO},
        syntax = "proto3";
        package acme.users.v1;
        // A person.
        message User {
          string id = 1; // stable id
          string name = 2;
          map<string, string> labels = 3;
        }
      PROTO
      good: clean
    },
    "COMMENT_ENUM" => {
      bad: {"acme/users/v1/color.proto" => "syntax = \"proto3\";\npackage acme.users.v1;\n\nenum Color {\n  COLOR_UNSPECIFIED = 0;\n}\n"},
      good: {"acme/users/v1/color.proto" => "syntax = \"proto3\";\npackage acme.users.v1;\n\n// Paint.\nenum Color {\n  COLOR_UNSPECIFIED = 0;\n}\n"}
    },
    "COMMENT_ENUM_VALUE" => {
      bad: {"acme/users/v1/color.proto" => "syntax = \"proto3\";\npackage acme.users.v1;\nenum Color {\n  // Not set.\n  COLOR_UNSPECIFIED = 0;\n  COLOR_RED = 1;\n}\n"},
      good: {"acme/users/v1/color.proto" => "syntax = \"proto3\";\npackage acme.users.v1;\nenum Color {\n  COLOR_UNSPECIFIED = 0; // Not set.\n}\n"}
    },
    "COMMENT_SERVICE" => {
      bad: {"acme/users/v1/api.proto" => "syntax = \"proto3\";\npackage acme.users.v1;\n\nservice UserService {}\n"},
      good: {"acme/users/v1/api.proto" => "syntax = \"proto3\";\npackage acme.users.v1;\n\n// Accounts.\nservice UserService {}\n"}
    },
    "COMMENT_RPC" => {
      bad: {"acme/users/v1/api.proto" => <<~PROTO},
        syntax = "proto3";
        package acme.users.v1;
        message GetUserRequest {}
        message GetUserResponse {}
        service UserService {
          rpc GetUser(GetUserRequest) returns (GetUserResponse);
        }
      PROTO
      good: {"acme/users/v1/api.proto" => <<~PROTO}
        syntax = "proto3";
        package acme.users.v1;
        message GetUserRequest {}
        message GetUserResponse {}
        service UserService {
          // Looks one user up by id.
          rpc GetUser(GetUserRequest) returns (GetUserResponse);
        }
      PROTO
    },
    "EDITION_RECOMMENDED" => {
      bad: {"acme/users/v1/user.proto" => "syntax = \"proto3\";\npackage acme.users.v1;\n"},
      good: clean
    }
  }.freeze

  # Runs one rule over a case's files
  # @return [Array<Protostar::Compiler::Diagnostic>] the rule's findings
  def self.findings(id, files)
    runner = Protostar::Lint::Runner.new(include_paths: [], rules: [id])
    runner.run(files.keys, sources: files).diagnostics.select { |d| d.rule == id }
  end

  # The rendered text and JSON lines of the findings, as the goldens hold them
  def self.outputs(id, files)
    found = findings(id, files)
    renderer = Protostar::Diagnostics::Renderer.new(source: ->(d) { files[d.file] })
    text = found.map { |d| renderer.render(d) }.join("\n")
    json = found.map do |d|
      source = Protostar::Diagnostics::Source.new(files[d.file])
      Protostar::Diagnostics::Formats.json(d, source: source) + "\n"
    end.join
    [text, json]
  end
end
