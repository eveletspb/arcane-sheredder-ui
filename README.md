# Arcane Shredder UI

![Arcane Shredder — mass disenchant addon](banner.png)

Companion addon for [mod-arcane-shredder](https://github.com/eveletspb/mod-arcane-shredder), providing a safe batch-disenchant interface for WoW WotLK 3.3.5a.

The addon requests a server-generated preview, displays every item selected for destruction, lets you exclude individual items, and requires an explicit confirmation. The server remains authoritative and validates every item again immediately before disenchanting it.

## Requirements

- WoW WotLK 3.3.5a (`Interface 30300`).
- A server running a compatible version of `mod-arcane-shredder`.
- A character that knows Disenchant and has the required Enchanting skill.

## Required addon folder name

The installed addon folder **must be named exactly**:

```text
ArcaneShredderUI
```

The repository name (`arcane-sheredder-ui`) is not the in-game addon folder name. After installation, this exact file must exist:

```text
World of Warcraft/Interface/AddOns/ArcaneShredderUI/ArcaneShredderUI.toc
```

Avoid an extra nested directory such as:

```text
Interface/AddOns/ArcaneShredderUI/ArcaneShredderUI/ArcaneShredderUI.toc
```

## Installation

1. Download or clone this repository.
2. Copy the inner `ArcaneShredderUI` directory into `World of Warcraft/Interface/AddOns/`.
3. Confirm that the resulting directory layout is:

   ```text
   Interface/
   └── AddOns/
       └── ArcaneShredderUI/
           ├── ArcaneShredderUI.toc
           ├── ArcaneShredderUI_Locales.lua
           └── ArcaneShredderUI.lua
   ```

4. Restart the WoW client if it was running.
5. Enable **Arcane Shredder** in the AddOns list on the character-selection screen.

## Usage

1. Log in to a character with Enchanting and open the addon with:

   ```text
   /ashred
   ```

2. Configure the filters:

   - **Quality:** Uncommon, Rare, and/or Epic.
   - **Binding:** unbound and/or soulbound items.
   - **Bags:** backpack and any of the four equipped bags.
   - **Max item level:** `0` disables the client-side item-level limit.
   - **Safe defaults:** restores Uncommon only, both binding types, all bags, and no client-side item-level limit.

3. Click **Preview**. The list is created by the server, not by the addon.
4. Review every item in the list. Hover over a row to see the standard item tooltip.
5. Click **Exclude** beside any item that must not be disenchanted.
6. Check the remaining item count and preview expiration timer.
7. Click **Disenchant: N** and accept the confirmation dialog, or click **Cancel preview** to discard the snapshot.

Filters are locked while a server preview is active. Cancel the current preview before changing the filters.

## Safety model

- Only the backpack and contents of the four equipped bags are scanned.
- Equipped gear, bank, keyring, buyback, trade, mail, auction, and guild-bank items are outside the scan scope.
- The addon cannot expand the server policy. Server configuration always takes precedence over client filters.
- Preview tokens are short-lived, owner-bound, and single-use.
- The server resolves every item again by GUID and repeats all eligibility checks before destroying it.
- Items moved, equipped, traded, changed, or removed after preview are skipped.
- Disenchant results use the server's normal loot templates. Exact materials are intentionally not pre-rolled during preview.

## Status and protocol

Addon-to-server communication uses the hidden AzerothCore addon-message transport through `SendAddonMessage` and `CHAT_MSG_ADDON` with the `AzerothCore` prefix. The prefix registration call is guarded because stock WotLK 3.3.5a predates `RegisterAddonMessagePrefix`; newer clients use it when available. Uncached item information is refreshed through a bounded `OnUpdate` poll instead of relying on a later-client event.

Visible chat is not used as the machine protocol. It remains available only for help, diagnostic status, and normal system messages. Server diagnostics can be requested with:

```text
.ashred status
```

## Troubleshooting

### The addon does not appear in the AddOns list

- Verify that the folder is named `ArcaneShredderUI` exactly.
- Verify that `ArcaneShredderUI.toc` is directly inside that folder.
- Remove any accidental extra nesting created while extracting the archive.
- Confirm that you are running a WotLK 3.3.5a client.

### The window does not open

- Run `/ashred` without a leading dot.
- Confirm that the addon is enabled for the current character.
- Reload the UI with `/reload` and check for Lua errors.

### The addon reports that the server transport is unavailable

- Confirm that `mod-arcane-shredder` is installed and enabled on the server.
- Run `.ashred status` for server-side diagnostics.
- Confirm that the AzerothCore addon channel is enabled and that the server and addon use compatible protocol versions.

### Preview returns no items

- Select at least one quality, one binding type, and one bag.
- Check the character's Enchanting skill and Disenchant spell.
- Remember that server policy may reject Rare, Epic, refundable, temporarily tradeable, enchanted, socketed, protected, or high-item-level gear.

## Development checks

From the repository root:

```bash
python3 -m unittest discover -s tests -p 'test_*.py'
luac -p ArcaneShredderUI/ArcaneShredderUI_Locales.lua ArcaneShredderUI/ArcaneShredderUI.lua
```
