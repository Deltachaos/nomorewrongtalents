# NoMoreWrongTalents

Retail World of Warcraft addon that nudges you when your **talent loadout** does not match what you set up for the Mythic+ dungeon or raid boss you are on. Pick the loadout you want per dungeon or boss in settings; if you forgot to switch, you get a popup and can apply the right one with one click (when you are not in combat).

**Author:** Deltachaos

## Install

1. Put the `NoMoreWrongTalents` folder in your retail `Interface\AddOns` directory.
2. On the character screen, enable the addon in the AddOns list.

Works with the game version supported by the addon’s TOC (see `NoMoreWrongTalents.toc`).

## How to open settings

- Type **`/nmwt`** in chat  
- **Esc → Options → AddOns → NoMoreWrongTalents**  
- **Minimap button** (left-click)

## What you configure

Everything is **per specialization**. You link a **saved talent loadout** (the named presets from the talents UI) to:

- **Mythic+** — each season dungeon you care about  
- **Raids** — each boss you care about (listed by raid tier in the UI)

You can hide or reposition the minimap button in those same options.

## What you see in-game

**Mythic+:** If you set a loadout for that dungeon and it does not match what you have selected now, you get a warning. You can switch or dismiss.

**Raids:** The warning focuses on bosses that matter for where you are and what you have configured. It only pops up when something still does not match—if you are already on the right loadout, it stays quiet. You can pick the boss you are pulling from a dropdown; the addon remembers that through the fight until you move on (new visit, a kill, or changing pulls in a sensible way).

**Ready checks** in raid can trigger that same kind of reminder once when it is relevant, so the group does not start with someone on the wrong build.

**Minimap:** Right-click tries to open the check window when it makes sense (handy if you closed it and want it back).

## License

This project is licensed under the **GNU General Public License v3.0**. See [`LICENSE`](LICENSE) for the full text.
