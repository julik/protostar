# frozen_string_literal: true

source "https://rubygems.org"

gemspec

# The gem we are replacing, used only as an oracle for cross-checks and for
# regenerating corpus goldens. Never a runtime dependency.
group :oracle, optional: true do
  gem "google-protobuf", "~> 4.31"
end
