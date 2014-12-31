#!/usr/bin/env ruby

require "logger"
require "optparse"
require "shellwords"
require "sqlite3"
require "hotdog/commands"
require "hotdog/formatters"

module Hotdog
  class Application
    def initialize()
      @confdir = File.join(ENV["HOME"], ".hotdog")
      @optparse = OptionParser.new
      @options = {
        environment: "default",
        minimum_expiry: 28800, # 8 hours
        random_expiry: 604800, # 7 days
        fixed_string: false,
        force: false,
        formatter: get_formatter("plain").new,
        headers: false,
        listing: false,
        logger: Logger.new(STDERR),
        max_time: 30,
        api_key: ENV["DATADOG_API_KEY"],
        application_key: ENV["DATADOG_APPLICATION_KEY"],
        print0: false,
        print1: true,
        tags: [],
      }
      @options[:logger].level = Logger::INFO
      define_options
    end
    attr_reader :options

    def main(argv=[])
      config = File.join(@confdir, "config.yml")
      if File.file?(config)
        @options = @options.merge(YAML.load(File.read(config)))
      end
      args = @optparse.parse(argv)

      unless options[:api_key]
        raise("DATADOG_API_KEY is not set")
      end

      unless options[:application_key]
        raise("DATADOG_APPLICATION_KEY is not set")
      end

      sqlite = File.expand_path(File.join(@confdir, "#{options[:environment]}.db"))
      FileUtils.mkdir_p(File.dirname(sqlite))
      @db = SQLite3::Database.new(sqlite)
      @db.synchronous = "off"

      begin
        command = ( args.shift || "help" )
        c = run_command(command, args)
        if c.suspended?
          exit(2)
        end
      rescue Errno::EPIPE
        # nop
      end
    end

    def run_command(command, args=[])
      get_command(command).new(@db, options.merge(application: self)).tap do |c|
        c.run(args)
      end
    end

    private
    def define_options
      @optparse.on("--api-key API_KEY", "Datadog API key") do |api_key|
        options[:api_key] = api_key
      end
      @optparse.on("--application-key APP_KEY", "Datadog application key") do |app_key|
        options[:application_key] = app_key
      end
      @optparse.on("-0", "--null", "Use null character as separator") do |v|
        options[:print0] = v
      end
      @optparse.on("-1", "Use newline as separator") do |v|
        options[:print1] = v
      end
      @optparse.on("-d", "--[no-]debug", "Enable debug mode") do |v|
        options[:logger].level = v ? Logger::DEBUG : Logger::INFO
      end
      @optparse.on("-E ENVIRONMENT", "--environment ENVIRONMENT", "Specify environment") do |environment|
        options[:environment] = environment
      end
      @optparse.on("--fixed-string", "Interpret pattern as fixed string") do |v|
        options[:fixed_string] = v
      end
      @optparse.on("-f", "--[no-]force", "Enable force mode") do |v|
        options[:force] = v
      end
      @optparse.on("-F FORMAT", "--format FORMAT", "Specify output format") do |format|
        options[:formatter] = get_formatter(format).new
      end
      @optparse.on("-h", "--[no-]headers", "Display headeres for each columns") do |v|
        options[:headers] = v
      end
      @optparse.on("-l", "--[no-]listing", "Use listing format") do |v|
        options[:listing] = v
      end
      @optparse.on("-a TAG", "-t TAG", "--tag TAG", "Use specified tag name/value") do |tag|
        options[:tags] += [tag]
      end
      @optparse.on("-m SECONDS", "--max-time SECONDS", Integer, "Maximum time in seconds") do |seconds|
        options[:max_time] = seconds
      end
      @optparse.on("-V", "--[no-]verbose", "Enable verbose mode") do |v|
        options[:logger].level = v ? Logger::DEBUG : Logger::INFO
      end
    end

    def const_name(name)
      name.to_s.split(/[^\w]+/).map { |s| s.capitalize }.join
    end

    def get_formatter(name)
      begin
        Hotdog::Formatters.const_get(const_name(name))
      rescue NameError
        if library = find_library("hotdog/formatters", name)
          load library
          Hotdog::Formatters.const_get(const_name(File.basename(library, ".rb")))
        else
          raise(NameError.new("unknown format: #{name}"))
        end
      end
    end

    def get_command(name)
      begin
        Hotdog::Commands.const_get(const_name(name))
      rescue NameError
        if library = find_library("hotdog/commands", name)
          load library
          Hotdog::Commands.const_get(const_name(File.basename(library, ".rb")))
        else
          raise(NameError.new("unknown command: #{name}"))
        end
      end
    end

    def find_library(dirname, name)
      load_path = $LOAD_PATH.map { |path| File.join(path, dirname) }.select { |path| File.directory?(path) }
      libraries = load_path.map { |path| Dir.glob(File.join(path, "*.rb")) }.reduce(:+).select { |file| File.file?(file) }
      rbname = "#{name}.rb"
      if library = libraries.find { |file| File.basename(file) == rbname }
        library
      else
        candidates = libraries.map { |file| [file, File.basename(file).slice(0, name.length)] }.select { |file, s| s == name }
        if candidates.length == 1
          candidates.first.first
        else
          nil
        end
      end
    end
  end
end

# vim:set ft=ruby :
