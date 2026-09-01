# What changed, and why (ClassicAPI / UnitXP SP3 / SuperWoW / Nampower / VanillaHelpers)

All changes are in `TrinketMenu.lua` only - `.xml`/`.toc`/`TrinketMenuQueue.lua`/`TrinketMenuOpt.lua`
are untouched. Nothing here changes SavedVariables format, so existing
profiles/settings carry over fine.

## Real, working additions

**ClassicAPI** - added as a third bag-scan tier in `ScanBaggedTrinkets`
(`TrinketMenu.hasClassicBag`, checked via `C_Container.GetContainerNumSlots`
/ `GetContainerItemInfo`). Order is: Nampower's `GetTrinkets()` first (fastest,
already existed) -> ClassicAPI's `C_Container` second (new) -> raw
`GetContainerItemLink` loop last (already existed). This means a client that
has ClassicAPI but not Nampower still gets a single-call-per-item bag scan
instead of falling all the way back to the slow path.

*Update:* detection of ClassicAPI itself is now separate from whether
`C_Container` specifically works (`TrinketMenu.hasClassicAPI` via the
`CLASSIC_API_VERSION` global vs. `TrinketMenu.hasClassicBag` via probing
`C_Container`) - on the first pass these were conflated into one flag, so a
report of "ClassicAPI is loaded but our C_Container probe came up empty"
looked identical to "ClassicAPI isn't loaded at all." `/trinket compat` now
shows both, plus the ClassicAPI version number, and if `C_Container` exists
but our two expected functions aren't on it, it lists every function name
actually present on `C_Container` so the real names can be confirmed instead
of guessed again.

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

## Caveats

I don't have a running WoW client to test against, so:
- The `C_Container.GetContainerItemInfo(...).hyperlink` / `.iconFileID` field
  names match every ClassicAPI-style backport I could confirm, but if your
  server's ClassicAPI build names these differently, that branch will just
  silently find 0 trinkets rather than error (it's guarded by `info and
  info.hyperlink`) - GetTrinkets/vanilla fallback still catch it if so.
- UnitXP's `"notify"` calls are documented as parameterless status pings
  (no title/text arguments) - confirmed from the wiki, not guessed.
- Please test `/trinket compat`, a normal `/reload`, and a bag scan with a
  duplicate trinket in your bags before relying on this in a raid.
