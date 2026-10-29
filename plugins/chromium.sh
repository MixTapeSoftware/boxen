# Playwright with Chromium, and a matched Chrome for Testing and ChromeDriver.
PLUGIN_EGRESS_HOSTS="cdn.playwright.dev playwright.download.prss.microsoft.com googlechromelabs.github.io storage.googleapis.com registry.npmjs.org"
plugin_install() { box_guest root chromium-root.sh && box_guest user chromium.sh; }
