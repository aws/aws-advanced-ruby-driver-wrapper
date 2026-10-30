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

require_relative '../../../spec_helper'
require 'aws_advanced_ruby_driver_wrapper/utils/parser/mysql_text'

RSpec.describe AwsAdvancedRubyDriverWrapper::Utils::Parser::MysqlText do
  def code(text, server_version = nil)
    chars = +''
    unclosed = described_class.each_code_char(text, server_version: server_version) { |char, _index| chars << char }
    [chars, unclosed]
  end

  describe '.each_code_char' do
    it 'yields every character of plain code' do
      expect(code('a = ?')).to eq(['a = ?', nil])
    end

    it 'skips quoted literals, whichever quote they use' do
      expect(code(%q(a = 'x?' AND b = "y?" AND `c?` = ?))).to eq(['a =  AND b =  AND  = ?', nil])
    end

    it 'reads past a backslash-escaped quote inside a literal' do
      expect(code("'it\\'s?' ?")).to eq([' ?', nil])
    end

    it 'reads a doubled quote as one literal closing and the next opening' do
      expect(code("'it''s?' ?")).to eq([' ?', nil])
    end

    it 'skips block comments' do
      expect(code('a /* b? */ ?')).to eq(['a  ?', nil])
    end

    it 'skips # and -- comments to the end of the line' do
      expect(code("a # b?\n? -- c?\n?")).to eq(["a \n? \n?", nil])
    end

    it 'reads a double dash with no whitespace after it as code' do
      expect(code('1--?')).to eq(['1--?', nil])
    end

    it 'reads the contents of an executable comment as code' do
      expect(code('/*! ? */')).to eq([' ? ', nil])
    end

    it 'reads a block comment inside an executable comment as a comment' do
      expect(code('/*! a /* b? */ ? */ c')).to eq([' a  ?  c', nil])
    end

    it 'reports an executable comment that never closes' do
      expect(code('/*! ?')).to eq([' ?', '/*'])
    end

    it 'reports the quote of a literal that never closes' do
      expect(code("a = 'b?")).to eq(['a = ', "'"])
    end

    it 'reports a block comment that never closes' do
      expect(code('a /* b?')).to eq(['a ', '/*'])
    end

    it 'reports nothing open when the text ends in a line comment' do
      expect(code('a -- b?')).to eq(['a ', nil])
    end

    it 'reads a double dash followed by a tab, a line break or the end of the text as a comment' do
      expect(code("a --\tb?\n?")).to eq(["a \n?", nil])
      expect(code("a --\n?")).to eq(["a \n?", nil])
      expect(code('a --')).to eq(['a ', nil])
    end

    it 'skips an optimizer hint as a comment' do
      expect(code('INSERT /*+ SET_VAR(x=1) */ INTO')).to eq(['INSERT  INTO', nil])
    end

    # MySQL does not nest comments: the first */ closes the comment, however many /* came before it.
    it 'ends a block comment at the first close' do
      expect(code('/* a /* b */ ? */')).to eq([' ? */', nil])
    end
  end

  describe '.each_code_char with a versioned executable comment' do
    it 'reads the contents as code on a server of that version or later' do
      expect(code('/*!80023 ? */', 80_023)).to eq([' ? ', nil])
      expect(code('/*!80023 ? */', 80_039)).to eq([' ? ', nil])
    end

    it 'skips the whole comment on an older server' do
      expect(code('a /*!80023 ? */ b', 80_022)).to eq(['a  b', nil])
    end

    it 'reads the contents as code when the server version is not known' do
      expect(code('/*!99999 ? */', nil)).to eq([' ? ', nil])
    end

    # MySQL lets one comment be nested inside a versioned comment it skips.
    it 'skips one comment nested inside a comment it skips' do
      expect(code('/*!99999 a /* b */ ? */ ?', 80_039)).to eq([' ?', nil])
    end

    it 'does not treat a quote inside a skipped comment as opening a literal' do
      expect(code("/*!99999 '*/ ?", 80_039)).to eq([' ?', nil])
    end

    it 'reports a skipped comment that never closes' do
      expect(code('/*!99999 ?', 80_039)).to eq(['', '/*'])
    end

    it 'reads fewer than five digits as no version at all' do
      expect(code('/*!8002 ? */', 70_000)).to eq(['8002 ? ', nil])
    end

    # A six-digit version is read only by a server that takes one, MySQL 8.1 and later; an older
    # server reads the first five digits as the version and the sixth as code.
    it 'reads a six-digit version on a server that takes one' do
      expect(code('/*!100000 ? */', 80_100)).to eq(['', nil])
      expect(code('/*!100000 ? */', 80_400)).to eq(['', nil])
      expect(code('/*!080400 ? */', 80_400)).to eq([' ? ', nil])
    end

    it 'reads the first five digits of a six-digit version on an older server' do
      expect(code('/*!100000 ? */', 80_039)).to eq(['0 ? ', nil])
    end

    # MySQL needs whitespace after six digits to read them as the version, and the end of the
    # comment is not enough.
    it 'reads five digits when the comment ends right after six' do
      expect(code('/*!800000*/ ?', 80_400)).to eq(['0 ?', nil])
    end
  end

  # Text whose comments have already been blanked is read for its literals alone: blanking can
  # leave a -- in front of whitespace that was a comment's, which would start a comment that the
  # server never saw.
  describe '.each_code_char without comments' do
    it 'reads a double dash in front of a blanked comment as code' do
      blanked = described_class.blank_comments('0--/**/?')

      chars = +''
      described_class.each_code_char(blanked, comments: false) { |char, _index| chars << char }
      expect(chars).to eq('0--    ?')
    end

    it 'still skips quoted literals' do
      chars = +''
      described_class.each_code_char("'a?' -- ?", comments: false) { |char, _index| chars << char }
      expect(chars).to eq(' -- ?')
    end
  end

  describe '.blank_comments' do
    it 'replaces every comment with spaces, keeping literals and offsets' do
      text = "a /* x */ 'b /* y */' -- z\n`c`"

      expect(described_class.blank_comments(text)).to eq("a         'b /* y */'     \n`c`")
    end

    it 'blanks a block comment that never closes to the end of the text' do
      expect(described_class.blank_comments('a /* b')).to eq('a     ')
    end
  end
end
