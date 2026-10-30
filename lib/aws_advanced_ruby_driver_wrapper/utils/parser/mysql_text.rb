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

        # The server version from which MySQL reads a six-digit version in a +/*!+ comment.
        SIX_DIGIT_VERSIONS_FROM = 80_100

        module_function

        # Yields every character that is code, along with its index, skipping quoted literals and
        # comments (see {each_segment}).
        #
        # @param server_version [Integer, nil] see {each_segment}
        # @param comments [Boolean] see {each_segment}
        # @return [String, nil] the quote character, or {UNCLOSED_COMMENT}, still open when the text
        #   ran out; nil when the text ended in code or in a line comment
        def each_code_char(text, server_version: nil, comments: true)
          each_segment(text, server_version: server_version, comments: comments) do |kind, from, to|
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
        #
        # @param server_version [Integer, nil] see {each_segment}
        def blank_comments(text, server_version: nil)
          blanked = text.dup
          each_segment(text, server_version: server_version) do |kind, from, to|
            blanked[from...to] = ' ' * (to - from) if kind == :comment
          end
          blanked
        end

        # Walks the text once, yielding each run of code, quoted literal or comment as its kind and the
        # range of indices it covers. A literal or block comment that never closes runs to the end.
        #
        # Inside a literal a backslash escapes the next character, except inside a backtick, and a
        # doubled quote reads as one closing and one opening quote, which leaves the state right
        # either way. A comment is +/* ... */+, +#+ to the end of the line, or +--+ to the end of the
        # line when whitespace or a control character follows the dashes, as MySQL requires; without
        # it the dashes are two minus signs.
        #
        # A +/*! ... */+ comment holds code that MySQL runs, so only its opening +/*!+ and its closing
        # +*/+ are comment and what is between them is read as code. When the +!+ is followed by a
        # version, +/*!80023 ... */+, MySQL runs the code only on a server of that version or later,
        # and on an older one the whole of it is a comment. Which of the two it is depends on the
        # server the statement is sent to, so the comment is read as code when that is not known.
        #
        # @param server_version [Integer, nil] the version of the server the statement is sent to, as
        #   MySQL numbers it (8.0.39 is 80039), or nil when it is not known
        # @param comments [Boolean] whether to look for comments at all; false for text whose comments
        #   have already been blanked (see {blank_comments}), so that only literals are skipped
        # @yieldparam kind [Symbol] +:code+, +:literal+ or +:comment+
        # @return [String, nil] as {each_code_char}
        def each_segment(text, server_version: nil, comments: true)
          index = 0
          code_from = 0
          executable_open = false

          while index < text.length
            kind, finish = if comments
                             segment_at(text, index, server_version, executable_open)
                           elsif QUOTES.include?(text[index])
                             [:literal, literal_end(text, index)]
                           end
            if kind.nil?
              index += 1
              next
            end

            case kind
            when :executable_open then executable_open = true
            when :executable_close then executable_open = false
            end
            yield(:code, code_from, index) if code_from < index
            yield(kind == :literal ? :literal : :comment, index, finish || text.length)
            return kind == :literal ? text[index] : UNCLOSED_COMMENT if finish.nil?

            index = code_from = finish
          end

          yield(:code, code_from, index) if code_from < index
          executable_open ? UNCLOSED_COMMENT : nil
        end

        # What starts at +index+, if it is not code.
        #
        # @return [Array(Symbol, Integer), nil] its kind and the index just past it, which is nil when it
        #   never ends; nil when the character is code
        def segment_at(text, index, server_version, executable_open)
          char = text[index]
          if QUOTES.include?(char)
            [:literal, literal_end(text, index)]
          elsif text[index, 3] == '/*!'
            executable_comment(text, index, server_version)
          elsif executable_open && text[index, 2] == '*/'
            [:executable_close, index + 2]
          elsif text[index, 2] == '/*'
            close = text.index('*/', index + 2)
            [:comment, close && (close + 2)]
          elsif char == '#' || dash_comment?(text, index)
            [:comment, text.index("\n", index) || text.length]
          end
        end

        # A +/*!+ comment: its opener and version when MySQL runs what it holds, or the whole of it when
        # the version it names is newer than the server's.
        def executable_comment(text, index, server_version)
          version, digits = comment_version(text, index + 3, server_version)
          return [:executable_open, index + 3 + digits] unless version && server_version && version > server_version

          [:comment, skipped_comment_end(text, index + 3 + digits)]
        end

        # The version a +/*!+ comment names, read as MySQL reads it: six digits followed by whitespace
        # on a server that takes six, otherwise five digits, and no version at all with fewer. The end
        # of the comment right after six digits is not whitespace, so MySQL reads five of them then.
        #
        # @return [Array(Integer, Integer), Array(nil, Integer)] the version, or nil, and how many
        #   digits it took up
        def comment_version(text, from, server_version)
          six = text[from, 7].to_s
          if server_version.to_i >= SIX_DIGIT_VERSIONS_FROM && six.match?(/\A\d{6}(?:\s|\z)/)
            [six[0, 6].to_i, 6]
          elsif text[from, 5].to_s.match?(/\A\d{5}\z/)
            [text[from, 5].to_i, 5]
          else
            [nil, 0]
          end
        end

        # Where a +/*!+ comment MySQL does not run ends. MySQL lets one comment be nested inside one of
        # these, so the first +*/+ after a nested +/*+ closes the nested one rather than this one.
        #
        # @return [Integer, nil] the index just past its close, or nil when it never closes
        def skipped_comment_end(text, from)
          nested = false
          index = from

          while index < text.length
            pair = text[index, 2]
            if pair == '*/'
              return index + 2 unless nested

              nested = false
              index += 2
            elsif pair == '/*' && !nested
              nested = true
              index += 2
            else
              index += 1
            end
          end

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

        def dash_comment?(text, index)
          return false unless text[index, 2] == '--'

          following = text[index + 2]
          following.nil? || following.match?(/[\s[:cntrl:]]/)
        end
      end
    end
  end
end
