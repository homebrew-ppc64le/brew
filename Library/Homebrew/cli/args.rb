# frozen_string_literal: true

require "ostruct"

module Homebrew
  module CLI
    class Args < OpenStruct
      attr_reader :processed_options, :args_parsed
      # undefine tap to allow --tap argument
      undef tap

      def initialize
        super

        self[:remaining] = []
        self[:cmdline_args] = ARGV.dup.freeze

        @args_parsed = false
        @processed_options = []
      end

      def freeze_processed_options!(processed_options)
        @processed_options += processed_options
        @processed_options.freeze
        @args_parsed = true
      end

      def option_to_name(option)
        option.sub(/\A--?/, "")
              .tr("-", "_")
      end

      def cli_args
        return @cli_args if @cli_args

        @cli_args = []
        processed_options.each do |short, long|
          option = long || short
          switch = "#{option_to_name(option)}?".to_sym
          flag = option_to_name(option).to_sym
          if @table[switch] == true || @table[flag] == true
            @cli_args << option
          elsif @table[flag].instance_of? String
            @cli_args << option + "=" + @table[flag]
          elsif @table[flag].instance_of? Array
            @cli_args << option + "=" + @table[flag].join(",")
          end
        end
        @cli_args
      end

      def options_only
        @options_only ||= cli_args.select { |arg| arg.start_with?("-") }
      end

      def flags_only
        @flags_only ||= cli_args.select { |arg| arg.start_with?("--") }
      end

      def passthrough
        options_only - CLI::Parser.global_options.values.map(&:first).flatten
      end

      def named
        remaining
      end

      def no_named?
        named.blank?
      end

      # If the user passes any flags that trigger building over installing from
      # a bottle, they are collected here and returned as an Array for checking.
      def collect_build_args
        build_flags = []

        build_flags << "--HEAD" if head
        build_flags << "--universal" if build_universal
        build_flags << "--build-bottle" if build_bottle
        build_flags << "--build-from-source" if build_from_source

        build_flags
      end

      def formulae
        require "formula"
        @formulae ||= (downcased_unique_named - casks).map do |name|
          if name.include?("/") || File.exist?(name)
            Formulary.factory(name, spec)
          else
            Formulary.find_with_priority(name, spec)
          end
        end.uniq(&:name)
      end

      def resolved_formulae
        require "formula"
        @resolved_formulae ||= (downcased_unique_named - casks).map do |name|
          Formulary.resolve(name, spec: spec(nil))
        end.uniq(&:name)
      end

      def formulae_paths
        @formulae_paths ||= (downcased_unique_named - casks).map do |name|
          Formulary.path(name)
        end.uniq
      end

      def casks
        @casks ||= downcased_unique_named.grep HOMEBREW_CASK_TAP_CASK_REGEX
      end

      def kegs
        require "keg"
        require "formula"
        require "missing_formula"
        @kegs ||= downcased_unique_named.map do |name|
          raise UsageError if name.empty?

          rack = Formulary.to_rack(name.downcase)

          dirs = rack.directory? ? rack.subdirs : []

          if dirs.empty?
            if (reason = Homebrew::MissingFormula.suggest_command(name, "uninstall"))
              $stderr.puts reason
            end
            raise NoSuchKegError, rack.basename
          end

          linked_keg_ref = HOMEBREW_LINKED_KEGS/rack.basename
          opt_prefix = HOMEBREW_PREFIX/"opt/#{rack.basename}"

          begin
            if opt_prefix.symlink? && opt_prefix.directory?
              Keg.new(opt_prefix.resolved_path)
            elsif linked_keg_ref.symlink? && linked_keg_ref.directory?
              Keg.new(linked_keg_ref.resolved_path)
            elsif dirs.length == 1
              Keg.new(dirs.first)
            else
              f = if name.include?("/") || File.exist?(name)
                Formulary.factory(name)
              else
                Formulary.from_rack(rack)
              end

              unless (prefix = f.installed_prefix).directory?
                raise MultipleVersionsInstalledError, rack.basename
              end

              Keg.new(prefix)
            end
          rescue FormulaUnavailableError
            raise <<~EOS
              Multiple kegs installed to #{rack}
              However we don't know which one you refer to.
              Please delete (with rm -rf!) all but one and then try again.
            EOS
          end
        end
      end

      def build_stable?
        !(HEAD? || devel?)
      end

      # Whether a given formula should be built from source during the current
      # installation run.
      def build_formula_from_source?(f)
        return false if !build_from_source && !build_bottle

        formulae.any? { |args_f| args_f.full_name == f.full_name }
      end

      def build_from_source
        return true if args_parsed && (build_from_source? || s?)

        cmdline_args.include?("--build-from-source") || cmdline_args.include?("-s")
      end

      def build_bottle
        return true if args_parsed && build_bottle?

        cmdline_args.include?("--build-bottle")
      end

      def force_bottle
        return true if args_parsed && force_bottle?

        cmdline_args.include?("--force-bottle")
      end

      private

      def downcased_unique_named
        # Only lowercase names, not paths, bottle filenames or URLs
        arguments = if args_parsed
          named
        else
          cmdline_args.reject { |arg| arg.start_with?("-") }
        end
        arguments.map do |arg|
          if arg.include?("/") || arg.end_with?(".tar.gz") || File.exist?(arg)
            arg
          else
            arg.downcase
          end
        end.uniq
      end

      def head
        return true if args_parsed && HEAD?

        cmdline_args.include?("--HEAD")
      end

      def devel
        return true if args_parsed && devel?

        cmdline_args.include?("--devel")
      end

      def build_universal
        return true if args_parsed && universal?

        cmdline_args.include?("--universal")
      end

      def spec(default = :stable)
        if head
          :head
        elsif devel
          :devel
        else
          default
        end
      end
    end
  end
end
