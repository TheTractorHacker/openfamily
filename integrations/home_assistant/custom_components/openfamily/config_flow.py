"""Config flow: server URL + token, reauth, and options."""

from __future__ import annotations

import hashlib
from collections.abc import Mapping
from typing import Any

import voluptuous as vol
from homeassistant.components import webhook
from homeassistant.config_entries import ConfigEntry, ConfigFlow, ConfigFlowResult, OptionsFlow
from homeassistant.core import callback
from homeassistant.helpers.aiohttp_client import async_get_clientsession
from homeassistant.helpers.selector import (
    NumberSelector,
    NumberSelectorConfig,
    NumberSelectorMode,
    TextSelector,
    TextSelectorConfig,
    TextSelectorType,
)

from .api import (
    OpenFamilyAuthError,
    OpenFamilyClient,
    OpenFamilyError,
    normalize_url,
    valid_token,
)
from .const import (
    CONF_SCAN_INTERVAL,
    CONF_TOKEN,
    CONF_URL,
    CONF_WEBHOOK_ID,
    CONF_WEBHOOK_SECRET,
    DEFAULT_SCAN_INTERVAL,
    DOMAIN,
    MAX_SCAN_INTERVAL,
    MIN_SCAN_INTERVAL,
)

_PASSWORD = TextSelector(TextSelectorConfig(type=TextSelectorType.PASSWORD))


def _unique_id(url: str, token: str) -> str:
    # Hash so the token itself never becomes an identifier shown anywhere.
    return hashlib.sha256(f"{url}|{token}".encode()).hexdigest()[:24]


class OpenFamilyConfigFlow(ConfigFlow, domain=DOMAIN):
    VERSION = 1

    async def _validate(self, url: str, token: str) -> tuple[dict[str, Any], dict[str, str]]:
        errors: dict[str, str] = {}
        info: dict[str, Any] = {}
        try:
            base = normalize_url(url)
        except ValueError:
            return info, {CONF_URL: "invalid_url"}
        if not valid_token(token.strip()):
            return info, {CONF_TOKEN: "invalid_token_format"}
        client = OpenFamilyClient(async_get_clientsession(self.hass), base, token.strip())
        try:
            info = await client.ping()
        except OpenFamilyAuthError:
            errors["base"] = "invalid_auth"
        except OpenFamilyError:
            errors["base"] = "cannot_connect"
        except Exception:  # noqa: BLE001 - never leak details into the UI
            errors["base"] = "unknown"
        info["_url"] = base
        return info, errors

    async def async_step_user(self, user_input: dict[str, Any] | None = None) -> ConfigFlowResult:
        errors: dict[str, str] = {}
        if user_input is not None:
            token = user_input[CONF_TOKEN].strip()
            info, errors = await self._validate(user_input[CONF_URL], token)
            if not errors:
                await self.async_set_unique_id(_unique_id(info["_url"], token))
                self._abort_if_unique_id_configured()
                return self.async_create_entry(
                    title=f"OpenFamily ({info.get('name') or info['_url']})",
                    data={
                        CONF_URL: info["_url"],
                        CONF_TOKEN: token,
                        CONF_WEBHOOK_ID: webhook.async_generate_id(),
                    },
                )
        schema = vol.Schema(
            {
                vol.Required(CONF_URL, default=(user_input or {}).get(CONF_URL, "")): TextSelector(
                    TextSelectorConfig(type=TextSelectorType.URL)
                ),
                vol.Required(CONF_TOKEN): _PASSWORD,
            }
        )
        return self.async_show_form(step_id="user", data_schema=schema, errors=errors)

    async def async_step_reauth(self, entry_data: Mapping[str, Any]) -> ConfigFlowResult:
        return await self.async_step_reauth_confirm()

    async def async_step_reauth_confirm(self, user_input: dict[str, Any] | None = None) -> ConfigFlowResult:
        entry = self._get_reauth_entry()
        errors: dict[str, str] = {}
        if user_input is not None:
            token = user_input[CONF_TOKEN].strip()
            info, errors = await self._validate(entry.data[CONF_URL], token)
            if not errors:
                return self.async_update_reload_and_abort(entry, data_updates={CONF_TOKEN: token})
        return self.async_show_form(
            step_id="reauth_confirm",
            data_schema=vol.Schema({vol.Required(CONF_TOKEN): _PASSWORD}),
            errors=errors,
        )

    @staticmethod
    @callback
    def async_get_options_flow(config_entry: ConfigEntry) -> OptionsFlow:
        return OpenFamilyOptionsFlow()


class OpenFamilyOptionsFlow(OptionsFlow):
    async def async_step_init(self, user_input: dict[str, Any] | None = None) -> ConfigFlowResult:
        if user_input is not None:
            data = {
                CONF_SCAN_INTERVAL: int(user_input[CONF_SCAN_INTERVAL]),
                CONF_WEBHOOK_SECRET: (user_input.get(CONF_WEBHOOK_SECRET) or "").strip(),
            }
            return self.async_create_entry(data=data)
        opts = self.config_entry.options
        webhook_id = self.config_entry.data.get(CONF_WEBHOOK_ID, "")
        try:
            url = webhook.async_generate_url(self.hass, webhook_id)
        except Exception:  # noqa: BLE001 - no external URL configured
            url = webhook.async_generate_path(webhook_id)
        schema = vol.Schema(
            {
                vol.Required(
                    CONF_SCAN_INTERVAL, default=opts.get(CONF_SCAN_INTERVAL, DEFAULT_SCAN_INTERVAL)
                ): NumberSelector(
                    NumberSelectorConfig(
                        min=MIN_SCAN_INTERVAL,
                        max=MAX_SCAN_INTERVAL,
                        step=10,
                        unit_of_measurement="s",
                        mode=NumberSelectorMode.BOX,
                    )
                ),
                vol.Optional(CONF_WEBHOOK_SECRET, default=opts.get(CONF_WEBHOOK_SECRET, "")): _PASSWORD,
            }
        )
        return self.async_show_form(
            step_id="init", data_schema=schema, description_placeholders={"webhook_url": url}
        )
