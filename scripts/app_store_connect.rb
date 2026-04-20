#!/usr/bin/env ruby

require "base64"
require "json"
require "net/http"
require "openssl"
require "optparse"
require "time"
require "uri"

class AppStoreConnectClient
  API_BASE = "https://api.appstoreconnect.apple.com"

  def initialize(key_id:, issuer_id:, key_path:)
    @key_id = key_id
    @issuer_id = issuer_id
    @private_key = OpenSSL::PKey.read(File.read(key_path))
    @token_mode = :auto
  end

  def publish_testflight(bundle_id:, platform:, version:, beta_group_id:, whats_new:, locale:, timeout:)
    app_id = find_app_id(bundle_id)
    build = wait_for_valid_build(app_id: app_id, platform: platform, version: version, timeout: timeout)
    update_localization(build.fetch("id"), locale: locale, whats_new: whats_new)
    add_build_to_beta_group(beta_group_id: beta_group_id, build_id: build.fetch("id"))
    ensure_beta_review_submission(build.fetch("id"))
  end

  def build_exists(bundle_id:, platform:, version:)
    app_id = find_app_id(bundle_id)
    build = latest_build(app_id: app_id, platform: platform_filter_value(platform), version: version)
    return nil unless build

    build
  end

  private

  def token(mode = @token_mode)
    now = Time.now.to_i
    header = { alg: "ES256", kid: @key_id, typ: "JWT" }
    payload = case mode
              when :individual
                { sub: "user", aud: "appstoreconnect-v1", iat: now, exp: now + 20 * 60 }
              else
                { iss: @issuer_id, aud: "appstoreconnect-v1", iat: now, exp: now + 20 * 60 }
              end
    unsigned = [header, payload].map { |part| base64url(JSON.generate(part)) }.join(".")
    signature = @private_key.dsa_sign_asn1(OpenSSL::Digest::SHA256.digest(unsigned))
    "#{unsigned}.#{base64url(signature)}"
  end

  def base64url(value)
    Base64.urlsafe_encode64(value).delete("=")
  end

  def request(method, path, params: nil, body: nil, allowed_statuses: [200, 201, 202, 204, 409, 422])
    uri = URI.join(API_BASE, path)
    uri.query = URI.encode_www_form(params) if params && !params.empty?
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true

    request_class = case method
                    when :get then Net::HTTP::Get
                    when :post then Net::HTTP::Post
                    when :patch then Net::HTTP::Patch
                    else
                      raise "unsupported method: #{method}"
                    end

    modes = case @token_mode
            when :auto then [:team, :individual]
            else [@token_mode]
            end

    last_response = nil
    modes.each do |mode|
      req = request_class.new(uri)
      req["Authorization"] = "Bearer #{token(mode)}"
      req["Accept"] = "application/json"
      if body
        req["Content-Type"] = "application/json"
        req.body = JSON.generate(body)
      end

      response = http.request(req)
      if allowed_statuses.include?(response.code.to_i)
        @token_mode = mode
        return nil if response.body.nil? || response.body.empty?

        return JSON.parse(response.body)
      end

      last_response = response
      next if response.code.to_i == 401 && @token_mode == :auto

      raise "App Store Connect API #{method.upcase} #{uri} failed with #{response.code}: #{response.body}"
    end

    raise "App Store Connect API #{method.upcase} #{uri} failed with #{last_response.code}: #{last_response.body}"
  end

  def find_app_id(bundle_id)
    response = request(
      :get,
      "/v1/apps",
      params: {
        "filter[bundleId]" => bundle_id,
        "fields[apps]" => "bundleId,name",
        "limit" => "1"
      }
    )
    app = response.fetch("data", []).first
    raise "no App Store Connect app found for #{bundle_id}" unless app

    app.fetch("id")
  end

  def wait_for_valid_build(app_id:, platform:, version:, timeout:)
    platform_filter = platform_filter_value(platform)
    deadline = Time.now + timeout
    loop do
      build = latest_build(app_id: app_id, platform: platform_filter, version: version)
      if build
        state = build.dig("attributes", "processingState")
        return build if state == "VALID"
        warn "#{platform} #{version} waiting for processing, current state: #{state}"
      else
        warn "#{platform} #{version} waiting for build to appear in App Store Connect"
      end
      raise "timed out waiting for #{platform} #{version} build to become VALID" if Time.now >= deadline

      sleep 20
    end
  end

  def latest_build(app_id:, platform:, version:)
    response = request(
      :get,
      "/v1/builds",
      params: {
        "filter[app]" => app_id,
        "filter[preReleaseVersion.platform]" => platform.upcase,
        "filter[preReleaseVersion.version]" => version,
        "fields[builds]" => "version,uploadedDate,processingState",
        "sort" => "-uploadedDate",
        "limit" => "1"
      }
    )
    response.fetch("data", []).first
  end

  def platform_filter_value(platform)
    case platform.downcase
    when "ios"
      "IOS"
    when "macos"
      "MAC_OS"
    when "tvos"
      "TV_OS"
    else
      raise "unsupported platform: #{platform}"
    end
  end

  def update_localization(build_id, locale:, whats_new:)
    response = request(
      :get,
      "/v1/builds/#{build_id}/betaBuildLocalizations",
      params: {
        "fields[betaBuildLocalizations]" => "locale,whatsNew"
      }
    )
    localization = response.fetch("data", []).find { |item| item.dig("attributes", "locale") == locale }
    return unless localization

    current = localization.dig("attributes", "whatsNew")
    return if current == whats_new

    request(
      :patch,
      "/v1/betaBuildLocalizations/#{localization.fetch('id')}",
      body: {
        data: {
          id: localization.fetch("id"),
          type: "betaBuildLocalizations",
          attributes: {
            whatsNew: whats_new
          }
        }
      }
    )
  end

  def add_build_to_beta_group(beta_group_id:, build_id:)
    request(
      :post,
      "/v1/betaGroups/#{beta_group_id}/relationships/builds",
      body: {
        data: [
          {
            type: "builds",
            id: build_id
          }
        ]
      }
    )
  end

  def ensure_beta_review_submission(build_id)
    response = request(
      :get,
      "/v1/betaAppReviewSubmissions",
      params: {
        "filter[build]" => build_id
      }
    )
    return unless response.fetch("data", []).empty?

    request(
      :post,
      "/v1/betaAppReviewSubmissions",
      body: {
        data: {
          type: "betaAppReviewSubmissions",
          relationships: {
            build: {
              data: {
                type: "builds",
                id: build_id
              }
            }
          }
        }
      }
    )
  end
end

options = {
  locale: "en-US",
  timeout: 1800
}

parser = OptionParser.new do |opts|
  opts.on("--bundle-id VALUE") { |value| options[:bundle_id] = value }
  opts.on("--platform VALUE") { |value| options[:platform] = value }
  opts.on("--version VALUE") { |value| options[:version] = value }
  opts.on("--beta-group-id VALUE") { |value| options[:beta_group_id] = value }
  opts.on("--whats-new VALUE") { |value| options[:whats_new] = value }
  opts.on("--locale VALUE") { |value| options[:locale] = value }
  opts.on("--timeout VALUE", Integer) { |value| options[:timeout] = value }
end

command = ARGV.shift
parser.parse!(ARGV)

client = AppStoreConnectClient.new(
  key_id: ENV.fetch("ASC_KEY_ID"),
  issuer_id: ENV.fetch("ASC_KEY_ISSUER_ID"),
  key_path: ENV.fetch("ASC_KEY_PATH")
)

case command
when "publish-testflight"
  %i[bundle_id platform version beta_group_id whats_new].each do |key|
    raise "missing #{key}" if options[key].nil? || options[key].empty?
  end

  client.publish_testflight(
    bundle_id: options[:bundle_id],
    platform: options[:platform],
    version: options[:version],
    beta_group_id: options[:beta_group_id],
    whats_new: options[:whats_new],
    locale: options[:locale],
    timeout: options[:timeout]
  )
when "build-exists"
  %i[bundle_id platform version].each do |key|
    raise "missing #{key}" if options[key].nil? || options[key].empty?
  end

  build = client.build_exists(
    bundle_id: options[:bundle_id],
    platform: options[:platform],
    version: options[:version]
  )

  unless build
    warn "#{options[:platform]} #{options[:version]} build not found for #{options[:bundle_id]}"
    exit 3
  end

  puts JSON.generate(
    id: build.fetch("id"),
    processingState: build.dig("attributes", "processingState"),
    uploadedDate: build.dig("attributes", "uploadedDate"),
    version: build.dig("attributes", "version")
  )
else
  raise "unknown command: #{command}"
end
