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

module AwsAdvancedRubyDriverWrapper
  module Utils
    module Parser
      # Reads MySQL statement text the way the server's lexer separates code from what is not code:
      # quoted literals and comments. Anything that counts the +?+ placeholders of a statement has to
      # skip both, since a +?+ inside either is not a placeholder, and miscounting one binds a value
      # to the wrong column.
      module MysqlText
        # The quote characters a literal can be wrapped in. A backtick quotes an identifier rather than
        # a value, but is included so a +?+ inside a backtick-quoted name is not miscounted either.
        QUOTES = ["'", '"', '`'].freeze
        # What a block comment that never closes is reported as by {each_code_char}.
        UNCLOSED_COMMENT = '/*'

        module_function

        # Yields every character that is code, along with its index, skipping quoted literals and
        # comments (see {each_segment}).
        #
        # @param comments [Boolean] see {each_segment}
        # @return [String, nil] the quote character, or {UNCLOSED_COMMENT}, still open when the text
        #   ran out; nil when the text ended in code or in a line comment
        def each_code_char(text, comments: true)
          each_segment(text, comments: comments) do |kind, from, to|
            (from...to).each { |index| yield(text[index], index) } if kind == :code
          end
        end

        # The text with every comment replaced by spaces, and its literals left as they are. Length and
        # every offset are unchanged, so a pattern that has to see quoted names, which a comment can
        # sit between, can be matched against it and its offsets used on the original text.
        #
        # What is left is to be read for its literals alone (+comments: false+), not scanned for
        # comments again: blanking +0--/**/?+ leaves +0--    ?+, where the dashes now look like the
        # start of a comment the server never saw.
        def blank_comments(text)
          blanked = text.dup
          each_segment(text) { |kind, from, to| blanked[from...to] = ' ' * (to - from) if kind == :comment }
          blanked
        end

        # Walks the text once, yielding each run of code, quoted literal or comment as its kind and the
        # range of indices it covers. A literal or block comment that never closes runs to the end.
        #
        # Inside a literal a backslash escapes the next character, except inside a backtick, and a
        # doubled quote reads as one closing and one opening quote, which leaves the state right
        # either way. A comment is +/* ... */+, +#+ to the end of the line, or +--+ to the end of the
        # line when whitespace or a control character follows the dashes, as MySQL requires; without
        # it the dashes are two minus signs. A +/*! ... */+ comment is code that MySQL runs, unless it
        # names a server version newer than the one it reaches, so its contents are read as code.
        #
        # @param comments [Boolean] whether to look for comments at all; false for text whose comments
        #   have already been blanked (see {blank_comments}), so that only literals are skipped
        # @yieldparam kind [Symbol] +:code+, +:literal+ or +:comment+
        # @return [String, nil] as {each_code_char}
        def each_segment(text, comments: true)
          index = 0
          code_from = 0

          while index < text.length
            char = text[index]
            if QUOTES.include?(char)
              kind = :literal
              finish = literal_end(text, index)
            elsif comments && block_comment?(text, index)
              kind = :comment
              close = text.index('*/', index + 2)
              finish = close && (close + 2)
            elsif comments && (char == '#' || dash_comment?(text, index))
              kind = :comment
              finish = text.index("\n", index) || text.length
            else
              index += 1
              next
            end

            yield(:code, code_from, index) if code_from < index
            yield(kind, index, finish || text.length)
            return kind == :literal ? char : UNCLOSED_COMMENT if finish.nil?

            index = code_from = finish
          end

          yield(:code, code_from, index) if code_from < index
          nil
        end

        # @return [Integer, nil] the index just past the quote that closes the literal opened at
        #   +start+, or nil when it is never closed
        def literal_end(text, start)
          quote = text[start]
          index = start + 1

          while index < text.length
            char = text[index]
            return index + 1 if char == quote

            index += char == '\\' && quote != '`' ? 2 : 1
          end

          nil
        end

        def block_comment?(text, index)
          text[index, 2] == '/*' && text[index + 2] != '!'
        end

        def dash_comment?(text, index)
          return false unless text[index, 2] == '--'

          following = text[index + 2]
          following.nil? || following.match?(/[\s[:cntrl:]]/)
        end
      end
    end
  end
end
