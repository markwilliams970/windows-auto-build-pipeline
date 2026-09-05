"""Host-identity generation: one ID per VM, decoupled from the guest's own
NetBIOS ComputerName.

Format: <netbios-lowercase>-<timestamp>-<uuid8>, e.g.
win2022prod-20260904-1314-a1b2c3d4. This replaces build.sh's own BUILD_ID
(<os>-<timestamp-to-the-second>, e.g. server2022-20260823-141034) which
existed purely to avoid path collisions across builds of the same OS - the
uuid8 suffix here gives a hard uniqueness guarantee on its own, so the
timestamp only needs to stay human-readable (minute granularity), not carry
the collision-avoidance burden by itself. This same id becomes the qcow2
basename, Packer's build_id, the NVRAM filename, and eventually the libvirt
domain name - one identifier reused everywhere, not two schemes to keep in
sync (this is the actual point of Phase 5's naming redesign).

The guest's own ComputerName (WIN2022PROD, etc.) is untouched by any of
this - it is looked up separately (common_sh.os_computer_name) or passed as
an explicit override, and is never derived from a host id.
"""

from __future__ import annotations

import uuid
from datetime import datetime


def generate_host_id(guest_computer_name: str, *, now: datetime | None = None) -> str:
    timestamp = (now or datetime.now()).strftime("%Y%m%d-%H%M")
    suffix = uuid.uuid4().hex[:8]
    return f"{guest_computer_name.lower()}-{timestamp}-{suffix}"
