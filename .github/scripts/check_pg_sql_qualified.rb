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
# This is a deterministic lint, not a SQL parser. It enforces, over the pg dialect files:
#
#   1. Every OPERATOR(...) must be OPERATOR(pg_catalog. ...).
#   2. Every bare function call foo(...) must be schema-qualified (pg_catalog. / rds_tools.) unless
#      foo is an exempt SQL keyword or SQL-standard construct (SELECT, COALESCE, SUBSTRING, ...).
#      This is fail-CLOSED: a new, unqualified, non-exempt call is flagged by default, so a query
#      that adds e.g. lower(...) fails until it is qualified or the construct is exempted.
#   3. Inside SQL heredoc bodies, no bare symbolic operator may appear - every comparison, pattern,
#      and arithmetic operator must be written as OPERATOR(pg_catalog....).
#   4. Internal SQL in a dialect file must live in a <<~SQL heredoc. A string literal that reads as
#      SQL (carries a SQL clause keyword) outside a SQL heredoc is flagged, because Rules 1-3 only
#      see heredoc bodies - a query written as a plain string would otherwise skip the operator scan.
#
# Rule 3 only scans the text inside <<~SQL ... SQL heredocs, so surrounding Ruby code and the
# "NAME = <<~SQL" assignment line itself are never mistaken for SQL operators. String literals are
# blanked before scanning so symbols inside them (e.g. '%aurora_stat_utils%', 'MASTER_SESSION_ID')
# do not trigger a match.
#
# A SEPARATE check (the KMS/shared section below) covers SQL that is built as ordinary Ruby strings
# and shared across engines: the KMS encryption plugin's metadata SQL and pg_driver_dialect.rb's
# internal queries (foreign_key_query, upsert_clause). That SQL is engine-portable, so instead of
# writing OPERATOR(pg_catalog....) directly it routes every comparison through an interpolated
# #{eq} helper that expands to OPERATOR(pg_catalog.=) on PostgreSQL and plain "=" on MySQL. The
# shared check enforces that indirection: no literal comparison operator may appear in such a query
# - it must always be #{eq}.
#
# KNOWN OMISSIONS (deliberately not covered; lower risk because pg_catalog is searched first unless
# search_path explicitly places a schema ahead of it, but both DO resolve through search_path):
#   - Unqualified relation references (e.g. FROM pg_settings).
#   - Cast target types (e.g. 'x'::regproc) - qualified today ('x'::pg_catalog.regproc) by
#     convention, but not enforced.

# Only the wrapper's own PostgreSQL dialect SQL is in scope. Application/ActiveRecord SQL passes
# through the wrapper unchanged and is intentionally not governed by this rule.
PG_DIALECT_GLOB = File.join(__dir__, '..', '..', 'lib', 'aws_advanced_ruby_driver_wrapper', 'db_dialects', '*pg*.rb')

KMS_SQL_GLOB = File.join(
  __dir__, '..', '..', 'lib', 'aws_advanced_ruby_driver_wrapper', 'plugins', 'kms_encryption', '*.rb'
)
PG_DRIVER_DIALECT_FILE = File.join(
  __dir__, '..', '..', 'lib', 'aws_advanced_ruby_driver_wrapper', 'driver_dialects', 'pg_driver_dialect.rb'
)

# A function call is "qualified" when a schema and dot immediately precede the name.
QUALIFIER = /(?:pg_catalog|rds_tools)\.\s*/i

# Keywords and SQL-standard constructs that legitimately appear as `WORD(` without a schema
# qualifier and do NOT resolve through search_path, so Rule 2 must not flag them.
EXEMPT_CALL_WORDS = %w[
  operator
  select from where and or not in like between is null as on join using
  case when then else end exists distinct limit offset order group by having
  cast coalesce nullif greatest least substring position extract overlay trim
  values set returning asc desc union all any some true false
].freeze

# A function/keyword call token: `word(` not immediately preceded by `.` (which would make it
# qualified) or by another identifier character. Case-insensitive; the captured word is checked
# against EXEMPT_CALL_WORDS.
CALL_TOKEN = /(?<![A-Za-z0-9_.])([A-Za-z_][A-Za-z0-9_]*)\s*\(/

# Comparison and pattern-matching operators that resolve through search_path on PostgreSQL. This is
# the single source of truth for that token set: the KMS/shared check scans for exactly these (a
# literal one in such a query means a comparison was written without the #{eq} helper), and
# BARE_OPERATOR below builds on it. Longest tokens first so the alternation is greedy (e.g. "<="
# before "<", "~~*" before "~~").
COMPARISON_OPERATOR = /~~\*|!~~|~~|!~|~|<=|>=|<>|!=|=|<|>/

# A string literal is only scanned as a query when it contains one of these clause keywords. Guards
# against false positives on non-SQL strings (log/error messages, prose) that happen to contain an
# operator character. A real query always carries at least one of these.
SQL_KEYWORD = /\b(?:SELECT|INSERT|UPDATE|DELETE|FROM|WHERE|JOIN|SET|ON|RETURNING)\b/i

# Every symbolic operator that resolves through search_path and so must be wrapped in
# OPERATOR(pg_catalog...) in the dialect heredocs: the comparison/pattern set above plus the
# arithmetic and string-concatenation operators, with guards so "::" casts, "--" comments, and "//"
# are not mistaken for operators. The KMS/shared check deliberately omits the arithmetic/concat
# operators - it only guards comparisons - so it uses COMPARISON_OPERATOR rather than this.
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

# True for a source line that is inside a <<~SQL heredoc body. Used by Rule 4 to tell SQL that lives
# in a heredoc (allowed) from SQL written as a plain string (flagged).
def heredoc_body_line_set(source)
  lines = source.lines
  in_body = {}
  i = 0
  while i < lines.length
    if lines[i] =~ /<<[~-]?['"]?SQL['"]?/
      j = i + 1
      while j < lines.length && lines[j] !~ /^\s*SQL\b/
        in_body[j + 1] = true # 1-based
        j += 1
      end
      i = j
    end
    i += 1
  end
  in_body
end

# Replaces every single-quoted SQL string literal with an equal-length run of spaces so that any
# operator-looking characters inside a literal cannot trigger a match, while byte offsets (and thus
# reported line/column) are preserved.
def blank_string_literals(sql)
  sql.gsub(/'(?:[^']|'')*'/) { |lit| ' ' * lit.length }
end

# Rule 2 (dialect files): every bare function/keyword call in a SQL heredoc must be schema-qualified
# unless its name is exempt. Fail-closed: an unqualified, non-exempt `word(` is a violation.
def unqualified_call_violations(path, source)
  found = []
  sql_heredoc_bodies(source).each do |body, start_line|
    scannable = blank_string_literals(body)
    scannable.to_enum(:scan, CALL_TOKEN).each do
      word = Regexp.last_match(1)
      next if EXEMPT_CALL_WORDS.include?(word.downcase)

      match_start = Regexp.last_match.begin(0)
      line = start_line + scannable[0...match_start].count("\n")
      found << "#{path}:#{line}: unqualified call to '#{word}(' - prefix with pg_catalog. or " \
               "rds_tools., or add '#{word.downcase}' to EXEMPT_CALL_WORDS if it is SQL-standard syntax."
    end
  end
  found
end

# Rule 4 (dialect files): internal SQL must be written in a <<~SQL heredoc. A string literal that
# reads as SQL (carries a clause keyword) outside a heredoc body is flagged - Rules 1-3 never scan
# it, so a bare operator there would slip through.
def sql_outside_heredoc_violations(path, source)
  found = []
  in_body = heredoc_body_line_set(source)
  source.each_line.with_index(1) do |line, line_number|
    next if in_body[line_number]
    next if line.lstrip.start_with?('#')
    next if line =~ /<<[~-]?['"]?SQL['"]?/ # the heredoc-opening assignment line itself

    line.to_enum(:scan, /"(?:[^"\\]|\\.)*"|'(?:[^'\\]|'')*'/).each do
      literal = Regexp.last_match[0]
      next unless literal.match?(SQL_KEYWORD)

      col = Regexp.last_match.begin(0) + 1
      found << "#{path}:#{line_number}:#{col}: SQL written as a plain string literal - move it into " \
               'a <<~SQL heredoc so the operator/function qualification checks (Rules 1-3) cover it.'
    end
  end
  found
end

# Flags every literal comparison operator in engine-portable / shared SQL (KMS plugin + pg driver
# dialect). Queries are reassembled from adjacent string literals first (logical_sql_blocks) so the
# SQL_KEYWORD gate is applied to the whole query, not to one wrapped continuation line - this is why
# a continuation line like "AND col = ?" is still scanned even though it has no gate keyword of its
# own.
def shared_sql_violations(path, source)
  found = []
  lines = source.lines
  logical_sql_blocks(source).each do |line_numbers|
    first = line_numbers.first
    last = line_numbers.last
    block = lines[(first - 1)..(last - 1)].join
    scannable = block_scannable_operators(block)

    scannable.to_enum(:scan, COMPARISON_OPERATOR).each do
      op_start = Regexp.last_match.begin(0)
      token = Regexp.last_match[0]
      before = scannable[0...op_start]
      line_number = first + before.count("\n")
      col = op_start - (before.rindex("\n") || -1)
      found << "#{path}:#{line_number}:#{col}: literal SQL comparison operator '#{token}' " \
               "in an engine-portable query - route it through the #{eq_example} helper so it is " \
               'qualified (OPERATOR(pg_catalog....)) on PostgreSQL.'
    end
  end
  found
end

# Groups runs of adjacent source lines whose string literals together form one logical SQL query,
# then keeps only the groups whose combined literal text reads as SQL (SQL_KEYWORD appears somewhere
# in the group). Returns [[line_number, ...], ...]. A "SQL line" is one that holds a string literal;
# a run is broken by a blank line, a comment-only line, or a line with no string literal. This lets
# a continuation clause (AND/OR/ON ...) be gated by a keyword that appears on an earlier line of the
# same query rather than being skipped for lacking one of its own.
def logical_sql_blocks(source)
  blocks = []
  current = []
  current_text = +''

  flush = lambda do
    blocks << current.dup if current.any? && current_text.match?(SQL_KEYWORD)
    current = []
    current_text = +''
  end

  source.each_line.with_index(1) do |line, line_number|
    stripped = line.lstrip
    literals = string_literal_contents(line)
    if stripped.start_with?('#') || literals.empty?
      flush.call
      next
    end
    current << line_number
    current_text << ' ' << literals.join(' ')
  end
  flush.call
  blocks
end

# The concatenated contents of every string literal on a line (quotes dropped), used only to decide
# whether a run of lines reads as SQL. Interpolations are left in place; they contain no bare
# comparison operator (the whole point of #{eq}) so they do not affect the keyword gate.
def string_literal_contents(line)
  line.scan(/"((?:[^"\\]|\\.)*)"|'((?:[^'\\]|'')*)'/).map { |dq, sq| dq || sq }
end

# Returns the scannable text of a reassembled SQL block for the comparison-operator scan: outside
# string literals is blanked (Ruby code, operators like the `\` line-continuation, `.join`), inside
# string literals the text is kept but quotes, interpolations, and SET assignments are blanked.
# Every replacement is an equal-length run of spaces (newlines preserved) so reported line/column
# stay accurate. Operating over the whole block - not per line - lets a SET assignment be
# recognised even when "SET" and the "=" sit on different fragments.
def block_scannable_operators(block)
  masked = block.gsub(/[^\n]/, ' ')
  # Reveal only the contents of string literals (keep newlines inside blanked spans intact).
  block.to_enum(:scan, /"(?:[^"\\]|\\.)*"|'(?:[^'\\]|'')*'/).each do
    span = Regexp.last_match[0]
    start = Regexp.last_match.begin(0)
    masked[start, span.length] = span
  end
  masked = masked.gsub(/["']/, ' ')                 # drop the quote characters themselves
  masked = blank_runs(masked, /\#\{[^}]*\}/)        # drop interpolations (#{eq}, #{schema}, ...)
  # Drop SET assignments across the whole block (DOTALL so a wrapped SET clause is covered).
  masked = blank_runs(masked, /\bSET\b.*?(?=\bWHERE\b|\bFROM\b|\bRETURNING\b|\z)/im)
  # Drop ON CONFLICT ... DO UPDATE upsert assignments. These assignment fragments ("col = EXCLUDED.
  # col") are often built separately and concatenated AFTER the SET keyword, so the SET blanking
  # above cannot reach them; the "= EXCLUDED." shape is unambiguously an assignment target (never a
  # WHERE comparison), so blanking its "=" is safe and does not open a hole in the comparison scan.
  blank_runs(masked, /=\s*EXCLUDED\./i)
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

# Scans a single pg dialect file for Rules 1-4.
def dialect_violations(path, source)
  found = []

  # Rule 1: unqualified OPERATOR(...).
  source.to_enum(:scan, /OPERATOR\(\s*([^)]*)\)/i).each do
    inner = Regexp.last_match(1)
    line = source[0...Regexp.last_match.begin(0)].count("\n") + 1
    unless inner =~ /\Apg_catalog\./i
      found << "#{path}:#{line}: OPERATOR(#{inner.strip}) is not qualified with pg_catalog."
    end
  end

  # Rule 2: bare (unqualified, non-exempt) function/keyword calls.
  found.concat(unqualified_call_violations(path, source))

  # Rule 3: bare symbolic operators inside SQL heredoc bodies. Blank out OPERATOR(...) wrappers and
  # string literals first; whatever operator characters remain are unqualified and therefore unsafe.
  sql_heredoc_bodies(source).each do |body, start_line|
    scannable = blank_string_literals(body)
    scannable = scannable.gsub(/OPERATOR\(\s*pg_catalog\.[^)]*\)/i) { |m| ' ' * m.length }

    scannable.to_enum(:scan, BARE_OPERATOR).each do
      op_start = Regexp.last_match.begin(0)
      token = Regexp.last_match[0]
      line = start_line + body[0...op_start].count("\n")
      found << "#{path}:#{line}: bare SQL operator '#{token}' - wrap it as OPERATOR(pg_catalog.#{token})."
    end
  end

  # Rule 4: SQL written as a plain string literal instead of a heredoc.
  found.concat(sql_outside_heredoc_violations(path, source))

  found
end

# Runs the full lint over the real tree. Returns the list of violation strings.
def run_lint
  violations = []

  dialect_files = Dir.glob(PG_DIALECT_GLOB).sort
  abort "No files matched #{PG_DIALECT_GLOB} - the pg dialect sources moved or were renamed." if dialect_files.empty?

  shared_files = Dir.glob(KMS_SQL_GLOB).sort
  shared_files << PG_DRIVER_DIALECT_FILE if File.file?(PG_DRIVER_DIALECT_FILE)
  abort "No files matched #{KMS_SQL_GLOB} - the KMS plugin sources moved or were renamed." if shared_files.empty?

  dialect_files.each { |path| violations.concat(dialect_violations(path, File.read(path))) }
  shared_files.each { |path| violations.concat(shared_sql_violations(path, File.read(path))) }

  violations
end

# ---------------------------------------------------------------------------------------------
# Self-test: proves each rule catches a known-bad snippet and passes a known-good one, so a future
# change cannot silently neuter the lint while CI stays green. Run with `--selftest`.
# ---------------------------------------------------------------------------------------------
SELFTEST_CASES = [
  # [label, scanner, source, expect_violation?]
  ['Rule 1: unqualified OPERATOR',
   :dialect,
   "Q = <<~SQL\n  SELECT 1 WHERE a OPERATOR(=) b\nSQL\n", true],
  ['Rule 1: qualified OPERATOR is clean',
   :dialect,
   "Q = <<~SQL\n  SELECT 1 WHERE a OPERATOR(pg_catalog.=) b\nSQL\n", false],
  ['Rule 2: unqualified function call (lower)',
   :dialect,
   "Q = <<~SQL\n  SELECT lower(name) FROM pg_catalog.pg_settings\nSQL\n", true],
  ['Rule 2: qualified function call is clean',
   :dialect,
   "Q = <<~SQL\n  SELECT pg_catalog.lower(name) FROM pg_catalog.pg_settings\nSQL\n", false],
  ['Rule 2: SQL-standard SUBSTRING/POSITION are exempt',
   :dialect,
   "Q = <<~SQL\n  SELECT SUBSTRING(x FROM 0 FOR POSITION('.' IN x))\nSQL\n", false],
  ['Rule 3: bare operator in heredoc',
   :dialect,
   "Q = <<~SQL\n  SELECT 1 WHERE a = b\nSQL\n", true],
  ['Rule 4: SQL as a plain string (no heredoc)',
   :dialect,
   "Q = \"SELECT col FROM t WHERE a OPERATOR(pg_catalog.=) b\"\n", true],
  ['Shared: literal operator on a continuation line with no keyword of its own',
   :shared,
   "def q\n  'SELECT 1 FROM t ' \\\n  \"WHERE a #{'#'}{eq} ? AND b = ?\"\nend\n", true],
  ['Shared: #{eq} on every comparison is clean',
   :shared,
   "def q\n  'SELECT 1 FROM t ' \\\n  \"WHERE a #{'#'}{eq} ? AND b #{'#'}{eq} ?\"\nend\n", false],
  ['Shared: non-SQL prose string with an operator is ignored',
   :shared,
   "MSG = 'value must be > zero'\n", false],
  ['Shared: ON CONFLICT upsert assignment (col = EXCLUDED.col) is not a comparison',
   :shared,
   "def q\n  a = cols.map { |c| \"#{'#'}{c} = EXCLUDED.#{'#'}{c}\" }.join(', ')\n" \
   "  \"INSERT INTO t VALUES (?) ON CONFLICT (id) DO UPDATE SET #{'#'}{a}\"\nend\n", false],
  ['Shared: a real WHERE comparison is still caught alongside an upsert assignment',
   :shared,
   "def q\n  a = cols.map { |c| \"#{'#'}{c} = EXCLUDED.#{'#'}{c}\" }.join(', ')\n" \
   "  \"UPDATE t SET #{'#'}{a} WHERE id = ?\"\nend\n", true]
].freeze

def run_selftest
  failures = []
  SELFTEST_CASES.each do |label, scanner, source, expect_violation|
    found =
      case scanner
      when :dialect then dialect_violations('selftest', source)
      when :shared then shared_sql_violations('selftest', source)
      end
    got = !found.empty?
    next if got == expect_violation

    failures << if expect_violation
                  "EXPECTED a violation but got none: #{label}"
                else
                  "EXPECTED no violation but got #{found.size}: #{label}\n    #{found.join("\n    ")}"
                end
  end

  if failures.empty?
    puts "Self-test passed (#{SELFTEST_CASES.size} cases)."
    exit 0
  end

  warn 'Self-test FAILED - the lint no longer behaves as documented:'
  failures.each { |f| warn "  #{f}" }
  exit 1
end

run_selftest if ARGV.include?('--selftest')

violations = run_lint

if violations.empty?
  puts 'PostgreSQL dialect and shared (KMS / pg driver dialect) SQL qualification check passed.'
  exit 0
end

warn 'SQL qualification check FAILED:'
violations.sort.each { |v| warn "  #{v}" }
warn ''
warn 'Internal PostgreSQL dialect queries must schema-qualify functions AND operators (pg_catalog.* /'
warn 'rds_tools.*) to prevent search_path hijacking, and must live in a <<~SQL heredoc. Fix the query,'
warn 'or if you added SQL-standard syntax that is wrongly flagged, add its keyword to EXEMPT_CALL_WORDS'
warn 'in this script.'
warn ''
warn 'Engine-portable queries (KMS encryption plugin, pg driver dialect) must not use a literal SQL'
warn "comparison operator; every comparison has to go through the #{eq_example} helper so it becomes"
warn "OPERATOR(pg_catalog....) on PostgreSQL. Replace the literal operator with #{eq_example}, or - for"
warn 'an operator with no helper yet - add one mirroring equals_operator before using it.'
exit 1
