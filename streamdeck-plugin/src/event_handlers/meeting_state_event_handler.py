import logging
import os
from urllib.parse import urlparse

try:
    import paho.mqtt.client as mqtt
except Exception:  # pragma: no cover - handled at runtime
    mqtt = None

from event_handlers.base_event_handler import EventHandler


class MeetingStateEventHandler(EventHandler):
    """
    Publishes Google Meet in-call state to MQTT when the browser extension
    reports meeting activity changes.
    """

    def __init__(self, stream_deck: "StreamDeckWebsocketClient", browser_manager: "BrowserWebsocketServer") -> None:
        super().__init__(stream_deck, browser_manager)
        self._logger = logging.getLogger(__name__)
        self._mqtt_client = None
        self._mqtt_topic = None
        self._mqtt_enabled = False
        self._mqtt_connected = False
        self._last_active = None
        self._setup_mqtt()

    def _setup_mqtt(self) -> None:
        if mqtt is None:
            self._logger.error("paho-mqtt not available; meeting state MQTT disabled.")
            return

        mqtt_url = os.environ.get("MQTT_URL")
        if not mqtt_url:
            self._logger.warning("MQTT_URL not set; meeting state MQTT disabled.")
            return
        mqtt_user = os.environ.get("MQTT_USER", "")
        mqtt_pass = os.environ.get("MQTT_PASS", "")
        self._mqtt_topic = os.environ.get("MEET_MQTT_TOPIC") or os.environ.get("MQTT_TOPIC") or "meet/call_active"

        parsed = urlparse(mqtt_url if "://" in mqtt_url else f"mqtt://{mqtt_url}")
        host = parsed.hostname
        port = parsed.port or 1883
        if not host:
            self._logger.error("Invalid MQTT_URL; meeting state MQTT disabled.")
            return

        client = mqtt.Client()
        if mqtt_user or mqtt_pass:
            client.username_pw_set(mqtt_user or None, mqtt_pass or None)
        client.reconnect_delay_set(min_delay=2, max_delay=60)
        client.on_connect = self._on_connect
        client.on_disconnect = self._on_disconnect

        try:
            client.connect_async(host, port, keepalive=30)
            client.loop_start()
        except Exception:
            self._logger.exception("Failed to start MQTT client; meeting state MQTT disabled.")
            return

        self._mqtt_client = client
        self._mqtt_enabled = True
        self._logger.info(f"Meeting state MQTT enabled (broker={host}:{port}, topic={self._mqtt_topic}).")

    def _on_connect(self, client, userdata, flags, rc) -> None:
        if rc == 0:
            self._mqtt_connected = True
            self._logger.info("MQTT connected.")
            if self._last_active is not None:
                self._publish_state(self._last_active, "reconnect")
        else:
            self._logger.warning(f"MQTT connect failed with rc={rc}.")

    def _on_disconnect(self, client, userdata, rc) -> None:
        self._mqtt_connected = False
        if rc != 0:
            self._logger.warning("MQTT disconnected unexpectedly; will retry.")

    def _publish_state(self, active: bool, reason: str) -> None:
        if not self._mqtt_enabled:
            return
        if active == self._last_active and self._mqtt_connected:
            return
        self._last_active = active
        if not self._mqtt_connected:
            self._logger.debug("MQTT not connected; deferring publish.")
            return
        payload = "true" if active else "false"
        try:
            self._mqtt_client.publish(self._mqtt_topic, payload, qos=0, retain=True)
            self._logger.info(f"Meeting state -> {self._mqtt_topic} {payload} ({reason})")
        except Exception:
            self._logger.exception("Failed to publish meeting state to MQTT.")

    async def on_browser_event(self, event: dict) -> None:
        if event.get("event") != "meetingState":
            return
        active = bool(event.get("active"))
        self._publish_state(active, "browser")

    async def on_all_browsers_disconnected(self) -> None:
        self._publish_state(False, "no_browsers")
