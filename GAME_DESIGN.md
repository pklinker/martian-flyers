# Barsoom Flyers — Game Design Document

*Companion document: `IMPLEMENTATION_PLAN.md` (architecture, status, roadmap).*

## 1. Vision

A single-player, turn-based tactical game in the spirit of **Star Fleet
Battles** — hex map, plotted movement, firing arcs, and above all the SSD:
a ship schematic where damage is marked off box by box — reskinned with
**flyers from Edgar Rice Burroughs' Barsoom** (John Carter of Mars). The
player and an AI opponent each fly one ship, maneuvering for position over
the dead sea bottoms of Mars.

The core feeling to preserve from SFB: **damage is capability erosion, not a
hit-point bar.** Losing engine boxes makes you slower. Losing your rudder
makes you turn like a barge. Losing a gun silences it. The player should
*feel* their ship dying by inches — and see it, on a damage sheet that looks
like the pencil-marked photocopies of the original game.

The core feeling to add from Barsoom: airships are **buoyant, crewed, and
mortal in a particular way** — they don't explode so much as settle, listing
and sinking, onto the ochre moss of a dead sea bottom. And when ships close,
it should eventually come to grapnels and swords.

## 2. The translation table (SFB → Barsoom)

| SFB concept | Barsoom equivalent | Design note |
|---|---|---|
| Shields (6 facings) | **Armor plating** (6 facings) | Absorbs first, marked off per facing, **never repairs**, never hit by internal damage. Directional play: protect your weak facings, attack theirs |
| Hull boxes | **Buoyancy tanks** (eighth-ray) | The DAC's most common internal hit. Each ship has a **falling line** (marked in red on the SSD's buoyancy row): hole tanks down to it and the flyer settles onto the dead sea bottom — forced grounding = **defeat** |
| Energy allocation | **Crew allocation** | Each turn, assign crew boxes: man guns (required to fire), **engine room** (powers speed — see below), damage control, (later: lookouts, boarding parties). Crew casualties shrink the pool — the resource squeeze that gives SFB its soul |
| Warp engines | **Radium engine** | **Boxes** set the speed ceiling; **engine-room crew** sets how much of it you can drive this turn (`speed ≤ engine_crew × rate`). Speed thus competes with guns and damage control for crew — the power economy, in Barsoom terms |
| Impulse engines | **Propellers** | Boxes scale acceleration/deceleration per turn |
| (Turn mode chart) | **Rudder** | Damage worsens turn mode (+1 at half, +2 at zero) |
| Phasers | **Deck guns** (light/medium/heavy radium guns) | Range brackets, firing arcs per mount, reload turns for the big ones |
| Photon torpedoes | **Aerial radium torpedoes** | A light flyer's asymmetric punch: finite rack (marked off as fired), armour-piercing warhead, long reload — looses from range to reach a cruiser's internals through plating that shrugs off shells |
| Warp core breach | **Radium magazine explosion** | Each magazine hit detonates on 5+ (d6): catastrophic loss |

*Altitude bands were prototyped and **cut**: an extra per-turn plot with no
real decision attached is bookkeeping, not depth (see §8). The Barsoom feel
of sinking ships lives in buoyancy/grounding. Revisit only if terrain ever
makes height a played decision.*

## 3. Core systems

### Movement
- Flat-top hex map; facing 0 = north, six facings clockwise.
- Plotted speed per turn; speed change bounded by propeller-derived
  acceleration; top speed bounded by the engine-box ceiling **and** by the
  engine-room crew committed this turn (power economy — see crew allocation).
- **8 impulses per turn**, SFB fractional distribution: a speed-S ship moves
  on exactly S impulses, interleaved with the enemy — fast ships weave around
  slow ones.
- **Turn mode**: must move N hexes straight before changing facing one
  hexside; N grows with speed and with rudder damage.
- Ships may not enter an occupied hex (collision rule).

### Gunnery
- Per-mount **firing arcs** expressed as relative bearings (0 = dead ahead);
  rendered as 6-sector arc roses on the SSD.
- **Range brackets** per gun type: to-hit (minimum on d6) and damage fall off
  with range.
- Heavy guns reload over multiple turns (tracked as pips); light guns fire
  every turn. Manning a gun costs crew.
- **Simultaneous resolution**: all fire declared, then resolved; killing a
  ship does not cancel its declared return fire.

### Damage
1. Hit lands on the **struck facing** (computed from firer's true bearing
   off the target).
2. Facing armor absorbs first; marked off permanently.
3. Overflow rolls per-point on the **Damage Allocation Chart** — a weighted
   table over surviving systems (buoyancy heaviest, then crew, engines,
   props, rudder, gun mounts, bridge, magazine, damage control).
4. Specials: magazine hits risk detonation (5+); a ship with nothing left
   becomes a destroyed hulk; bridge loss halves max speed.
- Damage control crew can patch buoyancy tanks (5+ per allocated crew per
  turn). Armor is never repairable.

### Buoyancy & grounding
- Each ship has a **falling line**: a tank count at or below which it can no
  longer hold the air (scout: 1 of 8; cruiser: 3 of 14). It is drawn in red
  on the SSD's buoyancy row — the player watches the X's eat toward it.
- At upkeep, **damage control patches tanks first, then the falling line is
  checked**: a flyer sitting right on the line can be lifted back above it by
  its repair crew the same turn — clawing back from the brink, very Barsoom. If
  it's still at or below the line after repairs, it **settles onto the dead sea
  bottom: grounded = you lose**, even with guns and crew intact. Patching is
  buoyancy-only (armor never repairs), and each patch is announced in the log
  so the recovering tank count never looks like a glitch.

### Victory
A side wins when the enemy flyer is **destroyed** (DAC exhaustion or
magazine) or **grounded** (buoyancy at or below the falling line). Future:
capture by boarding.

## 4. The two launch ships

| | **Helium Scout Flyer** (player default, blue) | **Zodangan Patrol Cruiser** (red) |
|---|---|---|
| Doctrine | Fast and agile; wins by holding the range band where its guns bite and the heavies can't | Broadside brawler; slow to turn, armored and crewed to absorb punishment while heavies cycle |
| Speed / buoyancy | 8 / 8 tanks, falls at 1 | 5 / 14 tanks, falls at 3 |
| Armor | Bow-heavy, thin aft (3/2/1/1/1/2) | Even and thick (5/4/4/3/4/4) |
| Guns | 3 light (bow, port, stbd) + medium chase gun + **bow torpedo tube** (3 AP shots, forward arcs) | Medium bow + **heavy port & starboard batteries** + medium stern |
| Crew | 6 (manning everything costs 5; full speed 8 costs 4) | 12 (manning everything costs 10; cruise speed 4 costs 2) |
| Tactical problem | Fragile; one heavy broadside hurts. And its crew can't run the engine flat-out *and* man every gun — **kiting means firing light** | Its weight of metal is **broadside-only** — nose-on it fires one medium gun; it must turn to fight, and turning is what it does worst. But it brawls at low speed, so it can man everything cheaply |

Observed baseline (200 simulated battles, naive greedy AI on both sides):
cruiser wins ~88%. We long assumed this was the AI's fault and that a
competent scout would kite at range 5–8.

**Update (Phase C AI built).** With a doctrine-driven AI (`ai/ship_ai.gd`),
the cruiser wins **~98%** — and tracing shows the kite premise was incomplete,
not the AI: at range 5–8 the scout's light guns (1 damage) can't penetrate the
cruiser's 4–5 armor, while the cruiser's heavy guns reach all the way to 18, so
kiting never escapes them.

This is *correct*, not a bug to balance away: a scout has no business winning a
gunnery duel against a cruiser. The scout's path to threatening a heavy is
**asymmetric punch — torpedoes** (§7, item 1): a limited-ammo, armor-piercing
weapon it can loose from range. The deck-gun matchup stays cruiser-favored on
purpose; the scout earns its kills with a well-timed salvo, not by out-shooting
the brawler. So the gun/armor numbers are left as-is, and torpedoes are the
balance lever. See `IMPLEMENTATION_PLAN.md` Phase B.

**Torpedoes shipped.** The scout now carries a 3-shot, armour-piercing aerial
torpedo tube, and the AI uses it (man the tube first when in reach, loose only
on good odds). The light flyer finally has a *mechanism* to make a cruiser bleed
without any deck-gun or armour number changing.

**Open-board caveat.** When the map became a large open field with a follow
camera (so a flyer can't get pinned against a wall), the AI-vs-AI scan fell from
**scout ~9–10% to ~0%**: the cramped old board had been *forcing* engagements,
and an open field lets the scout kite at a range where its salvo discipline
holds the torpedoes. Battles still resolve cleanly and a *player*-flown scout
closes and fires torpedoes fine, so this is an **AI-doctrine/tuning gap, not a
movement bug**. Making the AI scout a credible open-board threat — close into
the torpedo's good bracket while the tube is loaded, and/or a stronger tube — is
the open balance task. The board stays open; the doctrine gets smarter.

## 5. Turn sequence

1. **Allocation** — assign crew (man guns / engine room → caps this turn's top
   speed / damage control). The squeeze: you can't do all three at once.
2. **Plot** — set speed change, bounded by the crew-gated top speed.
3. **Movement** — 8 interleaved impulses per the chart.
4. **Fire** — declare, then resolve simultaneously; mark damage on the SSDs.
5. **Upkeep** — reloads tick, **damage control patches tanks, then** the
   falling line is enforced (so DC can save a flyer on the brink), victory check.

## 6. Presentation

- **The SSD is the star.** Ink-on-paper aesthetic: parchment ground, black
  boxes, pencil-gray shading and red X on destroyed boxes, marked off along
  each strip just like the tabletop sheets. Armor laid out spatially (bow
  top, stern bottom, port/starboard down the edges). Arc roses, reload pips,
  manned dots. Struck facing flashes on hit. The sheet *is* the damage model,
  visibly.
- **The map** is the dead sea bottom: ochre ground, subtle grid, ship tokens
  as facing-arrows. Legal moves highlight in green with resulting-facing
  ticks. The field is **large and the camera follows the flyers** — it scrolls
  to keep both framed and zooms out only as they separate, so the board reads
  as open sky rather than a boxed arena (a distant finite edge still keeps
  movement deterministic and stops a crippled flyer fleeing forever).
- The map fills the view; both SSDs live in a **toggleable overlay** the player
  opens to study the sheets (own and the enemy's public one — fog-of-war over
  enemy internals is a possible later option) and closes to see the whole hex
  field. Combat log beneath the map.
- Combat log narrates in genre voice where it's cheap to do so ("last tank
  holed — the flyer is falling", "damage control patches a buoyancy tank",
  "MAGAZINE EXPLOSION — consumed in radium fire").

## 7. Future design directions (priority order)

1. ~~**Torpedoes — the scout's answer to armor.**~~ **DONE (Phase B).** The
   scout carries an aerial radium torpedo tube: a 3-shot rack marked off on the
   SSD as it's loosed, armour-piercing (bypasses 3 plating), 2-crew to man, a
   3-turn reload, reaching out to range 11. A fast, lightly-gunned flyer still
   can't out-brawl a cruiser with deck guns — but a well-timed salvo makes one
   bleed, and the finite rack is a real resource decision (when do you spend
   it?). The crew cost sharpens the existing squeeze: at a full kiting sprint
   the scout can man the tube *or* its guns, not both. It moved the scan to
   scout ~9–10% / cruiser ~89% (was ~2/98) with the deck-gun and armour numbers
   untouched — the fix for the §4 balance finding, *not* a nerf to the cruiser.
   *Future tube tuning (rack size, reload, AP) is a balance dial; the mechanic
   is in.*
2. **Boarding** — at range 0–1, grapnel attempt; crew-vs-crew melee using
   allocated boarding parties; capture victory. This is the Barsoom endgame
   and the payoff for the crew-allocation economy.
2. **Terrain** — hills (LOS blocks), ruined cities, dust storms (spotting
   penalties; gives lookouts a job). *If terrain ever wants a vertical
   dimension, that is the moment to reopen the altitude question — not
   before.*
3. **Listing** — split buoyancy port/starboard; imbalance penalizes
   maneuver. Tanks are already location-tagged in spirit; make it real.
   This is the mid-fight consequence of buoyancy damage (not a speed nerf —
   speed belongs to engines, acceleration to propellers).
4. **Crits with flavor** — fires that spread, jammed steering, officer
   casualties.
5. **Fleet scenarios** — multiple ships per side, points buy, more classes
   (one-man flyer, Helium battleship), scenario seeds (convoy raid, tower
   assault).
6. **AI doctrine** — utility AI expressing each hull's playstyle, with
   lookahead via the deterministic engine; difficulty as evaluator weights.

## 8. Design guardrails

- Every mechanic must be expressible as **boxes on the sheet** and decisions
  the player makes with visible tradeoffs. If it can't be marked off or
  allocated, question it.
- Keep d6 throughout: one die type, SFB tradition, readable odds.
- Complexity budget: SFB's depth, not SFB's bookkeeping. The computer does
  the DAC and the impulse chart so the player can think about position,
  arcs, and the crew squeeze.
- Theme test for new features: would it happen in a Burroughs chapter? Radium
  shells, buoyancy tanks, swordplay on the deck — yes. Tractor beams — no.

## 9. Terrain

- Hills and towers — LOS blocking. If a hill or tower hex lies between the 
  firer and the target (strictly between, not at either end), the shot cannot 
  be made at all. No ammo is spent, no reload starts — the gun just can't see 
  the target. Ships fly over terrain freely; it only affects firing.
- Dust storms — spotting penalty. Each dust storm hex along the line of sight 
  path (including the target's own hex if it's sitting in dust) adds +1 to the 
  to-hit number needed. So a gun that normally hits on 3+ becomes 4+ through one 
  dust hex, 5+ through two, and so on. A natural 6 is never guaranteed — if the 
  penalty pushes the threshold past 6, the shot can't connect.
- Lookout crew — the counter. During allocation, you can pull crew off guns or 
  damage control and assign them as lookouts. Each lookout crew member cancels 
  one hex of dust penalty for all your shots that turn. So one lookout restores 
  a 4+ back to 3+ when there's one dust hex in the way.
- What's not affected. Movement is completely unaffected — flyers fly above 
  the terrain. Armor, turn mode, buoyancy, and all other systems are unchanged 
  by terrain. It's purely a firing concern.
- The tactical tension. The hill ridge across the midfield forces both 
  captains to choose: fly the direct approach and lose firing angles when the 
  ridge interposes, or bank around the flanks and give up range. The dust cluster 
  near the cruiser's side is a double-edged tool — the scout can use it as cover 
  for a torpedo run (the cruiser's shots through dust are harder), but only if 
  the scout allocates lookouts so its own shots aren't equally degraded.
