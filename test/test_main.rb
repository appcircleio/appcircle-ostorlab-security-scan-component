# ─── Coverage (must start before loading main.rb) ─────────────────────────────
unless defined?(Coverage) && Coverage.running?
  require 'coverage'
  Coverage.start
end

# ─── Dependencies ─────────────────────────────────────────────────────────────
require 'rspec'
require 'rspec/core/formatters/base_formatter'
require 'fileutils'
require 'json'
require 'open3'
require 'rbconfig'
require 'stringio'
require 'tmpdir'

MAIN_RB = File.expand_path('../main.rb', __dir__)

# ─── Custom Formatter ─────────────────────────────────────────────────────────
class ReadableFormatter < RSpec::Core::Formatters::BaseFormatter
  RSpec::Core::Formatters.register(
    self,
    :example_group_started,
    :example_group_finished,
    :example_passed,
    :example_failed,
    :example_pending,
    :dump_summary
  )

  PASS  = "\e[32;1m[ PASS ]\e[0m"
  FAIL  = "\e[31;1m[ FAIL ]\e[0m"
  ERROR = "\e[31;1m[ERROR ]\e[0m"
  SKIP  = "\e[33;1m[ SKIP ]\e[0m"

  DIVIDER     = "\e[90m#{'─' * 72}\e[0m"
  DIVIDER_FAT = "\e[90m#{'═' * 72}\e[0m"

  GROUP_COLORS = [
    "\e[34;1m",
    "\e[35;1m",
    "\e[36;1m",
    "\e[33;1m",
  ].freeze

  def initialize(output)
    super
    @depth    = 0
    @top_idx  = -1
    @failures = []
    @counts   = { passed: 0, failed: 0, pending: 0 }
  end

  def example_group_started(notification)
    group = notification.group
    if group.parent_groups.size <= 1
      output.puts if @depth.zero?
      @top_idx = (@top_idx + 1) % GROUP_COLORS.size
      output.puts "  #{GROUP_COLORS[@top_idx]}#{group.description}\e[0m"
    else
      output.puts "    #{'  ' * (@depth - 1)}\e[90m▸ \e[0m\e[37m#{group.description}\e[0m"
    end
    @depth += 1
  end

  def example_group_finished(_notification)
    @depth -= 1 if @depth > 0
  end

  def example_passed(notification)
    @counts[:passed] += 1
    print_example(PASS, notification.example)
  end

  def example_failed(notification)
    @counts[:failed] += 1
    ex    = notification.example
    exc   = ex.execution_result.exception
    badge = exc.is_a?(RSpec::Expectations::ExpectationNotMetError) ? FAIL : ERROR
    print_example(badge, ex)
    @failures << notification
  end

  def example_pending(notification)
    @counts[:pending] += 1
    ex = notification.example
    output.puts "    #{'  ' * [0, @depth - 1].max}#{SKIP}  #{ex.description}"
  end

  def dump_summary(notification)
    output.puts
    output.puts DIVIDER_FAT

    unless @failures.empty?
      output.puts "\n  \e[1;31mFailures:\e[0m\n"
      @failures.each_with_index do |n, i|
        ex  = n.example
        exc = ex.execution_result.exception
        output.puts "  \e[1m#{i + 1}) #{ex.full_description}\e[0m"
        exc.message.lines.first(6).each { |line| output.puts "     \e[31m#{line.rstrip}\e[0m" }
        output.puts "     \e[90m# #{ex.location}\e[0m"
        output.puts
      end
      output.puts DIVIDER
    end

    t   = notification.examples.size
    p   = @counts[:passed]
    f   = @counts[:failed]
    s   = @counts[:pending]
    sec = format('%.3fs', notification.duration)

    parts = ["\e[32m#{p} passed\e[0m"]
    parts << "\e[31m#{f} failed\e[0m"  if f > 0
    parts << "\e[33m#{s} pending\e[0m" if s > 0

    overall = f.zero? ? "\e[32;1m✔  All #{t} tests passed\e[0m" : "\e[31;1m✖  #{f} of #{t} tests failed\e[0m"
    output.puts "\n  #{overall}"
    output.puts "  #{parts.join('  |  ')}  \e[90m(#{sec})\e[0m"
    output.puts DIVIDER_FAT
  end

  private

  def print_example(badge, example)
    indent = '  ' * [0, @depth - 1].max
    time   = format('%.3fs', example.execution_result.run_time)
    output.puts "    #{indent}#{badge}  #{example.description}  \e[90m(#{time})\e[0m"
  end
end


# ─── Load main.rb (top-level execution is guarded by __FILE__ == $PROGRAM_NAME)
require_relative '../main.rb'

# ─── Global State Helpers ─────────────────────────────────────────────────────
INPUT_KEYS = %w[
  AC_STEP_TEMP AC_TEMP_DIR AC_OUTPUT_DIR AC_ENV_FILE_PATH AC_EXPORT_DIR
  AC_APK_PATH AC_AAB_PATH AC_SIGNED_APK_PATH AC_SIGNED_AAB_PATH OSTORLAB_API_KEY
  AC_OSTORLAB_API_KEY AC_OSTORLAB_ARTIFACT_PATH AC_OSTORLAB_SCAN_PROFILE AC_OSTORLAB_SCAN_TITLE
  AC_OSTORLAB_BREAK_ON_RISK_RATING AC_OSTORLAB_MAX_WAIT_MINUTES
  AC_OSTORLAB_TEST_CREDENTIALS_LOGIN AC_OSTORLAB_TEST_CREDENTIALS_PASSWORD
  AC_OSTORLAB_UI_PROMPTS AC_OSTORLAB_EXTRA_ARGUMENTS AC_OSTORLAB_CLI_VERSION AC_OSTORLAB_PYTHON_PATH
].freeze

def reset_inputs
  INPUT_KEYS.each { |key| ENV.delete(key) }
  $step_temp = nil
  $env_file_path = nil
  $secrets = []
end

def capture_abort
  buffer = StringIO.new
  original = $stderr
  $stderr = buffer
  aborted = false
  begin
    yield
  rescue SystemExit
    aborted = true
  ensure
    $stderr = original
  end
  return aborted ? buffer.string : nil
end

def capture_stdout
  buffer = StringIO.new
  original = $stdout
  $stdout = buffer
  begin
    yield
  ensure
    $stdout = original
  end
  return buffer.string
end

def touch_artifact(dir, name)
  FileUtils.mkdir_p(dir)
  path = File.join(dir, name)
  File.write(path, 'binary')
  return path
end

def write_script(path, body)
  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, body)
  FileUtils.chmod(0o755, path)
  return path
end

def base_settings(overrides = {})
  {
    api_key: 'secret-api-key',
    scan_profile: 'fast_scan',
    title: 'Appcircle scan',
    break_on: 'none',
    max_wait_minutes: 30,
    test_credentials: nil,
    ui_prompts: [],
    extra_arguments: [],
    cli_version: nil,
    artifact: '/builds/app-release.apk',
    asset_type: 'android-apk'
  }.merge(overrides)
end

# ─── Canned Ostorlab CLI Output ───────────────────────────────────────────────
# Mirrors what `ostorlab ci-scan run` prints through its console logger.
SCAN_CREATED = "✔ Output: scan_id:4242\n🔹 Scan created with id 4242.\n".freeze
SCAN_PASSED = (SCAN_CREATED + "🔹 Scan done with risk rating Medium.\n").freeze
SCAN_BREACH = (SCAN_CREATED + "🔺 ERROR: The scan risk rating is Critical.\n").freeze
SCAN_STILL_RUNNING = (SCAN_CREATED + "🔺 ERROR: The scan is still running.\n").freeze
SCAN_SUBSCRIPTION = "🔺 ERROR: Could not start the scan. The app is not included in your subscription.\n".freeze
PIP_PYTHON_TOO_OLD = "ERROR: Package 'ostorlab' requires a different Python: 3.11.6 not in '>=3.13'\n" \
                     "ERROR: No matching distribution found for ostorlab\n".freeze

# ─── Fake Python / pip / ostorlab Helper ──────────────────────────────────────
# A stand-in `python3.13` that answers the version probe and lays out a venv
# holding a fake pip and a fake ostorlab, so no network or real Python is used.
def plant_fake_python(workspace, fake)
  stubs = File.join(workspace, 'stubs')
  output = File.join(workspace, 'canned-scan-output')
  File.write(output, fake.fetch(:scan_output, SCAN_CREATED))
  pip_output = File.join(workspace, 'canned-pip-output')
  File.write(pip_output, fake.fetch(:pip_output, ''))

  pip = write_script(File.join(stubs, 'pip'), <<~SH)
    #!/bin/sh
    printf '%s\\n' "$@" > "#{workspace}/pip-args"
    /bin/cat "#{pip_output}" >&2
    exit #{fake.fetch(:pip_exit, 0)}
  SH

  ostorlab = write_script(File.join(stubs, 'ostorlab'), <<~SH)
    #!/bin/sh
    printf '%s\\n' "$@" > "#{workspace}/ostorlab-args"
    /bin/cat "#{output}"
    exit #{fake.fetch(:scan_exit, 0)}
  SH

  install_cli = fake.fetch(:install_cli, true)
  python = write_script(File.join(workspace, 'bin', 'python3.13'), <<~SH)
    #!/bin/sh
    if [ "$1" = "-c" ]; then
      echo "#{fake.fetch(:python_version, '3.13.1')}"
      exit 0
    fi
    if [ "$1" = "-m" ] && [ "$2" = "venv" ]; then
      /bin/mkdir -p "$3/bin"
      /bin/cp "#{pip}" "$3/bin/pip"
      #{install_cli ? "/bin/cp \"#{ostorlab}\" \"$3/bin/ostorlab\"" : ':'}
      exit 0
    fi
    exit 1
  SH

  return python
end

# ─── Subprocess Coverage ──────────────────────────────────────────────────────
# The end to end and ENV validation examples run main.rb in a child process, so
# the guarded top-level code only executes there. A small helper preloaded with
# `ruby -r` collects the child's line coverage of main.rb, and it is merged into
# the report printed at the end of the run.
COVERAGE_TMP = Dir.mktmpdir('ostorlab_security_scan_coverage')
at_exit { FileUtils.rm_rf(COVERAGE_TMP) }

CHILD_COVERAGE_HELPER = File.join(COVERAGE_TMP, 'child_coverage.rb')
File.write(CHILD_COVERAGE_HELPER, <<~'RUBY_HELPER')
  require 'coverage'
  require 'json'
  Coverage.start

  at_exit do
    out = ENV['OSTORLAB_TEST_COVERAGE_OUT']
    if out && !out.empty?
      main = Coverage.result.select { |path, _| path.end_with?('/main.rb') }
      File.write(out, JSON.generate(main))
    end
  end
RUBY_HELPER

$subprocess_coverage = nil

def merge_subprocess_coverage(path)
  return unless File.file?(path)

  JSON.parse(File.read(path)).each_value do |lines|
    $subprocess_coverage ||= Array.new(lines.size)
    lines.each_with_index do |count, i|
      next if count.nil?

      $subprocess_coverage[i] = $subprocess_coverage[i].to_i + count
    end
  end
end

# ─── Subprocess Helper ────────────────────────────────────────────────────────
# Pass nil as a value to unset that variable in the child, so the ambient
# environment cannot leak into a missing-variable example.
def run_main(env = {}, fake = {})
  Dir.mktmpdir do |workspace|
    step_temp = File.join(workspace, 'step_temp')
    output_dir = File.join(workspace, 'output')
    env_file = File.join(workspace, 'env_file')
    FileUtils.mkdir_p([step_temp, output_dir])
    FileUtils.touch(env_file)

    python = plant_fake_python(workspace, fake)
    coverage_out = File.join(workspace, 'coverage.json')
    clean_env = INPUT_KEYS.each_with_object({}) { |key, acc| acc[key] = nil }
                          .merge('AC_STEP_TEMP' => step_temp,
                                 'AC_TEMP_DIR' => step_temp,
                                 'AC_OUTPUT_DIR' => output_dir,
                                 'AC_ENV_FILE_PATH' => env_file,
                                 'AC_OSTORLAB_API_KEY' => 'secret-api-key',
                                 'AC_OSTORLAB_PYTHON_PATH' => python,
                                 'OSTORLAB_TEST_COVERAGE_OUT' => coverage_out)
                          .merge(env)
    clean_env = clean_env.merge(yield_env(workspace, env))

    stdout_str, stderr_str, status =
      Open3.capture3(clean_env, RbConfig.ruby, '-r', CHILD_COVERAGE_HELPER, MAIN_RB)
    merge_subprocess_coverage(coverage_out)
    stdout_str = stdout_str.force_encoding(Encoding::UTF_8)
    stderr_str = stderr_str.force_encoding(Encoding::UTF_8)
    outputs = {}
    File.readlines(env_file, chomp: true).reject(&:empty?).each do |line|
      key, value = line.split('=', 2)
      outputs[key] = value
    end

    args_file = File.join(workspace, 'ostorlab-args')
    pip_file = File.join(workspace, 'pip-args')
    yield({
      stdout: stdout_str,
      stderr: stderr_str,
      success: status.success?,
      outputs: outputs,
      workspace: workspace,
      ostorlab_args: File.file?(args_file) ? File.readlines(args_file, chomp: true) : nil,
      pip_args: File.file?(pip_file) ? File.readlines(pip_file, chomp: true) : nil
    })
  end
end

# Values given as a lambda are resolved against the run's workspace, so an
# example can point an input at a file created inside it.
def yield_env(workspace, env)
  env.each_with_object({}) do |(key, value), acc|
    acc[key] = value.call(workspace) if value.respond_to?(:call)
  end
end

def log_of(result)
  return "stdout:\n#{result[:stdout]}\nstderr:\n#{result[:stderr]}"
end

def apk_in(name = 'app-release.apk')
  return ->(workspace) { touch_artifact(File.join(workspace, 'build'), name) }
end

# ─── Tests ────────────────────────────────────────────────────────────────────

# ─── 0. Loading main.rb as a library ──────────────────────────────────────────
RSpec.describe 'loading main.rb' do
  it 'does not run the step when required' do
    expect(defined?(get_scan_command)).to eq('method')
    expect($settings).to be_nil
  end
end

# ─── 1. Environment helpers ───────────────────────────────────────────────────
RSpec.describe '#env_has_key' do
  before { reset_inputs }
  after { reset_inputs }

  it 'returns the value when set' do
    ENV['AC_OSTORLAB_SCAN_TITLE'] = 'Nightly'
    expect(env_has_key('AC_OSTORLAB_SCAN_TITLE')).to eq('Nightly')
  end

  it 'aborts when the key is missing' do
    expect(capture_abort { env_has_key('AC_OSTORLAB_SCAN_TITLE') }).to include('Missing AC_OSTORLAB_SCAN_TITLE')
  end
end

RSpec.describe '#env_default' do
  before { reset_inputs }
  after { reset_inputs }

  it 'returns the stripped value when set' do
    ENV['AC_OSTORLAB_SCAN_TITLE'] = '  Nightly  '
    expect(env_default('AC_OSTORLAB_SCAN_TITLE', 'x')).to eq('Nightly')
  end

  it 'returns the default for an unset or blank value' do
    expect(env_default('AC_OSTORLAB_SCAN_TITLE', 'x')).to eq('x')
    ENV['AC_OSTORLAB_SCAN_TITLE'] = '   '
    expect(env_default('AC_OSTORLAB_SCAN_TITLE', 'x')).to eq('x')
  end
end

RSpec.describe '#get_step_temp' do
  before { reset_inputs }
  after { reset_inputs }

  it 'prefers AC_STEP_TEMP' do
    ENV['AC_STEP_TEMP'] = '/tmp/step'
    ENV['AC_TEMP_DIR'] = '/tmp/temp'
    expect(get_step_temp).to eq('/tmp/step')
  end

  it 'falls back to a folder under AC_TEMP_DIR' do
    ENV['AC_TEMP_DIR'] = '/tmp/temp'
    expect(get_step_temp).to eq('/tmp/temp/appcircle_ostorlab_security_scan')
  end

  it 'aborts when neither is set' do
    expect(capture_abort { get_step_temp }).to include('Missing AC_STEP_TEMP or AC_TEMP_DIR')
  end
end

# ─── 2. Secrets ───────────────────────────────────────────────────────────────
RSpec.describe 'secret masking' do
  before { reset_inputs }
  after { reset_inputs }

  it 'masks every registered secret' do
    register_secret('abc123')
    register_secret('pa55')
    expect(mask_secrets('--api-key=abc123 --test-credentials-password=pa55')).to eq('--api-key=*** --test-credentials-password=***')
  end

  it 'ignores empty and repeated secrets' do
    register_secret(nil)
    register_secret('')
    register_secret('k')
    register_secret('k')
    expect($secrets).to eq(['k'])
  end

  it 'masks the longer secret first when one contains another' do
    register_secret('key')
    register_secret('key-long')
    expect(mask_secrets('key-long key')).to eq('*** ***')
  end

  it 'masks secrets in abort messages' do
    register_secret('abc123')
    message = capture_abort { abort_script('failed with abc123') }
    expect(message).to include('@@[error] failed with ***')
    expect(message).not_to include('abc123')
  end
end

# ─── 3. Input parsing ─────────────────────────────────────────────────────────
RSpec.describe '#get_api_key' do
  before { reset_inputs }
  after { reset_inputs }

  it 'reads the input and registers it as a secret' do
    ENV['AC_OSTORLAB_API_KEY'] = 'from-input'
    expect(get_api_key).to eq('from-input')
    expect($secrets).to include('from-input')
  end

  it 'falls back to OSTORLAB_API_KEY when the input is an unresolved reference' do
    ENV['AC_OSTORLAB_API_KEY'] = '$OSTORLAB_API_KEY'
    ENV['OSTORLAB_API_KEY'] = 'from-group'
    expect(get_api_key).to eq('from-group')
  end

  it 'falls back to OSTORLAB_API_KEY when the input is empty' do
    ENV['OSTORLAB_API_KEY'] = 'from-group'
    expect(get_api_key).to eq('from-group')
  end

  it 'aborts when no key is available' do
    ENV['AC_OSTORLAB_API_KEY'] = '$OSTORLAB_API_KEY'
    expect(capture_abort { get_api_key }).to include('The Ostorlab API key is missing')
  end
end

RSpec.describe '#get_scan_profile' do
  before { reset_inputs }
  after { reset_inputs }

  it 'defaults to fast_scan' do
    expect(get_scan_profile).to eq('fast_scan')
  end

  it 'accepts full_scan in any case' do
    ENV['AC_OSTORLAB_SCAN_PROFILE'] = 'FULL_SCAN'
    expect(get_scan_profile).to eq('full_scan')
  end

  it 'rejects an unsupported profile' do
    ENV['AC_OSTORLAB_SCAN_PROFILE'] = 'full_web_scan'
    expect(capture_abort { get_scan_profile }).to include('Invalid scan profile `full_web_scan`')
  end
end

RSpec.describe '#get_scan_title' do
  before { reset_inputs }
  after { reset_inputs }

  it 'defaults to the documented title' do
    expect(get_scan_title).to eq('Appcircle scan')
  end

  it 'uses the input' do
    ENV['AC_OSTORLAB_SCAN_TITLE'] = 'Release 1.2'
    expect(get_scan_title).to eq('Release 1.2')
  end
end

RSpec.describe '#get_break_on_risk_rating' do
  before { reset_inputs }
  after { reset_inputs }

  it 'defaults to none' do
    expect(get_break_on_risk_rating).to eq('none')
  end

  it 'accepts every listed rating' do
    BREAK_ON_RISK_RATINGS.each do |rating|
      ENV['AC_OSTORLAB_BREAK_ON_RISK_RATING'] = rating.upcase
      expect(get_break_on_risk_rating).to eq(rating)
    end
  end

  it 'rejects critical, which could never break the build' do
    ENV['AC_OSTORLAB_BREAK_ON_RISK_RATING'] = 'critical'
    expect(capture_abort { get_break_on_risk_rating }).to include('Invalid break on risk rating `critical`')
  end
end

RSpec.describe '#get_max_wait_minutes' do
  before { reset_inputs }
  after { reset_inputs }

  it 'defaults to 30' do
    expect(get_max_wait_minutes).to eq(30)
  end

  it 'accepts a positive whole number' do
    ENV['AC_OSTORLAB_MAX_WAIT_MINUTES'] = '90'
    expect(get_max_wait_minutes).to eq(90)
  end

  %w[0 -5 15m 1.5 abc].each do |value|
    it "rejects `#{value}`" do
      ENV['AC_OSTORLAB_MAX_WAIT_MINUTES'] = value
      expect(capture_abort { get_max_wait_minutes }).to include("Invalid max wait minutes `#{value}`")
    end
  end
end

RSpec.describe '#get_test_credentials' do
  before { reset_inputs }
  after { reset_inputs }

  it 'returns nil when both are empty' do
    expect(get_test_credentials).to be_nil
  end

  it 'returns both and masks the password' do
    ENV['AC_OSTORLAB_TEST_CREDENTIALS_LOGIN'] = 'qa@example.com'
    ENV['AC_OSTORLAB_TEST_CREDENTIALS_PASSWORD'] = 'hunter2'
    expect(get_test_credentials).to eq({ login: 'qa@example.com', password: 'hunter2' })
    expect($secrets).to include('hunter2')
  end

  it 'aborts when only the login is set' do
    ENV['AC_OSTORLAB_TEST_CREDENTIALS_LOGIN'] = 'qa@example.com'
    expect(capture_abort { get_test_credentials }).to include('need both a login and a password')
  end

  it 'aborts when only the password is set' do
    ENV['AC_OSTORLAB_TEST_CREDENTIALS_PASSWORD'] = 'hunter2'
    expect(capture_abort { get_test_credentials }).to include('need both a login and a password')
  end
end

RSpec.describe '#get_ui_prompts' do
  before { reset_inputs }
  after { reset_inputs }

  it 'returns no prompts when empty' do
    expect(get_ui_prompts).to eq([])
  end

  it 'parses one prompt per line and keeps colons in the action' do
    ENV['AC_OSTORLAB_UI_PROMPTS'] = "login: Tap Login, then type user: qa\n\n accept : Tap 'Accept'\n"
    expect(get_ui_prompts).to eq([
      { name: 'login', action: 'Tap Login, then type user: qa' },
      { name: 'accept', action: "Tap 'Accept'" }
    ])
  end

  ['no separator', ': missing name', 'missing action:'].each do |line|
    it "rejects `#{line}`" do
      ENV['AC_OSTORLAB_UI_PROMPTS'] = "ok: fine\n#{line}"
      expect(capture_abort { get_ui_prompts }).to include('Invalid UI prompt on line 2')
    end
  end
end

RSpec.describe '#get_extra_arguments' do
  before { reset_inputs }
  after { reset_inputs }

  it 'returns no arguments when empty' do
    expect(get_extra_arguments).to eq([])
  end

  it 'splits like a shell' do
    ENV['AC_OSTORLAB_EXTRA_ARGUMENTS'] = %q(--test-credentials-role admin --ui-prompt-id 12 --title-x "a b")
    expect(get_extra_arguments).to eq(['--test-credentials-role', 'admin', '--ui-prompt-id', '12', '--title-x', 'a b'])
  end

  it 'aborts on unbalanced quotes' do
    ENV['AC_OSTORLAB_EXTRA_ARGUMENTS'] = %q(--sbom "unterminated)
    expect(capture_abort { get_extra_arguments }).to include('The extra arguments could not be parsed')
  end
end

RSpec.describe '#get_cli_version' do
  before { reset_inputs }
  after { reset_inputs }

  it 'returns nil when empty' do
    expect(get_cli_version).to be_nil
  end

  %w[2.22.14 3 2.23.0rc1].each do |version|
    it "accepts `#{version}`" do
      ENV['AC_OSTORLAB_CLI_VERSION'] = version
      expect(get_cli_version).to eq(version)
    end
  end

  ['latest', '>=2.0', '2.0; rm -rf /'].each do |version|
    it "rejects `#{version}`" do
      ENV['AC_OSTORLAB_CLI_VERSION'] = version
      expect(capture_abort { get_cli_version }).to include('Invalid Ostorlab CLI version')
    end
  end
end

# ─── 4. Artifact resolution ───────────────────────────────────────────────────
RSpec.describe '#get_artifact_path' do
  around do |example|
    reset_inputs
    Dir.mktmpdir do |dir|
      @dir = dir
      capture_stdout { example.run }
    end
    reset_inputs
  end

  it 'uses the artifact path input' do
    apk = touch_artifact(@dir, 'app.apk')
    ENV['AC_OSTORLAB_ARTIFACT_PATH'] = apk
    expect(get_artifact_path).to eq(apk)
  end

  it 'accepts a folder for the artifact path input' do
    ipa = touch_artifact(@dir, 'App.ipa')
    ENV['AC_OSTORLAB_ARTIFACT_PATH'] = @dir
    expect(get_artifact_path).to eq(ipa)
  end

  it 'prefers the signed APK over the unsigned one' do
    ENV['AC_APK_PATH'] = touch_artifact(@dir, 'app-unsigned.apk')
    ENV['AC_SIGNED_APK_PATH'] = touch_artifact(@dir, 'app-signed.apk')
    expect(get_artifact_path).to eq(ENV['AC_SIGNED_APK_PATH'])
  end

  it 'uses the unsigned APK when no signed one exists' do
    ENV['AC_SIGNED_APK_PATH'] = File.join(@dir, 'missing.apk')
    ENV['AC_APK_PATH'] = touch_artifact(@dir, 'app.apk')
    expect(get_artifact_path).to eq(ENV['AC_APK_PATH'])
  end

  it 'uses the signed AAB' do
    ENV['AC_SIGNED_AAB_PATH'] = touch_artifact(@dir, 'app.aab')
    expect(get_artifact_path).to eq(ENV['AC_SIGNED_AAB_PATH'])
  end

  it 'finds the IPA under AC_EXPORT_DIR' do
    export = File.join(@dir, 'export')
    ipa = touch_artifact(export, 'App.ipa')
    ENV['AC_EXPORT_DIR'] = export
    expect(get_artifact_path).to eq(ipa)
  end

  it 'aborts when the input points at a missing file' do
    ENV['AC_OSTORLAB_ARTIFACT_PATH'] = File.join(@dir, 'missing.apk')
    expect(capture_abort { get_artifact_path }).to include('does not exist')
  end

  it 'aborts on an unsupported extension' do
    ENV['AC_OSTORLAB_ARTIFACT_PATH'] = touch_artifact(@dir, 'App.xcarchive.zip')
    expect(capture_abort { get_artifact_path }).to include('Ostorlab cannot scan `.zip` files')
  end

  it 'aborts on a folder without artifacts' do
    ENV['AC_OSTORLAB_ARTIFACT_PATH'] = @dir
    expect(capture_abort { get_artifact_path }).to include('No APK, AAB or IPA found')
  end

  it 'aborts when nothing can be found' do
    ENV['AC_EXPORT_DIR'] = @dir
    expect(capture_abort { get_artifact_path }).to include('No artifact to scan')
  end
end

RSpec.describe '#pick_single_artifact' do
  it 'warns and picks the first when several are found' do
    out = capture_stdout { expect(pick_single_artifact(['/a/x.apk', '/a/y.ipa'], '/a')).to eq('/a/x.apk') }
    expect(out).to include('@@[warning] 2 artifacts found in /a')
  end
end

RSpec.describe '#get_asset_type' do
  it 'maps each extension to the CLI asset type' do
    expect(get_asset_type('/a/app.apk')).to eq('android-apk')
    expect(get_asset_type('/a/app.AAB')).to eq('android-aab')
    expect(get_asset_type('/a/App.ipa')).to eq('ios-ipa')
  end
end

# ─── 5. Python discovery ──────────────────────────────────────────────────────
RSpec.describe 'Python discovery' do
  around do |example|
    reset_inputs
    original_path = ENV['PATH']
    Dir.mktmpdir do |dir|
      @dir = dir
      capture_stdout { example.run }
    end
    ENV['PATH'] = original_path
    reset_inputs
  end

  def fake_python(name, version)
    write_script(File.join(@dir, name), "#!/bin/sh\necho \"#{version}\"\n")
  end

  it 'reads the version of a Python' do
    expect(get_python_version(fake_python('python3.13', '3.13.2'))).to eq('3.13.2')
  end

  it 'returns nil for a missing or broken Python' do
    expect(get_python_version(File.join(@dir, 'nope'))).to be_nil
    expect(get_python_version(write_script(File.join(@dir, 'broken'), "#!/bin/sh\nexit 1\n"))).to be_nil
    expect(get_python_version(fake_python('weird', 'Python three'))).to be_nil
  end

  it 'compares against 3.13' do
    expect(python_supported?('3.13.0')).to be(true)
    expect(python_supported?('3.14.1')).to be(true)
    expect(python_supported?('4.0.0')).to be(true)
    expect(python_supported?('3.12.9')).to be(false)
    expect(python_supported?(nil)).to be(false)
  end

  it 'uses the Python Path input' do
    ENV['AC_OSTORLAB_PYTHON_PATH'] = fake_python('custom-python', '3.13.0')
    expect(find_python).to eq(ENV['AC_OSTORLAB_PYTHON_PATH'])
  end

  it 'aborts when the Python Path input is too old' do
    ENV['AC_OSTORLAB_PYTHON_PATH'] = fake_python('custom-python', '3.11.6')
    expect(capture_abort { find_python }).to include('is 3.11.6, the Ostorlab CLI needs 3.13 or later')
  end

  it 'aborts when the Python Path input cannot run' do
    ENV['AC_OSTORLAB_PYTHON_PATH'] = File.join(@dir, 'missing-python')
    expect(capture_abort { find_python }).to include('could not be run')
  end

  it 'picks the first supported candidate on PATH' do
    fake_python('python3', '3.11.6')
    fake_python('python3.13', '3.13.1')
    ENV['PATH'] = @dir
    expect(find_python).to eq('python3.13')
  end

  it 'aborts and lists what it found when every candidate is too old' do
    fake_python('python3', '3.11.6')
    ENV['PATH'] = @dir
    message = capture_abort { find_python }
    expect(message).to include('needs Python 3.13 or later, found python3 3.11.6')
  end

  it 'aborts when no Python is on PATH' do
    ENV['PATH'] = @dir
    expect(capture_abort { find_python }).to include('none was found')
  end
end

# ─── 6. Installation ──────────────────────────────────────────────────────────
RSpec.describe 'Ostorlab CLI installation helpers' do
  it 'pins the package when a version is given' do
    expect(get_package_spec(nil)).to eq('ostorlab')
    expect(get_package_spec('2.22.14')).to eq('ostorlab==2.22.14')
  end

  it 'points to the Python requirement when pip reports it' do
    expect(get_install_failure_message(PIP_PYTHON_TOO_OLD)).to include('needs Python 3.13 or later')
  end

  it 'points to PyPI access otherwise' do
    expect(get_install_failure_message('connection refused')).to include('reach pypi.org')
  end
end

# ─── 7. Scan command ──────────────────────────────────────────────────────────
RSpec.describe '#get_scan_command' do
  it 'builds the documented command without waiting' do
    expect(get_scan_command('/venv/bin/ostorlab', base_settings)).to eq([
      '/venv/bin/ostorlab', '--api-key=secret-api-key', 'ci-scan', 'run',
      '--scan-profile=fast_scan', '--title=Appcircle scan',
      'android-apk', '/builds/app-release.apk'
    ])
  end

  it 'adds the wait options, credentials, UI prompts and extra arguments before the asset' do
    settings = base_settings(
      break_on: 'high', max_wait_minutes: 45, scan_profile: 'full_scan',
      test_credentials: { login: 'qa', password: 'pw' },
      ui_prompts: [{ name: 'login', action: 'Tap Login' }, { name: 'accept', action: 'Tap Accept' }],
      extra_arguments: ['--test-credentials-role', 'admin'],
      asset_type: 'ios-ipa', artifact: '/builds/App.ipa'
    )
    expect(get_scan_command('ostorlab', settings)).to eq([
      'ostorlab', '--api-key=secret-api-key', 'ci-scan', 'run',
      '--scan-profile=full_scan', '--title=Appcircle scan',
      '--break-on-risk-rating=high', '--max-wait-minutes=45',
      '--test-credentials-login=qa', '--test-credentials-password=pw',
      '--ui-prompt-name=login', '--ui-prompt-action=Tap Login',
      '--ui-prompt-name=accept', '--ui-prompt-action=Tap Accept',
      '--test-credentials-role', 'admin',
      'ios-ipa', '/builds/App.ipa'
    ])
  end
end

RSpec.describe '#get_scan_timeout' do
  it 'allows the upload time only when not waiting' do
    expect(get_scan_timeout('none', 30)).to eq(30 * 60)
  end

  it 'adds the wait time when waiting' do
    expect(get_scan_timeout('medium', 45)).to eq((30 + 45) * 60)
  end
end

# ─── 8. Scan result ───────────────────────────────────────────────────────────
RSpec.describe '#get_scan_result' do
  it 'reads a created scan that was not waited for' do
    expect(get_scan_result(SCAN_CREATED, 0, false)).to eq({ scan_id: '4242', risk_rating: nil, status: :submitted })
  end

  it 'reads a finished scan below the break value' do
    expect(get_scan_result(SCAN_PASSED, 0, false)).to eq({ scan_id: '4242', risk_rating: 'Medium', status: :passed })
  end

  it 'reads a risk breach' do
    expect(get_scan_result(SCAN_BREACH, 2, false)).to eq({ scan_id: '4242', risk_rating: 'Critical', status: :risk_breach })
  end

  it 'reads a scan that is still running' do
    expect(get_scan_result(SCAN_STILL_RUNNING, 2, false)[:status]).to eq(:still_running)
  end

  it 'reads a failure' do
    expect(get_scan_result(SCAN_SUBSCRIPTION, 2, false)).to eq({ scan_id: nil, risk_rating: nil, status: :failed })
    expect(get_scan_result('', nil, false)[:status]).to eq(:failed)
  end

  it 'reads a step timeout before anything else' do
    expect(get_scan_result(SCAN_CREATED, nil, true)[:status]).to eq(:timed_out)
  end

  it 'falls back to the created line for the scan ID' do
    expect(get_scan_result("Scan created with id 77.\n", 0, false)[:scan_id]).to eq('77')
  end
end

RSpec.describe '#get_scan_failure' do
  let(:settings) { base_settings(break_on: 'high', max_wait_minutes: 20) }

  it 'is nil for a passed or submitted scan' do
    expect(get_scan_failure({ status: :passed }, settings, '')).to be_nil
    expect(get_scan_failure({ status: :submitted }, settings, '')).to be_nil
  end

  it 'explains a risk breach' do
    message = get_scan_failure({ status: :risk_breach, risk_rating: 'Critical' }, settings, '')
    expect(message).to include('The scan risk rating is Critical, higher than `high`')
  end

  it 'explains a scan that did not finish' do
    expect(get_scan_failure({ status: :still_running }, settings, '')).to include('did not finish within 20 minutes')
  end

  it 'explains a step timeout' do
    expect(get_scan_failure({ status: :timed_out }, settings, '')).to include('did not finish within 3000 seconds')
  end

  it 'explains a subscription problem' do
    expect(get_scan_failure({ status: :failed }, settings, SCAN_SUBSCRIPTION)).to include('subscription does not cover')
  end

  it 'falls back to a generic failure' do
    expect(get_scan_failure({ status: :failed }, settings, 'boom')).to include('could not be started')
  end
end

# ─── 9. Run command ───────────────────────────────────────────────────────────
RSpec.describe '#run_command' do
  before { reset_inputs }
  after { reset_inputs }

  it 'streams and returns stdout and stderr with the exit code' do
    output = nil
    exit_code = nil
    log = capture_stdout do
      output, exit_code, timed_out = run_command(['/bin/sh', '-c', 'echo out; echo err >&2; exit 3'], 10)
      expect(timed_out).to be(false)
    end
    expect(output).to include("out\n", "err\n")
    expect(exit_code).to eq(3)
    expect(log).to include('@@[command] /bin/sh -c', "out\n", "err\n")
  end

  it 'masks secrets in the logged command and output' do
    register_secret('s3cr3t')
    log = capture_stdout { run_command(['/bin/sh', '-c', 'echo s3cr3t', '--api-key=s3cr3t'], 10) }
    expect(log).not_to include('s3cr3t')
    expect(log).to include('--api-key=***')
  end

  it 'masks a secret that holds characters the shell would escape' do
    register_secret('ab+c/d=e$f')
    log = capture_stdout { run_command(['/bin/echo', '--api-key=ab+c/d=e$f', 'two words'], 10) }
    expect(log).to include("@@[command] /bin/echo --api-key=*** two\\ words\n")
    expect(log).not_to include('ab+c')
  end

  it 'passes the environment to the command' do
    output = nil
    capture_stdout { output, = run_command(['/bin/sh', '-c', 'echo $COLUMNS'], 10, { 'COLUMNS' => '1000' }) }
    expect(output.strip).to eq('1000')
  end

  it 'reads the output as UTF-8 and replaces invalid bytes' do
    output = nil
    capture_stdout { output, = run_command(['/bin/sh', '-c', "printf '\\360\\237\\224\\271 ok \\377\\n'"], 10) }
    expect(output.encoding).to eq(Encoding::UTF_8)
    expect(output).to be_valid_encoding
    expect(output).to eq("🔹 ok ?\n")
    expect(output).to match(/ok/)
  end

  it 'terminates the whole process group on timeout' do
    output = nil
    timed_out = nil
    started = monotonic_now
    capture_stdout { output, _, timed_out = run_command(['/bin/sh', '-c', 'sleep 30 & sleep 30'], 1) }
    expect(timed_out).to be(true)
    expect(monotonic_now - started).to be < 15
  end

  it 'aborts when the command does not exist' do
    message = capture_abort { capture_stdout { run_command(['/nonexistent/ostorlab'], 5) } }
    expect(message).to include('/nonexistent/ostorlab was not found on this runner')
  end
end

RSpec.describe '#run_checked_command' do
  it 'returns the output and exit code' do
    capture_stdout do
      expect(run_checked_command(['/bin/sh', '-c', 'echo hi; exit 4'], 10)).to eq(["hi\n", 4])
    end
  end

  it 'aborts on timeout' do
    message = capture_abort { capture_stdout { run_checked_command(['/bin/sh', '-c', 'sleep 30'], 1) } }
    expect(message).to include('`sh` exceeded the 1 second timeout')
  end
end

RSpec.describe '#signal_process_group' do
  it 'returns false for a process group that does not exist' do
    expect(signal_process_group(2_147_483_000, 0)).to be(false)
  end
end

# ─── 10. Outputs and summary ──────────────────────────────────────────────────
RSpec.describe '#write_environment_variables' do
  after { $env_file_path = nil }

  it 'appends each output' do
    Dir.mktmpdir do |dir|
      $env_file_path = File.join(dir, 'env')
      write_environment_variables({ 'A' => '1', 'B' => nil })
      expect(File.read($env_file_path)).to eq("A=1\nB=\n")
    end
  end

  it 'warns when AC_ENV_FILE_PATH is not set' do
    $env_file_path = nil
    expect(capture_stdout { write_environment_variables({ 'A' => '1' }) }).to include('AC_ENV_FILE_PATH is not set')
  end

  it 'aborts when the file cannot be written' do
    $env_file_path = '/nonexistent/dir/env'
    expect(capture_abort { write_environment_variables({ 'A' => '1' }) }).to include('@@[error]')
  end
end

RSpec.describe '#get_step_outputs' do
  it 'exports the scan ID, risk rating and artifact' do
    outputs = get_step_outputs({ scan_id: '4242', risk_rating: 'High' }, '/a/app.apk')
    expect(outputs).to eq({
      'AC_OSTORLAB_SCAN_ID' => '4242',
      'AC_OSTORLAB_RISK_RATING' => 'High',
      'AC_OSTORLAB_SCANNED_ARTIFACT' => '/a/app.apk'
    })
  end
end

RSpec.describe '#print_summary' do
  it 'summarises a scan that was not waited for' do
    out = capture_stdout { print_summary({ scan_id: '4242', risk_rating: nil }, base_settings, nil) }
    expect(out).to include('Scan ID               4242', 'not waited for', 'none (report only)', 'pipeline continues')
  end

  it 'summarises a breaking scan' do
    settings = base_settings(break_on: 'high')
    out = capture_stdout { print_summary({ scan_id: nil, risk_rating: nil }, settings, 'broke') }
    expect(out).to include('not created', 'Risk rating           unknown', 'Break on risk rating  high', 'pipeline breaks')
  end
end

# ─── 11. End to end ───────────────────────────────────────────────────────────
RSpec.describe 'main.rb end to end' do
  context 'positive path – scan created without waiting' do
    it 'installs the CLI, starts the scan and exports the scan ID' do
      run_main({ 'AC_APK_PATH' => apk_in }) do |result|
        expect(result[:success]).to be(true), log_of(result)
        expect(result[:pip_args]).to eq(['install', '--quiet', '--upgrade', 'pip', 'ostorlab'])
        expect(result[:ostorlab_args]).to eq([
          '--api-key=secret-api-key', 'ci-scan', 'run', '--scan-profile=fast_scan',
          '--title=Appcircle scan', 'android-apk', File.join(result[:workspace], 'build', 'app-release.apk')
        ])
        expect(result[:outputs]['AC_OSTORLAB_SCAN_ID']).to eq('4242')
        expect(result[:outputs]['AC_OSTORLAB_RISK_RATING']).to eq('')
        expect(result[:outputs]['AC_OSTORLAB_SCANNED_ARTIFACT']).to end_with('app-release.apk')
        expect(result[:stdout]).to include('the step does not wait for the result')
      end
    end

    it 'never prints the API key or the test password' do
      env = { 'AC_APK_PATH' => apk_in,
              'AC_OSTORLAB_TEST_CREDENTIALS_LOGIN' => 'qa',
              'AC_OSTORLAB_TEST_CREDENTIALS_PASSWORD' => 'hunter2' }
      run_main(env) do |result|
        expect(result[:success]).to be(true), log_of(result)
        expect(result[:stdout] + result[:stderr]).not_to include('secret-api-key', 'hunter2')
        expect(result[:stdout]).to include('--api-key=***', '--test-credentials-password=***')
        expect(result[:ostorlab_args]).to include('--test-credentials-password=hunter2')
      end
    end

    it 'reads the key from OSTORLAB_API_KEY when the input is unresolved' do
      env = { 'AC_APK_PATH' => apk_in, 'AC_OSTORLAB_API_KEY' => '$OSTORLAB_API_KEY', 'OSTORLAB_API_KEY' => 'group-key' }
      run_main(env) do |result|
        expect(result[:success]).to be(true), log_of(result)
        expect(result[:ostorlab_args].first).to eq('--api-key=group-key')
      end
    end
  end

  context 'positive path – waits and the risk rating is acceptable' do
    it 'passes the wait options, a pinned CLI and an IPA from the export folder' do
      env = {
        'AC_EXPORT_DIR' => ->(ws) { File.dirname(touch_artifact(File.join(ws, 'export'), 'App.ipa')) },
        'AC_OSTORLAB_BREAK_ON_RISK_RATING' => 'high',
        'AC_OSTORLAB_MAX_WAIT_MINUTES' => '45',
        'AC_OSTORLAB_SCAN_PROFILE' => 'full_scan',
        'AC_OSTORLAB_CLI_VERSION' => '2.22.14',
        'AC_OSTORLAB_UI_PROMPTS' => 'login: Tap Login'
      }
      run_main(env, { scan_output: SCAN_PASSED }) do |result|
        expect(result[:success]).to be(true), log_of(result)
        expect(result[:pip_args].last).to eq('ostorlab==2.22.14')
        expect(result[:ostorlab_args]).to include('--scan-profile=full_scan', '--break-on-risk-rating=high',
                                                  '--max-wait-minutes=45', '--ui-prompt-name=login',
                                                  '--ui-prompt-action=Tap Login', 'ios-ipa')
        expect(result[:outputs]['AC_OSTORLAB_RISK_RATING']).to eq('Medium')
        expect(result[:stdout]).to include('does not break the pipeline')
      end
    end
  end

  context 'negative path – the risk rating breaks the pipeline' do
    it 'fails after exporting the scan ID and the risk rating' do
      env = { 'AC_SIGNED_AAB_PATH' => apk_in('app-release.aab'), 'AC_OSTORLAB_BREAK_ON_RISK_RATING' => 'high' }
      run_main(env, { scan_output: SCAN_BREACH, scan_exit: 2 }) do |result|
        expect(result[:success]).to be(false)
        expect(result[:ostorlab_args]).to include('android-aab')
        expect(result[:stderr]).to include('The scan risk rating is Critical, higher than `high`')
        expect(result[:outputs]['AC_OSTORLAB_SCAN_ID']).to eq('4242')
        expect(result[:outputs]['AC_OSTORLAB_RISK_RATING']).to eq('Critical')
        expect(result[:stdout]).to include('pipeline breaks')
      end
    end
  end

  context 'negative path – the scan does not finish in time' do
    it 'fails and names the wait time' do
      env = { 'AC_APK_PATH' => apk_in, 'AC_OSTORLAB_BREAK_ON_RISK_RATING' => 'medium' }
      run_main(env, { scan_output: SCAN_STILL_RUNNING, scan_exit: 2 }) do |result|
        expect(result[:success]).to be(false)
        expect(result[:stderr]).to include('did not finish within 30 minutes')
        expect(result[:outputs]['AC_OSTORLAB_SCAN_ID']).to eq('4242')
      end
    end
  end

  context 'negative path – the scan cannot be started' do
    it 'explains a subscription problem' do
      run_main({ 'AC_APK_PATH' => apk_in }, { scan_output: SCAN_SUBSCRIPTION, scan_exit: 2 }) do |result|
        expect(result[:success]).to be(false)
        expect(result[:stderr]).to include('subscription does not cover')
      end
    end
  end

  context 'negative path – installation' do
    it 'explains a Python that is too old for the CLI' do
      run_main({ 'AC_APK_PATH' => apk_in }, { pip_output: PIP_PYTHON_TOO_OLD, pip_exit: 1 }) do |result|
        expect(result[:success]).to be(false)
        expect(result[:stderr]).to include('needs Python 3.13 or later')
        expect(result[:ostorlab_args]).to be_nil
      end
    end

    it 'fails when pip leaves no ostorlab executable' do
      run_main({ 'AC_APK_PATH' => apk_in }, { install_cli: false }) do |result|
        expect(result[:success]).to be(false)
        expect(result[:stderr]).to include('was installed but')
      end
    end

    it 'fails on a Python Path input that is too old' do
      run_main({ 'AC_APK_PATH' => apk_in }, { python_version: '3.12.4' }) do |result|
        expect(result[:success]).to be(false)
        expect(result[:stderr]).to include('is 3.12.4, the Ostorlab CLI needs 3.13 or later')
      end
    end
  end

  context 'negative path – inputs' do
    it 'fails without an API key' do
      run_main({ 'AC_APK_PATH' => apk_in, 'AC_OSTORLAB_API_KEY' => nil }) do |result|
        expect(result[:success]).to be(false)
        expect(result[:stderr]).to include('The Ostorlab API key is missing')
        expect(result[:pip_args]).to be_nil
      end
    end

    it 'fails without an artifact' do
      run_main({}) do |result|
        expect(result[:success]).to be(false)
        expect(result[:stderr]).to include('No artifact to scan')
      end
    end
  end
end

# ─── 12. ENV validation ───────────────────────────────────────────────────────
RSpec.describe 'ENV validation' do
  it 'fails without AC_STEP_TEMP and AC_TEMP_DIR' do
    run_main({ 'AC_APK_PATH' => apk_in, 'AC_STEP_TEMP' => nil, 'AC_TEMP_DIR' => nil }) do |result|
      expect(result[:success]).to be(false)
      expect(result[:stderr]).to include('Missing AC_STEP_TEMP or AC_TEMP_DIR')
    end
  end

  it 'falls back to AC_TEMP_DIR for the venv' do
    run_main({ 'AC_APK_PATH' => apk_in, 'AC_STEP_TEMP' => nil }) do |result|
      expect(result[:success]).to be(true), log_of(result)
      expect(result[:stdout]).to include('appcircle_ostorlab_security_scan/ostorlab-venv')
    end
  end

  it 'still succeeds without AC_ENV_FILE_PATH, with a warning' do
    run_main({ 'AC_APK_PATH' => apk_in, 'AC_ENV_FILE_PATH' => nil }) do |result|
      expect(result[:success]).to be(true), log_of(result)
      expect(result[:stdout]).to include('AC_ENV_FILE_PATH is not set')
    end
  end
end

# ─── Coverage Report ──────────────────────────────────────────────────────────
def print_coverage_report
  return unless defined?(Coverage) && Coverage.running?

  result = begin
    Coverage.result(stop: false, clear: false)
  rescue ArgumentError
    Coverage.result
  end

  data = result[MAIN_RB] || result[File.realpath(MAIN_RB)]
  return puts("\nCoverage: main.rb not found in results") unless data

  if $subprocess_coverage
    data = data.each_with_index.map do |count, i|
      count.nil? ? nil : count + $subprocess_coverage[i].to_i
    end
  end

  lines     = data.each_with_index.reject { |c, _| c.nil? }
  total     = lines.size
  covered   = lines.count { |c, _| c.to_i > 0 }
  pct       = total.positive? ? (covered * 100.0 / total).round(1) : 100.0
  uncovered = lines.select { |c, _| c.to_i == 0 }.map { |_, i| i + 1 }

  color = pct == 100 ? "\e[32;1m" : pct >= 80 ? "\e[33m" : "\e[31m"
  bar_filled = (pct / 5).round
  bar = "\e[32m" + '█' * bar_filled + "\e[90m" + '░' * (20 - bar_filled) + "\e[0m"

  puts "\n\e[90m#{'═' * 72}\e[0m"
  puts '  Coverage Report'
  puts "\e[90m#{'─' * 72}\e[0m"
  puts "  main.rb  #{bar}  #{color}#{pct}%\e[0m  (#{covered}/#{total} lines)"
  if uncovered.any? && uncovered.size <= 20
    puts "  Uncovered lines: \e[90m#{uncovered.join(', ')}\e[0m"
  elsif uncovered.any?
    puts "  Uncovered lines: \e[90m#{uncovered.first(15).join(', ')} … (+#{uncovered.size - 15} more)\e[0m"
  end
  puts "\e[90m#{'═' * 72}\e[0m"
end

# ─── Runner ───────────────────────────────────────────────────────────────────
if __FILE__ == $PROGRAM_NAME
  RSpec.configure do |config|
    config.add_formatter ReadableFormatter
    config.color  = true
    config.order  = :defined
  end

  exit_code = RSpec::Core::Runner.run(['--order', 'defined'])
  print_coverage_report
  exit exit_code
end
