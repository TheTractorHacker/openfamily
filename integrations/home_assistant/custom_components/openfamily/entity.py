"""Shared entity base."""

from __future__ import annotations

from typing import Any

from homeassistant.helpers.device_registry import DeviceInfo
from homeassistant.helpers.update_coordinator import CoordinatorEntity

from .const import DOMAIN
from .coordinator import OpenFamilyCoordinator


class OpenFamilyEntity(CoordinatorEntity[OpenFamilyCoordinator]):
    _attr_has_entity_name = True

    def __init__(self, coordinator: OpenFamilyCoordinator, member_id: str, key: str) -> None:
        super().__init__(coordinator)
        self._member_id = member_id
        entry_id = coordinator.config_entry.entry_id
        self._attr_unique_id = f"{entry_id}_{member_id}_{key}"

    @property
    def member(self) -> dict[str, Any] | None:
        return (self.coordinator.data or {}).get("members", {}).get(self._member_id)

    @property
    def available(self) -> bool:
        return super().available and self.member is not None

    @property
    def device_info(self) -> DeviceInfo:
        member = self.member or {}
        return DeviceInfo(
            identifiers={(DOMAIN, self._member_id)},
            name=member.get("name") or "Orbitly member",
            manufacturer="Orbitly",
            model="Family member",
        )


def add_new_members(coordinator, async_add_entities, known: set[str], factory) -> None:
    """Create entities for members that are not known yet (called on every update)."""
    new = [mid for mid in (coordinator.data or {}).get("members", {}) if mid not in known]
    if not new:
        return
    known.update(new)
    async_add_entities([entity for mid in new for entity in factory(mid)])
