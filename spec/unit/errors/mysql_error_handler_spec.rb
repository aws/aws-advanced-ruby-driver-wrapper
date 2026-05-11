# frozen_string_literal: true

require 'aws_advanced_ruby_wrapper/errors/mysql_error_handler'
require 'aws_advanced_ruby_wrapper/driver_dialects/mysql_driver_dialect'

RSpec.describe AwsAdvancedRubyWrapper::Errors::MysqlErrorHandler do
  let(:driver_dialect) { AwsAdvancedRubyWrapper::DriverDialects::MysqlDriverDialect.new }
  subject(:handler) { described_class.new(driver_dialect) }

  describe '#network_error_by_sql_state?' do
    it 'returns true for 08 prefix states (except 08004)' do
      expect(handler.network_error_by_sql_state?('08001')).to be true
      expect(handler.network_error_by_sql_state?('08S01')).to be true
      expect(handler.network_error_by_sql_state?('08006')).to be true
    end

    it 'returns false for 08004 (server rejected connection)' do
      expect(handler.network_error_by_sql_state?('08004')).to be false
    end

    it 'returns false for non-network states' do
      expect(handler.network_error_by_sql_state?('28000')).to be false
      expect(handler.network_error_by_sql_state?('HY000')).to be false
    end
  end

  describe '#login_error_by_sql_state?' do
    it 'returns true for 28000' do
      expect(handler.login_error_by_sql_state?('28000')).to be true
    end

    it 'returns false for other states' do
      expect(handler.login_error_by_sql_state?('08001')).to be false
      expect(handler.login_error_by_sql_state?('HY000')).to be false
    end
  end

  describe '#read_only_error_by_sql_state?' do
    it 'returns true for HY000 with error code 1290' do
      expect(handler.read_only_error_by_sql_state?('HY000', 1290)).to be true
    end

    it 'returns true for HY000 with error code 1836' do
      expect(handler.read_only_error_by_sql_state?('HY000', 1836)).to be true
    end

    it 'returns false for HY000 with unrecognized error code' do
      expect(handler.read_only_error_by_sql_state?('HY000', 9999)).to be false
    end

    it 'returns false for HY000 with nil error code' do
      expect(handler.read_only_error_by_sql_state?('HY000', nil)).to be false
    end

    it 'returns false for wrong sql_state even with valid error code' do
      expect(handler.read_only_error_by_sql_state?('25006', 1290)).to be false
    end
  end

  describe '#network_error?' do
    it 'detects network error from exception with sql_state' do
      error = build_mysql_error('08S01')
      expect(handler.network_error?(error)).to be true
    end

    it 'returns false for non-network error' do
      error = build_mysql_error('28000')
      expect(handler.network_error?(error)).to be false
    end

    it 'walks the cause chain' do
      cause = build_mysql_error('08001')
      wrapper = build_error_with_cause(cause)
      expect(handler.network_error?(wrapper)).to be true
    end

    it 'returns false when sql_state is nil throughout chain' do
      error = StandardError.new('no sql state')
      expect(handler.network_error?(error)).to be false
    end
  end

  describe '#login_error?' do
    it 'detects login error from exception' do
      error = build_mysql_error('28000')
      expect(handler.login_error?(error)).to be true
    end

    it 'walks the cause chain' do
      cause = build_mysql_error('28000')
      wrapper = build_error_with_cause(cause)
      expect(handler.login_error?(wrapper)).to be true
    end
  end

  describe '#read_only_error?' do
    it 'detects read-only error using sql_state and error_number' do
      error = build_mysql_error('HY000', error_number: 1290)
      expect(handler.read_only_error?(error)).to be true
    end

    it 'returns false when error_number is missing' do
      error = build_mysql_error('HY000')
      expect(handler.read_only_error?(error)).to be false
    end

    it 'walks the cause chain for read-only detection' do
      cause = build_mysql_error('HY000', error_number: 1836)
      wrapper = build_error_with_cause(cause)
      expect(handler.read_only_error?(wrapper)).to be true
    end
  end

  private

  # Build a mock that behaves like Mysql2::Error with sql_state and optional error_number
  def build_mysql_error(sql_state, error_number: nil)
    klass = Class.new(StandardError) do
      attr_reader :sql_state, :error_number

      def initialize(msg, sql_state, error_number)
        super(msg)
        @sql_state = sql_state
        @error_number = error_number
      end
    end
    klass.new('test error', sql_state, error_number)
  end

  def build_error_with_cause(cause)
    begin
      begin
        raise cause
      rescue StandardError
        raise StandardError, 'wrapper error'
      end
    rescue StandardError => e
      return e
    end
  end
end
