# What changed, and why (ClassicAPI / UnitXP SP3 / SuperWoW / Nampower / VanillaHelpers)

All changes are in `TrinketMenu.lua` only - `.xml`/`.toc`/`TrinketMenuQueue.lua`/`TrinketMenuOpt.lua`
are untouched. Nothing here changes SavedVariables format, so existing
profiles/settings carry over fine.

## Real, working additions

**ClassicAPI** - added as a fallback tier in two places, used only when
Nampower isn't present:

- `ScanBaggedTrinkets` (bag scan): Nampower's `GetTrinkets()` first (fastest,
  already existed) -> ClassicAPI's `C_Container` second (new) -> raw
  `GetContainerItemLink` loop last (already existed).
- `CooldownUpdate`/`WriteMenuCooldowns` (item-ID cooldown lookup, see
  *Update 2* below).

*Update 1:* detection of ClassicAPI itself is now separate from whether
`C_Container` specifically works (`TrinketMenu.hasClassicAPI` via the
`CLASSIC_API_VERSION` global vs. `TrinketMenu.hasClassicBag` via probing
`C_Container`) - on the first pass these were conflated into one flag, so a
report of "ClassicAPI is loaded but our C_Container probe came up empty"
looked identical to "ClassicAPI isn't loaded at all." `/trinket compat` now
shows both, plus the ClassicAPI version number, and if `C_Container` exists
but our two expected functions aren't on it, it lists every function name
actually present on `C_Container` so the real names can be confirmed instead
of guessed again.

*Update 2:* Cross-checked against ClassicAPI's own API reference (its
maintainer-provided `classicAPI.md`) and found two real issues/opportunities:

1. **Bug fix:** `GetContainerNumSlots` was never moved onto `C_Container` by
   ClassicAPI - it stays a plain global, same as stock vanilla. My
   `hasClassicBag` check required `C_Container.GetContainerNumSlots` to
   exist, which it never will, so the flag under-reported even when
   ClassicAPI's bag API genuinely worked. Fixed to only require
   `C_Container.GetContainerItemInfo`, and the scan loop now calls the plain
   global `GetContainerNumSlots(bag)` for the slot count.
2. **New capability:** ClassicAPI also exposes `GetItemCooldown(itemID)` /
   `C_Container.GetItemCooldown(itemID)` - a direct-by-item-ID cooldown
   lookup returning `(start, duration, enable)`, the same shape as the stock
   `GetContainerItemCooldown`/`GetInventoryItemCooldown` calls, just
   addressed by item ID instead of bag/slot. This is functionally
   ClassicAPI's equivalent of Nampower's `GetItemIdCooldown` advantage (no
   bag/slot re-tracking needed to know if a specific trinket, wherever it
   currently is, is on cooldown). Added as a fallback tier - used only when
   Nampower isn't present - in both `CooldownUpdate` (watched-item ready
   notifications) and `WriteMenuCooldowns` (bag menu cooldown swirls/timers).
   New flag: `TrinketMenu.hasClassicItemCooldown`. New helper:
   `TrinketMenu.ClassicItemCooldown(itemID)`.

Also switched the ClassicAPI bag-scan tier to read `info.itemID` directly off
`C_Container.GetContainerItemInfo`'s returned table (confirmed field name)
instead of regex-parsing it out of the hyperlink - simpler and matches
ClassicAPI's documented table shape. `itemName` still comes from the
hyperlink's bracketed text rather than `info.itemName`, because ClassicAPI's
docs note `itemName` is cache-derived and can be briefly nil right after a
bag update, while `hyperlink` is documented as always present.

**UnitXP SP3** - `TrinketMenu.Notify()` now also fires
`UnitXP("notify","taskbarIcon")` and `UnitXP("notify","systemSound")` when
UnitXP is detected. Per UnitXP's own docs these are no-ops while the game
window has focus, so it's safe to always call alongside the existing in-game
message - you'll only notice it if you're alt-tabbed when a trinket comes off
cooldown.

**Nampower** - was already the addon's primary integration (worn/bagged
cooldowns, trinket-use detection via `SPELL_CAST_EVENT`); left as-is. Added
only a version readout (`GetNampowerVersion`) to the new diagnostic command.

**New:** `/trinket compat` prints what got detected and what TrinketMenu
actually does with each one.

**New, small, and not tied to any of the five libraries specifically:**
`ScanBaggedTrinkets` now tags trinkets that share a name with another bagged
copy, and the bag tooltip shows "You have N copies - Priority/Delay apply to
all of them". This exists because Priority/Delay/Pause and the cooldown watch
table are all keyed by trinket *name*, so two physical copies of the same
trinket have always shared one settings entry - this just makes that visible
instead of surprising.

## Honest non-additions

**SuperWoW** - the `hasSuperWoW` flag was already in the code but nothing
ever used it (dead flag, despite the README claiming "enhanced item info").
I didn't wire it to anything, because I couldn't find a real gap it fills
for this addon: TrinketMenu already addresses every trinket by exact
bag/slot, or by item ID via Nampower - both are already 100% reliable
without SuperWoW. SuperWoW's real value-add (genuine per-item unique IDs in
item links) only matters when you *can't* otherwise tell two items apart,
which isn't the situation here. Flag is kept (and now reported by
`/trinket compat`) since other addons on your setup may still need it.

**VanillaHelpers** - genuinely has no item/bag/cooldown/spell API at all
(it's `WriteFile`/`ReadFile`/minimap blips/character-skin morphing), so
there's nothing to hook. Detected purely for `/trinket compat` reporting.

**WeirdUtils** (checked, not integrated) - investigated per a follow-up
request. It's a client-side visual/QoL DLL (world markers, outlines,
clickthrough, screenshot tools, etc.) whose only documented "API" is a
C/C++ export (`WeirdUtils_IsModuleActive`, `WeirdUtils_DisableModule`,
`WeirdUtils_DisableAll`) meant for *other DLLs* to call via `GetProcAddress`
- there is no Lua-facing surface at all, so nothing in TrinketMenu (or any
addon) can call into it. Not added, and not worth a detection flag since
there's nothing to detect it *for*.

## Caveats

I don't have a running WoW client to test against, so:
- Function/field names for Nampower, UnitXP SP3, and ClassicAPI were all
  confirmed against each project's own docs (ClassicAPI via its
  maintainer-provided `classicAPI.md` reference, UnitXP via its codeberg
  wiki) rather than guessed from similar APIs - but I still can't execute
  any of this, so treat it as reference-verified, not runtime-verified.
- The ClassicAPI bag-scan and item-cooldown tiers are both guarded (`if info
  and info.itemID`, `if cd then`, etc.) so if a given build's field names
  differ, those branches just find nothing rather than error - Nampower/
  vanilla fallback still catch it if so, and `/trinket compat` will show
  `hasClassicAPI: detected` alongside `hasClassicBag: not detected` if that
  happens, which is exactly what surfaced the `GetContainerNumSlots` bug.
- Please test `/trinket compat`, a normal `/reload`, and a bag scan with a
  duplicate trinket in your bags before relying on this in a raid.
