"""Tests for the gaming role's Jinja2 templates.

The Sunshine session hooks are the only thing that tells gpu-manager whether
somebody is streaming, so a hook that reports to the wrong place silently
disables the daemon's whole idle-release path.
"""

import pytest
from jinja2.exceptions import UndefinedError


class TestSunshineSessionHooks:
    """Tests for the hooks that tell gpu-manager about streaming sessions.

    These run as Sunshine `global_prep_cmd`, where a non-zero exit aborts the
    stream, so they must swallow every failure. They are also the only thing
    that makes the daemon's grace period able to fire at all.
    """

    def _render(self, env, name, variables):
        return env.get_template(name).render(**variables)

    def test_start_hook_reports_the_session_to_the_daemon(
        self, gaming_jinja_env, sunshine_hook_vars
    ):
        body = self._render(
            gaming_jinja_env, "sunshine-session-start.sh.j2", sunshine_hook_vars
        )

        assert "-X PUT" in body
        assert "http://192.168.1.200:8080/v1/sessions/gaming" in body

    def test_stop_hook_reports_the_session_ended(
        self, gaming_jinja_env, sunshine_hook_vars
    ):
        body = self._render(
            gaming_jinja_env, "sunshine-session-stop.sh.j2", sunshine_hook_vars
        )

        assert "-X DELETE" in body
        assert "http://192.168.1.200:8080/v1/sessions/gaming" in body

    @pytest.mark.parametrize(
        "name", ["sunshine-session-start.sh.j2", "sunshine-session-stop.sh.j2"]
    )
    def test_hooks_never_fail_the_stream(
        self, gaming_jinja_env, sunshine_hook_vars, name
    ):
        """A non-zero exit from a global_prep_cmd aborts the stream."""
        body = self._render(gaming_jinja_env, name, sunshine_hook_vars)

        assert "set -e" not in body
        assert body.rstrip().endswith("exit 0")

    @pytest.mark.parametrize(
        "name", ["sunshine-session-start.sh.j2", "sunshine-session-stop.sh.j2"]
    )
    def test_hooks_require_the_api_url(self, gaming_jinja_env, sunshine_hook_vars, name):
        """Reporting nowhere is the failure this whole change is fixing, so a
        missing URL must fail loudly at template time."""
        del sunshine_hook_vars["gpu_manager_api_url"]

        with pytest.raises(UndefinedError):
            self._render(gaming_jinja_env, name, sunshine_hook_vars)

    def test_start_hook_starts_the_heartbeat(
        self, gaming_jinja_env, sunshine_hook_vars
    ):
        """Without a heartbeat a crashed session would read active forever."""
        body = self._render(
            gaming_jinja_env, "sunshine-session-start.sh.j2", sunshine_hook_vars
        )

        assert "sunshine-heartbeat.timer" in body
        assert "--user start" in body

    def test_stop_hook_stops_the_heartbeat(self, gaming_jinja_env, sunshine_hook_vars):
        body = self._render(
            gaming_jinja_env, "sunshine-session-stop.sh.j2", sunshine_hook_vars
        )

        assert "sunshine-heartbeat.timer" in body
        assert "--user stop" in body

    def test_heartbeat_unit_reports_active(self, gaming_jinja_env, sunshine_hook_vars):
        body = self._render(
            gaming_jinja_env, "sunshine-heartbeat.service.j2", sunshine_hook_vars
        )

        assert "-X PUT" in body
        assert "http://192.168.1.200:8080/v1/sessions/gaming" in body

    def test_heartbeat_timer_fires_within_the_ttl(
        self, gaming_jinja_env, sunshine_hook_vars
    ):
        """The daemon's session_ttl_s is 180, so 60s gives three chances."""
        body = self._render(
            gaming_jinja_env, "sunshine-heartbeat.timer.j2", sunshine_hook_vars
        )

        assert "OnUnitActiveSec=60" in body
