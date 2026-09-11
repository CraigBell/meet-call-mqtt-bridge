# Meet / call bridge

[![Build and bundle the Stream Deck plugin](https://github.com/CraigBell/meet-call-mqtt-bridge/actions/workflows/streamdeck-plugin-build.yml/badge.svg)](https://github.com/CraigBell/meet-call-mqtt-bridge/actions/workflows/streamdeck-plugin-build.yml)
[![GitHub release](https://img.shields.io/github/v/release/CraigBell/meet-call-mqtt-bridge)](https://github.com/CraigBell/meet-call-mqtt-bridge/releases)
[![License](https://img.shields.io/github/license/CraigBell/meet-call-mqtt-bridge)](LICENSE)

OpenDeck keys for Google Meet, Teams, and Zoom, plus Alexa ducking from the **Jabra headset** (any video call).

## What it does

- Google Meet: Chrome plugin still owns camera/hand/chat/reactions; mute and leave are Jabra like the other pages
- Teams and Zoom: Call Bridge keys on their OpenDeck profiles (pick the profile yourself)
- Alexa: Call Bridge watches the Jabra Engage 75 in Core Audio and publishes `jabra/call_active`. Home Assistant does not care which VC app you used

Meet’s Chrome extension does **not** publish MQTT. That was VC-specific and fought Teams.

## Setup

### 1) Install the OpenDeck/Stream Deck Meet plugin

OpenDeck looks for plugins in:

`~/Library/Application Support/opendeck/plugins/com.chrisregado.googlemeet.sdPlugin`

If you need to point OpenDeck at a plugin file, use:

`~/Library/Application Support/opendeck/plugins/com.chrisregado.googlemeet.sdPlugin/manifest.json`

### 2) Install the Chrome extension

Chrome -> `chrome://extensions` -> enable Developer mode -> Load unpacked -> select:

`browser-extension`

Reload the extension after pulling this repo so the old Meet MQTT detector is gone.

## OpenDeck quick install

1. Copy `com.chrisregado.googlemeet.sdPlugin` into:
   `~/Library/Application Support/opendeck/plugins/`
2. Restart OpenDeck.
3. If OpenDeck asks for a plugin file, point it at:
   `~/Library/Application Support/opendeck/plugins/com.chrisregado.googlemeet.sdPlugin/manifest.json`

## Alexa ducking (any VC)

`mac-call-helper` is a small Swift LaunchAgent that:

- Watches the **Jabra** headset in Core Audio (`DeviceIsRunningSomewhere`). When the Engage 75 is in a Softphone call, it publishes retained `true`/`false` on `jabra/call_active`
- Mute and hang-up on every OpenDeck profile (Default / Meet / Teams / Zoom) talk to the Jabra over HID **without seizing** the device, so Jabra Direct keeps the call lock. Each page keeps its own icons
- Meet / Teams / Zoom volume keys adjust Jabra; Default volume stays Alexa
- Camera / hand / blur / Zoom reactions still go to the VC app (System Events shortcuts). Teams meeting reactions have no public shortcut
- Does **not** use the Jabra SDK or exclusive HID seize
- Does **not** scrape Teams windows and does not auto-switch OpenDeck profiles

MQTT config lives on the Mac helper, not in the Meet plugin:

`~/Library/Application Support/call-bridge/config.json`

```json
{
  "MQTT_URL": "mqtt://broker.local:1883",
  "MQTT_USER": "",
  "MQTT_PASS": "",
  "MQTT_TOPIC": "jabra/call_active"
}
```

Install (Mac):

```sh
bash scripts/install-call-bridge.sh
```

Grant **Accessibility** to `~/Library/Application Support/call-bridge/call-bridge` so Teams/Zoom camera keys can run. If macOS asks to control **System Events**, allow it. Alexa ducking and Jabra mute/hang-up do not need that.

```sh
~/Library/Application\ Support/call-bridge/call-bridge doctor
```

Do not reinstall `com.microsoft.teams.sdPlugin`.

### Home Assistant examples

#### Sensor

```yaml
mqtt:
  sensor:
    - name: "Jabra Call Status"
      state_topic: "jabra/call_active"
      value_template: >-
        {% if value | lower == 'true' %}
          on-air
        {% else %}
          off-air
        {% endif %}
```

#### Binary sensor (preferred)

```yaml
mqtt:
  binary_sensor:
    - name: "Jabra Call Active"
      state_topic: "jabra/call_active"
      payload_on: "true"
      payload_off: "false"
```

#### Automation example

```yaml
alias: Jabra / Call-aware Echo Volume
description: Set Echo volume to 0.70 when on-air, revert to 0.80 when off-air
trigger:
  - platform: state
    entity_id: binary_sensor.jabra_call_active
action:
  - service: media_player.volume_set
    target:
      device_id: 2511000a71e24cd7909b73a7cd3936a4
    data:
      volume_level: >
        {% if is_state('binary_sensor.jabra_call_active', 'on') %}
          0.7
        {% else %}
          0.8
        {% endif %}
mode: restart
```

## Building the Meet plugin (macOS)

```bash
cd streamdeck-plugin
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
rm -rf ../com.chrisregado.googlemeet.sdPlugin/dist/macos
pyinstaller --clean --dist "../com.chrisregado.googlemeet.sdPlugin/dist/macos" src/main.py
rm -rf build
```

## Troubleshooting

- **Alexa does not duck**: `call-bridge doctor` should list the Jabra device. Join a call on the headset and confirm `jabra inCall=true` and MQTT `jabra/call_active` is `true`.
- **OpenDeck shows “Disconnected”** on Meet keys: ensure the Chrome extension is enabled and loaded from `browser-extension` in `chrome://extensions`.
- **Chrome extension not connecting**: ad blockers can block `ws://127.0.0.1:2394`;
  allowlist `meet.google.com`.

## Attribution

This project is a fork of https://github.com/ChrisRegado/streamdeck-googlemeet and retains its action UUIDs and UI assets.

## License

See `LICENSE`.
