-- SPDX-License-Identifier: AGPL-3.0-or-later
-- $1 is one literal route selected by the assembly HTTP router.
-- One statement observes one committed head. No row means unavailable.
SELECT body FROM asm_catalog.current_exports WHERE route = $1;
