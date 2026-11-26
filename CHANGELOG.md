# Lorebound

## 0.3.8

- **Riding has its own category**: Learning to Ride, the first-mount quests, Swift as the Wind and An Epic Ride
  are now under Other, Riding. Starting zones like Dun Morogh no longer wait on level 40 and 60 riding quests
  before they can be finished.
- **Quest items on the quest page**: a quest that starts from an item shows the item (hover it for its tooltip)
  and lists the mobs it drops from, or the chest it's found in or the vendor who sells it. The button under it is
  now Show where it drops: the zone map with a dot on every spawn. The site's quest pages show the same.

## 0.3.7

- **Fold the quest list**: click a heading in a zone's quests to fold it. Section headings like "Available now"
  or "Done" stay folded in every zone; chain headings like "The Hunter's Way" fold to one line with its dots and
  count. Click again to open it. On a controller the D-pad stops on headings too, and A folds them.
- **Quests in your log always show**: whatever the quest data says about race, class or side, a quest you have
  is listed, counted and found by the search. A Skyborne druid's Trial of the Lake was missing because the old
  quest data names only Tauren and Night Elves for it.
- **Class quest chains for Forever's races**: once you're on a class chain the old data gives only to classic
  races (the druid's Trial of the Lake, Trial of the Sea Lion and Aquatic Form), its next steps show too. Quests
  Forever replaces with your race's own version (the Great Windborne Cat Spirit, the Skyborne's Moonglade) stay
  hidden.
- **Where quest items come from**: a quest started by an item now says where to get it, like "Empty Powder Keg:
  dropped by Rockjaw mobs in Dun Morogh" or "Chen's Empty Keg: picked up in The Barrens", on the quest list, the
  quest's page (with a map pin to go to) and the site. That's 125 quests; crafted items and the like have no
  source in the quest data.

## 0.3.6

- **Move the windows**: the journal moves when you drag its title bar, the big header across its top, a badge's
  close-up or a quest's page, and it stays where you leave it. Drag a turn-in toast and the toasts after it
  show up in the same spot (Test toast in the settings shows one to move). The Share quests window can be
  dragged as well. "Windows back to normal" in the settings puts the journal and the toast back.

## 0.3.5

- **A click opens the quest page**: clicking a quest in the journal (or A on a controller) opens its page straight away;
  the page now also says what the quest needs first and what it leads to.
- **203 more quests**: quests the quest data gives no zone at all, Forever's newest among them, were left out; they're
  now filed where their quest giver stands. Mount Hyjal gains 103, Shen'dralas 20 and Riverglades 17.
- **Rewards and notes from ForeverDungeonJournal**: its dungeon quests show Forever's own rewards (items, money,
  reputation, experience), its notes, and where each is picked up and handed in.
- **Gear rewards from OneForAll**: where nothing else says, a quest's page shows the gear OneForAll knows it gives
  ("Rewards include").
- **Needs first** on the quest page lists only the quests you can have, each once.
- **Rewards from Forever's own servers**: every quest's rewards were asked of the game itself, so 4,689 quests now
  show exactly what Forever gives: the choices (705 quests have them), the items you receive with their counts,
  money and experience, Forever's new items among them (Hogger now also offers an Apprentice Wizard's Gown; The
  Tempest's Weapons offers Lightning's Grasp, Tidebringer's Claw or Rage of the Storm, with an Elementalist's Guard).
  Opening the journal also reads your quest log's rewards, choices and all, and Share quests sends any Lorebound
  hasn't got.
- **Asking as you go**: a quest page whose rewards still aren't known asks the game straight away, and so do the
  quests of the zone you're looking at (one at a time, never in combat).
- **Chains as your character sees them**: a chain that starts with another race's version of a quest (Call of Air
  from Orgrimmar, for a Tauren) now starts with your own version (Thunder Bluff's) instead, and steps you can't
  have are left out, on the quest page's chain list and the journal's storylines alike. Steps are numbered as you
  see them, so the counts and dots add up.

## 0.3.4

- Quest list update: 0 quests added, 1 removed (4690 in all).

## 0.3.3

- **Fix**: finishing your own race's class quest could bring another race's version of it back. The game marks the
  other quest of an either-or pair done too (a Tauren who finishes Kranal Fiss's Call of Fire has the Skyborne's
  Sessaria Skystride quest marked done), and Lorebound took that as you choosing that version, showing its later
  steps as still to do. Now only a later step of that version, done or in your log, says you took it; otherwise the
  whole version stays out of your lists and counts.

## 0.3.2

- **Whole chains, wherever they start**: a zone's or dungeon's page shows every step of a chain it has a step in,
  the ones in other zones too (named in place of the quest giver), so a dungeon quest that's Part 4 of a chain begun
  outside it shows Parts 1 to 3 above it. Those steps still count in their own zones.

## 0.3.1

- **A toast you notice**: it slides down into place as it fades in, waits a beat, then its ring ticks up more
  slowly with the percentage counting, a soft pulse and a band of light across it when it lands. The +1 is bigger
  and gold. It stays 6 seconds, fades out gently, and holds while the mouse is over it.
- **Closing a ring is an event**: a bigger banner shows only the zone's name while its ring sweeps all the way round
  from empty, gathering speed. At the close the banner jolts, its border flashes gold, a halo and a flash burst,
  sparks fly, a gold starburst opens and turns behind the badge as it springs out, and the title becomes
  "... complete!" with the details following. It stays 10 seconds.
- **Fix**: the settings' Test fanfare showed the badge greyed out, as not earned yet; it now shows it as you'd earn it.

## 0.3.0

- **Quest chains as storylines**: a zone's chain now shows once, in the section of the step you're on, under a
  heading with its name, a dot for every step and how many are done. Below it every step of the chain in this zone,
  in order, joined by a line (green past the steps you've finished). A single step of a chain shows "Part 3 of 6".
  The Done filter still shows a chain you've started, in full.
- **Fix**: a saved setting of the wrong kind (a damaged or hand-edited saved variables file) could stop the journal
  opening; it now falls back to the default. A quest you'd met that was saved without its name or zone is dropped
  instead of stopping the journal loading.

## 0.2.0

- **Your race's class quests only**: where a class quest comes in one version per race (Call of Earth in Durotar,
  Mulgore and on Zephras Isle), the other races' versions are left out instead of showing as done or still to do.
  If you took another race's version, that one shows.
- **Share quest text**: Share quests (it was Share new quests) now also sends the Forever text you read for quests
  Lorebound only has Classic's text for, or none: about 1,700 quests that changed or are new in Forever. Text is
  kept with your character's name taken out from now on, and only that is shared (English clients). Once it's
  checked, the text joins those quests' pages for everyone, marked as players' text.
- **When you come back**: the quest page keeps what the quest giver says when you return, as it does the rest.
- **Lighter quest pages**: their text comes in three parts (Eastern Kingdoms, Kalimdor, and the rest), and only the
  part a quest is in loads, kept as text until a page is shown: about a fifth of the memory it took.
- **Fix**: a quest you'd met with a backtick in its name was left out of the code you shared.

## 0.1.0

- **The journal** (`/lb` or `/lorebound`, a key of your choice in Key Bindings > AddOns, LT + L3 on a
  controller, or the addon compartment): every zone down the left with its own ring, grouped by continent,
  dungeons, raids, class, professions, PvP and the rest. A zone's page shows three nested rings over the zone's map art:
  the zone, its continent and the whole Lorebound count, and its quests below: in your log, available now, coming up
  (and what for: a level, a quest first, reputation, a profession), done, and locked out.
- **Skipped and locked out**: a quest you only missed because you'd already gone further (a breadcrumb whose
  quest you did directly, a step whose next quest is done, one only there until a quest you've done, the other
  quest of a pair you can only do one of) counts as done, marked as such. Quests you're cut off from for good
  (anything that needs one of those, a level or reputation cap, a quest only while another is in your log) are
  locked out: left out of the
  count and hidden until you tick "Locked out", each with the reason. Worked out live from your completed
  quests and quest log.
- **Quest text**: open a quest in the list for its objective, the story text from the last time you read it at the
  quest giver (kept for every character), its turn-in text, who gives it and what it needs first.
- **Quest givers**: "Show quest giver" puts them on a map of the zone in the journal and a map pin link in chat; click
  the link to set the waypoint (Blizzard's own link, so nothing of ours touches the world map).
- **Quests the list hasn't got** are learned as you meet them (offered or accepted) and count in their zone from then on,
  with their quest giver (and where you stood), who takes them in, and the quest you'd just turned in there. The
  overview's "Share new quests" button gives you a code to copy and send, and `_tools/make_lore.py` adds pasted
  codes (`_tools/lore_reports`) to the next list.
- **Your progress on the web**: "Export to website" on the overview (or `/lb export`) makes a code of this character
  (every quest's status as the journal shows it, badges, name and realm) to paste at lb.frogwizard.net/me: rings,
  badges and every zone's quests with what's left and why, on a phone too. The site saves it to a private link with a
  QR code, and each newer export from the same browser updates that link. The site also browses every quest.
- **Dungeons**: each dungeon's quests on its own page (ForeverDungeonJournal's lists: wings together, quests given
  in towns that lead there), and Forever's new dungeons (Krol'dok Stronghold, the Drowned City, Blackmaw Hold,
  Alcaz Prison) with theirs. A badge in the badge case opens large to inspect, with its numbers and dates.
- **Toasts**: each quest turned in shows the zone's ring ticking up. Closing a ring (a zone, a continent, everything)
  gets a banner: the ring sweeps shut, a halo bursts, sparks fly and a fanfare plays.
- **Controller**: in the gamepad UI the journal takes the D-pad while it's open (up/down zones, right or A into the
  quests, A opens one, X shows its quest giver, Y locked out, LB/RB filters, B back and close), let go the moment a
  fight starts, through override bindings to Lorebound's own buttons only.
- **Overview**: a wall of every zone's ring, closed ones gold, and how many quests you've turned in today and this week.
- **Badges**, like a gym leader's: closing a zone's ring earns its badge, the zone's own map in a gold frame (a medal
  for a zone, a shield for a dungeon or battleground, a crest for a raid, a sigil with its icon for class and
  profession quests). Each continent earns its crest, and everything the Lorebound Seal. The overview's Badges
  tab is the badge case (ones still to earn greyed, with how far along you are), and the banner for a closed ring
  hands you the badge. Each character keeps its own, with the day it was earned.
- **Pinned zones**: right-click a zone (or the pin on its page, or X on a controller) to pin it to the top of the
  zone list and the overview.
- **The look**: every row of the zone list (zones and their groups) sits on its zone's own map, and every map
  Lorebound shows is fully revealed: each explorable sub-zone painted in, explored or not. The rings fill
  clockwise from twelve o'clock with round caps, a lighter leading end and a soft shadow under it, in ember,
  arcane and jade (gold once closed), with a pin, star and book on the big rings' start caps.
- The quest list (Lorebound_Data, 4,665 quests) loads only when needed. Made by `_tools/make_lore.py` from Zquest's
  QuestieDB export and Quest Completist's Forever data, checked against the game's own quest list.
