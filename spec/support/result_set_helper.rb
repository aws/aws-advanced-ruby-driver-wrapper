# frozen_string_literal: true

# A simple result set wrapper that mimics database query results with fields and enumerable rows.
# Used in topology utils specs to avoid stubbing methods on plain arrays.
module ResultSetHelper
  ResultSet = Struct.new(:fields, :rows) do
    include Enumerable

    def each(&block)
      rows.each(&block)
    end

    def first
      rows.first
    end

    def empty?
      rows.empty?
    end

    def size
      rows.size
    end
  end

  def make_result_set(fields, rows)
    ResultSet.new(fields, rows)
  end
end
