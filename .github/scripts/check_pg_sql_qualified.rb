# frozen_string_literal: true

#  Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
#
#  Licensed under the Apache License, Version 2.0 (the "License").
#  You may not use this file except in compliance with the License.
#  You may obtain a copy of the License at
#
#  http://www.apache.org/licenses/LICENSE-2.0
#
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.

# Guards against search_path hijacking in the wrapper's internal PostgreSQL queries.
#
# In PostgreSQL both functions AND operators resolve through search_path. A user-defined object in
# a schema that sits earlier on search_path than pg_catalog can shadow a built-in - e.g. a rogue
# "=" operator or a rogue count() function - and change what the wrapper's topology/role detection
# returns. Internal queries defend against this by schema-qualifying everything: pg_catalog.* for
# built-ins, rds_tools.* for the RDS extension, and the OPERATOR(pg_catalog....) syntax for every
# symbolic operator (=, ~~ i.e. LIKE, <=, -, != and friends), which is the only way to pin an
# operator to a schema.
#
# This is a deterministic lint, not a SQL parser. It enforces three rules:
#
#   1. Every OPERATOR(...) must be OPERATOR(pg_catalog. ...).
#   2. No SENSITIVE_FUNCTION may appear as a bare call foo(...) without a schema qualifier.
#   3. Inside SQL heredoc bodies, no bare symbolic operator may appear - every comparison, pattern,
#      and arithmetic operator must be written as OPERATOR(pg_catalog....).
#
# Rule 3 only scans the text inside <<~SQL ... SQL heredocs, so surrounding Ruby code and the
# "NAME = <<~SQL" assignment line itself are never mistaken for SQL operators. String literals are
# blanked before scanning so symbols inside them (e.g. '%aurora_stat_utils%', 'MASTER_SESSION_ID')
# do not trigger a match.
#
# When you add a new internal query that calls a schema-resolvable function, add that function to
# SENSITIVE_FUNCTIONS so this check continues to protect it.
#
# A SEPARATE check (see the KMS section below) covers the KMS encryption plugin's own metadata SQL.
# That SQL is engine-portable, so instead of writing OPERATOR(pg_catalog....) directly it routes
# every comparison through an interpolated #{eq} helper that expands to OPERATOR(pg_catalog.=) on
# PostgreSQL and plain "=" on MySQL. The KMS check enforces that indirection: no literal comparison
# operator may appear in a KMS query - it must always be #{eq}.

# Only the wrapper's own PostgreSQL dialect SQL is in scope. Application/ActiveRecord SQL passes
# through the wrapper unchanged and is intentionally not governed by this rule.
PG_DIALECT_GLOB = File.join(__dir__, '..', '..', 'lib', 'aws_advanced_ruby_driver_wrapper', 'db_dialects', '*pg*.rb')

KMS_SQL_GLOB = File.join(
  __dir__, '..', '..', 'lib', 'aws_advanced_ruby_driver_wrapper', 'plugins', 'kms_encryption',
  '{key_manager,metadata_manager,key_management_utility,schema_validator}.rb'
)

# Functions that resolve through search_path and must therefore always be schema-qualified in
# internal queries. Keep this list in sync with the SQL in the pg dialect files.
SENSITIVE_FUNCTIONS = %w[
  count now concat
  inet_server_addr inet_server_port pg_is_in_recovery
  aurora_replica_status aurora_db_instance_identifier
  aurora_global_db_status aurora_global_db_instance_status
  get_blue_green_fast_switchover_metadata
  show_topology dbi_resource_id multi_az_db_cluster_source_dbi_resource_id
].freeze

# A function call is "qualified" when a schema and dot immediately precede the name.
QUALIFIER = /(?:pg_catalog|rds_tools)\.\s*/i

# Comparison and pattern-matching operators that resolve through search_path on PostgreSQL. This is
# the single source of truth for that token set: the KMS check scans for exactly these (a literal
# one in a KMS query means a comparison was written without the #{eq} helper), and BARE_OPERATOR
# below builds on it. Longest tokens first so the alternation is greedy (e.g. "<=" before "<",
# "~~*" before "~~").
COMPARISON_OPERATOR = /~~\*|!~~|~~|!~|~|<=|>=|<>|!=|=|<|>/

# A string literal is only scanned as a KMS query when it contains one of these clause keywords.
# Guards against false positives on non-SQL strings (log/error messages, prose) that happen to
# contain an operator character. A real query always carries at least one of these.
SQL_KEYWORD = /\b(?:SELECT|INSERT|UPDATE|DELETE|FROM|WHERE|JOIN|SET|ON|RETURNING)\b/i

# Every symbolic operator that resolves through search_path and so must be wrapped in
# OPERATOR(pg_catalog...) in the dialect heredocs: the comparison/pattern set above plus the
# arithmetic and string-concatenation operators, with guards so "::" casts, "--" comments, and "//"
# are not mistaken for operators. The KMS check deliberately omits the arithmetic/concat operators -
# it only guards comparisons - so it uses COMPARISON_OPERATOR rather than this.
BARE_OPERATOR = %r{
  #{COMPARISON_OPERATOR}    # comparison / pattern-matching operators (shared)
  | \|\|                    # string concatenation
  | (?<![:*])-(?![-:])      # subtraction, but not part of "::", "--" comment, or arrow-like tokens
  | (?<![:])\+              # addition
  | (?<![:/])/(?![/*])      # division, but not "//" or a comment delimiter
}x

# Extracts the bodies of SQL heredocs (<<~SQL / <<-SQL / <<SQL, optionally quoted) with the line
# number on which each body starts. Returns [[body, start_line], ...].
def sql_heredoc_bodies(source)
  bodies = []
  lines = source.lines
  i = 0
  while i < lines.length
    if lines[i] =~ /<<[~-]?['"]?SQL['"]?/
      body_start = i + 1
      body = +''
      j = body_start
      j += 1 while j < lines.length && lines[j] !~ /^\s*SQL\b/
      body << lines[body_start...j].join
      bodies << [body, body_start + 1] # +1 => 1-based line of first body line
      i = j
    end
    i += 1
  end
  bodies
end

# Replaces every single-quoted SQL string literal with an equal-length run of spaces so that any
# operator-looking characters inside a literal cannot trigger a match, while byte offsets (and thus
# reported line/column) are preserved.
def blank_string_literals(sql)
  sql.gsub(/'(?:[^']|'')*'/) { |lit| ' ' * lit.length }
end

# Flags every literal comparison operator in the plugin's own metadata SQL in the given source.
def kms_sql_violations(path, source)
  found = []
  source.each_line.with_index(1) do |line, line_number|
    next if line.lstrip.start_with?('#')

    scannable = kms_scannable_sql(line)
    next if scannable.nil?

    scannable.to_enum(:scan, COMPARISON_OPERATOR).each do
      op_start = Regexp.last_match.begin(0)
      token = Regexp.last_match[0]
      found << "#{path}:#{line_number}:#{op_start + 1}: literal SQL comparison operator '#{token}' " \
               "in a KMS query - route it through the #{eq_example} helper so it is qualified " \
               '(OPERATOR(pg_catalog....)) on PostgreSQL.'
    end
  end
  found
end

# Returns the scannable SQL text of a source line - the string-literal spans with interpolations and
# SET assignments blanked out - or nil when the line holds no SQL string. Offsets are preserved
# (every replacement is an equal-length run of spaces) so reported columns stay accurate.
def kms_scannable_sql(line)
  masked = ' ' * line.length
  line.to_enum(:scan, /"(?:[^"\\]|\\.)*"|'(?:[^'\\]|'')*'/).each do
    span = Regexp.last_match[0]
    start = Regexp.last_match.begin(0)
    masked[start, span.length] = span
  end
  return nil unless masked.match?(/\S/)

  # Only string literals that actually read as SQL are in scope. A plain Ruby string that happens
  # to contain an operator character (a log message, an error string, "a > b" in prose) is not a
  # query, so skip the line unless a SQL clause keyword is present. This keeps the check from
  # false-flagging non-SQL strings in the plugin files while still catching every real query.
  return nil unless masked.match?(SQL_KEYWORD)

  masked = masked.gsub(/["']/, ' ')              # drop the quote characters themselves
  masked = blank_runs(masked, /\#\{[^}]*\}/)     # drop interpolations (#{eq}, #{schema}, ...)
  blank_runs(masked, /\bSET\b.*?(?=\bWHERE\b|\bFROM\b|\bRETURNING\b|\z)/i) # drop SET assignments
end

# Replaces each match of +pattern+ in +text+ with an equal-length run of spaces, preserving offsets.
def blank_runs(text, pattern)
  text.gsub(pattern) { |m| ' ' * m.length }
end

# The #{eq} helper spelled out for violation messages, with the "#" escaped so the interpolation
# marker shows verbatim rather than being interpolated by this script.
def eq_example
  "\#{eq}"
end

violations = []

Dir.glob(PG_DIALECT_GLOB).sort.each do |path|
  source = File.read(path)

  # Rule 1: unqualified OPERATOR(...).
  source.to_enum(:scan, /OPERATOR\(\s*([^)]*)\)/i).each do
    inner = Regexp.last_match(1)
    line = source[0...Regexp.last_match.begin(0)].count("\n") + 1
    unless inner =~ /\Apg_catalog\./i
      violations << "#{path}:#{line}: OPERATOR(#{inner.strip}) is not qualified with pg_catalog."
    end
  end

  # Rule 2: bare calls to sensitive functions.
  SENSITIVE_FUNCTIONS.each do |fn|
    pattern = /(?<!\.)(?<![A-Za-z0-9_])#{Regexp.escape(fn)}\s*\(/i
    source.to_enum(:scan, pattern).each do
      match_start = Regexp.last_match.begin(0)
      preceding = source[0...match_start]
      next if preceding =~ /#{QUALIFIER}\z/

      line_start = (preceding.rindex("\n") || -1) + 1
      current_line = source[line_start..match_start]
      next if current_line.lstrip.start_with?('#')

      line = preceding.count("\n") + 1
      violations << "#{path}:#{line}: unqualified call to '#{fn}(' - prefix with pg_catalog. or rds_tools."
    end
  end

  # Rule 3: bare symbolic operators inside SQL heredoc bodies. Blank out OPERATOR(...) wrappers and
  # string literals first; whatever operator characters remain are unqualified and therefore unsafe.
  sql_heredoc_bodies(source).each do |body, start_line|
    scannable = blank_string_literals(body)
    # Remove the safe, qualified operator wrappers so only bare operators remain.
    scannable = scannable.gsub(/OPERATOR\(\s*pg_catalog\.[^)]*\)/i) { |m| ' ' * m.length }

    scannable.to_enum(:scan, BARE_OPERATOR).each do
      op_start = Regexp.last_match.begin(0)
      token = Regexp.last_match[0]
      line = start_line + body[0...op_start].count("\n")
      violations << "#{path}:#{line}: bare SQL operator '#{token}' - wrap it as OPERATOR(pg_catalog.#{token})."
    end
  end
end

Dir.glob(KMS_SQL_GLOB).each do |path|
  violations.concat(kms_sql_violations(path, File.read(path)))
end

if violations.empty?
  puts 'PostgreSQL dialect and KMS plugin SQL qualification check passed.'
  exit 0
end

warn 'SQL qualification check FAILED:'
violations.sort.each { |v| warn "  #{v}" }
warn ''
warn 'Internal PostgreSQL dialect queries must schema-qualify functions AND operators (pg_catalog.* /'
warn 'rds_tools.*) to prevent search_path hijacking. Fix the query, or if you added a new'
warn 'sensitive function, add it to SENSITIVE_FUNCTIONS in this script.'
warn ''
warn "The KMS encryption plugin's queries must not use a literal SQL comparison operator; every"
warn "comparison has to go through the #{eq_example} helper (SqlRunner#equals_operator) so it becomes"
warn "OPERATOR(pg_catalog....) on PostgreSQL. Replace the literal operator with #{eq_example}, or - for"
warn 'an operator with no helper yet - add one mirroring equals_operator before using it.'
exit 1
