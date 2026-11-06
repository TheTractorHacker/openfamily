"""Sensors: battery, speed, place, last seen and driving summaries."""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
from datetime import datetime
from typing import Any

from homeassistant.components.sensor import (
    SensorDeviceClass,
    SensorEntity,
    SensorEntityDescription,
    SensorStateClass,
)
from homeassistant.const import PERCENTAGE, UnitOfLength, UnitOfSpeed
from homeassistant.core import HomeAssistant
from homeassistant.helpers.entity_platform import AddEntitiesCallback
from homeassistant.util import dt as dt_util

from .entity import OpenFamilyEntity, add_new_members


@dataclass(frozen=True, kw_only=True)
class OpenFamilySensorDescription(SensorEntityDescription):
    value_fn: Callable[[dict[str, Any]], Any]
    scope: str = "presence"


def _driving(member: dict[str, Any], key: str) -> Any:
    d = member.get("driving")
    return None if not isinstance(d, dict) else d.get(key)


def _ts(value: Any) -> datetime | None:
    return dt_util.parse_datetime(value) if isinstance(value, str) else None


SENSORS: tuple[OpenFamilySensorDescription, ...] = (
    OpenFamilySensorDescription(
        key="battery",
        translation_key="battery",
        device_class=SensorDeviceClass.BATTERY,
        native_unit_of_measurement=PERCENTAGE,
        state_class=SensorStateClass.MEASUREMENT,
        value_fn=lambda m: None if m.get("battery_pct") is None else round(m["battery_pct"]),
    ),
    OpenFamilySensorDescription(
        key="speed",
        translation_key="speed",
        device_class=SensorDeviceClass.SPEED,
        native_unit_of_measurement=UnitOfSpeed.METERS_PER_SECOND,
        state_class=SensorStateClass.MEASUREMENT,
        suggested_display_precision=1,
        value_fn=lambda m: m.get("speed_mps"),
    ),
    OpenFamilySensorDescription(
        key="place",
        translation_key="place",
        value_fn=lambda m: m.get("state"),
    ),
    OpenFamilySensorDescription(
        key="last_seen",
        translation_key="last_seen",
        device_class=SensorDeviceClass.TIMESTAMP,
        value_fn=lambda m: _ts(m.get("last_seen")),
    ),
    OpenFamilySensorDescription(
        key="drives_24h",
        translation_key="drives_24h",
        scope="driving",
        state_class=SensorStateClass.MEASUREMENT,
        value_fn=lambda m: _driving(m, "drives_24h"),
    ),
    OpenFamilySensorDescription(
        key="driving_distance_24h",
        translation_key="driving_distance_24h",
        scope="driving",
        device_class=SensorDeviceClass.DISTANCE,
        native_unit_of_measurement=UnitOfLength.METERS,
        suggested_unit_of_measurement=UnitOfLength.KILOMETERS,
        suggested_display_precision=1,
        state_class=SensorStateClass.MEASUREMENT,
        value_fn=lambda m: _driving(m, "distance_m_24h"),
    ),
)


async def async_setup_entry(hass: HomeAssistant, entry, async_add_entities: AddEntitiesCallback) -> None:
    coordinator = entry.runtime_data
    known: set[str] = set()
    descriptions = [d for d in SENSORS if d.scope in coordinator.scopes]

    def _sync() -> None:
        add_new_members(
            coordinator,
            async_add_entities,
            known,
            lambda mid: [OpenFamilySensor(coordinator, mid, d) for d in descriptions],
        )

    _sync()
    entry.async_on_unload(coordinator.async_add_listener(_sync))


class OpenFamilySensor(OpenFamilyEntity, SensorEntity):
    entity_description: OpenFamilySensorDescription

    def __init__(self, coordinator, member_id: str, description: OpenFamilySensorDescription) -> None:
        super().__init__(coordinator, member_id, description.key)
        self.entity_description = description

    @property
    def native_value(self) -> Any:
        member = self.member
        return None if member is None else self.entity_description.value_fn(member)
