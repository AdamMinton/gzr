# frozen_string_literal: true

require 'pastel'
require 'tty-reader'

require_relative '../../gzr'

module Gzr
  module Session

    def pastel
      @pastel ||= Pastel.new
    end

    def say_ok(data)
      puts pastel.green data
    end

    def say_warning(data)
      puts pastel.yellow data
    end

    def say_error(data)
      puts pastel.red data
    end

    def v3_1_available?
      @v3_1_available ||= false
    end

    def build_connection_hash(api_version)
      conn_hash = Hash.new
      conn_hash[:api_endpoint] = "http#{@options[:ssl] ? "s" : ""}://#{@options[:host]}:#{@options[:port]}/api/#{api_version}"
      conn_hash[:connection_options] = {:ssl => {:verify => @options[:verify_ssl]}} if @options[:ssl] 
      if @options[:client_id] then
        conn_hash[:client_id] = @options[:client_id]
        if @options[:client_secret] then
          conn_hash[:client_secret] = @options[:client_secret]
        else
          reader = TTY::Reader.new
          @secret ||= reader.read_line("Enter your client_secret:", echo: false)
          conn_hash[:client_secret] = @secret
        end
      else
        conn_hash[:netrc] = true
        conn_hash[:netrc_file] = "~/.netrc"
      end
      conn_hash
    end

    def login(api_version)
      @secret = nil
      begin
        conn_hash = build_connection_hash("3.0")
        sdk = LookerSDK::Client.new(conn_hash)
        raise Gzr::CLI::Error, "Invalid credentials" unless sdk.authenticated?
        sdk.versions.supported_versions.each do |v|
          @v3_1_available = true if v.version == "3.1"
        end
        begin
          sdk.logout
        rescue LookerSDK::Error => e
          # eat this error if it occurs
        end
      end unless @options[:api_version]

      say_warning "API 3.1 available? #{v3_1_available?}" if @options[:debug]

      raise Gzr::CLI::Error, "Operation requires API v3.1, but user specified a different version" if (api_version == "3.1") && @options[:api_version] && !("3.1" == @options[:api_version])
      raise Gzr::CLI::Error, "Operation requires API v3.1, which is not available from this host" if (api_version == "3.1") && !v3_1_available?

      conn_hash = build_connection_hash(@options[:api_version] || api_version)
      @secret = nil

      say_ok("connecting to #{conn_hash.each { |k,v| "#{k}=>#{(k == :client_secret) ? '*********' : v}" }}") if @options[:debug]

      begin
        @sdk = LookerSDK::Client.new(conn_hash) unless @sdk
        say_ok "check for connectivity: #{@sdk.alive?}" if @options[:debug]
        say_ok "verify authentication: #{@sdk.authenticated?}" if @options[:debug]
      rescue LookerSDK::Unauthorized => e
        say_error "Unauthorized - credentials are not valid"
        raise
      rescue LookerSDK::Error => e
        say_error "Unable to connect"
        say_error e.message
        raise
      end
      raise Gzr::CLI::Error, "Invalid credentials" unless @sdk.authenticated?


      if @options[:su] then
        say_ok "su to user #{@options[:su]}" if @options[:debug]
        @access_token_stack.push(@sdk.access_token)
        begin
          @sdk.access_token = @sdk.login_user(@options[:su]).access_token
          say_warning "verify authentication: #{@sdk.authenticated?}" if @options[:debug]
        rescue LookerSDK::Error => e
          say_error "Unable to su to user #{@options[:su]}" 
          say_error e.message
          raise
        end
      end
      @sdk
    end

    def logout_all
      pastel = Pastel.new(enabled: true)
      say_ok "logout" if @options[:debug]
      begin
        @sdk.logout
      rescue LookerSDK::Error => e
        say_error "Unable to logout"
        say_error e.message
      end if @sdk
      loop do
        token = @access_token_stack.pop
        break unless token
        say_ok "logout the parent session" if @options[:debug]
        @sdk.access_token = token
        begin
          @sdk.logout
        rescue LookerSDK::Error => e
          say_error "Unable to logout"
          say_error e.message
        end
      end
    end

    def with_session(api_version="3.0")
      return nil unless block_given?
      begin
        login(api_version) unless @sdk
        yield
      ensure
        logout_all
      end
    end

  end
end
