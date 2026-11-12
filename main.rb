require 'open3'
require 'fileutils'
require 'shellwords'

###### Defaults & Constants
DEFAULT_SCAN_PROFILE = "fast_scan"
DEFAULT_SCAN_TITLE = "Appcircle scan"
DEFAULT_BREAK_ON_RISK_RATING = "none"
DEFAULT_MAX_WAIT_MINUTES = 30

SCAN_PROFILES = ["fast_scan", "full_scan"]

# Ostorlab breaks the build when the scan risk rating is strictly higher than the
# selected value, so `critical` would never break and is left out.
BREAK_ON_RISK_RATINGS = ["none", "high", "medium", "low", "potentially", "hardening"]

###### Ostorlab CLI
OSTORLAB_PACKAGE = "ostorlab"
OSTORLAB_API_KEY_VARIABLE = "OSTORLAB_API_KEY"
MINIMUM_PYTHON_VERSION = [3, 13]
PYTHON_CANDIDATES = ["python3.14", "python3.13", "python3"]
VENV_DIRECTORY = "ostorlab-venv"

INSTALL_TIMEOUT = 900
UPLOAD_TIMEOUT_MINUTES = 30
MINUTE = 60

# The CLI prints through rich, which wraps at 80 columns and colours its output
# when it thinks it is on a terminal. This environment keeps every message on
# one plain line so the step can read the scan ID and risk rating back.
CLI_ENVIRONMENT = {
  "COLUMNS" => "1000",
  "NO_COLOR" => "1",
  "TERM" => "dumb",
  "PYTHONUNBUFFERED" => "1",
  "PIP_DISABLE_PIP_VERSION_CHECK" => "1"
}

SCAN_ID_PATTERNS = [/Output: scan_id:\s*(\S+)/, /Scan created with id ([^\s.]+)/]
RISK_RATING_PATTERNS = [/Scan done with risk rating (\w+)/, /The scan risk rating is (\w+)/]
RISK_BREACH_PATTERN = /The scan risk rating is (\w+)/
SCAN_TIMEOUT_PATTERN = /The scan is still running/
SUBSCRIPTION_PATTERN = /not included in .*subscription/i
PYTHON_TOO_OLD_PATTERN = /Requires-Python|No matching distribution found for ostorlab/i

###### Artifact
ASSET_TYPES = {".apk" => "android-apk", ".aab" => "android-aab", ".ipa" => "ios-ipa"}
SUPPORTED_ARTIFACTS = ASSET_TYPES.keys

ARTIFACT_PATH_VARIABLES = ["AC_SIGNED_APK_PATH", "AC_APK_PATH", "AC_SIGNED_AAB_PATH", "AC_AAB_PATH"]
ARTIFACT_DIR_VARIABLES = ["AC_EXPORT_DIR", "AC_OUTPUT_DIR"]

###### Enviroment Variable Check
def env_has_key(key)
  return (ENV[key] != nil && ENV[key] != "") ? ENV[key] : abort("Missing #{key}.")
end

def env_default(key, default)
  return (ENV[key] != nil && ENV[key].strip != "") ? ENV[key].strip : default
end

def get_step_temp()
  step_temp = env_default("AC_STEP_TEMP", nil)
  return step_temp if step_temp != nil

  temp_dir = env_default("AC_TEMP_DIR", nil)
  if temp_dir == nil
    abort("Missing AC_STEP_TEMP or AC_TEMP_DIR.")
  end

  return "#{temp_dir}/appcircle_ostorlab_security_scan"
end

if __FILE__ == $PROGRAM_NAME

$stdout.sync = true
$step_temp = get_step_temp()
$env_file_path = ENV["AC_ENV_FILE_PATH"]

end # if __FILE__ == $PROGRAM_NAME

$secrets = []

###### Abort Function
def abort_script(error)
  abort("@@[error] #{mask_secrets(error.to_s)}")
end

###### Secret Masking
def register_secret(value)
  $secrets.push(value) if value != nil && value != "" && !$secrets.include?(value)
end

def mask_secrets(text)
  masked = text.to_s.dup
  $secrets.sort_by { |secret| -secret.length }.each { |secret| masked = masked.gsub(secret, "***") }
  return masked
end

# Masks each argument before quoting it, since quoting first would escape the
# special characters of a secret and keep it from matching.
def get_command_log(command)
  return command.map { |arg|
    masked = mask_secrets(arg)
    masked == arg ? arg.shellescape : masked
  }.join(" ")
end

###### Run Command Function
READER_DRAIN_TIMEOUT = 2
REAP_TIMEOUT = 10
KILL_GRACE_TIMEOUT = 3
KILL_POLL_INTERVAL = 0.1

def monotonic_now()
  return Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

# Streams the command output to the build log while it runs, since a scan that
# waits for its result can stay quiet for a long time, and returns it as well.
def run_command(command, timeout, environment = {})
  puts "@@[command] #{get_command_log(command)}"

  output = String.new(encoding: Encoding::UTF_8)
  begin
    stdin, stdout, stderr, wait_thr = Open3.popen3(environment, *command, :pgroup => true)
  rescue Errno::ENOENT
    abort_script("#{command[0]} was not found on this runner.")
  end

  begin
    stdin.close
    lock = Mutex.new
    readers = [read_stream(stdout, output, lock), read_stream(stderr, output, lock)]

    timed_out = wait_thr.join(timeout) == nil
    kill_process_group(wait_thr.pid) if timed_out
    stop_readers(readers, [stdout, stderr])
    status = wait_thr.join(REAP_TIMEOUT) != nil ? wait_thr.value : nil
  ensure
    [stdout, stderr].each { |io| io.close unless io.closed? }
  end

  exit_code = status != nil ? status.exitstatus : nil
  return output, exit_code, timed_out
end

def run_checked_command(command, timeout, environment = {})
  output, exit_code, timed_out = run_command(command, timeout, environment)
  name = File.basename(command[0])
  abort_script("`#{name}` exceeded the #{timeout} second timeout and was terminated.") if timed_out
  abort_script("`#{name}` did not report an exit code.") if exit_code == nil

  return output, exit_code
end

def read_stream(io, buffer, lock)
  return Thread.new do
    begin
      io.each_line do |raw|
        # The CLI prints emoji, and a runner without a UTF-8 locale would read
        # them as invalid US-ASCII, so decode as UTF-8 and drop broken bytes.
        line = raw.dup.force_encoding(Encoding::UTF_8).scrub("?")
        lock.synchronize { buffer << line }
        puts mask_secrets(line.chomp)
      end
    rescue IOError, Errno::EBADF
    end
  end
end

def stop_readers(readers, streams)
  deadline = monotonic_now() + READER_DRAIN_TIMEOUT
  readers.each do |reader|
    remaining = deadline - monotonic_now()
    reader.join(remaining > 0 ? remaining : 0)
  end
  return if readers.none? { |reader| reader.alive? }

  streams.each { |io| io.close unless io.closed? }
  readers.each { |reader| reader.kill if reader.join(KILL_GRACE_TIMEOUT) == nil }
end

def kill_process_group(pid)
  return unless signal_process_group(pid, "TERM")

  deadline = monotonic_now() + KILL_GRACE_TIMEOUT
  while monotonic_now() < deadline
    return unless signal_process_group(pid, 0)

    sleep KILL_POLL_INTERVAL
  end

  signal_process_group(pid, "KILL")
end

def signal_process_group(pid, signal)
  begin
    Process.kill(signal, -pid)
    return true
  rescue Errno::ESRCH, Errno::EPERM
    return false
  end
end

###### Input Parsing
def get_api_key()
  key = env_default("AC_OSTORLAB_API_KEY", nil)
  # An unresolved `$OSTORLAB_API_KEY` reaches the step as the literal text when
  # the variable group is not selected, so read the variable directly then.
  key = nil if key != nil && key.start_with?("$")
  key = env_default(OSTORLAB_API_KEY_VARIABLE, nil) if key == nil

  if key == nil
    abort_script("The Ostorlab API key is missing. Add it as a secret named `#{OSTORLAB_API_KEY_VARIABLE}` " \
                 "to an environment variable group, select the group in the configuration, or set the " \
                 "Ostorlab API Key input.")
  end

  register_secret(key)
  return key
end

#scan_profile - Options: fast_scan, full_scan
def get_scan_profile()
  profile = env_default("AC_OSTORLAB_SCAN_PROFILE", DEFAULT_SCAN_PROFILE).downcase
  unless SCAN_PROFILES.include?(profile)
    abort_script("Invalid scan profile `#{profile}`. Supported values: #{SCAN_PROFILES.join(", ")}.")
  end

  return profile
end

def get_scan_title()
  return env_default("AC_OSTORLAB_SCAN_TITLE", DEFAULT_SCAN_TITLE)
end

#break_on_risk_rating - Options: none, high, medium, low, potentially, hardening
def get_break_on_risk_rating()
  rating = env_default("AC_OSTORLAB_BREAK_ON_RISK_RATING", DEFAULT_BREAK_ON_RISK_RATING).downcase
  unless BREAK_ON_RISK_RATINGS.include?(rating)
    abort_script("Invalid break on risk rating `#{rating}`. Supported values: #{BREAK_ON_RISK_RATINGS.join(", ")}.")
  end

  return rating
end

def get_max_wait_minutes()
  configured = env_default("AC_OSTORLAB_MAX_WAIT_MINUTES", "#{DEFAULT_MAX_WAIT_MINUTES}")
  minutes = configured.to_i
  unless configured =~ /\A\d+\z/ && minutes > 0
    abort_script("Invalid max wait minutes `#{configured}`. A positive whole number of minutes is expected.")
  end

  return minutes
end

def get_test_credentials()
  login = env_default("AC_OSTORLAB_TEST_CREDENTIALS_LOGIN", nil)
  password = env_default("AC_OSTORLAB_TEST_CREDENTIALS_PASSWORD", nil)
  register_secret(password)

  return nil if login == nil && password == nil

  if login == nil || password == nil
    abort_script("Test credentials need both a login and a password. Set both Test Credentials Login " \
                 "and Test Credentials Password, or leave both empty.")
  end

  return {:login => login, :password => password}
end

def get_ui_prompts()
  prompts = []
  configured = env_default("AC_OSTORLAB_UI_PROMPTS", nil)
  return prompts if configured == nil

  configured.each_line.with_index do |line, index|
    next if line.strip.empty?

    name, action = line.split(":", 2).map { |part| part.to_s.strip }
    if name.empty? || action == nil || action.empty?
      abort_script("Invalid UI prompt on line #{index + 1}: `#{line.strip}`. Write one prompt per line " \
                   "as `name: action`.")
    end

    prompts.push({:name => name, :action => action})
  end

  return prompts
end

def get_extra_arguments()
  configured = env_default("AC_OSTORLAB_EXTRA_ARGUMENTS", nil)
  return [] if configured == nil

  begin
    return Shellwords.split(configured)
  rescue ArgumentError => e
    abort_script("The extra arguments could not be parsed: #{e.message}.")
  end
end

def get_cli_version()
  version = env_default("AC_OSTORLAB_CLI_VERSION", nil)
  return nil if version == nil

  unless version =~ /\A\d+(\.\d+)*([A-Za-z0-9.+-]*)\z/
    abort_script("Invalid Ostorlab CLI version `#{version}`. A version such as `2.22.14` is expected.")
  end

  return version
end

###### Artifact Resolution
def get_artifact_path()
  configured = env_default("AC_OSTORLAB_ARTIFACT_PATH", nil)
  return resolve_artifact(configured, "the artifact path input") if configured != nil

  ARTIFACT_PATH_VARIABLES.each do |key|
    value = env_default(key, nil)
    next if value == nil || !File.file?(value)

    puts "Using the artifact from #{key}"
    return resolve_artifact(value, key)
  end

  ARTIFACT_DIR_VARIABLES.each do |key|
    value = env_default(key, nil)
    next if value == nil || !File.directory?(value)

    found = find_artifacts(value)
    next if found.empty?

    puts "Found the artifact under #{key}"
    return pick_single_artifact(found, value)
  end

  abort_script("No artifact to scan. Set the artifact path input, or run this step after the build and " \
               "sign steps so that #{ARTIFACT_PATH_VARIABLES.join(", ")} or an .ipa under " \
               "#{ARTIFACT_DIR_VARIABLES.join(" / ")} is available.")
end

def resolve_artifact(path, origin)
  expanded = File.expand_path(path)
  unless File.exist?(expanded)
    abort_script("The artifact from #{origin} does not exist: #{expanded}")
  end

  return pick_single_artifact(find_artifacts(expanded), expanded) if File.directory?(expanded)

  get_asset_type(expanded)
  return expanded
end

def find_artifacts(directory)
  found = []
  SUPPORTED_ARTIFACTS.each do |extension|
    found.concat(Dir.glob("#{directory}/*#{extension}"))
  end

  return found.sort
end

def pick_single_artifact(found, directory)
  if found.empty?
    abort_script("No APK, AAB or IPA found in #{directory}.")
  end

  if found.length > 1
    puts "@@[warning] #{found.length} artifacts found in #{directory}, scanning the first one. " \
         "Set the artifact path input to choose: #{found.map { |f| File.basename(f) }.join(", ")}"
  end

  return found[0]
end

def get_asset_type(artifact)
  extension = File.extname(artifact).downcase
  asset_type = ASSET_TYPES[extension]
  if asset_type == nil
    abort_script("Ostorlab cannot scan `#{extension}` files. Supported: #{SUPPORTED_ARTIFACTS.join(", ")}. " \
                 "An .xcarchive is not an artifact, export the .ipa first.")
  end

  return asset_type
end

###### Python Discovery
def get_python_version(python)
  begin
    output, status = Open3.capture2e(python, "-c", "import sys; print('%d.%d.%d' % sys.version_info[:3])")
  rescue SystemCallError
    return nil
  end
  return nil unless status.success?

  version = output.strip
  return version =~ /\A\d+\.\d+\.\d+\z/ ? version : nil
end

def python_supported?(version)
  return false if version == nil

  major, minor = version.split(".").map(&:to_i)
  return ([major, minor] <=> MINIMUM_PYTHON_VERSION) >= 0
end

def minimum_python_label()
  return MINIMUM_PYTHON_VERSION.join(".")
end

def find_python()
  configured = env_default("AC_OSTORLAB_PYTHON_PATH", nil)
  if configured != nil
    version = get_python_version(configured)
    if version == nil
      abort_script("The Python at #{configured} could not be run.")
    end
    unless python_supported?(version)
      abort_script("The Python at #{configured} is #{version}, the Ostorlab CLI needs " \
                   "#{minimum_python_label()} or later.")
    end

    puts "Using Python #{version} at #{configured}"
    return configured
  end

  found = []
  PYTHON_CANDIDATES.each do |candidate|
    version = get_python_version(candidate)
    next if version == nil

    if python_supported?(version)
      puts "Using Python #{version} (#{candidate})"
      return candidate
    end

    found.push("#{candidate} #{version}")
  end

  found_label = found.empty? ? "none was found" : "found #{found.join(", ")}"
  abort_script("The Ostorlab CLI needs Python #{minimum_python_label()} or later, #{found_label}. Install a " \
               "newer Python on the runner or set the Python Path input to its full path.")
end

###### Ostorlab CLI Installation
def get_venv_path()
  return "#{$step_temp}/#{VENV_DIRECTORY}"
end

def get_package_spec(version)
  return version != nil ? "#{OSTORLAB_PACKAGE}==#{version}" : OSTORLAB_PACKAGE
end

def install_ostorlab_cli(python, version)
  venv = get_venv_path()
  puts "Installing the Ostorlab CLI in #{venv}"

  output, exit_code = run_checked_command([python, "-m", "venv", venv], INSTALL_TIMEOUT, CLI_ENVIRONMENT)
  abort_script("The Python virtual environment could not be created.\n#{output}") unless exit_code == 0

  pip = "#{venv}/bin/pip"
  command = [pip, "install", "--quiet", "--upgrade", "pip", get_package_spec(version)]
  output, exit_code = run_checked_command(command, INSTALL_TIMEOUT, CLI_ENVIRONMENT)
  unless exit_code == 0
    abort_script(get_install_failure_message(output))
  end

  ostorlab = "#{venv}/bin/ostorlab"
  abort_script("The Ostorlab CLI was installed but #{ostorlab} was not found.") unless File.file?(ostorlab)

  return ostorlab
end

def get_install_failure_message(output)
  if output =~ PYTHON_TOO_OLD_PATTERN
    return "The Ostorlab CLI could not be installed: it needs Python #{minimum_python_label()} or later. " \
           "Install a newer Python on the runner or set the Python Path input to its full path."
  end

  return "The Ostorlab CLI could not be installed. Check that the runner can reach pypi.org.\n#{output}"
end

###### Scan
def get_scan_command(ostorlab, settings)
  command = [ostorlab, "--api-key=#{settings[:api_key]}", "ci-scan", "run",
             "--scan-profile=#{settings[:scan_profile]}",
             "--title=#{settings[:title]}"]

  if waits_for_result?(settings[:break_on])
    command.push("--break-on-risk-rating=#{settings[:break_on]}")
    command.push("--max-wait-minutes=#{settings[:max_wait_minutes]}")
  end

  credentials = settings[:test_credentials]
  if credentials != nil
    command.push("--test-credentials-login=#{credentials[:login]}")
    command.push("--test-credentials-password=#{credentials[:password]}")
  end

  (settings[:ui_prompts] || []).each do |prompt|
    command.push("--ui-prompt-name=#{prompt[:name]}")
    command.push("--ui-prompt-action=#{prompt[:action]}")
  end

  command.concat(settings[:extra_arguments] || [])
  command.push(settings[:asset_type], settings[:artifact])
  return command
end

def waits_for_result?(break_on)
  return break_on != nil && break_on != "none"
end

def get_scan_timeout(break_on, max_wait_minutes)
  minutes = UPLOAD_TIMEOUT_MINUTES
  minutes += max_wait_minutes if waits_for_result?(break_on)
  return minutes * MINUTE
end

def find_match(output, patterns)
  patterns.each do |pattern|
    match = output.match(pattern)
    return match[1] if match != nil
  end

  return nil
end

def get_scan_result(output, exit_code, timed_out)
  result = {
    :scan_id => find_match(output, SCAN_ID_PATTERNS),
    :risk_rating => find_match(output, RISK_RATING_PATTERNS)
  }

  result[:status] =
    if timed_out
      :timed_out
    elsif exit_code == 0
      result[:risk_rating] != nil ? :passed : :submitted
    elsif output =~ RISK_BREACH_PATTERN
      :risk_breach
    elsif output =~ SCAN_TIMEOUT_PATTERN
      :still_running
    else
      :failed
    end

  return result
end

def run_scan(ostorlab, settings)
  puts "Uploading #{File.basename(settings[:artifact])} to Ostorlab as #{settings[:asset_type]}"
  command = get_scan_command(ostorlab, settings)
  timeout = get_scan_timeout(settings[:break_on], settings[:max_wait_minutes])
  output, exit_code, timed_out = run_command(command, timeout, CLI_ENVIRONMENT)

  return get_scan_result(output, exit_code, timed_out), output
end

###### Verdict
def get_scan_failure(result, settings, output)
  case result[:status]
  when :passed, :submitted
    return nil
  when :risk_breach
    return "The scan risk rating is #{result[:risk_rating]}, higher than `#{settings[:break_on]}`, " \
           "which breaks the pipeline."
  when :still_running
    return "The scan did not finish within #{settings[:max_wait_minutes]} minutes. Raise Max Wait Minutes, " \
           "or follow the scan in Ostorlab."
  when :timed_out
    return "The Ostorlab CLI did not finish within #{get_scan_timeout(settings[:break_on], settings[:max_wait_minutes])} " \
           "seconds and was terminated."
  end

  if output =~ SUBSCRIPTION_PATTERN
    return "Your Ostorlab subscription does not cover this application or scan profile. Contact your " \
           "Ostorlab account manager."
  end

  return "The Ostorlab scan could not be started. Check the API key and the log above."
end

def get_risk_rating_label(result, settings)
  return result[:risk_rating] if result[:risk_rating] != nil
  return "not waited for (Break On Risk Rating is none)" unless waits_for_result?(settings[:break_on])

  return "unknown"
end

def print_summary_line(label, value)
  puts "  #{label.ljust(22)}#{value}"
end

def print_summary(result, settings, failure)
  puts "------------------------------------------------------"
  puts "Ostorlab Security Scan Summary"
  print_summary_line("Artifact", File.basename(settings[:artifact]))
  print_summary_line("Asset type", settings[:asset_type])
  print_summary_line("Scan profile", settings[:scan_profile])
  print_summary_line("Scan ID", result[:scan_id] != nil ? result[:scan_id] : "not created")
  print_summary_line("Risk rating", get_risk_rating_label(result, settings))
  print_summary_line("Break on risk rating", settings[:break_on] == "none" ? "none (report only)" : settings[:break_on])
  print_summary_line("Verdict", failure != nil ? "pipeline breaks" : "pipeline continues")
  puts "------------------------------------------------------"
end

###### Environment Variables
def write_environment_variables(values)
  if $env_file_path == nil
    puts "@@[warning] AC_ENV_FILE_PATH is not set, the step outputs are not exported."
    return
  end

  begin
    open($env_file_path, 'a') { |f|
      values.each { |key, value| f.puts "#{key}=#{value}" }
    }
  rescue Exception => e
    abort_script(e)
  end
end

def get_step_outputs(result, artifact)
  return {
    "AC_OSTORLAB_SCAN_ID" => result[:scan_id],
    "AC_OSTORLAB_RISK_RATING" => result[:risk_rating],
    "AC_OSTORLAB_SCANNED_ARTIFACT" => artifact
  }
end

def get_settings()
  artifact = get_artifact_path()
  return {
    :api_key => get_api_key(),
    :scan_profile => get_scan_profile(),
    :title => get_scan_title(),
    :break_on => get_break_on_risk_rating(),
    :max_wait_minutes => get_max_wait_minutes(),
    :test_credentials => get_test_credentials(),
    :ui_prompts => get_ui_prompts(),
    :extra_arguments => get_extra_arguments(),
    :cli_version => get_cli_version(),
    :artifact => artifact,
    :asset_type => get_asset_type(artifact)
  }
end

###############################################################

if __FILE__ == $PROGRAM_NAME

$settings = get_settings()

FileUtils.mkdir_p($step_temp)

$python = find_python()
$ostorlab = install_ostorlab_cli($python, $settings[:cli_version])
$result, $output = run_scan($ostorlab, $settings)

$failure = get_scan_failure($result, $settings, $output)
print_summary($result, $settings, $failure)
write_environment_variables(get_step_outputs($result, $settings[:artifact]))

abort_script($failure) if $failure != nil

if $result[:status] == :submitted
  puts "The scan was created. Follow it in Ostorlab, the step does not wait for the result."
else
  puts "The scan risk rating does not break the pipeline."
end

exit 0

end # if __FILE__ == $PROGRAM_NAME
