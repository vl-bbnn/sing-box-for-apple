#!/usr/bin/env ruby

require "base64"
require "json"
require "net/http"
require "openssl"
require "optparse"
require "time"
require "uri"
require "fileutils"
require "open3"

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
    return if beta_group_id.nil? || beta_group_id.empty?

    add_build_to_beta_group(beta_group_id: beta_group_id, build_id: build.fetch("id"))
    ensure_beta_review_submission(build.fetch("id"))
  end

  def verify_app(bundle_id:)
    app_id = find_app_id(bundle_id)
    bundles = request(:get, "/v1/bundleIds", params: { "filter[identifier]" => bundle_id, "limit" => "200" }).fetch("data")
    bundle = bundles.find { |item| item.dig("attributes", "identifier") == bundle_id }
    raise "bundle ID is not registered" unless bundle
    raise "bundle ID team mismatch" unless bundle.dig("attributes", "seedId") == ENV.fetch("OVERLAY_DEVELOPMENT_TEAM")
    [".share", ".action"].each do |suffix|
      identifier = bundle_id + suffix
      result = request(:get, "/v1/bundleIds", params: { "filter[identifier]" => identifier, "limit" => "200" }).fetch("data")
      item = result.find { |entry| entry.dig("attributes", "identifier") == identifier }
      item ||= request(:post, "/v1/bundleIds", body: { data: {
        type: "bundleIds", attributes: { name: "bbnn VPN #{suffix.delete_prefix(".")}", identifier: identifier, platform: "IOS" }
      } }).fetch("data")
      capabilities = request(:get, "/v1/bundleIds/#{item.fetch('id')}/bundleIdCapabilities").fetch("data")
      unless capabilities.any? { |cap| cap.dig("attributes", "capabilityType") == "APP_GROUPS" }
        request(:post, "/v1/bundleIdCapabilities", body: { data: {
          type: "bundleIdCapabilities", attributes: { capabilityType: "APP_GROUPS" },
          relationships: { bundleId: { data: { type: "bundleIds", id: item.fetch("id") } } }
        } })
      end
      puts "Registered shipping extension #{identifier} with App Groups enabled"
    end
    puts JSON.pretty_generate({ app_id: app_id, bundle_id: bundle_id, token_mode: @token_mode, developer_api: "accessible" })
  end

  def prepare_signing(bundle_id:, build_number:)
    team = ENV.fetch("OVERLAY_DEVELOPMENT_TEAM")
    password = ENV.fetch("P12_PASSWORD")
    raise "empty P12_PASSWORD" if password.empty?
    directory = "build/signing"
    FileUtils.mkdir_p(directory, mode: 0700)
    p12_path = "#{directory}/Distribution.p12"
    certificates = request(:get, "/v1/certificates", params: { "limit" => "200" }).fetch("data")
    if File.exist?(p12_path)
      p12 = OpenSSL::PKCS12.new(File.binread(p12_path), password)
      certificate = p12.certificate
      key = p12.key
      fingerprint = OpenSSL::Digest::SHA1.hexdigest(certificate.to_der)
      record = certificates.find { |item|
        der = Base64.decode64(item.dig("attributes", "certificateContent"))
        OpenSSL::Digest::SHA1.hexdigest(der) == fingerprint
      }
      raise "retained signing certificate is missing or expired" unless record && certificate.not_after > Time.now
    else
      active = certificates.select { |item|
        %w[DISTRIBUTION IOS_DISTRIBUTION].include?(item.dig("attributes", "certificateType")) &&
          Time.parse(item.dig("attributes", "expirationDate")) > Time.now
      }
      raise "distribution certificate quota would be exceeded; existing certificates preserved" if active.length >= 3
      key = OpenSSL::PKey::RSA.new(2048)
      csr = OpenSSL::X509::Request.new
      csr.version = 0
      csr.subject = OpenSSL::X509::Name.parse("/CN=bbnn-vpn CI release")
      csr.public_key = key.public_key
      csr.sign(key, OpenSSL::Digest::SHA256.new)
      record = request(:post, "/v1/certificates", body: { data: {
        type: "certificates", attributes: { certificateType: "DISTRIBUTION", csrContent: csr.to_pem }
      } }).fetch("data")
      certificate = OpenSSL::X509::Certificate.new(Base64.decode64(record.dig("attributes", "certificateContent")))
      File.binwrite(p12_path, OpenSSL::PKCS12.create(password, "bbnn-vpn distribution", key, certificate).to_der)
      File.chmod(0600, p12_path)
    end
    raise "certificate belongs to another team" unless certificate.subject.to_a.any? { |part| part[0] == "OU" && part[1] == team }
    keychain = File.join(ENV.fetch("RUNNER_TEMP"), "app-signing.keychain-db")
    _, _, status = Open3.capture3("security", "import", p12_path, "-P", password, "-t", "cert", "-f", "pkcs12", "-k", keychain, "-T", "/usr/bin/codesign", "-T", "/usr/bin/security")
    raise "distribution identity import failed" unless status.success?
    _, _, status = Open3.capture3("security", "set-key-partition-list", "-S", "apple-tool:,apple:", "-k", ENV.fetch("KEYCHAIN_PASSWORD"), keychain)
    raise "distribution keychain setup failed" unless status.success?

    bundles = request(:get, "/v1/bundleIds", params: { "filter[identifier]" => bundle_id, "limit" => "200" }).fetch("data")
    receipt = { certificate_id: record.fetch("id"), certificate_sha1: OpenSSL::Digest::SHA1.hexdigest(certificate.to_der), profiles: [] }
    ["", ".extension", ".fileprovider", ".intents", ".widget", ".share", ".action"].each do |suffix|
      identifier = bundle_id + suffix
      bundle = bundles.find { |item| item.dig("attributes", "identifier") == identifier }
      raise "missing bundle ID #{identifier}" unless bundle
      raise "bundle ID team mismatch" unless bundle.dig("attributes", "seedId") == team
      name = "bbnn-ios-#{build_number}-#{identifier}"
      existing = request(:get, "/v1/profiles", params: { "filter[name]" => name, "limit" => "200" }).fetch("data")
      profile = existing.find { |item| item.dig("attributes", "name") == name && item.dig("attributes", "profileState") == "ACTIVE" }
      profile ||= request(:post, "/v1/profiles", body: { data: {
        type: "profiles", attributes: { name: name, profileType: "IOS_APP_STORE" }, relationships: {
          bundleId: { data: { type: "bundleIds", id: bundle.fetch("id") } },
          certificates: { data: [{ type: "certificates", id: record.fetch("id") }] }
        }
      } }).fetch("data")
      content = Base64.decode64(profile.dig("attributes", "profileContent"))
      path = "#{directory}/#{identifier}.mobileprovision"
      File.binwrite(path, content)
      decoded, _, status = Open3.capture3("security", "cms", "-D", "-i", path)
      raise "profile decoding failed" unless status.success?
      parsed, _, status = Open3.capture3("python3", "-c", "import sys,plistlib,json; p=plistlib.loads(sys.stdin.buffer.read()); print(json.dumps({'UUID':p['UUID'], 'Entitlements':p['Entitlements']}))", stdin_data: decoded)
      raise "profile parsing failed" unless status.success?
      plist = JSON.parse(parsed)
      entitlements = plist.fetch("Entitlements")
      raise "profile app identifier mismatch" unless entitlements["application-identifier"] == "#{team}.#{identifier}"
      raise "profile lacks new App Group for #{identifier}" unless Array(entitlements["com.apple.security.application-groups"]).include?("group.#{bundle_id}")
      if ["", ".intents"].include?(suffix)
        raise "profile lacks new iCloud container for #{identifier}" unless Array(entitlements["com.apple.developer.icloud-container-identifiers"]).include?("iCloud.#{bundle_id}")
      end
      if suffix == ".extension"
        ["com.apple.developer.networking.multicast", "com.apple.developer.networking.wifi-info"].each do |permission|
          raise "profile lacks #{permission} for #{identifier}" unless entitlements[permission] == true
        end
      end
      if ["", ".extension"].include?(suffix)
        raise "profile lacks packet tunnel for #{identifier}" unless Array(entitlements["com.apple.developer.networking.networkextension"]).include?("packet-tunnel-provider")
      end
      ["Library/MobileDevice/Provisioning Profiles", "Library/Developer/Xcode/UserData/Provisioning Profiles"].each do |subdirectory|
        target = File.join(Dir.home, subdirectory)
        FileUtils.mkdir_p(target)
        File.binwrite(File.join(target, "#{plist.fetch('UUID')}.mobileprovision"), content)
      end
      receipt[:profiles] << { identifier: identifier, id: profile.fetch("id"), name: name, entitlements: entitlements.select { |key, _| key.start_with?("com.apple.") || key == "application-identifier" } }
      puts "Prepared App Store profile for #{identifier}"
    end
    File.write("#{directory}/receipt.json", JSON.pretty_generate(receipt))
  end

  def verify_build(bundle_id:, platform:, version:, build_number:, timeout:)
    app_id = find_app_id(bundle_id)
    deadline = Time.now + timeout
    loop do
      response = request(:get, "/v1/builds", params: {
        "filter[app]" => app_id,
        "filter[preReleaseVersion.platform]" => platform.upcase,
        "filter[preReleaseVersion.version]" => version,
        "filter[version]" => build_number,
        "fields[builds]" => "version,uploadedDate,processingState",
        "limit" => "1"
      })
      build = response.fetch("data", []).first
      state = build&.dig("attributes", "processingState")
      if state == "VALID"
        [".share", ".action"].each do |suffix|
      identifier = bundle_id + suffix
      result = request(:get, "/v1/bundleIds", params: { "filter[identifier]" => identifier, "limit" => "200" }).fetch("data")
      item = result.find { |entry| entry.dig("attributes", "identifier") == identifier }
      item ||= request(:post, "/v1/bundleIds", body: { data: {
        type: "bundleIds", attributes: { name: "bbnn VPN #{suffix.delete_prefix(".")}", identifier: identifier, platform: "IOS" }
      } }).fetch("data")
      capabilities = request(:get, "/v1/bundleIds/#{item.fetch('id')}/bundleIdCapabilities").fetch("data")
      unless capabilities.any? { |cap| cap.dig("attributes", "capabilityType") == "APP_GROUPS" }
        request(:post, "/v1/bundleIdCapabilities", body: { data: {
          type: "bundleIdCapabilities", attributes: { capabilityType: "APP_GROUPS" },
          relationships: { bundleId: { data: { type: "bundleIds", id: item.fetch("id") } } }
        } })
      end
      puts "Registered shipping extension #{identifier} with App Groups enabled"
    end
    puts JSON.pretty_generate({ app_id: app_id, bundle_id: bundle_id, version: version, build: build })
        return
      end
      raise "build processing failed: #{state}" if ["FAILED", "INVALID"].include?(state)
      raise "timed out waiting for build #{version} (#{build_number})" if Time.now >= deadline
      warn "waiting for #{bundle_id} #{version} (#{build_number}): #{state || 'not yet visible'}"
      sleep 20
    end
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
    signature = raw_ecdsa_signature(
      @private_key.dsa_sign_asn1(OpenSSL::Digest::SHA256.digest(unsigned))
    )
    "#{unsigned}.#{base64url(signature)}"
  end

  def raw_ecdsa_signature(der_signature)
    r, s = OpenSSL::ASN1.decode(der_signature).value.map(&:value)
    [r, s].map { |component| component.to_s(2).rjust(32, "\0") }.join
  end

  def base64url(value)
    Base64.urlsafe_encode64(value).delete("=")
  end

  def request(method, path, params: nil, body: nil, allowed_statuses: [200, 201, 202, 204])
    uri = URI.join(API_BASE, path)
    uri.query = URI.encode_www_form(params) if params && !params.empty?
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true

    request_class = case method
                    when :get then Net::HTTP::Get
                    when :post then Net::HTTP::Post
                    when :patch then Net::HTTP::Patch
                    when :delete then Net::HTTP::Delete
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
    unless localization
      request(
        :post,
        "/v1/betaBuildLocalizations",
        body: {
          data: {
            type: "betaBuildLocalizations",
            attributes: {
              locale: locale,
              whatsNew: whats_new
            },
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
      return
    end

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
  opts.on("--build-number VALUE") { |value| options[:build_number] = value }
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
when "verify-app"
  client.verify_app(bundle_id: options.fetch(:bundle_id))
when "prepare-signing"
  client.prepare_signing(bundle_id: options.fetch(:bundle_id), build_number: options.fetch(:build_number))
when "verify-build"
  client.verify_build(
    bundle_id: options.fetch(:bundle_id), platform: options.fetch(:platform),
    version: options.fetch(:version), build_number: options.fetch(:build_number),
    timeout: options.fetch(:timeout)
  )
when "publish-testflight"
  %i[bundle_id platform version whats_new].each do |key|
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
else
  raise "unknown command: #{command}"
end
