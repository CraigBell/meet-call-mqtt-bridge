# Changelog

## Unreleased

- Jabra-only Alexa ducking (any video call); removed Meet Chrome/OpenDeck MQTT publishing.
- OpenDeck mute and hang-up on Default/Meet/Teams/Zoom control the Engage 75 over shared HID (no seize); volume on Meet/Teams/Zoom is Jabra, Default stays Alexa.
- Teams/Zoom camera, hand, and blur use System Events shortcuts after focusing the app.

## 0.1.1

- Support JSON config file for MQTT settings when env vars are unavailable.
- Add OpenDeck quick install and troubleshooting notes.

## 0.1.0

- Add meeting-state MQTT publishing for Home Assistant automations.
- Add Meet call detector in the Chrome extension.
- Remove hardcoded MQTT defaults; use environment variables.
- Document HA sensor/binary sensor/automation examples.
