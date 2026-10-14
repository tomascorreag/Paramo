# Fauna: animals of the three mountains

**Status: research shortlist, compiled 2026-10-09.** The animal-level counterpart to [flora.md](flora.md). Nothing here is in the game yet. It exists so that "which animal lives on this mountain, at what height, in what cover, and how often would you see it" has one sourced answer per species.

The three mountains are the three `EcosystemProfile`s: `chingaza` (humid páramo, Cordillera Oriental), `guerrero` (dry, heavily farmed páramo, Oriental), `nevados` (Cordillera Central, superpáramo to glacier).

## How to read the tables

- **Ch / Gu / Ne**: presence per mountain. `yes`, `no`, `lost` (documented as extirpated), `?` (unverified), `contested` (sources disagree; see notes).
- **Tier** is a judgement call that turns the evidence into one game-usable word. It is not a measured quantity:
  - `common`: most-recorded animals at the site, seen or heard on any walk.
  - `frequent`: recorded routinely in site surveys.
  - `uncommon`: present, but most visits miss it.
  - `rare`: threatened, small population, or few site records.
  - `relict`: possibly gone, last seen years ago.
- **GBIF CO** is the GBIF occurrence count for Colombia. It is a frequency-of-encounter proxy with the same bias as in flora.md, and here it is worse:
  - Bird counts are 85–95% eBird, so they measure birders at accessible sites.
  - Mammal counts are dominated by single camera-trap projects: 4,052 of Chingaza's 5,907 bear records come from one 2015–16 study, and 1,366 of Guerrero's 1,369 guinea-pig records come from cameras at Neusa.
  - Compare counts within a class, never across classes.
- **Site counts** (bird and mammal tables) are GBIF records inside a rough lat/lon box per mountain, not the park polygon. Every box spills into the forest or sabana below the páramo.
  - Guerrero's bird box holds 9,179 records against Chingaza's 225,245, so a low Guerrero count is low survey effort, not proven rarity.
- **IUCN / CO**: global Red List category, then the Colombian national category (Res. 0126 de 2024; `–` = not listed).
  - Categories came via GBIF's Red List mirror or Wikipedia infoboxes, because iucnredlist.org refused automated fetches. **Population trends are unverified for every species**; confirm on iucnredlist.org before quoting.
- **Altitude** is in metres, followed by the game's half-step height `h`.
  - `h ≈ (m − 3000) / 37.5`, the mapping `ObjectPainter` already uses for flora ([../dev-notes/flora.md](../dev-notes/flora.md)).
  - level1's ground spans roughly h 6–32 (3225–4200 m). An animal whose range ends below 3000 m (h < 0) belongs at the forest edge just off the map.
- **Habitat codes** cover the páramo mosaic, mapped to what the game draws:

  | Code | Habitat | What the game draws there |
  |---|---|---|
  | B | bosque altoandino / subpáramo edge | below the map |
  | P | pajonal | *Calamagrostis* grass |
  | F | frailejonal | *Espeletia* stands |
  | C | chuscal | *Chusquea* bamboo |
  | H | turbera / humedal / laguna | water, lake apron |
  | R | roca / superpáramo | rock biome |
  | G | glacier edge | snow biome |

- **Act.** is activity: D diurnal, N nocturnal, Cr crepuscular, Ca cathemeral. Mammal splits are camera-trap timestamps at ≥2500 m in Colombia, given as day/twilight/night %.

## Mammals

| Species | es-CO / English | Ch | Gu | Ne | Tier | IUCN / CO | GBIF CO | Altitude (h) | Hab. | Act. |
|---|---|---|---|---|---|---|---|---|---|---|
| *Tremarctos ornatus* | oso andino, oso de anteojos / Andean bear | yes | lost | yes | Ch uncommon, Ne rare | VU / VU | 8,057 | bulk 2000–3500, max 4246 (h ≤ 33) | B F P | D 91/8/1 |
| *Tapirus pinchaque* | danta de páramo / mountain tapir | no | lost | yes | rare | EN / EN | 1,437 | 2000–4000, peak 3000–3500 (h 0–13) | B, P in transit | ? |
| *Puma concolor* | puma / puma | yes | lost | yes | uncommon | LC / – | 2,540 | mostly < 3000, max 3930 (h ≤ 25) | all | Ca 39/13/48 |
| *Odocoileus goudotii* (= *O. virginianus goudotii*) | venado cola blanca, venado de páramo / white-tailed deer | yes | lost | contested | Ch frequent | LC (as *O. virginianus*) / – | 8,457* | to 3930 (h ≤ 25) | P near water, shrubs | D 82/10/8 |
| *Mazama rufina* | venado soche / dwarf red brocket | yes | lost | yes | uncommon | VU / VU | 1,270 | 2000–3500 (h ≤ 13) | B C | mixed 48/24/28 |
| *Pudu mephistophiles* | venado conejo / northern pudu | ? | no | yes | rare | DD / EN | 77 | 2000–4000 (h ≤ 27) | B, shrub páramo | ? |
| *Leopardus pardinoides* (ex *L. tigrinus*) | tigrillo / clouded tiger cat | yes | yes | yes | uncommon | VU / VU | 877 | bulk 2000–3000, max 3841 (h ≤ 22) | B | N 20/14/66 |
| *Nasuella olivacea* | cusumbo de montaña / mountain coati | yes | yes | yes | frequent | NT / – | 1,552 | bulk 2000–3000, max 4100 (h ≤ 29) | B F P | N-leaning 23/12/65 |
| *Cuniculus taczanowskii* | borugo, guagua de páramo / mountain paca | yes | yes | yes | frequent | NT / – | 1,706 | 2000–3500, max 4150 (h ≤ 30) | B, streams | N 2/28/70 |
| *Cavia aperea* (incl. *C. anolaimae*) | curí / guinea pig | yes | yes | no | common | LC / – | 5,348 | 2000–3500 (h ≤ 13) | P, H edges | D/Cr 51/28/22 |
| *Sylvilagus andinus* | conejo de páramo / Andean cottontail | likely | yes | yes | frequent | DD / – | 237 | 2000–3800 (h ≤ 21) | P F | N (n=8) |
| *Neogale frenata* | comadreja / long-tailed weasel | yes | yes | yes | uncommon | LC / – | 477 | mostly < 3000 | P R | D (n=11) |
| *Cerdocyon thous* | zorro perruno / crab-eating fox | yes | yes | yes | uncommon | LC / – | 13,231* | mostly lowland, 39 records ≥ 3000 | B, pasture | Ca 40/24/36 |
| *Didelphis pernigra* | chucha, fara / Andean white-eared opossum | yes | yes | yes | frequent | LC / – | 2,309 | bulk 2000–3000 | B, farmland | N 18/11/71 |
| *Thomasomys laniger* | ratón de páramo / woolly Thomas's rat | yes | yes | yes | frequent | LC / – | 428 | 2000–4000 (h ≤ 27) | P F C | ? |
| *Anoura geoffroyi* | murciélago longirostro / Geoffroy's tailless bat | yes | yes | yes | uncommon | LC / – | 751 | max 3834 (h ≤ 22) | flowers | N |
| *Histiotus montanus* | murciélago orejón / small big-eared bat | yes | yes | yes | uncommon | LC / – | 151 | max 3834 (h ≤ 22) | open ground | N |

\* National totals dominated by lowland records; not comparable to páramo-only species.

Mammal notes:
- **Guerrero has lost its large mammals.**
  - CAR & CI (2004), cited in the Humboldt *Atlas de Páramos*, list bear, puma, tapir, red brocket, white-tailed deer and jaguarundi as gone [M3].
  - GBIF has 0 bear, puma, tapir or brocket records in the Guerrero box.
  - What remains is meso-mammals on camera traps at Embalse del Neusa and at 3200–3470 m in Cogua [M5, M6]: tiger cat, coati, borugo, guinea pig, rabbit, weasel, fox and opossum.
  - For the game this is the strongest finding in the doc: the farmed mountain is the one where the big animals already left.
- **Bear, Chingaza.**
  - 33 individuals identified by camera trap since 2011; occupancy 0.79 → 1.0 over 2010–14 [M1].
  - Diet includes *Puya* hearts, *Greigia* and the basal meristem of frailejones [M7]. That is a direct hook into the flora layer.
  - Home range ♂ ~59 km², ♀ ~15 km² [M7], so one bear's range is far larger than one map.
  - Takes cattle and carrion in the wet season [M1].
- **Tapir.**
  - The PNN tapir strategy says Chingaza has "no current or historical reports" [M8]. Chingaza's own plan has community memory of the tapir "no longer being seen" [M1]. Treated as `no`.
  - Nevados: present. Density 0.25 ind/km² (Acosta 1996, via Cortolima [M9]; table alignment in that source is ambiguous).
  - One source says it uses páramo "only as transit, does not feed" (Lizcano 2006 via [M9]); this is disputed.
- **Deer, Nevados.** The Nevados plan says it was extirpated (Botero & Lotero 2004) [M2]. GBIF has 5 iNaturalist records there from 2017–25.
- **Deer, Chingaza.** A density of 8.9 deer/km² at Monterredondo comes from a thesis snippet that could not be opened. UNVERIFIED.
- **Feral dogs, Chingaza.** Their most-eaten prey is white-tailed deer, then borugo. Source is a newspaper citing a 2009 diet study [I2]; secondary.
- **No source was found for deer grazing post-fire regrowth.** Do not build on it without one.
- **Hunting and roadkill.** Borugo is Chingaza's most-hunted game species; curí is eaten [M1].

## Birds

The bird table reports GBIF counts per site box instead of yes/no, because birds are well surveyed; Guerrero's box has ~4% of Chingaza's effort. Several species have a sister species on the other cordillera, written Oriental / Central.

| Species | es-CO† / English | Ch | Gu | Ne | Tier | IUCN / CO | GBIF CO | Altitude (h) | Hab. | Diet / note |
|---|---|---|---|---|---|---|---|---|---|---|
| *Vultur gryphus* | cóndor de los Andes / Andean condor | 112 | 0 | 889 | rare | VU / **CR** | 3,495 | 3000–5000 (h 0–53) | R P | carrion |
| *Oxypogon guerinii* (Oriental) | chivito de páramo / green-bearded helmetcrest | 427 | 34 | – | uncommon | LC / – | 3,140 | 3000–4200 (h 0–32) | F P | *Espeletia* nectar specialist |
| *Oxypogon stuebelii* (Central) | chivito del Ruiz / buffy helmetcrest | 0 | 0 | 4,532 | rare | VU / **EN** | 5,162 | 3000–4600 (h 0–43) | F P | *E. hartwegiana* nectar; 250–999 mature birds |
| *Chalcostigma heteropogon* / *C. herrani* | pico espina / bronze-tailed / rainbow-bearded thornbill | 1,446 | 29 | 4,046 | frequent | LC / – | 4,371 / 7,532 | 2700–4100 (h ≤ 29) | R P F | shrub nectar |
| *Eriocnemis vestita* | calzoncitos / glowing puffleg | 3,344 | 104 | 177 | Ch frequent | LC / – | 15,442 | 2300–4200 (h ≤ 32) | B P | shrub nectar |
| *Metallura tyrianthina* (+ *M. williami* in Ne) | metalura / Tyrian / Viridian metaltail | 4,071 | 194 | 2,642 (+5,084) | common | LC / – | 50,900 | 1500–4200, most 2500–3300 | B P | Ericaceae nectar |
| *Pterophanes cyanopterus* | alazafiro grande / great sapphirewing | 1,184 | 15 | 4,842 | frequent | LC / – | 10,126 | 2600–3600 (h ≤ 16) | B P | favours *Puya* |
| *Aglaeactis cupripennis* | rayito brillante / shining sunbeam | 163 | 29 | 5,620 | Ne common | LC / – | 15,963 | 2500–4300 (h ≤ 35) | B P | *Puya* nectar |
| *Lesbia nuna* / *L. victoriae* | colas de tijera / trainbearers | 537+476 | 145+100 | 7 | Gu common | LC / – | 10,833 / 9,720 | 1700–3800 (h ≤ 21) | B P | the most-recorded hummingbirds in Guerrero |
| *Grallaria rufula* / *G. quitensis* | tororoí / Muisca / tawny antpitta | 3,026 | 5 | 5,231 | frequent (heard) | LC / – | 5,673 / 9,725 | 1850–4000 (h ≤ 27) | B / P F | tawny tolerates farmland |
| *Scytalopus griseicollis* / *S. opacus* | tapaculo / pale-bellied / páramo tapaculo | 3,940 | 175 | 2,626 | frequent (heard) | LC / – | 13,714 / 5,609 | 2000–4000 (h ≤ 27) | B C | arthropods |
| *Asthenes flammulata* | canastero rayado / many-striped canastero | 295 | 15 | 1,009 | uncommon | LC / – | 4,381 | 2700–4500 (h ≤ 40) | P F R | hurt by overgrazing, helped by occasional burning |
| *Asthenes fuliginosa* | colicardo / white-chinned thistletail | 1,300 | 1 | 1,134 | frequent | LC / – | 4,980 | 2800–4000 (h ≤ 27) | B P | treeline |
| *Muscisaxicola alpinus* | dormilona de páramo / páramo ground tyrant | 122 | 3 | 481 | uncommon | LC / – | 1,273 | 3200–4400 (h 5–37) | R P | ground insectivore |
| *Cinclodes excelsior* | remolinera / stout-billed cinclodes | 0 | 0 | 2,917 | Ne frequent | LC / – | 5,158 | 3200–5200 (h 5–59) | R G H | Nevados only, up to snowline |
| *Leptasthenura andicola* | tijeral andino / Andean tit-spinetail | 30 | 2 | 3,181 | Ne frequent | LC / – | 5,835 | 3000–4200 (h 0–32) | P F | arthropods |
| *Cistothorus platensis* | cucarachero sabanero / grass wren | 1,097 | 18 | 4,273 | frequent | LC / – | 15,407 | ? | P H | wet sedge |
| *Cistothorus apolinari* | cucarachero de Apolinar / Apolinar's wren | 20 | 10 | 0 | rare | EN / **CR** | 6,661‡ | páramo form 3800–3900 (h 21–24) | H C | páramo form nests in *Chusquea tessellata* |
| *Geospizopsis unicolor* | gorrión paramuno plomizo / plumbeous sierra finch | 1,492 | 27 | 4,933 | common | LC / – | 12,337 | ? | P R | seeds |
| *Catamenia inornata* | semillero paramuno / plain-colored seedeater | 407 | 44 | 3,290 | frequent | LC / – | 10,921 | ? | P B | seeds |
| *Zonotrichia capensis* | copetón / rufous-collared sparrow | 6,882 | 430 | 7,472 | common | LC / – | 307,800 | wide | all, disturbed | seeds, grain |
| *Turdus fuscater* | mirla patinaranja / great thrush | 7,807 | 482 | 8,803 | common | LC / – | 202,209 | 1800–4000 (h ≤ 27) | B P | most-recorded bird at all three sites |
| *Anisognathus igniventris* | clarinero / scarlet-bellied mountain tanager | 5,503 | 268 | 5,954 | common | LC / – | 39,742 | ? | B | subpáramo |
| *Diglossa humeralis* | picaflor negro / black flowerpiercer | 2,919 | 229 | 2,257 | common | LC / – | 47,781 | 2175–4000 (h ≤ 27) | B P | nectar robber |
| *Geranoaetus melanoleucus* | águila paramuna / black-chested buzzard-eagle | 1,183 | 104 | 2,438 | uncommon | LC / – | 10,944 | ? | P R | mammals, carrion |
| *Falco sparverius* | cernícalo / American kestrel | 1,264 | 35 | 170 | uncommon | LC / – | 42,167 | ? | P, farmland | |
| *Bolborhynchus ferrugineifrons* | periquito de los nevados / rufous-fronted parakeet | 0 | 0 | 1,496 | rare | VU / VU | 2,100 | 3000–4000 (h 0–27) | P F B | grass seed; Colombian endemic; hurt by burning for regrowth |
| *Gallinago nobilis* | caica / noble snipe | 538 | 29 | 203 | uncommon | **NT** / – | 5,867 | 2700–4200 (h ≤ 32) | H | probes peat |
| *Anas andium* / *Oxyura ferruginea* | pato paramuno / pato turrio / Andean teal / Andean duck | 1,744 / 440 | 13 / 15 | 1,069 / 1,081 | uncommon | LC / see note | 10,489 / 15,315 | ? | H | lagunas |
| *Rallus semiplumbeus* | tingua bogotana / Bogotá rail | 602 | 6 | 0 | rare | VU / **EN** | 7,078 | 2000–4100 (h ≤ 29) | H | Laguna Chingaza records 2018–25 |
| *Vanellus resplendens* | pellar andino / Andean lapwing | 0 | 0 | 291 | Ne uncommon | LC / – | 954 | 2700–4600 (h ≤ 43) | P H | Nevados only |
| *Systellura longirostris* | guardacaminos / band-winged nightjar | 259 | 28 | 137 | uncommon | LC / – | 9,201 | to 4200 (h ≤ 32) | P R | the only night bird kept |

† es-CO bird names were written from memory and are unverified. Check them against the ACO/SAC Colombian checklist before any copy ships.
‡ Mostly the sabana wetland form.

Bird notes:
- **Condor.**
  - Colombia: 71 released 1989–2013; the first national census (Feb 2021) counted at least 63 birds [B2].
  - Los Nevados: 14 released 1997–99; the park holds the country's only reintroduced nest, monitored since 2013 [B2].
  - Chingaza: the number released is UNVERIFIED. A 2026 ranger sighting was reported as the first there in 25+ years [B3], but the article's dates are internally inconsistent.
- **Statuses to confirm before quoting.**
  - Condor IUCN: CMS shows NT, Wikipedia shows VU.
  - Res. 0126 lists *Oxyura jamaicensis* as EN while GBIF files Colombian birds as *O. ferruginea*; whether that EN listing covers the Andean duck is UNVERIFIED.
- **Apolinar's wren.** The páramo subspecies *hernandezi* was described from Sumapaz [B4]. It depends on *Chusquea tessellata*, which is already in the game, but whether Chingaza and Guerrero birds are that form is UNVERIFIED.
- **Burning cuts both ways.** Canastero: hurt by overgrazing, helped by occasional burning. Rufous-fronted parakeet: hurt by burning for pasture regrowth. Source for both: Wikipedia species pages (secondary).

## Amphibians, reptiles, fish

No published herp inventory exists for Guerrero: the Humboldt páramo checklist states there was no primary biotic data for it [H1]. Guerrero rows rest on GBIF records in a bounding box (≥2900 m) or matching Cogua / Zipaquirá / Tausa / Subachoque. Altitudes are p5–p95 of up to 900 GBIF Colombia elevations, my computation, with published ranges where found. Nevados is reptile-poor: 2 reptile records ≥2900 m in its box.

| Species | es-CO / English | Ch | Gu | Ne | Tier | IUCN | GBIF CO | Altitude (h) | Hab. | Note |
|---|---|---|---|---|---|---|---|---|---|---|
| *Pristimantis bogotensis* | rana de lluvia de Bogotá | yes | ? | no | common | LC | 3,215 | 2714–3590 (h ≤ 16) | P, shrubs | tolerates pasture with shrubs |
| *Pristimantis nervicus* | — | yes | ? | no | frequent | LC | 380 | 2790–3645, type loc. 3870 (h ≤ 23) | exposed P | body temp measured to −1.05 °C [H2] |
| *Pristimantis elegans* | rana elegante | yes | ? | no | uncommon | **VU** | 731 | 3000–3716 (h 0–19) | ? | highest-median Oriental frog here |
| *Dendropsophus molitor* (= *D. labialis*; contested) | ranita sabanera / Andean tree frog | yes | **yes** | no | common | LC | 3,480 | 2541–3513 (h ≤ 13) | H, P | tadpoles need standing water; drought-sensitive |
| *Hyloxalus subpunctatus* | rana sabanera | yes | **yes** | no | frequent | LC | 2,000 | 2100–3725 (h ≤ 19) | H, moss | shallow ponds raise occupancy [H3] |
| *Bolitoglossa adspersa* | salamandra / Peters' climbing salamander | yes | ? | no | uncommon | **NT** | 1,647 | 1750–3650 (h ≤ 17) | B litter, P | threatened by agriculture [H4] |
| *Atelopus lozanoi* | sapo arlequín | buffer zone | no | no | rare | **CR** | 64 | ~2300–3350 (h ≤ 9) | streams | rediscovered 2016; trout eat its tadpoles; WCS removes trout [H5] |
| *Atelopus muisca* | sapo arlequín muisca | yes (only here) | no | no | relict | **CR** | 126 | 2900–3350 (h ≤ 9) | streams | one animal in 2008, none since [H6] |
| *Pristimantis simoterus* | — | no | no | **yes** | common ("very abundant") | NT | 522 | 3200–3934; calls to 4350 (h 5–36) | F P | hides by day in dead frailejón leaves; threats: cattle, burning [H7, H8] |
| *Pristimantis uranobates* | — | no | no | yes | frequent | LC | 1,062 | 2400–3567 (h ≤ 15) | ? | |
| *Osornophryne percrassa* | sapito de páramo | no | no | yes | uncommon | **VU** | 175 | 2893–3577 (h ≤ 15) | ground litter | only Nevados frog in the survey not found on branches at night [H8] |
| *Atelopus quimbaya* | sapo quimbaya | no | no | historical | relict | **CR** (authors propose EX) | 42 | ~2900 | streams | last records 1994–97; suspects: trout, chytrid fungus, climate [H9] |
| *Stenocercus trachycephalus* | lagarto collarejo | yes | **yes** | no | frequent | LC | 751 | 2087–3670; to 3950 (h ≤ 25) | P, shrubs, R | herb generalist, uses rocks |
| *Anadia bogotensis* | lagartija de Bogotá | yes | yes | no | uncommon | **NT** | 997 | 2743–3751 (h ≤ 20) | R, litter | communal egg nests under páramo rocks [H10] |
| *Anolis heterodermus* | camaleón / páramo anole | yes | yes | ? (split lineage) | uncommon | LC | 853 | 2159–3750 (h ≤ 20) | B shrubs | thermoconformer at 3400 m [H11] |
| *Riama striata* | lagartija bombillo | yes | ? | no | uncommon | LC | 473 | 2100–3197 (h ≤ 5) | B/P transition | |
| *Grundulus bogotensis* | guapucha | no | Neusa reservoir 1973–74 | no | rare | LC (one paper: NT) | 254 | 2530–2885 (below map) | H | sabana lake fish, not a páramo one |

No native fish were found in the GBIF Chingaza or Nevados boxes.

## Invertebrates

| Species | Ch | Gu | Ne | IUCN | GBIF CO | Altitude (h) | Note |
|---|---|---|---|---|---|---|---|
| *Bombus rubicundus* (abejorro) | yes | yes | yes | DD | 456 | 2412–3689 (h ≤ 18) | main *Espeletia grandiflora* pollinator with *B. funebris*; *E. grandiflora* is strongly self-incompatible, so seed set needs bees [H12] |
| *Bombus funebris* | ? | yes | yes | LC | 108 | 2650–3654 (h ≤ 17) | highest-ranging of the bumblebees by GBIF median (3459 m) |

Butterflies, dung beetles, spiders and earthworms were not researched.

## Introduced and domestic

These matter more to a stewardship game than most natives: they are the pressures the player can act on.

| Taxon | Where | Effect |
|---|---|---|
| Rainbow trout *Oncorhynchus mykiss* | Ch (Peñas Blancas 3557 m; Guatiquía river), Ne (Laguna del Otún ~3900 m, stocked for angling), Gu (Neusa reservoir) | eats harlequin-toad tadpoles [H5], a suspected cause in *A. quimbaya*'s loss [H9]; introduced 1938 [I1] |
| Feral dogs | Ch [I2] | prey mostly on white-tailed deer, then borugo |
| Cattle | Ne: ~7,000 ha critically degraded, 258 ha under restoration [I3]; Gu: core potato-and-dairy zone, >43,000 ha [I4] | trampling and pasture conversion; listed threat for *P. simoterus*; bears take calves [M1] |
| Potato farming, coal mining (land use, context) | Gu, Cogua [I5, I6] | main driver of alteration; coal tunnels run through frailejonal |

## By mountain

The animals each run would draw, in the same spirit as the flora profiles. **Signature** = only on this mountain among the three.

| | `chingaza` | `guerrero` | `nevados` |
|---|---|---|---|
| Signature | Bogotá rail, *Atelopus lozanoi* / *muisca*, *P. bogotensis*, *P. nervicus*, Chingaza salamander, green-bearded helmetcrest | — (nothing exclusive; everything here also lives in Chingaza) | buffy helmetcrest, rufous-fronted parakeet, stout-billed cinclodes, Andean lapwing, *P. simoterus*, *O. percrassa*, tapir, pudu |
| Large mammals | bear, puma, white-tailed deer, red brocket | **all lost** | bear, tapir, puma, red brocket, pudu |
| Common day sightings | great thrush, sparrow, tanager, metaltail, guinea pig, deer | great thrush, sparrow, trainbearers, guinea pig, rabbit | great thrush, sparrow, sunbeam, sapphirewing, sierra finch, buffy helmetcrest |
| Night | borugo, coati, opossum, tiger cat, frogs | borugo, opossum, tiger cat, tree frogs | borugo, coati, frogs in frailejón |
| Introduced | trout, feral dogs | trout, cattle, potato and mining | trout (Otún), cattle |

## Hooks into existing systems

Facts above that already touch a built system. All are sourced, but each is a design lead, not a decision.

- **Flora → fauna.**
  - Bears eat frailejón meristems and *Puya* [M7].
  - Both helmetcrests are *Espeletia* nectar specialists, each tied to its own mountain's frailejón (*hartwegiana* on Nevados [B5]); *guerinii* matches the Oriental's two.
  - Bumblebees are required for *E. grandiflora* seed set [H12].
  - Apolinar's wren nests in *Chusquea* [B4]; *P. simoterus* sleeps in dead frailejón leaves [H8].
- **Fire.**
  - Burning is a listed threat for *P. simoterus* and the rufous-fronted parakeet.
  - The many-striped canastero benefits from occasional burns. A burn that helps one species and hurts another is in the literature, not invented.
- **Visitors / trampling.** Overgrazing and trampling hurt the canastero; the Nevados plan says the effect of burning and trampling on páramo fauna is unknown [M2].
- **Water.** *Dendropsophus*, *Hyloxalus*, snipe, teal and rail are standing-water species; a dry season shrinking the lake apron is where they would show it.
- **Guerrero as the degraded mountain.** Its fauna is what is left after conversion. That matches its flora profile: almost no *Chusquea*, more grass.

## Gaps

- IUCN population trends: none verified.
- Colombian national status for herps: not checked.
- Guerrero has no published inventory for any class. The Humboldt 2015 ET-ESA Guerrero study exists [M4] but was not read.
- Chingaza's published bird list (Linares-Romero et al. 2020, 531 spp.) [B1] was not opened.
- Bird altitudes and IUCN categories are from Wikipedia (secondary).
- Mammal habitat columns are mostly inferred from elevation, except where a note cites a source.
- Invertebrates beyond two bumblebees: not researched.

## Sources

GBIF API (all counts, 2026-10-09):
- Species match: `https://api.gbif.org/v1/species/match?name=<binomial>`
- Occurrence count: `https://api.gbif.org/v1/occurrence/search?taxonKey=<key>&country=CO&limit=0`, with `decimalLatitude`/`decimalLongitude` ranges for site boxes.
- Red List mirror: `https://api.gbif.org/v1/species/<key>/iucnRedListCategory`
- Res. 0126/2024 checklist: https://www.gbif.org/dataset/09174029-d182-442c-a12f-8013aee328d7

Mammals:
- M1 Plan de Manejo PNN Chingaza — https://www.parquesnacionales.gov.co/wp-content/uploads/2020/10/plan-de-manejo-pnn-chingaza.pdf
- M2 Plan de Manejo PNN Los Nevados — https://www.parquesnacionales.gov.co/wp-content/uploads/2020/10/plan-de-manejo-pnn-los-nevados.pdf
- M3 Atlas de Páramos, Guerrero chapter (citing CAR & CI 2004) — http://www.mamacoca.org/docs_de_base/Ambienta/Carupa/11_guerrero.pdf
- M4 Humboldt ET-ESA Guerrero 2015 — https://repository.humboldt.org.co/entities/publication/155d6b4d-fd41-4ff3-8260-2648f85a1902
- M5 Neusa camera traps — https://www.gbif.org/dataset/a9a819bb-b94e-4e06-bbbd-4cc1eb6f3b1c
- M6 Cogua camera traps 2021–25 — https://www.gbif.org/dataset/504e0089-b4cc-40e7-9bff-e1cb9e3f38ac
- M7 Vela-Vargas et al. 2017, *El Oso Andino en el Macizo de Chingaza*, ch. 3 — https://cales.arizona.edu/research/redsquirrel/res_pdf/VelaVargasetal2017LibroOsoChingaza_Cap3_Generalidades_.pdf
- M8 PNN, Plan Estratégico Tapir de Montaña 2020–2030 — https://old.parquesnacionales.gov.co/portal/wp-content/uploads/2022/10/tapir-pnn.pdf
- M9 Cortolima 2012, danta de páramo plan — https://cortolima.gov.co/images/estudio/biodiversidad/PLAN_DE_MANEJO_REGIONAL_PARA_LA_CONSERVACION_DE_LA_DANTA_DE_PARAMO_EN_EL_DPTO_DEL_TOLIMA_2012.pdf
- Tiger-cat split — https://mammaldiversity.org/taxon/1006848
- Rabbit taxonomy — https://mammaldiversity.org/taxon/1001121, https://pdxscholar.library.pdx.edu/bio_fac/194

Birds:
- B1 Linares-Romero et al. 2020, Aves del PNN Chingaza — https://pure.urosario.edu.co/en/publications/aves-del-parque-nacional-natural-chingaza-y-zona-de-amortiguaci%C3%B3n
- B2 Javeriana, condor census and Nevados nest — https://www.javeriana.edu.co/pesquisa/sos-para-el-condor-andino-en-colombia/ ; Oryx 1989–91 reintroduction — https://www.cambridge.org/core/journals/oryx/article/reintroduction-of-the-andean-condor-into-colombia-south-america-19891991/7177C3415CCA351110DF0C130DE58EE9
- B3 Infobae 2026, Chingaza condor sighting — https://www.infobae.com/colombia/2026/03/14/grabaron-el-avistamiento-de-un-condor-de-los-andes-en-el-parque-nacional-natural-chingaza-despego/
- B4 Stiles & Caycedo 2002, *C. apolinari hernandezi* — https://revistas.unal.edu.co/index.php/cal/article/view/39440
- B5 BirdLife, buffy helmetcrest — https://datazone.birdlife.org/species/factsheet/buffy-helmetcrest-oxypogon-stuebelii/text
- Species pages: `https://en.wikipedia.org/wiki/<English_name>` (altitude, diet, IUCN category)

Herps and invertebrates:
- H1 Humboldt páramo amphibian checklist — https://i2d.humboldt.org.co/ceiba/resource.do?r=doc_recom_anfibios
- H2 Freezing risk in high-elevation anurans, SAJH 2011 — https://complete.bioone.org/journals/south-american-journal-of-herpetology/volume-6/issue-2/057.006.0205/Freezing-Risk-in-Tropical-High-Elevation-Anurans--An-Assessment/10.2994/057.006.0205.full
- H3 Rev. Biol. Trop., *H. subpunctatus* occupancy — https://revistas.ucr.ac.cr/index.php/rrbt/article/view/918
- H4 AmphibiaWeb, *B. adspersa* — https://amphibiaweb.org/species/3950
- H5 WCS Colombia, *A. lozanoi* — https://colombia.wcs.org/en-us/STRATEGIC-PILLARS/SPECIES/AMPHIBIANS/Atelopus-lozanoi.aspx
- H6 *A. muisca* — https://recentlyextinctspecies.com/anura/atelopus-muisca
- H7 AmphibiaWeb, *P. simoterus* — https://amphibiaweb.org/species/3214
- H8 Buitrago-González 2016, Nevados frogs — https://doi.org/10.21068/bc.v17iSupl.2.417
- H9 *A. quimbaya*, Rev. Latinoam. Herpetol. 2018 — https://herpetologia.fciencias.unam.mx/index.php/revista/article/view/11
- H10 *Anadia bogotensis*, ACH catálogo — https://www.researchgate.net/publication/264557944_Anadia_bogotensis_Catalogo_de_Anfibios_y_Reptiles_de_Colombia_2014
- H11 *A. heterodermus* thermal biology — https://www.anoleannals.org/2020/05/05/the-highest-kingdom-of-anolis-thermal-biology-of-the-andean-lizard-anolis-heterodermus-squamata-dactyloidae-over-an-elevational-gradient-in-the-eastern-cordillera-of-colombia/
- H12 Fagua & Gonzalez 2007, *Espeletia grandiflora* pollination, Plant Biology — https://thieme-connect.de/products/ejournals/html/10.1055/s-2006-924544 (abstract only; whether the site is Chingaza is UNVERIFIED)
- *D. molitor* synonymy — https://amphibiansoftheworld.amnh.org/Amphibia/Anura/Hylidae/Dendropsophus/Dendropsophus-molitor

Introduced:
- I1 El Espectador, trout — https://www.elespectador.com/ambiente/trucha-arcoiris-esta-depredando-peces-nativos-article-473080/
- I2 El Espectador, feral dogs — https://www.elespectador.com/bogota/los-perros-que-se-vuelven-salvajes-en-bogota-article-866097/
- I3 Mongabay 2020, Nevados restoration — https://es.mongabay.com/2020/03/restauracion-de-paramos-en-parque-los-nevados-colombia/
- I4 MinAmbiente, Guerrero — https://www.minambiente.gov.co/bavaria-le-apuesta-a-la-proteccion-del-paramo-guerrero-en-cundinamarca/
- I5 Rev. Geográfica, Cogua land use — https://revistas.una.ac.cr/index.php/geografica/article/download/2533/2422/5766
- I6 Pulitzer Center, Guerrero coal — https://pulitzercenter.org/node/25484

## Dropped candidates

- **Mammals:**
  - Culpeo fox: Nariño only.
  - Striped hog-nosed skunk and Neotropical otter: no records at this altitude.
  - Stump-tailed porcupine: forest species.
  - Peccary, woolly monkey and anteater: Chingaza's lowland flank, not the páramo.
  - Bamboo rat *Olallamys albicauda*: a chuscal candidate, but no records ≥3000 m.
  - Shrew and *Akodon*: dropped to hold the count.
- **Birds:**
  - Carunculated caracara: 0 records at any site.
  - Yellow-eared parrot, rusty-faced parrot, golden-plumed parakeet and Grallaria milleri: forest birds.
  - Andean snipe and the owls: too few records.
  - Andean coot: marginal records.
- **Herps:**
  - *P. lynchi* (Boyacá) and *Gastrotheca nicefori* (Antioquia): no records in the site boxes.
  - *Atelopus nahumae*: Santa Marta, not Los Nevados.
  - *Centrolene buckleyi*: forest streams.
  - *Atractus crassicaudatus*: mostly below the páramo.
  - Other lowland species: out of range.
