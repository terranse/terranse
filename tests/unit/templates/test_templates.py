"""Tests for Docker compose Jinja2 templates.

These tests verify that docker-compose templates render valid YAML
and contain expected service configurations.
"""

import pytest
import yaml
from pathlib import Path


# Templates that can be tested with basic mocks (no Ansible lookups)
BASIC_TEMPLATES = [
    "common.yaml.j2",
    "jellyfin.yaml.j2",
    "homeassistant.yaml.j2",
    "mosquitto.yaml.j2",
    "zigbee2mqtt.yaml.j2",
    "zwave-js-ui.yaml.j2",
]

# Templates requiring Ansible lookups (onepassword, etc.) - skip in unit tests
ANSIBLE_LOOKUP_TEMPLATES = [
    "gluetun.yaml.j2",
    "serverarr.yaml.j2",
    "nextcloud.yaml.j2",
    "authentik.yaml.j2",
    "vikunja.yaml.j2",
]


def mock_lookup(*args, **kwargs):
    """Mock Ansible lookup function for testing."""
    return "mocked_secret_value"


class TestCommonTemplate:
    """Tests for common.yaml.j2 base service template."""

    def test_renders_valid_yaml(self, jinja_env):
        """Test that common.yaml renders valid YAML."""
        template = jinja_env.get_template("common.yaml.j2")
        rendered = template.render()
        parsed = yaml.safe_load(rendered)

        assert parsed is not None
        assert "services" in parsed
        assert "base-service" in parsed["services"]

    def test_base_service_has_environment(self, jinja_env):
        """Test that base-service has expected environment variables."""
        template = jinja_env.get_template("common.yaml.j2")
        rendered = template.render()
        parsed = yaml.safe_load(rendered)

        env = parsed["services"]["base-service"]["environment"]
        assert "PUID" in env
        assert "PGID" in env
        assert "TZ" in env
        assert env["UMASK_SET"] == "022"


class TestJellyfinTemplate:
    """Tests for jellyfin.yaml.j2 media server template."""

    def test_renders_valid_yaml(self, jinja_env, mock_service_mounts, mock_item):
        """Test that jellyfin.yaml renders valid YAML."""
        template = jinja_env.get_template("jellyfin.yaml.j2")
        rendered = template.render(
            service_mounts=mock_service_mounts,
            item=mock_item,
        )
        parsed = yaml.safe_load(rendered)

        assert parsed is not None
        assert "services" in parsed
        assert "jellyfin" in parsed["services"]

    def test_jellyfin_has_required_volumes(
        self, jinja_env, mock_service_mounts, mock_item
    ):
        """Test that jellyfin has config and media volumes."""
        template = jinja_env.get_template("jellyfin.yaml.j2")
        rendered = template.render(
            service_mounts=mock_service_mounts,
            item=mock_item,
        )
        parsed = yaml.safe_load(rendered)

        volumes = parsed["services"]["jellyfin"]["volumes"]
        volume_str = " ".join(volumes)

        assert "/config" in volume_str
        assert "/media/tvshows" in volume_str
        assert "/media/movies" in volume_str

    def test_jellyfin_exposes_webui_port(
        self, jinja_env, mock_service_mounts, mock_item
    ):
        """Test that jellyfin exposes the WebUI port."""
        template = jinja_env.get_template("jellyfin.yaml.j2")
        rendered = template.render(
            service_mounts=mock_service_mounts,
            item=mock_item,
        )
        parsed = yaml.safe_load(rendered)

        ports = parsed["services"]["jellyfin"]["ports"]
        port_str = " ".join(str(p) for p in ports)

        assert "8096" in port_str

    def test_jellyseerr_included(self, jinja_env, mock_service_mounts, mock_item):
        """Test that jellyseerr is also defined in the template."""
        template = jinja_env.get_template("jellyfin.yaml.j2")
        rendered = template.render(
            service_mounts=mock_service_mounts,
            item=mock_item,
        )
        parsed = yaml.safe_load(rendered)

        assert "jellyseerr" in parsed["services"]


class TestGluetunTemplate:
    """Tests for gluetun.yaml.j2 VPN container template."""

    @pytest.mark.skip(reason="Template uses Ansible onepassword lookups")
    def test_renders_valid_yaml(self, jinja_env, mock_service_mounts, mock_item):
        """Test that gluetun.yaml renders valid YAML."""
        pass


class TestServerarrTemplate:
    """Tests for serverarr.yaml.j2 media automation template."""

    @pytest.mark.skip(reason="Template uses Ansible onepassword lookups")
    def test_renders_valid_yaml(self, jinja_env, mock_service_mounts, mock_item):
        """Test that serverarr.yaml renders valid YAML."""
        pass


class TestDockerComposeTemplate:
    """Tests for the main docker-compose.yaml.j2 template."""

    @pytest.mark.skip(reason="Template uses Ansible-specific filters (from_json)")
    def test_renders_valid_yaml(self, jinja_env, mock_service_mounts, mock_item):
        """Test that docker-compose.yaml renders valid YAML."""
        pass


class TestHomeassistantTemplate:
    """Tests for homeassistant.yaml.j2."""

    def test_renders_valid_yaml(self, jinja_env, mock_service_mounts, mock_item):
        template = jinja_env.get_template("homeassistant.yaml.j2")
        parsed = yaml.safe_load(
            template.render(service_mounts=mock_service_mounts, item=mock_item)
        )
        assert "homeassistant" in parsed["services"]

    def test_uses_host_networking_for_discovery(
        self, jinja_env, mock_service_mounts, mock_item
    ):
        template = jinja_env.get_template("homeassistant.yaml.j2")
        parsed = yaml.safe_load(
            template.render(service_mounts=mock_service_mounts, item=mock_item)
        )
        assert parsed["services"]["homeassistant"]["network_mode"] == "host"

    def test_config_volume_in_appdata(self, jinja_env, mock_service_mounts, mock_item):
        template = jinja_env.get_template("homeassistant.yaml.j2")
        parsed = yaml.safe_load(
            template.render(service_mounts=mock_service_mounts, item=mock_item)
        )
        volumes = " ".join(parsed["services"]["homeassistant"]["volumes"])
        assert "/appdata/homeassistant:/config" in volumes


class TestMosquittoTemplate:
    """Tests for mosquitto.yaml.j2 MQTT broker template."""

    def test_renders_valid_yaml(self, jinja_env, mock_service_mounts, mock_item):
        template = jinja_env.get_template("mosquitto.yaml.j2")
        parsed = yaml.safe_load(
            template.render(service_mounts=mock_service_mounts, item=mock_item)
        )
        assert "mosquitto" in parsed["services"]

    def test_broker_bound_to_localhost_only(
        self, jinja_env, mock_service_mounts, mock_item
    ):
        """MQTT runs unauthenticated: it must only be reachable from inside
        the LXC (HA on host network) and the compose network (Z2M)."""
        template = jinja_env.get_template("mosquitto.yaml.j2")
        parsed = yaml.safe_load(
            template.render(service_mounts=mock_service_mounts, item=mock_item)
        )
        ports = [str(p) for p in parsed["services"]["mosquitto"]["ports"]]
        assert any(p.startswith("127.0.0.1:1883:") for p in ports)


class TestZigbee2mqttTemplate:
    """Tests for zigbee2mqtt.yaml.j2."""

    def test_renders_valid_yaml(
        self, jinja_env, mock_service_mounts, mock_service_devices, mock_item
    ):
        template = jinja_env.get_template("zigbee2mqtt.yaml.j2")
        parsed = yaml.safe_load(
            template.render(
                service_mounts=mock_service_mounts,
                service_devices=mock_service_devices,
                item=mock_item,
            )
        )
        assert "zigbee2mqtt" in parsed["services"]

    def test_maps_zigbee_dongle_by_id(
        self, jinja_env, mock_service_mounts, mock_service_devices, mock_item
    ):
        template = jinja_env.get_template("zigbee2mqtt.yaml.j2")
        parsed = yaml.safe_load(
            template.render(
                service_mounts=mock_service_mounts,
                service_devices=mock_service_devices,
                item=mock_item,
            )
        )
        devices = parsed["services"]["zigbee2mqtt"]["devices"]
        path = mock_service_devices["zigbee"]["path"]
        assert devices == [f"{path}:{path}"]


class TestZwaveJsUiTemplate:
    """Tests for zwave-js-ui.yaml.j2."""

    def test_renders_valid_yaml(
        self, jinja_env, mock_service_mounts, mock_service_devices, mock_item
    ):
        template = jinja_env.get_template("zwave-js-ui.yaml.j2")
        parsed = yaml.safe_load(
            template.render(
                service_mounts=mock_service_mounts,
                service_devices=mock_service_devices,
                item=mock_item,
            )
        )
        assert "zwave-js-ui" in parsed["services"]

    def test_maps_zwave_stick_by_id(
        self, jinja_env, mock_service_mounts, mock_service_devices, mock_item
    ):
        template = jinja_env.get_template("zwave-js-ui.yaml.j2")
        parsed = yaml.safe_load(
            template.render(
                service_mounts=mock_service_mounts,
                service_devices=mock_service_devices,
                item=mock_item,
            )
        )
        devices = parsed["services"]["zwave-js-ui"]["devices"]
        path = mock_service_devices["zwave"]["path"]
        assert devices == [f"{path}:{path}"]

    def test_websocket_bound_to_localhost(
        self, jinja_env, mock_service_mounts, mock_service_devices, mock_item
    ):
        """HA reaches the Z-Wave JS websocket via localhost (host network);
        it must not be exposed to the LAN."""
        template = jinja_env.get_template("zwave-js-ui.yaml.j2")
        parsed = yaml.safe_load(
            template.render(
                service_mounts=mock_service_mounts,
                service_devices=mock_service_devices,
                item=mock_item,
            )
        )
        ports = [str(p) for p in parsed["services"]["zwave-js-ui"]["ports"]]
        assert any(p.startswith("127.0.0.1:3000:") for p in ports)


class TestTemplateDiscovery:
    """Tests to verify all templates are accounted for."""

    def test_all_templates_exist(self, templates_dir):
        """Verify expected templates exist in the templates directory."""
        expected_templates = [
            "common.yaml.j2",
            "jellyfin.yaml.j2",
            "gluetun.yaml.j2",
            "serverarr.yaml.j2",
            "nextcloud.yaml.j2",
            "authentik.yaml.j2",
            "vikunja.yaml.j2",
            "docker-compose.yaml.j2",
            "homeassistant.yaml.j2",
            "mosquitto.yaml.j2",
            "zigbee2mqtt.yaml.j2",
            "zwave-js-ui.yaml.j2",
            "gitlab-runner.yaml.j2",
        ]

        for template_name in expected_templates:
            template_path = templates_dir / template_name
            assert template_path.exists(), f"Template {template_name} not found"

    def test_no_unknown_templates(self, templates_dir):
        """Verify we know about all templates in the directory."""
        known_templates = {
            "common.yaml.j2",
            "jellyfin.yaml.j2",
            "gluetun.yaml.j2",
            "serverarr.yaml.j2",
            "nextcloud.yaml.j2",
            "authentik.yaml.j2",
            "vikunja.yaml.j2",
            "docker-compose.yaml.j2",
            "homeassistant.yaml.j2",
            "mosquitto.yaml.j2",
            "zigbee2mqtt.yaml.j2",
            "zwave-js-ui.yaml.j2",
            "gitlab-runner.yaml.j2",
        }

        actual_templates = {
            f.name for f in templates_dir.glob("*.j2") if f.is_file()
        }

        unknown = actual_templates - known_templates
        assert not unknown, f"Unknown templates found: {unknown}"
