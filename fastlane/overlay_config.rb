require "open3"

module OverlayConfig
  ROOT_DIR = File.expand_path("..", __dir__)
  SETTING_SCRIPT = File.join(ROOT_DIR, "scripts", "overlay_setting.sh")

  def self.setting(name)
    environment_value = ENV[name]&.strip
    return environment_value unless environment_value.nil? || environment_value.empty?

    stdout, stderr, status = Open3.capture3(SETTING_SCRIPT, name, chdir: ROOT_DIR)
    unless status.success?
      raise "Unable to read #{name}: #{stderr.strip}"
    end

    value = stdout.strip
    raise "Overlay setting #{name} is empty" if value.empty?

    value
  end
end
