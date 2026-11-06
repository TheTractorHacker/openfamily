"""Binary sensors: SOS and possible-crash flags (need the ``events`` scope)."""

from __future__ import annotations

from homeassistant.components.binary_sensor import BinarySensorDeviceClass, BinarySensorEntity
from homeassistant.core import HomeAssistant
from homeassistant.helpers.entity_platform import AddEntitiesCallback

from .entity import OpenFamilyEntity, add_new_members

KINDS = (("sos_active", "sos"), ("crash_active", "crash"))


async def async_setup_entry(hass: HomeAssistant, entry, async_add_entities: AddEntitiesCallback) -> None:
    coordinator = entry.runtime_data
    if "events" not in coordinator.scopes:
        return
    known: set[str] = set()

    def _sync() -> None:
        add_new_members(
            coordinator,
            async_add_entities,
            known,
            lambda mid: [OpenFamilyAlertSensor(coordinator, mid, field, key) for field, key in KINDS],
        )

    _sync()
    entry.async_on_unload(coordinator.async_add_listener(_sync))


class OpenFamilyAlertSensor(OpenFamilyEntity, BinarySensorEntity):
    _attr_device_class = BinarySensorDeviceClass.SAFETY

    def __init__(self, coordinator, member_id: str, field: str, key: str) -> None:
        super().__init__(coordinator, member_id, key)
        self._field = field
        self._attr_translation_key = key

    @property
    def is_on(self) -> bool | None:
        member = self.member
        if member is None or self._field not in member:
            return None
        return bool(member[self._field])
