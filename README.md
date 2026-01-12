# Meet Call MQTT Bridge

[![Build and bundle the Stream Deck plugin](https://github.com/CraigBell/meet-call-mqtt-bridge/actions/workflows/streamdeck-plugin-build.yml/badge.svg)](https://github.com/CraigBell/meet-call-mqtt-bridge/actions/workflows/streamdeck-plugin-build.yml)
[![GitHub release](https://img.shields.io/github/v/release/CraigBell/meet-call-mqtt-bridge)](https://github.com/CraigBell/meet-call-mqtt-bridge/releases)
[![License](https://img.shields.io/github/license/CraigBell/meet-call-mqtt-bridge)](LICENSE)

A Stream Deck/OpenDeck plugin + Chrome extension fork that controls Google Meet and publishes call state to MQTT so Home Assistant automations can react (e.g., lower Echo volume during calls).

## What it does

- Uses the original Google Meet control buttons (mic, camera, leave call, etc.)
- Publishes meeting state changes to MQTT (`true` for in-call, `false` for not in-call)
- Works with OpenDeck or the Stream Deck desktop app

## Differences from upstream

- Adds MQTT publishing for meeting state
- Adds a Meet call detector in the Chrome extension
- Defaults are removed; MQTT is configured via environment variables

## Setup

### 1) Install the OpenDeck/Stream Deck plugin

OpenDeck looks for plugins in:

`~/Library/Application Support/opendeck/plugins/com.chrisregado.googlemeet.sdPlugin`

If you need to point OpenDeck at a plugin file, use:

`~/Library/Application Support/opendeck/plugins/com.chrisregado.googlemeet.sdPlugin/manifest.json`

### 2) Install the Chrome extension

Chrome -> `chrome://extensions` -> enable Developer mode -> Load unpacked -> select:

`browser-extension`

### 3) Configure MQTT

Set environment variables for the plugin process (OpenDeck or Stream Deck launcher):

- `MQTT_URL` (required), e.g. `mqtt://broker.local:1883`
- `MQTT_USER` (optional)
- `MQTT_PASS` (optional)
- `MEET_MQTT_TOPIC` (optional, default: `meet/call_active`)

## Home Assistant examples

### Sensor

```yaml
mqtt:
  sensor:
    - name: "Jabra Call Status"
      state_topic: "meet/call_active"
      value_template: >-
        {% if value | lower == 'true' %}
          on-air
        {% else %}
          off-air
        {% endif %}
```

### Binary sensor (preferred)

```yaml
mqtt:
  binary_sensor:
    - name: "Jabra Call Active"
      state_topic: "meet/call_active"
      payload_on: "true"
      payload_off: "false"
```

### Automation example

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

## Building the plugin (macOS)

```bash
cd streamdeck-plugin
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
rm -rf ../com.chrisregado.googlemeet.sdPlugin/dist/macos
pyinstaller --clean --dist "../com.chrisregado.googlemeet.sdPlugin/dist/macos" src/main.py
rm -rf build
```

## Attribution

This project is a fork of https://github.com/ChrisRegado/streamdeck-googlemeet and retains its action UUIDs and UI assets.

## License

See `LICENSE`.
