# Player Notes

A WoW Forever addon for keeping your own notes about other players.

## Features

- **Right-click menu** on a player's portrait / unit frame (target, party, raid) and on player names in chat, friends and guild lists:
  - **Create Note** when you have no note about that player yet
  - **Read Note** and **Edit Note** when you do
- **Quick Note**: two dropdowns on every note, an adjective and a noun, for a fast coloured tag such as **Good Tank** or **Bad DPS**
  - Default adjectives: Good (bright green), Okay (white), Bad (red)
  - Default nouns: Tank (blue), Healer (dark green), DPS (white)
  - **Create Adjective / Create Noun** at the bottom of each dropdown adds your own word with a colour from a 12-colour palette
  - A note can be just a Quick Note, just text, or both
- **Per-ruleset notes**: players are separated by ruleset (PvE, PvP, RP, Hardcore), so each ruleset keeps its own notes. You only see notes made on the ruleset of the character you are playing.
- **Faction icons**: each note remembers the player's faction (Alliance or Horde) and shows its icon in the list and the note window
- **Minimap button** (LibDBIcon): left-click opens Player Notes, right-click turns tooltip notes on/off, drag to move
- **Tooltip notes**: hover a player and the first part of your note shows at the bottom of their tooltip, cut to a character limit (default **50**) with `...`
- **Options window** (`/pn`):
  - Turn tooltip notes on or off
  - Set the tooltip character limit (5–500; the − / + buttons step by 10, or 50 with Shift)
  - Manually add a player and their note
  - Browse, search, read, edit and delete all saved notes (columns: Player, Quick Note, Note)
  - **Quick Note Words** panel: create adjectives and nouns, and rename or recolour any word, including the defaults. Custom words can be deleted; the defaults can't (rename them if you don't want them)
- Notes are **account-wide**, so every one of your characters sees them

## Names

WoW Forever names are "First-name Last-name". Player Notes matches names without caring about upper/lower case or extra spaces, so a note added manually as `john smith` is found on **John Smith**. The first time the game shows you that player (tooltip), the stored spelling is updated to match.

On WoW Forever, the game's `UnitName()` returns the first name and surname as two separate values, so Player Notes joins them (or uses `GetUnitName()`, which returns the full name) to always save the complete "First-name Last-name".

## Installation

1. Copy the `PlayerNotes` folder (including its `Libs` folder) into:
   ```
   World of Warcraft\_forever_\Interface\AddOns\PlayerNotes\
   ```
2. `/reload` or restart the game.

## The note window

- **Read view** shows the full note plus when it was created and last edited. Buttons: Edit, Delete, Close.
- **Edit view** has a multi-line text box (up to 2,000 characters, counter in the corner). Buttons: Save, Delete, Cancel.
- Saving an empty note deletes it (after asking).
- Drag the window to move it; Escape closes it. Window positions are remembered.

## Rulesets and factions

- The ruleset is read from the game when you log in (`C_GameRules`): Hardcore, RP, PvP, otherwise PvE. Notes, tooltips and right-click menus only use the notes of that ruleset. The `/pn` window shows which ruleset you are on.
- A note's faction comes from the player's unit (target, mouseover, party...) or, for chat/friends/guild names, from their race. Hovering the player in game fills in or corrects it, just like their class colour. Notes without a known faction show no icon.
- The manual add form has Alliance / Horde buttons next to the name; it starts on your own faction. Click the selected one again to leave the faction unknown.
- Quick Note words are shared by all rulesets.

## Quick Notes

- In the note window, pick an adjective and a noun from the two dropdowns above the text box. Choose **None** to leave one empty.
- **+ Create Adjective... / + Create Noun...** opens a small window: type the word (up to 20 characters), click a colour swatch, check the preview, Save. The new word is selected right away.
- In `/pn`, the **Quick Note Words** panel on the right lists every word. Click a word (or **Edit**) to change its name or colour; **X** deletes a custom word. Renaming or recolouring a word updates every note that uses it. Deleting one removes it from those notes.
- The tooltip shows the Quick Note before the note text: `Note: Good Healer - Kept the group alive...`. The character limit applies to the written part only.
- Search in `/pn` also matches Quick Note words, so searching `tank` finds every note tagged Tank.

## Commands

| Command | Effect |
|---|---|
| `/pn` or `/playernotes` | Open / close the options window |
| `/pn target` | Read (or create) a note for your current target |
| `/pn First Last` | Read (or create) a note for that player |
| `/pn tooltip` | Turn tooltip notes on/off |
| `/pn minimap` | Show/hide the minimap button |
| `/pn limit <number>` | Set the tooltip character limit |
| `/pn debug` | Show version, ruleset, faction, notes per ruleset and which menu/tooltip hooks are in use |
| `/pn help` | Show help |

Player Notes also adds an entry under the game's **Options → AddOns** list with a button that opens the options window.

## Saved data

Everything is stored in the `PlayerNotesDB` SavedVariable:

```lua
PlayerNotesDB = {
    notesByRuleset = {
        Hardcore = {
            ["john smith"] = { name = "John Smith", text = "...", adj = "adj_good", noun = "noun_healer",
                               class = "PRIEST", faction = "Alliance", created = 1760400000, updated = 1760400000 },
        },
        PvP = { ... },
    },
    minimap = { hide = false, minimapPos = 220 },
    words = {
        adjectives = { { id = "adj_good", text = "Good", color = "1eff00", default = true }, ... },
        nouns      = { { id = "noun_tank", text = "Tank", color = "3d8bff", default = true }, ... },
    },
    settings  = { showTooltip = true, tooltipLimit = 50 },
    positions = { ... },   -- window positions
}
```

## Compatibility notes

- Right-click menus: uses the modern `Menu.ModifyMenu` system when the client has it, otherwise hooks the older `UnitPopup_ShowMenu` dropdowns. `/pn debug` shows which one was found.
- Tooltips: uses `TooltipDataProcessor` when available and `OnTooltipSetUnit` on older clients (with a check so the note is never added twice).
- Your own character doesn't get the Create/Read/Edit options.

## Changes

**1.3.1**
- Removed all realm handling: WoW Forever separates servers by ruleset, not realm, so names are used exactly as the game gives them.

**1.3.0**
- Notes are kept per ruleset (PvE / PvP / RP / Hardcore); only notes of your current ruleset are shown.
- Faction (Alliance / Horde) stored per note, shown as an icon in the saved-notes list, the note window title and the list tooltip; picker in the manual add form.
- Minimap button via the embedded LibDBIcon-1.0 (with LibStub, CallbackHandler-1.0, LibDataBroker-1.1), with a "Show minimap button" setting and `/pn minimap`.
- The "Tooltip" settings section is now "Settings".

**1.2.0**
- Quick Note: adjective + noun dropdowns when creating or editing a note, with Create Adjective / Create Noun and a colour palette.
- New Quick Note column in the saved-notes list, and a Quick Note Words panel in the `/pn` window to create words and edit the defaults.
- Quick Notes appear in player tooltips and in the note window, and can be searched.
- The `/pn` window is wider (780 x 680) to fit the Quick Note Words panel.

**1.1.0**
- New look matching Heal Rank Advisor and Waylaid Crate Advisor: solid dark window with layered gold trim, title plate on the top edge, gold section headings and rules, striped list rows, footer with Close button.
- The note window's title plate shows the player's name in their class colour; created/edited dates sit on the line under it.
- The saved-notes list now scrolls with the standard scrollbar and has Player / Note column headers.
- Input boxes light up gold while you type in them. Both windows can also be dragged by their title plate.

**1.0.1**
- Fixed: notes created from the right-click menu or `/pn target` were saved under the first name only. The surname is now included.
