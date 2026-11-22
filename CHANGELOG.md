# Lorebound

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
