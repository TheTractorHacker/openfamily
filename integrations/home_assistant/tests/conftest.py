"""Shared fixtures.

Two tiers run from this directory:

* ``test_api.py`` and ``test_webhook_auth.py`` import the pure modules by path
  and need only aiohttp and pytest-asyncio.
* ``test_ha_*.py`` need ``pytest-homeassistant-custom-component`` and are skipped
  automatically when it is not installed.
"""

from __future__ import annotations

import importlib.util
import pathlib
import sys

import pytest

PKG = pathlib.Path(__file__).resolve().parents[1] / "custom_components" / "openfamily"
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))


def load_pure(name: str):
    """Import api.py / webhook_auth.py without importing the package (and Home Assistant)."""
    spec = importlib.util.spec_from_file_location(f"openfamily_pure_{name}", PKG / f"{name}.py")
    mod = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = mod
    spec.loader.exec_module(mod)
    return mod


try:
    import pytest_homeassistant_custom_component  # noqa: F401

    HAVE_HA = True
except ImportError:  # pragma: no cover
    HAVE_HA = False


def pytest_ignore_collect(collection_path, config):
    return collection_path.name.startswith("test_ha_") and not HAVE_HA


if HAVE_HA:
    pytest_plugins = ["pytest_homeassistant_custom_component"]

    @pytest.fixture(autouse=True)
    def _loopback_sockets(socket_enabled):
        """The fake OpenFamily server listens on 127.0.0.1."""
        yield

    @pytest.fixture(autouse=True)
    def auto_enable_custom_integrations(enable_custom_integrations):
        yield
