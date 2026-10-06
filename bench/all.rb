# frozen_string_literal: true

# Every benchmark in bench/, in one process; bench/run.rb runs this once per
# side and YJIT setting
%w[codec view builder definition compiler].each { |name| require_relative "#{name}_bench" }
