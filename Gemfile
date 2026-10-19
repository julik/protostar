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
