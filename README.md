# Appcircle _Ostorlab Security Scan_ component

Uploads the built **APK, AAB or IPA** to [Ostorlab](https://www.ostorlab.co) and starts a security
scan in your Ostorlab organization. It can also wait for the result and break the pipeline when the
scan risk rating is too high.

The step follows Ostorlab's
[Run Ostorlab as a Workflow Step](https://docs.ostorlab.co/integrations/appcircle/#run-ostorlab-as-a-workflow-step)
guide: it installs the Ostorlab CLI in a Python virtual environment in the step's temporary folder
and runs `ostorlab ci-scan run`.

It scans whatever the build produced, so it works on Java / Kotlin, Objective-C / Swift,
React Native and Flutter projects alike. Run it after the step that signs the application, for
example **Android Sign** or **Xcodebuild for Devices**.

> Use either the Ostorlab webhook or this step for a build profile, not both. Otherwise every
> build is scanned twice.

## Before You Start

- An Ostorlab API key. In Ostorlab, open **Integrations/API → API Keys**, click **New API Key** and
  copy the key.
- Python 3.13 or later on the runner. The Appcircle cloud runners have it.
- For self-hosted runners, outbound access to `api.ostorlab.co` and `pypi.org`.

Store the key as a secret:

1. In Appcircle, open **Build → Environment variables** and click **Add variable group**, for
   example `OSTORLAB`.
2. Select **Secret**, enter `OSTORLAB_API_KEY` as the key and your Ostorlab API key as the value.
3. In the build profile configuration, open the **Environment** tab and select the `OSTORLAB`
   group.

The **Ostorlab API Key** input defaults to `$OSTORLAB_API_KEY`, so nothing else is needed.

## Required Input Variables

- `AC_OSTORLAB_API_KEY`: Ostorlab API Key. Defaults to `$OSTORLAB_API_KEY`. When the reference
  is left unresolved, the step reads `OSTORLAB_API_KEY` directly.
- `AC_OSTORLAB_SCAN_PROFILE`: Scan Profile. `fast_scan` (default) runs static analysis only,
  `full_scan` runs static, dynamic and backend analysis.

## Optional Input Variables

- `AC_OSTORLAB_ARTIFACT_PATH`: Artifact Path. The APK, AAB or IPA, or the folder holding it. When
  empty the step tries `AC_SIGNED_APK_PATH`, `AC_APK_PATH`, `AC_SIGNED_AAB_PATH`, `AC_AAB_PATH`,
  then the `.ipa` under `AC_EXPORT_DIR` and `AC_OUTPUT_DIR`. iOS exposes no IPA path variable,
  which is why a folder is accepted. The asset type (`android-apk`, `android-aab`, `ios-ipa`)
  follows from the extension.
- `AC_OSTORLAB_SCAN_TITLE`: Scan Title shown in Ostorlab. Defaults to `Appcircle scan`.
- `AC_OSTORLAB_BREAK_ON_RISK_RATING`: Break On Risk Rating. `none` (default), `high`, `medium`,
  `low`, `potentially` or `hardening`. When set, the step waits for the scan and breaks the
  pipeline when the risk rating is **higher** than this value, so `high` breaks only on a
  `Critical` rating. `none` creates the scan and does not wait for the result.
- `AC_OSTORLAB_MAX_WAIT_MINUTES`: Max Wait Minutes. How long to wait for the result when Break On
  Risk Rating is set, default `30`. The step fails if the scan does not finish in time.
- `AC_OSTORLAB_TEST_CREDENTIALS_LOGIN`, `AC_OSTORLAB_TEST_CREDENTIALS_PASSWORD`: Credentials the
  Full Scan uses to log in to the application. Set both or neither. Keep the password in a secret
  environment variable.
- `AC_OSTORLAB_UI_PROMPTS`: UI Prompts. Natural language instructions that tell the scanner how to
  navigate the application, one per line as `name: action`:

  ```
  accept-terms: Scroll down and tap the 'Accept Terms' checkbox.
  submit: Tap the 'Submit' button to complete the login process.
  ```

- `AC_OSTORLAB_EXTRA_ARGUMENTS`: Extra Arguments. Any other `ostorlab ci-scan run` option, split
  like a shell command line, for example `--test-credentials-role admin --ui-prompt-id 12` or
  `--sbom sbom.json`. See the
  [full option list](https://docs.ostorlab.co/integrations/bitrise/#additional-options).
- `AC_OSTORLAB_CLI_VERSION`: Ostorlab CLI Version to install, for example `2.22.14`. When empty
  the latest version is installed.
- `AC_OSTORLAB_PYTHON_PATH`: Python Path. A Python 3.13 or later. When empty the step tries
  `python3.14`, `python3.13` and `python3` on `PATH`.

## Output Variables

- `AC_OSTORLAB_SCAN_ID`: The ID of the scan created in Ostorlab.
- `AC_OSTORLAB_RISK_RATING`: The risk rating of the scan, for example `High`. Empty when the step
  does not wait for the result.
- `AC_OSTORLAB_SCANNED_ARTIFACT`: The artifact that was uploaded.

The outputs are exported on the failing path too, so a broken risk gate still leaves the scan ID
for the following steps.

## Build Log

The API key and the test password are masked in the log. The log closes with a summary:

```
  Artifact              app-release.apk
  Asset type            android-apk
  Scan profile          fast_scan
  Scan ID               4242
  Risk rating           Critical
  Break on risk rating  high
  Verdict               pipeline breaks
```

## Troubleshooting

| Message | What to check |
| --- | --- |
| Your Ostorlab subscription does not cover this application or scan profile | Contact your Ostorlab account manager. |
| The Ostorlab CLI needs Python 3.13 or later | Install a newer Python on the runner, or set Python Path to its full path. |
| The Ostorlab CLI could not be installed | Check that the runner can reach `pypi.org`. |
| The scan did not finish within N minutes | Raise Max Wait Minutes, or follow the scan in Ostorlab. |

## Running tests

Requires the [RSpec](https://rspec.info) gem and the Ruby standard library. No Gemfile or
Bundler needed.

```bash
ruby test/test_main.rb
```

The end to end examples run `main.rb` the way the runner does, against a stand-in `python3.13`
that lays out a fake `pip` and `ostorlab` in the virtual environment, so no network, Python or
Ostorlab account is needed.

## Contributing

Source: https://github.com/appcircleio/appcircle-ostorlab-security-scan-component
