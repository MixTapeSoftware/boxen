#!/usr/bin/env bash
set -euo pipefail
source /etc/sandbox-persistent.sh
npm install --global playwright@1.61.1 @playwright/test@1.61.1
playwright install chromium
# Wallaby expects google-chrome and chromedriver. Install an exact matching pair
# instead of combining Playwright's Chromium with an unrelated latest driver.
version=155.0.8059.39
case "$(uname -m)" in
  x86_64)
    platform=linux64
    chrome_sum=55672d1f392fd3e7b7a08621b6e804e6bcb39d40cf155504abb74b3a021ea8ea
    driver_sum=a65f025c692e686ec2a21fa6b9639c69fa9813683a47af9cabf1ba0b1f453e42 ;;
  aarch64|arm64)
    platform=linux-arm64
    chrome_sum=b9d44e5d183260ca941a4c4d8d21c8a437d81ef778a489047ef98968b0475dc5
    driver_sum=e375914dc2ee52c38ffc6db4ee8276b462a2872f94ca458c18d787e0f761b129 ;;
  *) echo 'Unsupported Chrome architecture' >&2; exit 1 ;;
esac
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
destination="$HOME/.local/share/boxen/chrome/$version"
mkdir -p "$destination"
for artifact in chrome chromedriver; do
  curl -fsSL "https://storage.googleapis.com/chrome-for-testing-public/$version/$platform/$artifact-$platform.zip" -o "$tmp/$artifact.zip"
done
printf '%s  %s\n%s  %s\n' "$chrome_sum" "$tmp/chrome.zip" "$driver_sum" "$tmp/chromedriver.zip" | sha256sum -c --quiet -
for artifact in chrome chromedriver; do
  unzip -qo "$tmp/$artifact.zip" -d "$destination"
done
ln -sfn "$destination/chrome-$platform/chrome" "$HOME/.local/bin/google-chrome"
ln -sfn "$destination/chromedriver-$platform/chromedriver" "$HOME/.local/bin/chromedriver"
google-chrome --version
chromedriver --version
