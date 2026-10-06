# WIN or DIE — a 16-player Roblox party game

WIN or DIE is a round-based party game for up to 16 players. Each round, the server votes on one of three random minigames. Win a round and you score a point; the first player to five points wins the game. Every third game switches to an elimination format, where the worst players of each round are cut until a final showdown.

The game has **55 minigames** (races, last-one-standing games, team games, hide and seek, a penalty shootout and more), a lobby with shops and daily rewards, saved progress, and spectating for players who are out.

**Status:** in final testing before release. The game link will be added here at launch.

## Contents

- [What's in this folder](#whats-in-this-folder)
- [How it works](#how-it-works)
- [Design decisions](#design-decisions)
- [What I learned](#what-i-learned)
- [How this was built](#how-this-was-built)

## What's in this folder

This is a selection of the game's core scripts, not the whole game: 17 files and about 5,400 lines out of roughly 240 live scripts. The full source stays private because the game is live. Some files refer to modules that are not included here.

| Path | What it does |
|---|---|
| [`src/server/RoundManager.server.luau`](src/server/RoundManager.server.luau) | The game loop: intermission, pick a map, run the minigame, award wins, repeat. |
| [`src/server/Voting.luau`](src/server/Voting.luau) | The three voting pads and how the next game is chosen. |
| [`src/server/PlayerData.luau`](src/server/PlayerData.luau) | Coins, cosmetics and progress, saved safely across servers. |
| [`src/server/Stats.luau`](src/server/Stats.luau) | Lifetime stats, badges and achievements. |
| [`src/server/Elimination.luau`](src/server/Elimination.luau) | The elimination game format. |
| [`src/server/Twists.luau`](src/server/Twists.luau) | Random round modifiers such as low gravity. |
| [`src/server/Modes/`](src/server/Modes/) | Five of the 55 minigames: Hex Spleef, Spinning Bar, Tug of War, King of the Hill and Glass Bridge. |
| [`src/client/`](src/client/) | The matching client scripts: on-screen effects and UI for those five minigames. |
| [`src/shared/UIKit.luau`](src/shared/UIKit.luau) | The shared look for every menu: colors, fonts, buttons and windows. |

## How it works

### One loop, many minigames

`RoundManager` runs the same loop for every round:

1. **Intermission** in the lobby while players vote.
2. **Pick the map.** A paid pick wins first, then the voting pad with the most players, then a random choice from the three games on offer. A game cannot repeat until five other games have been played.
3. **Intro and countdown.** Everyone sees a short intro explaining the game, then players are teleported and frozen for a three-second countdown.
4. **Run the minigame** until it reports winners or the two-minute clock runs out.
5. **Award** round wins, coins, experience and stats, then go back to the lobby.

### Every minigame has the same shape

Each minigame is a ModuleScript that returns a table with the same few functions. `RoundManager` knows nothing about any particular game. It only calls these:

| Function | When it is called |
|---|---|
| `prepare(map)` | Optional. Before players arrive, to reset the map. |
| `start(map, players)` | Players are in place. Set up the round. |
| `begin()` | Optional. The moment the countdown ends. |
| `getWinners()` | Every tick. Returns `nil` until the round is decided, then the winners and a message. |
| `timeUp()` | Optional. The clock ran out, so the minigame picks a winner. |
| `stop()` | Always. Disconnect events and clean up. |

A minigame can also set a few fields: `intro` (how-to-play text), `countdown` (a longer countdown) and `noFreeze` (players may move during the countdown).

Adding a minigame means writing one module and tagging a map folder with its name. Every call into a minigame is wrapped in `pcall`, so an error inside one game ends that round and the loop carries on.

### The server decides, the client draws

Anything that affects who wins runs on the server, and the client only shows it.

- **Hex Spleef.** The floor is a hexagon grid, so the server works out which tile a player is standing on from their position with a little math. No `Touched` events are involved. The server marks *when* a tile will drop, and each player's client script plays the fade on their own screen.
- **Tug of War.** The server limits how fast one player can pull, which stops spam clicking and cheating.
- **Stale timers.** Each round has a counter. Delayed callbacks carry the counter they started with and quit if the round has moved on, so a timer from an old round can never affect a new one.

### Saving without losing data

`PlayerData` saves with Roblox DataStores and guards against the usual ways players lose progress:

- **Retries.** The save service sometimes fails briefly, so each load and save is tried several times.
- **Session locking.** While a player is in one server, their save is marked as in use. A second server waits for the first to finish before loading, so it can never load an old copy and overwrite a newer one. Locks from crashed servers expire.
- **No blind overwrites.** If a player's data failed to load, the server never saves for them, so a failed load cannot wipe a save.
- **Shutdown.** When a server closes, it waits until every save has finished.

## Design decisions

These are choices I made while playtesting:

- **First to five wins, not ten.** At ten, games ran past thirty rounds.
- **Three voting options, and votes stick.** A vote stays on the last pad a player stepped on, so nobody has to stand still to keep it.
- **No repeats until five other games have been played**, so the same game does not keep coming back.
- **Out means spectator.** A player who is out watches the rest of the round and can switch between the players still alive.
- **Every map is closed off.** No map can see another, and players cannot leave the play area.
- **Elimination every third game**, to break up the "first to five" format.
- **Instructions stay small.** How-to-play text goes in the intro before the round, not in a banner over the gameplay.

## What I learned

- **Client and server are different programs.** Deciding what the server must own, and what is safe to leave to the client, was the main design question in almost every minigame.
- **A small shared interface scales.** Because every minigame has the same six functions, the game grew from one minigame to 55 without the round loop getting more complicated.
- **Saving data is harder than it looks.** Most of `PlayerData` exists to handle failure: failed loads, two servers at once, and shutdowns.
- **Make testing cheap.** Attributes on `RoundManager` force a map, shorten intermissions or play a list of games in order, so a change can be tested in seconds without editing code.

## How this was built

I built this in Roblox Studio with an AI coding tool (Claude) connected to Studio. I designed each minigame and system, wrote down how it should play, playtested every one and sent back the fixes. The AI wrote most of the Luau and explained it as it went, which is how I am learning the language. I had never opened Roblox Studio before starting this project in September 2026.
