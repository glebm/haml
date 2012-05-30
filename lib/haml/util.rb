require 'erb'
require 'set'
require 'stringio'
require 'strscan'

module Haml
  # A module containing various useful functions.
  module Util
    extend self

    # An array of ints representing the Ruby version number.
    # @api public
    RUBY_VERSION = ::RUBY_VERSION.split(".").map {|s| s.to_i}

    # Returns the path of a file relative to the Haml root directory.
    #
    # @param file [String] The filename relative to the Haml root
    # @return [String] The filename relative to the the working directory
    def scope(file)
      File.expand_path("../../../#{file}", __FILE__)
    end

    # Computes the powerset of the given array.
    # This is the set of all subsets of the array.
    #
    # @example
    #   powerset([1, 2, 3]) #=>
    #     Set[Set[], Set[1], Set[2], Set[3], Set[1, 2], Set[2, 3], Set[1, 3], Set[1, 2, 3]]
    # @param arr [Enumerable]
    # @return [Set<Set>] The subsets of `arr`
    def powerset(arr)
      arr.inject([Set.new].to_set) do |powerset, el|
        new_powerset = Set.new
        powerset.each do |subset|
          new_powerset << subset
          new_powerset << subset + [el]
        end
        new_powerset
      end
    end

    # Returns information about the caller of the previous method.
    #
    # @param entry [String] An entry in the `#caller` list, or a similarly formatted string
    # @return [[String, Fixnum, (String, nil)]] An array containing the filename, line, and method name of the caller.
    #   The method name may be nil
    def caller_info(entry = caller[1])
      info = entry.scan(/^(.*?):(-?.*?)(?::.*`(.+)')?$/).first
      info[1] = info[1].to_i
      # This is added by Rubinius to designate a block, but we don't care about it.
      info[2].sub!(/ \{\}\Z/, '') if info[2]
      info
    end

    # Silence all output to STDERR within a block.
    #
    # @yield A block in which no output will be printed to STDERR
    def silence_warnings
      the_real_stderr, $stderr = $stderr, StringIO.new
      yield
    ensure
      $stderr = the_real_stderr
    end

    # Returns an ActionView::Template* class.
    # In pre-3.0 versions of Rails, most of these classes
    # were of the form `ActionView::TemplateFoo`,
    # while afterwards they were of the form `ActionView;:Template::Foo`.
    #
    # @param name [#to_s] The name of the class to get.
    #   For example, `:Error` will return `ActionView::TemplateError`
    #   or `ActionView::Template::Error`.
    def av_template_class(name)
      return ActionView.const_get("Template#{name}") if ActionView.const_defined?("Template#{name}")
      return ActionView::Template.const_get(name.to_s)
    end

    ## Rails XSS Safety

    # Whether or not ActionView's XSS protection is available and enabled,
    # as is the default for Rails 3.0+, and optional for version 2.3.5+.
    # Overridden in haml/template.rb if this is the case.
    #
    # @return [Boolean]
    def rails_xss_safe?
      false
    end

    # Returns the given text, marked as being HTML-safe.
    # With older versions of the Rails XSS-safety mechanism,
    # this destructively modifies the HTML-safety of `text`.
    #
    # @param text [String, nil]
    # @return [String, nil] `text`, marked as HTML-safe
    def html_safe(text)
      return unless text
      return text.html_safe if defined?(ActiveSupport::SafeBuffer)
      text.html_safe!
    end

    # Whether or not this is running under Ruby 1.8 or lower.
    #
    # Note that IronRuby counts as Ruby 1.8,
    # because it doesn't support the Ruby 1.9 encoding API.
    #
    # @return [Boolean]
    def ruby1_8?
      # IronRuby says its version is 1.9, but doesn't support any of the encoding APIs.
      # We have to fall back to 1.8 behavior.
      RUBY_VERSION < "1.9"
    end

    # Checks that the encoding of a string is valid in Ruby 1.9
    # and cleans up potential encoding gotchas like the UTF-8 BOM.
    # If it's not, yields an error string describing the invalid character
    # and the line on which it occurrs.
    #
    # @param str [String] The string of which to check the encoding
    # @yield [msg] A block in which an encoding error can be raised.
    #   Only yields if there is an encoding error
    # @yieldparam msg [String] The error message to be raised
    # @return [String] `str`, potentially with encoding gotchas like BOMs removed
    def check_encoding(str)
      if ruby1_8?
        return str.gsub(/\A\xEF\xBB\xBF/, '') # Get rid of the UTF-8 BOM
      elsif str.valid_encoding?
        # Get rid of the Unicode BOM if possible
        if str.encoding.name =~ /^UTF-(8|16|32)(BE|LE)?$/
          return str.gsub(Regexp.new("\\A\uFEFF".encode(str.encoding.name)), '')
        else
          return str
        end
      end

      encoding = str.encoding
      newlines = Regexp.new("\r\n|\r|\n".encode(encoding).force_encoding("binary"))
      str.force_encoding("binary").split(newlines).each_with_index do |line, i|
        begin
          line.encode(encoding)
        rescue Encoding::UndefinedConversionError => e
          yield <<MSG.rstrip, i + 1
Invalid #{encoding.name} character #{e.error_char.dump}
MSG
        end
      end
      return str
    end

    # Like {\#check\_encoding}, but also checks for a Ruby-style `-# coding:` comment
    # at the beginning of the template and uses that encoding if it exists.
    #
    # The Haml encoding rules are simple.
    # If a `-# coding:` comment exists,
    # we assume that that's the original encoding of the document.
    # Otherwise, we use whatever encoding Ruby has.
    #
    # Haml uses the same rules for parsing coding comments as Ruby.
    # This means that it can understand Emacs-style comments
    # (e.g. `-*- encoding: "utf-8" -*-`),
    # and also that it cannot understand non-ASCII-compatible encodings
    # such as `UTF-16` and `UTF-32`.
    #
    # @param str [String] The Haml template of which to check the encoding
    # @yield [msg] A block in which an encoding error can be raised.
    #   Only yields if there is an encoding error
    # @yieldparam msg [String] The error message to be raised
    # @return [String] The original string encoded properly
    # @raise [ArgumentError] if the document declares an unknown encoding
    def check_haml_encoding(str, &block)
      return check_encoding(str, &block) if ruby1_8?
      str = str.dup if str.frozen?

      bom, encoding = parse_haml_magic_comment(str)
      if encoding; str.force_encoding(encoding)
      elsif bom; str.force_encoding("UTF-8")
      end

      return check_encoding(str, &block)
    end

    # Checks to see if a class has a given method.
    # For example:
    #
    #     Haml::Util.has?(:public_instance_method, String, :gsub) #=> true
    #
    # Method collections like `Class#instance_methods`
    # return strings in Ruby 1.8 and symbols in Ruby 1.9 and on,
    # so this handles checking for them in a compatible way.
    #
    # @param attr [#to_s] The (singular) name of the method-collection method
    #   (e.g. `:instance_methods`, `:private_methods`)
    # @param klass [Module] The class to check the methods of which to check
    # @param method [String, Symbol] The name of the method do check for
    # @return [Boolean] Whether or not the given collection has the given method
    def has?(attr, klass, method)
      klass.send("#{attr}s").include?(ruby1_8? ? method.to_s : method.to_sym)
    end

    # Like `Object#inspect`, but preserves non-ASCII characters rather than escaping them under Ruby 1.9.2.
    # This is necessary so that the precompiled Haml template can be `#encode`d into `@options[:encoding]`
    # before being evaluated.
    #
    # @param obj {Object}
    # @return {String}
    def inspect_obj(obj)
      return obj.inspect unless (::RUBY_VERSION >= "1.9.2")
      return ':' + inspect_obj(obj.to_s) if obj.is_a?(Symbol)
      return obj.inspect unless obj.is_a?(String)
      '"' + obj.gsub(/[\x00-\x7F]+/) {|s| s.inspect[1...-1]} + '"'
    end

    ## Static Method Stuff

    # The context in which the ERB for \{#def\_static\_method} will be run.
    class StaticConditionalContext
      # @param set [#include?] The set of variables that are defined for this context.
      def initialize(set)
        @set = set
      end

      # Checks whether or not a variable is defined for this context.
      #
      # @param name [Symbol] The name of the variable
      # @return [Boolean]
      def method_missing(name, *args, &block)
        super unless args.empty? && block.nil?
        @set.include?(name)
      end
    end

    # This is used for methods in {Haml::Buffer} that need to be very fast,
    # and take a lot of boolean parameters
    # that are known at compile-time.
    # Instead of passing the parameters in normally,
    # a separate method is defined for every possible combination of those parameters;
    # these are then called using \{#static\_method\_name}.
    #
    # To define a static method, an ERB template for the method is provided.
    # All conditionals based on the static parameters
    # are done as embedded Ruby within this template.
    # For example:
    #
    #     def_static_method(Foo, :my_static_method, [:foo, :bar], :baz, :bang, <<RUBY)
    #       <% if baz && bang %>
    #         return foo + bar
    #       <% elsif baz || bang %>
    #         return foo - bar
    #       <% else %>
    #         return 17
    #       <% end %>
    #     RUBY
    #
    # \{#static\_method\_name} can be used to call static methods.
    #
    # @overload def_static_method(klass, name, args, *vars, erb)
    # @param klass [Module] The class on which to define the static method
    # @param name [#to_s] The (base) name of the static method
    # @param args [Array<Symbol>] The names of the arguments to the defined methods
    #   (**not** to the ERB template)
    # @param vars [Array<Symbol>] The names of the static boolean variables
    #   to be made available to the ERB template
    def def_static_method(klass, name, args, *vars)
      erb = vars.pop
      info = caller_info
      powerset(vars).each do |set|
        context = StaticConditionalContext.new(set).instance_eval {binding}
        klass.class_eval(<<METHOD, info[0], info[1])
def #{static_method_name(name, *vars.map {|v| set.include?(v)})}(#{args.join(', ')})
  #{ERB.new(erb).result(context)}
end
METHOD
      end
    end

    # Computes the name for a method defined via \{#def\_static\_method}.
    #
    # @param name [String] The base name of the static method
    # @param vars [Array<Boolean>] The static variable assignment
    # @return [String] The real name of the static method
    def static_method_name(name, *vars)
      "#{name}_#{vars.map {|v| !!v}.join('_')}"
    end

    # Scans through a string looking for the interoplation-opening `#{`
    # and, when it's found, yields the scanner to the calling code
    # so it can handle it properly.
    #
    # The scanner will have any backslashes immediately in front of the `#{`
    # as the second capture group (`scan[2]`),
    # and the text prior to that as the first (`scan[1]`).
    #
    # @yieldparam scan [StringScanner] The scanner scanning through the string
    # @return [String] The text remaining in the scanner after all `#{`s have been processed
    def handle_interpolation(str)
      scan = StringScanner.new(str)
      yield scan while scan.scan(/(.*?)(\\*)\#\{/)
      scan.rest
    end

    # Moves a scanner through a balanced pair of characters.
    # For example:
    #
    #     Foo (Bar (Baz bang) bop) (Bang (bop bip))
    #     ^                       ^
    #     from                    to
    #
    # @param scanner [StringScanner] The string scanner to move
    # @param start [Character] The character opening the balanced pair.
    #   A `Fixnum` in 1.8, a `String` in 1.9
    # @param finish [Character] The character closing the balanced pair.
    #   A `Fixnum` in 1.8, a `String` in 1.9
    # @param count [Fixnum] The number of opening characters matched
    #   before calling this method
    # @return [(String, String)] The string matched within the balanced pair
    #   and the rest of the string.
    #   `["Foo (Bar (Baz bang) bop)", " (Bang (bop bip))"]` in the example above.
    def balance(scanner, start, finish, count = 0)
      str = ''
      scanner = StringScanner.new(scanner) unless scanner.is_a? StringScanner
      regexp = Regexp.new("(.*?)[\\#{start.chr}\\#{finish.chr}]", Regexp::MULTILINE)
      while scanner.scan(regexp)
        str << scanner.matched
        count += 1 if scanner.matched[-1] == start
        count -= 1 if scanner.matched[-1] == finish
        return [str.strip, scanner.rest] if count == 0
      end
    end

    # Formats a string for use in error messages about indentation.
    #
    # @param indentation [String] The string used for indentation
    # @param was [Boolean] Whether or not to add `"was"` or `"were"`
    #   (depending on how many characters were in `indentation`)
    # @return [String] The name of the indentation (e.g. `"12 spaces"`, `"1 tab"`)
    def human_indentation(indentation, was = false)
      if !indentation.include?(?\t)
        noun = 'space'
      elsif !indentation.include?(?\s)
        noun = 'tab'
      else
        return indentation.inspect + (was ? ' was' : '')
      end

      singular = indentation.length == 1
      if was
        was = singular ? ' was' : ' were'
      else
        was = ''
      end

      "#{indentation.length} #{noun}#{'s' unless singular}#{was}"
    end

    private

    # Parses a magic comment at the beginning of a Haml file.
    # The parsing rules are basically the same as Ruby's.
    #
    # @return [(Boolean, String or nil)]
    #   Whether the document begins with a UTF-8 BOM,
    #   and the declared encoding of the document (or nil if none is declared)
    def parse_haml_magic_comment(str)
      scanner = StringScanner.new(str.dup.force_encoding("BINARY"))
      bom = scanner.scan(/\xEF\xBB\xBF/n)
      return bom unless scanner.scan(/-\s*#\s*/n)
      if coding = try_parse_haml_emacs_magic_comment(scanner)
        return bom, coding
      end

      return bom unless scanner.scan(/.*?coding[=:]\s*([\w-]+)/in)
      return bom, scanner[1]
    end

    def try_parse_haml_emacs_magic_comment(scanner)
      pos = scanner.pos
      return unless scanner.scan(/.*?-\*-\s*/n)
      # From Ruby's parse.y
      return unless scanner.scan(/([^\s'":;]+)\s*:\s*("(?:\\.|[^"])*"|[^"\s;]+?)[\s;]*-\*-/n)
      name, val = scanner[1], scanner[2]
      return unless name =~ /(en)?coding/in
      val = $1 if val =~ /^"(.*)"$/n
      return val
    ensure
      scanner.pos = pos
    end
  end
end
