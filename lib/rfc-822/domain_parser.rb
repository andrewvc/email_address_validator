class RFC822::DomainParser
# STANDALONE START
    def setup_parser(str, debug=false)
      @string = str
      @pos = 0
      @memoizations = Hash.new { |h,k| h[k] = {} }
      @result = nil
      @failed_rule = nil
      @failing_rule_offset = -1

      setup_foreign_grammar
    end

    # This is distinct from setup_parser so that a standalone parser
    # can redefine #initialize and still have access to the proper
    # parser setup code.
    #
    def initialize(str, debug=false)
      setup_parser(str, debug)
    end

    attr_reader :string
    attr_reader :result, :failing_rule_offset
    attr_accessor :pos

    # STANDALONE START
    def current_column(target=pos)
      if c = string.rindex("\n", target-1)
        return target - c - 1
      end

      target + 1
    end

    def current_line(target=pos)
      cur_offset = 0
      cur_line = 0

      string.each_line do |line|
        cur_line += 1
        cur_offset += line.size
        return cur_line if cur_offset >= target
      end

      -1
    end

    def lines
      lines = []
      string.each_line { |l| lines << l }
      lines
    end

    #

    def get_text(start)
      @string[start..@pos-1]
    end

    def show_pos
      width = 10
      if @pos < width
        "#{@pos} (\"#{@string[0,@pos]}\" @ \"#{@string[@pos,width]}\")"
      else
        "#{@pos} (\"... #{@string[@pos - width, width]}\" @ \"#{@string[@pos,width]}\")"
      end
    end

    def failure_info
      l = current_line @failing_rule_offset
      c = current_column @failing_rule_offset

      if @failed_rule.kind_of? Symbol
        info = self.class::Rules[@failed_rule]
        "line #{l}, column #{c}: failed rule '#{info.name}' = '#{info.rendered}'"
      else
        "line #{l}, column #{c}: failed rule '#{@failed_rule}'"
      end
    end

    def failure_caret
      l = current_line @failing_rule_offset
      c = current_column @failing_rule_offset

      line = lines[l-1]
      "#{line}\n#{' ' * (c - 1)}^"
    end

    def failure_character
      l = current_line @failing_rule_offset
      c = current_column @failing_rule_offset
      lines[l-1][c-1, 1]
    end

    def failure_oneline
      l = current_line @failing_rule_offset
      c = current_column @failing_rule_offset

      char = lines[l-1][c-1, 1]

      if @failed_rule.kind_of? Symbol
        info = self.class::Rules[@failed_rule]
        "@#{l}:#{c} failed rule '#{info.name}', got '#{char}'"
      else
        "@#{l}:#{c} failed rule '#{@failed_rule}', got '#{char}'"
      end
    end

    class ParseError < RuntimeError
    end

    def raise_error
      raise ParseError, failure_oneline
    end

    def show_error(io=STDOUT)
      error_pos = @failing_rule_offset
      line_no = current_line(error_pos)
      col_no = current_column(error_pos)

      io.puts "On line #{line_no}, column #{col_no}:"

      if @failed_rule.kind_of? Symbol
        info = self.class::Rules[@failed_rule]
        io.puts "Failed to match '#{info.rendered}' (rule '#{info.name}')"
      else
        io.puts "Failed to match rule '#{@failed_rule}'"
      end

      io.puts "Got: #{string[error_pos,1].inspect}"
      line = lines[line_no-1]
      io.puts "=> #{line}"
      io.print(" " * (col_no + 3))
      io.puts "^"
    end

    def set_failed_rule(name)
      if @pos > @failing_rule_offset
        @failed_rule = name
        @failing_rule_offset = @pos
      end
    end

    attr_reader :failed_rule

    def match_string(str)
      len = str.size
      if @string[pos,len] == str
        @pos += len
        return str
      end

      return nil
    end

    def scan(reg)
      if m = reg.match(@string[@pos..-1])
        width = m.end(0)
        @pos += width
        return true
      end

      return nil
    end

    if "".respond_to? :getbyte
      def get_byte
        if @pos >= @string.size
          return nil
        end

        s = @string.getbyte @pos
        @pos += 1
        s
      end
    else
      def get_byte
        if @pos >= @string.size
          return nil
        end

        s = @string[@pos]
        @pos += 1
        s
      end
    end

    def parse(rule=nil)
      if !rule
        _root ? true : false
      else
        # This is not shared with code_generator.rb so this can be standalone
        method = rule.gsub("-","_hyphen_")
        __send__("_#{method}") ? true : false
      end
    end

    class LeftRecursive
      def initialize(detected=false)
        @detected = detected
      end

      attr_accessor :detected
    end

    class MemoEntry
      def initialize(ans, pos)
        @ans = ans
        @pos = pos
        @uses = 1
        @result = nil
      end

      attr_reader :ans, :pos, :uses, :result

      def inc!
        @uses += 1
      end

      def move!(ans, pos, result)
        @ans = ans
        @pos = pos
        @result = result
      end
    end

    def external_invoke(other, rule, *args)
      old_pos = @pos
      old_string = @string

      @pos = other.pos
      @string = other.string

      begin
        if val = __send__(rule, *args)
          other.pos = @pos
        else
          other.set_failed_rule "#{self.class}##{rule}"
        end
        val
      ensure
        @pos = old_pos
        @string = old_string
      end
    end

    def apply(rule)
      if m = @memoizations[rule][@pos]
        m.inc!

        prev = @pos
        @pos = m.pos
        if m.ans.kind_of? LeftRecursive
          m.ans.detected = true
          return nil
        end

        @result = m.result

        return m.ans
      else
        lr = LeftRecursive.new(false)
        m = MemoEntry.new(lr, @pos)
        @memoizations[rule][@pos] = m
        start_pos = @pos

        ans = __send__ rule

        m.move! ans, @pos, @result

        # Don't bother trying to grow the left recursion
        # if it's failing straight away (thus there is no seed)
        if ans and lr.detected
          return grow_lr(rule, start_pos, m)
        else
          return ans
        end

        return ans
      end
    end

    def grow_lr(rule, start_pos, m)
      while true
        @pos = start_pos
        @result = m.result

        ans = __send__ rule
        return nil unless ans

        break if @pos <= m.pos

        m.move! ans, @pos, @result
      end

      @result = m.result
      @pos = m.pos
      return m.ans
    end

    class RuleInfo
      def initialize(name, rendered)
        @name = name
        @rendered = rendered
      end

      attr_reader :name, :rendered
    end

    def self.rule_info(name, rendered)
      RuleInfo.new(name, rendered)
    end

    #
  def setup_foreign_grammar; end

  # domain = < subdomain > &{ text.size < 255 }
  def _domain

    _save = self.pos
    while true # sequence
    _text_start = self.pos
    _tmp = apply(:_subdomain)
    if _tmp
      text = get_text(_text_start)
    end
    unless _tmp
      self.pos = _save
      break
    end
    _save1 = self.pos
    _tmp = begin;  text.size < 255 ; end
    self.pos = _save1
    unless _tmp
      self.pos = _save
    end
    break
    end # end sequence

    set_failed_rule :_domain unless _tmp
    return _tmp
  end

  # subdomain = (subdomain "." label | label)
  def _subdomain

    _save = self.pos
    while true # choice

    _save1 = self.pos
    while true # sequence
    _tmp = apply(:_subdomain)
    unless _tmp
      self.pos = _save1
      break
    end
    _tmp = match_string(".")
    unless _tmp
      self.pos = _save1
      break
    end
    _tmp = apply(:_label)
    unless _tmp
      self.pos = _save1
    end
    break
    end # end sequence

    break if _tmp
    self.pos = _save
    _tmp = apply(:_label)
    break if _tmp
    self.pos = _save
    break
    end # end choice

    set_failed_rule :_subdomain unless _tmp
    return _tmp
  end

  # label = let-dig < let-dig-hyp* > &{ text.size < 63 && (text.size == 0 || text[-1] != ?-) }
  def _label

    _save = self.pos
    while true # sequence
    _tmp = apply(:_let_hyphen_dig)
    unless _tmp
      self.pos = _save
      break
    end
    _text_start = self.pos
    while true
    _tmp = apply(:_let_hyphen_dig_hyphen_hyp)
    break unless _tmp
    end
    _tmp = true
    if _tmp
      text = get_text(_text_start)
    end
    unless _tmp
      self.pos = _save
      break
    end
    _save2 = self.pos
    _tmp = begin;  text.size < 63 && (text.size == 0 || text[-1] != ?-) ; end
    self.pos = _save2
    unless _tmp
      self.pos = _save
    end
    break
    end # end sequence

    set_failed_rule :_label unless _tmp
    return _tmp
  end

  # let-dig-hyp = (let-dig | "-")
  def _let_hyphen_dig_hyphen_hyp

    _save = self.pos
    while true # choice
    _tmp = apply(:_let_hyphen_dig)
    break if _tmp
    self.pos = _save
    _tmp = match_string("-")
    break if _tmp
    self.pos = _save
    break
    end # end choice

    set_failed_rule :_let_hyphen_dig_hyphen_hyp unless _tmp
    return _tmp
  end

  # let-dig = (letter | digit)
  def _let_hyphen_dig

    _save = self.pos
    while true # choice
    _tmp = apply(:_letter)
    break if _tmp
    self.pos = _save
    _tmp = apply(:_digit)
    break if _tmp
    self.pos = _save
    break
    end # end choice

    set_failed_rule :_let_hyphen_dig unless _tmp
    return _tmp
  end

  # letter = /[A-Za-z]/
  def _letter
    _tmp = scan(/\A(?-mix:[A-Za-z])/)
    set_failed_rule :_letter unless _tmp
    return _tmp
  end

  # digit = /[0-9]/
  def _digit
    _tmp = scan(/\A(?-mix:[0-9])/)
    set_failed_rule :_digit unless _tmp
    return _tmp
  end

  # root = domain !.
  def _root

    _save = self.pos
    while true # sequence
    _tmp = apply(:_domain)
    unless _tmp
      self.pos = _save
      break
    end
    _save1 = self.pos
    _tmp = get_byte
    _tmp = _tmp ? nil : true
    self.pos = _save1
    unless _tmp
      self.pos = _save
    end
    break
    end # end sequence

    set_failed_rule :_root unless _tmp
    return _tmp
  end

  Rules = {}
  Rules[:_domain] = rule_info("domain", "< subdomain > &{ text.size < 255 }")
  Rules[:_subdomain] = rule_info("subdomain", "(subdomain \".\" label | label)")
  Rules[:_label] = rule_info("label", "let-dig < let-dig-hyp* > &{ text.size < 63 && (text.size == 0 || text[-1] != ?-) }")
  Rules[:_let_hyphen_dig_hyphen_hyp] = rule_info("let-dig-hyp", "(let-dig | \"-\")")
  Rules[:_let_hyphen_dig] = rule_info("let-dig", "(letter | digit)")
  Rules[:_letter] = rule_info("letter", "/[A-Za-z]/")
  Rules[:_digit] = rule_info("digit", "/[0-9]/")
  Rules[:_root] = rule_info("root", "domain !.")
end
