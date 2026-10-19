# frozen_string_literal: true

source "https://rubygems.org"

gemspec

# The gem we are replacing, used only as an oracle for cross-checks and for
# regenerating corpus goldens. Never a runtime dependency.
group :oracle, optional: true do
  gem "google-protobuf", "~> 4.31"
end

# Typechecks the generated RBI in test/emitters/rbi_test.rb (BUNDLE_WITH=sorbet).
# The tests skip without it; SORBET=path/to/sorbet works too.
group :sorbet, optional: true do
  gem "sorbet-static"
end

# Checks lib/ against the signatures in sig/ (rake steep); it needs Ruby 3.3
if RUBY_VERSION >= "3.3"
  gem "steep", "~> 2.1", require: false
end
