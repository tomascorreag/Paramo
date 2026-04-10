# PARAMO — Game Design Document

**Genre:** Tower Defense / Environmental Strategy
**Engine:** Godot 4
**Platform:** Desktop (landscape)
**Vertical Slice:** 1 level, 30-45 min run
**Art Style:** Isometric pixel art, serious tone. Dome Keeper's atmospheric weight and chunky readability, reprojected into isometric (diamond tiles, 2:1 aspect). Dense per-tile detail that holds up at strategic zoom and rewards closer inspection.

---

## Core Design Thesis

**The paramo operates on geological time. Humans destroy on industrial time.**

Every mechanic reinforces this asymmetry. A frailejon takes centuries to grow and seconds to burn. A mined hillside takes decades to revegetate. The game is not about winning — it's about enduring, stewarding, making impossible tradeoffs about what to save when you can't save everything.

Conservation is not a battle you win. It's a commitment you maintain.

---

## Concept

The player is a field coordinator for a conservation NGO protecting a paramo mountain — a high-altitude tropical ecosystem unique to the Andes. The paramo is a "water factory": its frailejones capture fog, its mosses retain moisture, its glacial lake feeds rivers that supply millions downstream.

Threats climb the mountain from below — miners, tourists, cattle, land speculators, invasive species. Environmental threats strike from all directions — drought, fire, erosion, climate shift. The player must physically traverse the mountain to plant, build, investigate, and respond, while managing their organization from a mid-mountain research station.

At the summit: a glacial laguna. If it dies, everything dies.

---

## The Mountain

### Layout

The map is a single mountain peak rendered in true isometric projection (diamond tiles, 2:1 aspect ratio), landscape orientation. Wide at the base, narrowing toward the summit. The laguna sits at the top — a still, reflective lake surrounded by exposed rock and lichen. Vertical elevation is faked by tile stacking / elevation offset, not a 3D camera — the projection is locked.

Altitude is a continuous variable, not discrete zones. It modifies every system:

| Rule | Low Altitude | Mid Altitude | High Altitude |
|------|-------------|-------------|---------------|
| Plant growth speed | Fast | Medium | Very slow |
| Ecosystem recovery | Quick | Moderate | Extremely slow |
| Human threat exposure | High | Medium | Low (but devastating when it arrives) |
| Environmental exposure | Lower | Moderate | Highest (wind, UV, cold) |
| Infrastructure disruption | Minimal | Moderate | Severe |
| Player movement speed | Normal | Slowed | Slowest |
| Water generation | Low (downstream) | Moderate | Highest (fog capture, laguna) |

No hard-coded biome bands. Instead, altitude-based planting rules and environmental pressures create emergent zonation — the mountain looks banded because of gameplay, not because the designer drew lines.

### Tile System

Each tile has:
- **Ecosystem health:** Healthy > Stressed > Degraded > Barren > Scarred
- **Tile type:** Determined by altitude, moisture, and player action — frailejon field, moss bog, rocky outcrop, stream, grassland, trail, built infrastructure
- **Moisture level:** Affected by proximity to water flow, season, tile health
- **Biodiversity index:** Per-tile species richness — drives resilience and synergies with adjacent tiles

**Starting state:** Mixed. The upper paramo is mostly healthy but shows some climate stress. Mid-mountain has patches of old cattle damage, some invasive grass encroachment. Lower slopes show previous agricultural scarring and an abandoned mining site. The player inherits a wounded landscape, not a pristine one.

### Water Flow

Water is generated primarily at upper altitudes:
- Frailejones capture fog and channel moisture into the soil
- The laguna seeps water into streams
- Moss bogs retain and slowly release rainfall

Water flows downhill through natural stream channels. Tiles along water paths are more fertile (easier planting, faster restoration). Disrupting upper water generation starves everything below — even healthy lower tiles will stress without water from above.

Player-built water channels can redirect flow to dry areas, but pulling water from one path starves another. Every redirect is a tradeoff.

### The Laguna

The summit lake. Headwater for the entire mountain. Sacred.

**Purity meter:** Degrades from mining runoff (travels through groundwater), erosion carrying sediment, tourist contamination, acid deposition from industrial activity. Degradation is slow and hard to notice until it's already in trouble.

**Consequences:**
- Purity below 75%: Water generation across entire map reduced 25%
- Purity below 50%: Downstream community support begins dropping (their water supply is declining)
- Purity below 25%: Cascade failure — upper tiles begin dying regardless of other conditions
- Purity at 0%: Game over. The laguna is dead.

**Key insight the player must learn:** Protecting the laguna requires acting far downhill, long before any threat reaches the summit. By the time contamination is visible at the lake, it's almost too late.

---

## Resources

### Water

The paramo's primary output. Generated passively by healthy terrain — frailejones capture fog, moss retains moisture, healthy soil filters rainfall.

**Used for:** Planting, firefighting, sustaining the ecosystem during dry spells, supplying downstream communities.

**If water drops critically:** Plants die in cascade, restoration becomes impossible, community support falls.

**HUD element:** "Downstream communities with water access" — a number that ticks down as the paramo degrades. Makes the stakes concrete beyond the map.

### Funding

NGO budget. Baseline trickle from grants (unreliable — can be cut by events). Spikes from eco-tourism revenue, research publications, legal victories.

**Spent on:** Infrastructure, personnel, legal actions, community programs, equipment upgrades.

**If funding hits 0 for 2+ consecutive seasons:** NGO shuts down. Game over.

### Community Support

Not spent directly — acts as a global modifier.

**High support effects:**
- Fewer desperate farmer/cattle threats spawn
- Rangers are more effective (locals provide intel)
- Legal actions get political backing (better success rates)
- Volunteers occasionally assist with restoration
- Eco-tourism programs yield more revenue

**Low support effects:**
- More encroachment from edges
- Rangers get harassed, reduced effectiveness
- Restoration projects vandalized
- Political cover for mining permits increases
- Funding from local sources dries up

**Generated by:** Economic alternatives (eco-tourism jobs, sustainable agriculture training), education programs, visible positive outcomes (healthy downstream water supply).

**Lost by:** Punitive measures without alternatives (fences without community programs), ignoring local needs, ecosystem degradation itself (if the paramo dies, so do livelihoods — locals turn to extraction out of desperation).

**Design intent:** Conservation that ignores communities fails. A player who only builds fences and hires security will lose because community support craters and threats multiply. The game mechanically punishes fortress conservation.

---

## The Player Character

A field coordinator. A small isometric sprite you walk across the mountain — a person on the slope, not a floating strategic cursor. The same physical-presence fantasy as Dome Keeper's operator, in isometric projection. Occupies a tile and must move to locations to interact with them.

### Camera & Visibility

The camera follows the player. Only a fraction of the mountain is visible at any time — the player sees their immediate surroundings, not the full map. This reinforces the field coordinator fantasy: you are a person on a mountain, not an omniscient strategist.

**Visibility rules:**
- Base visibility radius around the player character (scales slightly with altitude — you can see further from the peak)
- Monitoring stations reveal tiles within their radius permanently (or until destroyed). Building a monitoring network IS building your vision.
- Severe weather (fog, heavy rain) reduces visibility radius
- Tiles outside visibility are hidden — not blacked out, but showing their last-known state (stale information). Changes happen off-screen and the player discovers them when they return or receive a report.

**Information flow for off-screen events:**
- **Audio cues:** Directional sounds from off-screen — chainsaw buzz, fire crackle, tourist chatter, cattle lowing. Experienced players learn to read audio for threat type and approximate direction. Distance affects volume.
- **Monitoring station alerts:** Stations within range detect threats and send alerts (notification popup with approximate location and threat type). More/better stations = more detailed alerts.
- **Ranger reports:** Rangers on patrol periodically flag threats they encounter. Notification with approximate location. More rangers with wider patrol routes = better coverage.
- **Planning phase overview:** Between seasons, the player gets a full strategic map view from the research station — a satellite/overview showing the entire mountain's current state. This is the only time the whole map is visible. Review damage, plan the next season, then drop back to ground level when the season starts.
- **Station map view:** The player can also access the strategic overview mid-season by returning to the research station. This costs field time — the tradeoff is real.

**What this creates:** An awareness progression arc across the run. Early game: near-blind, discovering threats by stumbling into them. Mid game: monitoring network and ranger patrols provide a web of intel. Late game: coordinating a complex information system while still needing to be physically present for critical actions. The mountain goes from mysterious and threatening to known and managed — but never fully controlled.

### Movement

- Downhill is faster than uphill
- Trails create fast-travel corridors (incentivizes trail-building beyond tourism)
- Degraded/barren tiles slow movement (rough terrain)
- Crossing streams without bridges is slow
- Severe weather (heavy rain, fog) slows movement further
- High altitude slows movement (thin air)

### Movement Upgrades

Progression rewards that expand the player's reach:
- **High-altitude oxygen kit:** Reduces altitude movement penalty
- **Bridges:** Built over streams, enables fast crossing
- **Trail network:** Each trail segment improves travel through that tile
- **Radio:** Unlocks Tier 3 remote actions (see Interaction Tiers below). Without the radio, the player has NO remote capability — must physically be at a location or at the station for everything.
- **Weather gear:** Reduces weather-based movement penalties

### Interaction Tiers

Actions are split into three tiers based on where the player must be to perform them. No action queuing — everything happens in real-time when and where the player initiates it.

**Tier 1 — Physical Presence (must be on the tile)**

Actions that are physical work. The core reason movement matters.

- Planting / building / repairing infrastructure
- Firefighting (direct, tile by tile)
- Investigating monitoring station alerts (confirming threat identity before committing resources)
- Confronting illegal miners directly
- Collecting water/soil samples (scientific evidence for legal cases)
- Assessing tile damage (prerequisite before restoration can begin)
- Directing rangers to specific nearby targets with precision

**Tier 2 — Research Station Only**

Administrative work that needs the office. The pull back to base.

- Spending funding (hiring, purchasing equipment)
- Filing legal challenges and managing ongoing cases
- Applying for grants
- Reviewing full strategic map overview (the only way to see the whole mountain mid-season)
- Reviewing detailed monitoring data and research outputs
- Initiating and managing community programs
- Hiring / dismissing personnel

**Tier 3 — Remote via Radio (from any tile, requires radio upgrade)**

Limited field coordination. The radio is an awareness and coordination tool, not a management tool. It does not replace the station.

- Receive alerts from monitoring stations and ranger reports
- Check current resource levels (water, funding, community support)
- Issue simple ranger commands ("patrol sector X," "respond to alert at Y")

**Without the radio upgrade:** Tier 3 does not exist. The player has zero remote capability — alerts only appear when you return to station or walk into a situation. This makes the radio one of the most impactful early purchases.

**Design tension:** Every moment at the station is a moment not in the field. Every moment in the field is a moment the org runs on autopilot. You can hear a chainsaw from across the mountain but can't file the legal injunction to stop it without walking back to the station first. The player is always choosing what to neglect.

---

## Player Tools

### Planting (Water cost, slow payoff)

**Frailejones**
- Only plantable above ~3500m equivalent altitude
- Extremely slow to mature: 3-4 seasons to reach full effectiveness
- Once mature: highest water generation per tile, area resilience buff to adjacent tiles, fog capture
- If burned: gone. Centuries of growth, seconds of fire. Should be the game's most visceral loss.

**Moss Gardens**
- Prefer wet zones near streams and the laguna. Altitude-agnostic but moisture-dependent.
- Medium growth: 1-2 seasons to establish
- Water retention on tile + adjacent tiles. Moderate protection against erosion.

**Native Shrubs**
- Thrive at lower-to-mid altitudes. Struggle at top.
- Fast: 1 season to establish
- Provide wildlife habitat (attract beneficial fauna for biodiversity). Good ground cover to stabilize degraded tiles before deeper restoration.

**Native Trees (small, woody)**
- Only at lowest altitudes
- Slow but provide windbreak (reduces fire spread), wildlife corridor, carbon capture
- Most effective at creating a "buffer zone" between human activity and the paramo proper

**Restoration Plots**
- Special action: upgrades a Degraded tile toward Stressed over multiple seasons
- Requires water + at least one healthy adjacent tile as a seed source
- Scarred tiles can be partially restored but have a permanently lower health ceiling — the map remembers damage

### Infrastructure (Funding cost)

**Hiking Trails**
- Redirect tourist movement along designated safe paths
- Generate eco-tourism funding (more trails + tourist volume = more revenue)
- Create fast-travel corridors for the player
- Double-edged: trails attract more tourists. Unmanaged tourism is worse than no tourism.
- Low ecosystem disruption at any altitude

**Fences / Barriers**
- Block physical access. Stop cattle, casual tourists, small-scale miners from entering an area.
- Effective and immediate, but:
  - Useless against corporate/legal threats, environmental events, groundwater contamination
  - Excessive fencing drops community support (locals feel excluded from their own land)
  - Higher altitude = more ecosystem disruption from installation

**Monitoring Stations**
- Extended threat detection radius. Reveal incoming threats earlier.
- Provide evidence data (improves legal case outcomes)
- Enable research (scientists stationed here generate publications → grant funding)
- Force multiplier — make everything else more effective

**Water Channels**
- Redirect water flow to specific areas
- Irrigate dry restoration zones
- Create fire breaks (wet tiles resist fire spread)
- Critical dry-season infrastructure
- Tradeoff: redirecting water from one path starves another

**Signage / Education Posts**
- Placed along trails
- Chance to convert "ignorant tourist" into "conscious tourist" (reduced damage, leaves faster, may even donate)
- Cheap, passive, but only affects tourist-type threats

**Bridges**
- Built over streams
- Enable fast player and ranger movement across water
- Low ecosystem impact

### Personnel (Ongoing funding drain per season)

**Rangers**
- Patrol routes (configurable when player is at station, or directed in person in the field)
- Intercept illegal miners, poachers, trespassers
- Deter cattle when stationed at boundaries
- Effectiveness scales with community support — high support means local intel, tip-offs; low support means locals warn trespassers instead
- Cannot act against legal mining operations (that requires legal team)

**Scientists**
- Station at monitoring posts or research station
- Generate research data → publications → grant funding (slow but compounding returns)
- Improve restoration efficiency (evidence-based planting)
- Provide evidence for legal challenges
- Like frailejones but for the organization — slow investment, growing returns

**Community Educators**
- Generate community support over time
- Reduce farmer/cattle spawn rates after sustained presence
- Can train local volunteers (occasional free labor for restoration/trail maintenance)
- THE answer to "desperate farmer" enemies

**Legal Team**
- Based at research station
- Can file injunctions against legal mining operations
- Base success rate: ~50%. Modified by:
  - Evidence gathered (monitoring stations, scientist reports): +15-25%
  - Community support level: +10-20% (political pressure)
  - Funding invested in the case: +5-15%
  - Prior legal precedent (previous wins in the run): +5-10%
- Failed cases still cost funding. Sometimes you lose.
- Only counter to permitted extraction — the most devastating but "legal" threat

### Community Programs (Funding + high community support to unlock)

**Eco-Tourism Program**
- Requires: existing trail network + minimum community support
- Converts trail revenue into community jobs
- Boosts community support
- But increases tourist volume — must be paired with trail infrastructure and education posts
- Risk/reward tradeoff

**Sustainable Agriculture Training**
- Reduces "desperate farmer" spawns permanently after sustained investment (3+ seasons)
- Expensive upfront, permanent payoff
- The humane, mechanically optimal solution to the farmer dilemma

**Water Stewardship Program**
- Community helps maintain water channels and restoration plots
- Reduces vandalism of infrastructure
- Requires sustained high community support to unlock

---

## Threats

Threats do not follow fixed paths. They enter from map edges (primarily below) and move toward objectives — resources to extract, land to claim, the laguna to reach. They degrade tiles they occupy or pass through. The map health IS the health bar.

Threat arrival is organic, not rigid wave-based. Seasons have threat profiles (types and intensity curves), and within a season, threats arrive in clusters with natural variation — sometimes a quiet stretch, sometimes multiple crises overlap. Between seasons, a brief planning phase allows resource spending and strategic repositioning.

### Biological

**Invasive Grasses (e.g., kikuyu)**
- Appear on edge tiles at low-to-mid altitude
- Spread to adjacent tiles each season if not removed
- Convert native grassland to monoculture: lower biodiversity, reduced water retention
- Slow and undramatic — which is why they're dangerous. The player learns to fear the quiet creep.
- Removal: manual (rangers), or outcompeted by dense native planting. Herbicide option exists but damages adjacent native plants (tradeoff).
- Climate change causes their viable altitude to creep upward over the run

**Feral Cattle**
- Trample vegetation, compact soil (reduces water absorption)
- Spawn more frequently when community support is low (farmers letting them graze freely)
- Fences stop them. Education programs reduce them at the source.
- Low individual damage but persistent

### Human — Ignorant

**Casual Tourists**
- Wander off trails if no trail infrastructure exists. Follow trails when available.
- Trample frailejones (each one walked over loses growth progress), leave trash (minor tile degradation)
- Come in groups during dry season (peak tourism)
- Countered by: trails (redirect), signage (educate), fences (block sensitive areas)
- Not malicious — just unaware. The game should not demonize them.

**Reckless Tourists**
- Light campfires (FIRE RISK — can cascade in dry season)
- Pick plants, disturb wildlife, swim in the laguna (contamination)
- Less common than casual tourists but high individual impact
- Countered by: rangers (intercept), signage (deter some), trails + barriers (limit access)

### Human — Extractive

**Illegal Miners**
- Small groups, arrive at lower-to-mid map edges
- Set up operations that rapidly degrade tiles to Scarred in 1-2 turns if uncontested
- High priority targets — fast, devastating, concentrated damage
- Countered by: rangers (remove operations), monitoring stations (early detection), community intel (faster response if support is high)
- Prefer lower altitudes (access to roads) but will push higher for deposits

**Legal Mining Operations**
- Arrive with government permits. Cannot be "attacked" by rangers — that would be illegal.
- Proceed slowly but methodically, degrading large areas with industrial equipment
- The most devastating sustained threat in the game
- Countered by: legal team injunction (expensive, probability-based). Monitoring evidence and community support improve odds. Sometimes you lose the case and the mine proceeds.
- Design intent: the player must experience the frustration of watching permitted destruction they cannot physically stop. The legal system is the only recourse — and it's slow, expensive, and uncertain.

**Land Speculators**
- Don't degrade tiles directly
- "Claim" tiles — player loses ability to build or plant on those tiles until the legal team resolves the claim
- Target strategically valuable positions (near trails, water sources, flat buildable areas)
- Countered by: legal team (faster resolution than mining injunctions)

### Human — Desperate

**Subsistence Farmers**
- Expand small plots into paramo edges, particularly at lower altitudes
- Slow, low individual damage, but persistent and recurring
- Removing them by force (rangers) triggers visible consequences: belongings left behind, the cleared plot sits empty. Community support drops significantly.
- Countered optimally by: community educators (reduce spawn rate), sustainable agriculture training (permanent reduction after investment). Fences work but breed resentment — higher fence density with low community programs = accelerating support loss.
- Design intent: These are not enemies. They are people feeding families. The mechanically optimal play (education + economic alternatives) aligns with the ethically optimal play. Players who treat farmers like enemies will lose through community collapse. This should provoke discomfort and reflection, not through heavy-handed narrative but through systemic consequences.

### Environmental

**Dry Spells**
- Multi-turn events. Water generation drops ~40% further. Fire risk maximized.
- Plants enter stress. Can't plant during dry spells (nothing takes root).
- Frequency and severity increase in later years (climate change).
- Countered by: water reserves (channels storing surplus), pre-established healthy terrain with deep root systems, firebreaks

**Heavy Rains**
- Erosion on degraded and barren tiles — they worsen without any enemy action. Rain washes away loose soil.
- Healthy tiles with good root systems are fine — incentivizes maintaining ecosystem health as its own defense.
- Can flood lower areas if water channels are at capacity.
- Countered by: maintaining tile health, water channels to manage flow, moss bogs to absorb excess

**Wildfire**
- Triggered by: reckless tourist campfires, dry spell + spark from mining equipment, occasionally lightning
- Spreads to adjacent tiles. Speed depends on dryness, vegetation density, wind.
- Wet tiles and water channels act as firebreaks.
- The player character can fight fire directly (slowly, tile by tile) or use water reserves.
- Frailejones are extremely flammable when dry. A mature frailejon field catching fire should be the game's most devastating visual: seasons of patient growth, gone in seconds. Sound design should reinforce this — crackling, roaring, then silence.

**Climate Shift (Background Pressure)**
- Not an "enemy" — a slow, invisible modifier
- Each year: baseline temperature rises slightly, dry seasons get longer and harsher, wet seasons become more extreme
- The viable altitude range for frailejones shifts upward — plantings at the former lower limit begin to stress
- Invasive grass viable altitude creeps up
- The game gets harder not because enemies scale up — but because the environment itself becomes less forgiving
- No counter. This is the one threat that cannot be stopped, only adapted to. It is the ticking clock underneath everything.

---

## Seasons & Rhythm

### The Year

Each in-game year has two seasons:

**Dry Season (Verano)**
- Water generation: reduced ~40%
- Fire risk: HIGH
- Tourist activity: HIGH (peak season — more revenue AND more risk)
- Mining/extraction: ramps up (ground easier to work)
- Player movement: normal (dry terrain is easier to traverse)
- Visuals: golden-yellow light, haze, exposed earth tones, dust particles

**Wet Season (Invierno)**
- Water generation: peak
- Erosion risk: active on degraded tiles
- Tourist activity: LOW (fewer tourists, but reckless ones still come)
- Mining: slower but doesn't stop
- Restoration planting: most effective this season (things take root)
- Fog: reduced visibility (monitoring stations matter more)
- Player movement: slowed by mud, swollen streams (bridges critical)
- Visuals: gray-blue mist, visible rain, lush greens, fog drifting across the mountain

### Planning Phase

Between seasons: a brief pause. The player returns to (or is at) the research station. During this phase:
- Review ecosystem status (health map, biodiversity report, water levels)
- Spend accumulated funding (hire personnel, purchase equipment, initiate programs)
- Review monitoring intel (preview of next season's primary threats — not exact, but directional)
- Reposition rangers and set patrol routes
- Plan where to focus field work next season

### Within-Season Rhythm

Threats arrive organically, not in rigid waves. Each season has a threat profile defining:
- Which threat types are active
- Intensity curve (e.g., mining ramps up mid-dry-season, tourists peak early)
- Random event probability (funding cuts, political shifts, weather extremes)
- Cluster patterns (sometimes simultaneous crises, sometimes relative calm)

The player is always reacting and adapting, but there are natural ebbs — moments to plant or restore before the next cluster arrives. The rhythm should feel like weather: sometimes a storm, sometimes a lull, never fully predictable.

### Vertical Slice Scope

1 run = 5 years (10 seasons) + planning phases. Target playtime: 30-45 minutes.

---

## Win / Loss

### Loss Triggers

- **Laguna purity reaches 0%:** Headwater death. Ecological collapse.
- **Total ecosystem health below 20%:** Cascading tile death across the mountain. Irrecoverable.
- **Funding at 0 for 2+ consecutive seasons:** NGO folds. Operations cease.

### "Victory"

Survive 10 seasons with the laguna alive and ecosystem above critical threshold.

But there is no triumphant win screen. The end shows the mountain — scarred or preserved, whatever the player achieved. Scoring dimensions:

- Tiles remaining at Healthy or Stressed
- Tiles restored from Degraded/Barren during the run
- Peak biodiversity achieved
- Community support level at end
- Laguna purity at end
- "Downstream communities with water access" — the moral weight number
- Frailejones planted vs. frailejones surviving

The scars on the map are visible. The frailejones planted in Season 1 — are they still standing? The restored tiles show their history. Nothing is erased.

---

## Emergent Behaviors & Feedback Loops

### Virtuous Cycles (player must build and protect these)

- Healthy upper tiles → water generation → downstream fertility → easier restoration → more healthy tiles
- Community programs → fewer human threats → less damage → more eco-tourism → more funding → more programs
- Monitoring → evidence → legal wins → fewer legal mining operations → saved funding and tiles
- Mature frailejones → fog capture → water → more planting capacity → more frailejones (SLOW but powerful)

### Death Spirals (player must prevent these from taking hold)

- Degraded upper tiles → reduced water → downstream plants die → more degraded tiles → less water → laguna starved
- Low community support → more farmer/cattle encroachment → more damage → less eco-tourism revenue → less funding for community programs → lower support
- Fire destroys frailejones → water gen drops → next dry spell is worse → higher fire risk → more fire
- Legal mining proceeds → large area scarred → biodiversity loss → reduced ecosystem resilience → next threat does more damage

### The Central Tension

The player's job is to keep virtuous cycles spinning and prevent death spirals from gaining momentum. One bad season can cascade. But the virtuous cycles are slow to build (frailejones, community trust, legal precedent) while the death spirals are fast to trigger (one fire, one mining operation, one season of neglect).

This asymmetry IS the message.

---

## Indigenous Presence

Represented sparingly and with great care. Not a game mechanic — a narrative and atmospheric element.

- The laguna has cultural significance. Brief, respectful text when the player first visits it (not lore dumps — a single line about the water's meaning to the people who were here before the NGO).
- Occasional environmental storytelling: old stone markers, terracing that predates colonization, names on the map that aren't Spanish.
- If community programs reach high levels, a subtle indicator that indigenous communities are part of the conservation dialogue — not as subjects to be managed, but as partners with knowledge the NGO doesn't have.
- **No indigenous "units," "abilities," or gamified cultural mechanics.** Their presence is contextual and respectful.
- Further representation requires research consultation with actual Muisca or relevant indigenous communities. The game should be designed to accommodate this input later, not to assume it now.

---

## Visual Direction

### Palette

- **Healthy paramo:** Deep greens, silver-gray mist, golden frailejon flowers, cool blue water, lichen-covered rock
- **Damaged terrain:** Harsh orange-brown exposed earth, dark gray mine scars, muddy runoff
- **Dry season shift:** Warm golden haze, yellowed grasses, exposed soil tones
- **Wet season shift:** Blue-gray fog, saturated greens, visible rain streaks

Dome Keeper's pixel density, applied to isometric diamond tiles. Each tile is a small illustrated vignette: individual frailejones, visible moss, exposed roots, water glints. Tiles read clearly at strategic zoom and reward close inspection. Altitude banding emerges from tile content, not from hand-drawn zones.

**Projection & tile layout:**
- Isometric projection, 2:1 aspect diamond tiles (e.g., 64×32 or 128×64 base — final size TBD in production)
- Multi-layer tile stack: terrain → vegetation → infrastructure → entities → fog. Y-sorted so player, threats, and tall sprites (frailejones, trees) sort correctly against terrain.
- Character sprites: minimum 4 facings (NE/SE/SW/NW). 8 facings if budget allows. Mirroring halves the art load.
- Tall structures (monitoring stations, the research station, mature frailejones) extend above their tile footprint — Y-sort origin per tile must be tuned in the TileSet so sorting holds.

### Atmosphere

- Mist drifts across the mountain, obscuring and revealing tiles
- Clouds cast moving shadows on the slopes
- Water in streams visibly flows downhill
- Wind is constant — frailejones sway, grasses ripple, fog moves
- Subtle particle effects: dust in dry season, rain droplets in wet season, embers during fire
- The laguna reflects the sky. Its color shifts with purity — clear blue when healthy, murky green-brown when contaminated.

### Damage Visualization

Tile degradation should be painful to watch:
- Healthy → Stressed: slight browning at edges, fewer flowers
- Stressed → Degraded: visible bare soil patches, wilting plants
- Degraded → Barren: mostly exposed earth, dead plant stumps
- Barren → Scarred: gouged terrain, discoloration, rubble. Even after partial restoration, scar textures remain underneath new growth.

Fire should be vivid and spreading. The contrast between a lush frailejon field and its charred aftermath should be stark.

---

## Audio Direction

### Ambient Layer (always present, mixed by context)

- Wind: constant, varying intensity with altitude and weather. The paramo is defined by its wind.
- Water: trickling streams, the laguna's stillness (barely audible — a presence, not a sound)
- Birds: distant calls, occasional close passes. Fewer as biodiversity drops.
- Insects: subtle buzz at lower altitudes. Absent at top.

### Threat Audio

- Chainsaw buzz (loggers — distant, then closer)
- Pickaxe clinks (miners)
- Cattle lowing (feral herds)
- Tourist chatter (groups — laughter, voices, then silence when they've gone)
- Heavy machinery rumble (legal mining — a low, grinding drone)
- Fire: crackling → roaring → silence after. The silence is worse.

### Music

Minimal. Ambient, textural. Builds tension during overlapping crises. Releases during planning phases. Something that evokes Andean high altitude without cliche — processed wind instruments, resonant strings, low drones. Consider collaborating with a Colombian musician for authenticity.

---

## Technical Architecture (Godot 4)

All systems designed data-driven. New levels = new config, not new code.

### Core Systems

**TileMap System**
- Tile types defined as resources: base type, altitude rules, health states, visual variants per health level
- Health state machine per tile with transition rules and timers
- Moisture propagation system (water flows downhill through tiles based on connectivity)
- Biodiversity calculated from tile health + adjacent tile diversity + altitude

**Threat Spawner**
- Season threat profiles defined as resources: threat types, intensity curves, timing distributions, random event pools
- Each threat type is a scene with shared interface: movement behavior, tile interaction, counter vulnerabilities
- Spawn timing uses weighted randomness within seasonal envelopes — not rigid wave timers
- Climate shift modifier increases severity coefficients each year

**Tool / Structure System**
- Each player tool is a scene with a shared interface:
  - Placement rules (altitude range, required adjacent tiles, terrain type)
  - Resource costs (build + ongoing maintenance)
  - Effect radius and behavior
  - Upgrade paths (if applicable)
- New tools = new scene + resource config. Core system unchanged.

**Resource System**
- Abstract resource manager supporting N resource types
- Each entity registers generation and drain rates
- Per-season modifiers applied globally
- Event-based spikes and cuts
- UI bindings for HUD display

**Season / Time System**
- Season definitions as resources: duration (in game ticks), global modifiers, threat profile reference, weather parameters
- Planning phase state with paused simulation
- Year counter driving climate shift escalation
- Day counter within seasons (not day/night cycle — just pacing clock for threat spawn timing)

**Camera & Visibility System**
- Camera follows player with smooth interpolation
- Visibility radius calculated per-frame: base radius + altitude bonus - weather penalty
- Fog-of-war: tiles outside visibility show last-known state (cached tile snapshot). Updates when tile re-enters visibility.
- Monitoring stations register as persistent visibility sources (reveal radius around them, independent of player position)
- Alert/notification system: monitoring stations and rangers push events to a queue. Displayed as UI popups with directional indicator (compass bearing from player). Requires radio upgrade to receive in field; otherwise only visible at station.
- Directional audio: threat sounds positioned in world space, audible beyond visibility radius. Volume attenuates with distance. Stereo panning indicates direction.

**Player Controller**
- Grid-based movement with pathfinding
- Movement cost per tile (altitude, terrain type, infrastructure, weather)
- Action system: context-sensitive interaction based on what's on the current tile
- Three interaction tiers enforced by player state: field (Tier 1 + Tier 3 if radio), station (Tier 2 + map overview)
- No action queuing — all actions are immediate and require the player to be in the correct location

**Event System**
- Weighted random event pools per season type
- Events defined as resources: trigger conditions, effects (resource changes, threat modifiers, narrative text)
- Examples: "Government funding cut" (-30% grant baseline for 2 seasons), "University partnership" (free scientist for 3 seasons), "Election year" (community support more volatile)

**Save / Level System**
- Level definition = map data + season sequence + threat profiles + available tools + event pools + win/loss conditions
- Map data: tile grid with initial types, health states, pre-placed features (streams, rock, the laguna, the research station, pre-existing damage)
- All config in resource files (JSON or Godot .tres)

### Vertical Slice Scope

For the first playable level:
- One handcrafted mountain map with ~200-300 tiles
- 10 seasons (5 years) of threat profiles
- Core threats: invasive grass, casual tourists, reckless tourists, illegal miners, one legal mining event, desperate farmers, dry spell, fire, heavy rain
- Core tools: frailejones, native shrubs, trails, fences, water channels, signage, monitoring stations, rangers, community educators, legal team
- Camera/visibility system with player-following camera, fog of last-known-state, directional audio cues
- Radio upgrade as early progression gate
- Player movement with altitude/terrain costs
- Research station with basic management UI + strategic map overview
- 3 resources (water, funding, community support)
- Win/loss conditions
- End screen with map state + score breakdown

**Deferred to post-vertical-slice:**
- Moss gardens, native trees, restoration plots (planting variety)
- Scientists (intel system depth)
- Bridges, oxygen kit (movement upgrades)
- Community programs (eco-tourism, agriculture training, water stewardship)
- Land speculators, feral cattle, climate shift escalation (threat variety)
- Indigenous presence (requires research)
- Procedural map generation
- Multiple difficulty levels / scenarios
- Sound design and music (placeholder audio for vertical slice)

---

## Portfolio & Application Relevance

This project demonstrates:

- **Systems design thinking:** Resource ecology, emergent behaviors, feedback loops as rhetorical tools
- **Technical capability:** Godot, procedural/data-driven architecture, simulation systems
- **Cultural grounding:** Colombian ecosystem, real conservation challenges, site-specific design
- **Critical game design:** Mechanics as argument — the game's systems make claims about conservation, community, and environmental justice that the player experiences rather than reads
- **Research potential:** Games for environmental education, civic engagement, Colombian cultural heritage, interactive systems for social change

Directly aligns with stated research interest: *"Games as cultural, social, civic tools — particularly for Colombia. Critical inquiry into how interactive systems foster social cohesion, education, collective memory, and social change."*

---

## Open Questions for Development

- [ ] Exact tile count and mountain proportions (playtest needed for pacing vs. scale)
- [ ] Specific upgrade paths for tools (linear? branching? unlocked by achievements?)
- [ ] Ranger AI patrol behavior (autonomous patrol logic vs. fully player-directed)
- [ ] Difficulty tuning: how fast do things degrade? How quickly should the player feel pressure?
- [ ] Onboarding: tutorial season? Or learn-by-doing with contextual hints?
- [ ] Narrative framing: any story wrapper (the NGO's backstory, the coordinator's motivation)? Or purely emergent?
- [ ] Legal mining: how many legal mining events per run? One is impactful; too many becomes rote.
- [ ] Indigenous representation: consultation pathway for respectful inclusion in post-slice development
- [ ] Monetization / release model: free portfolio piece? Itch.io release? Commercial potential?
