"""Pytest configuration and shared fixtures for terranse tests."""

import pytest
from pathlib import Path
from jinja2 import Environment, FileSystemLoader


@pytest.fixture
def project_root():
    """Return the project root directory."""
    return Path(__file__).parent.parent


@pytest.fixture
def ansible_dir(project_root):
    """Return the ansible directory."""
    return project_root / "ansible"


@pytest.fixture
def templates_dir(ansible_dir):
    """Return the docker templates directory."""
    return ansible_dir / "roles" / "docker" / "templates"


@pytest.fixture
def jinja_env(templates_dir):
    """Return a Jinja2 environment configured for the templates directory."""
    return Environment(
        loader=FileSystemLoader(str(templates_dir)),
        keep_trailing_newline=True,
    )


@pytest.fixture
def mock_service_mounts():
    """Return mock service mount paths for template testing."""
    return {
        "config": "/appdata",
        "configs": "/appdata",
        "tv_series": "/media/tv",
        "movies": "/media/movies",
        "downloads": "/media/downloads",
        "cloud": "/storage/cloud",
    }


@pytest.fixture
def mock_service_devices():
    """Return mock USB serial device entries for template testing."""
    return {
        "zigbee": {
            "name": "zigbee",
            "path": "/dev/serial/by-id/usb-ITead_Sonoff_Zigbee_3.0_USB_Dongle_Plus_TEST-if00-port0",
            "adapter": "deconz",
        },
        "zwave": {
            "name": "zwave",
            "path": "/dev/serial/by-id/usb-Zooz_800_Z-Wave_Stick_TEST-if00",
        },
        "skyconnect": {
            "name": "skyconnect",
            "path": "/dev/serial/by-id/usb-Nabu_Casa_SkyConnect_v1.0_TEST-if00-port0",
        },
    }


@pytest.fixture
def mock_item():
    """Return a mock item (container) for template testing."""
    return {"name": "testservice"}


@pytest.fixture
def mock_secrets():
    """Return mock secrets for templates that require them."""
    return {
        "MYSQL_PASSWORD": "test_mysql_pass",
        "MYSQL_ROOT_PASSWORD": "test_root_pass",
        "NEXTCLOUD_ADMIN_PASSWORD": "test_admin_pass",
        "REDIS_PASSWORD": "test_redis_pass",
        "JWT_SECRET": "test_jwt_secret",
    }


@pytest.fixture
def mock_ansible_env():
    """Return mock ansible_env for templates."""
    return {"HOME": "/home/testuser"}
