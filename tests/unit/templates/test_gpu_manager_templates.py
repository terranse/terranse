"""Tests for the gpu-manager role's Jinja2 templates.

The daemon validates its config at load and refuses to start on anything it
does not recognise, so a template that emits a half-written stanza takes the
card's arbitration down with it. These live apart from the docker-compose
template tests because they cover a different role.
"""

import yaml


class TestGPUManagerConfigTemplate:
    """Tests for the gpu-manager daemon's config.yaml.

    The daemon validates this file at load and refuses to start on anything it
    does not recognise, so a template that emits a half-written stanza takes
    the card's arbitration down with it.
    """

    def _render(self, env, variables):
        return yaml.safe_load(env.get_template("gpu-manager.config.yaml.j2").render(**variables))

    def test_renders_the_vms_tofu_injects(self, gpu_manager_jinja_env, gpu_manager_vars):
        parsed = self._render(gpu_manager_jinja_env, gpu_manager_vars)

        assert parsed["vms"]["gaming"] == {"vmid": 111, "tier": "game"}
        assert parsed["vms"]["ai-vm"] == {"vmid": 114, "tier": "ai"}

    def test_omits_default_tenant_when_not_declared(self, gpu_manager_jinja_env, gpu_manager_vars):
        """No declaration means the behaviour is off, not half-configured."""
        parsed = self._render(gpu_manager_jinja_env, gpu_manager_vars)

        assert "default_tenant" not in parsed

    def test_emits_default_tenant_when_declared(self, gpu_manager_jinja_env, gpu_manager_vars):
        gpu_manager_vars["gpu_manager_default_tenant"] = {"vm": "ai-vm", "profile": "Q-24C"}

        parsed = self._render(gpu_manager_jinja_env, gpu_manager_vars)

        assert parsed["default_tenant"] == {"vm": "ai-vm", "profile": "Q-24C"}

    def test_emits_the_session_ttl(self, gpu_manager_jinja_env, gpu_manager_vars):
        parsed = self._render(gpu_manager_jinja_env, gpu_manager_vars)

        assert parsed["session_ttl_s"] == 180

    def test_no_longer_emits_session_dir(self, gpu_manager_jinja_env, gpu_manager_vars):
        """Sessions arrive over the API now; the directory nothing could read
        is gone, and a config still naming it would be a lie about where the
        daemon looks."""
        parsed = self._render(gpu_manager_jinja_env, gpu_manager_vars)

        assert "session_dir" not in parsed
