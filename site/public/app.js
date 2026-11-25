'use strict'
// Lorebound's site, laid out like the journal: the zones down the left (their maps behind them), the page on
// the right. A character's progress comes from the addon's "Export to website" code (Export.lua), decoded
// here in the browser; it's stored only when asked, under a random id, for a phone link (/api/progress).
//
// Routes: /  the overview   /zone/<n>  a zone   /me  your code and phone link   /p/<id>[/zone/<n>]  a saved link

const IN_TOTAL = new Set([1, 2, 3, 4, 5, 8]) // the groups the Lorebound ring counts (Lore.lua)
const OTHER_GROUP = 8
const SHAPES = [null, 'medal', 'medal', 'shield', 'crest', 'hex', 'hex', 'shield', 'medal']
const GROUP_MAPS = { 1: 1415, 2: 1414 } // the continents' maps, for their crests
const RACES = { 1: 'Human', 2: 'Orc', 3: 'Dwarf', 4: 'Night Elf', 5: 'Undead', 6: 'Tauren', 7: 'Gnome', 8: 'Troll',
  95: 'Skyborne', 96: 'Skyborne' }
const CLASSES = { 1: 'Warrior', 2: 'Paladin', 3: 'Hunter', 4: 'Rogue', 5: 'Priest', 7: 'Shaman', 8: 'Mage',
  9: 'Warlock', 11: 'Druid' }
const LETTERS = { a: 'hidden', b: 'done', c: 'active', d: 'available', e: 'later', f: 'locked', g: 'skip' }
const MARKS = { done: '✓', skip: '✓', active: '?', available: '!', later: '!', locked: '✕' }
const SECTIONS = [['active', 'In your quest log'], ['available', 'Available now'], ['later', 'Coming up'],
  ['done', 'Done'], ['skip', 'Done by moving past it'], ['locked', 'Locked out']]
const FILTERS = { todo: ['active', 'available', 'later'], done: ['done', 'skip'], all: ['active', 'available', 'later', 'done', 'skip'] }
const VERSION = /^[0-9a-f]{10}$/

const page = document.getElementById('page')
const sidePane = document.getElementById('side')
const lists = {}        // quest lists by version (data/quests-<version>.json)
let icons = {}          // zone name: icon file, for class and profession badges (art/icons.json)
let shown = null        // what's on screen: { list, quests, zones, progress, base, counts }
let filter = 'todo'
let showLocked = false
let side = 'both'       // with no character: whose quests to show (alliance, horde or both), remembered

const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]))
const fraction = (done, total) => (total > 0 ? done / total : 0)
const percent = (done, total) => Math.floor(fraction(done, total) * 100) + '%'
const number = (n) => n.toLocaleString('en-GB')
const store = {
  get(key) { try { return JSON.parse(localStorage.getItem(key)) } catch { return null } },
  set(key, value) { try { localStorage.setItem(key, JSON.stringify(value)) } catch { /* a private window */ } },
  drop(key) { try { localStorage.removeItem(key) } catch { /* a private window */ } },
}

async function getJson(url) {
  const res = await fetch(url, { cache: 'no-cache' })
  if (!res.ok || !(res.headers.get('content-type') || '').includes('json')) return null
  return res.json()
}

// A quest list by version (null: the newest). A version the site hasn't got gives null.
async function loadList(version) {
  if (!version) {
    const latest = await getJson('/data/latest.json')
    if (!latest) throw new Error("Couldn't load the quest list. Check your connection and reload the page.")
    version = latest.version
  }
  if (!lists[version]) {
    const list = await getJson(`/data/quests-${version}.json`)
    if (!list) return null
    list.field = Object.fromEntries(list.fields.map((name, i) => [name, i]))
    list.order = new Map(list.ids.map((id, i) => [id, i]))
    lists[version] = list
  }
  return lists[version]
}

// ---------------------------------------------------------------- a progress code (Export.lua)

function decode(code) {
  const parts = String(code).trim().split('~')
  if (parts[0] !== 'LMP1' || parts.length < 15) throw new Error("That isn't a Lorebound progress code: it starts with LMP1~.")
  const [, version, name, realm, race, cls, faction, level, time, today, week, runs, reasons, learned, badges] = parts
  if (!VERSION.test(version)) throw new Error("That code's quest list version doesn't read. Export it again in game.")
  return { code: String(code).trim(), version, name, realm, race: +race, cls: +cls, faction: +faction, level: +level || 1,
    time: +time, today: +today || 0, week: +week || 0, runs, reasons, learned, badges }
}

// The letters and the rest, read against the code's own quest list.
function unpack(progress, list) {
  const letters = []
  for (const [, letter, length] of progress.runs.matchAll(/([a-g])(\d*)/g)) {
    const n = length ? parseInt(length, 10) : 1
    if (letters.length + n > list.ids.length) throw new Error("That code has more quests than its quest list. Export it again in game.")
    for (let i = 0; i < n; i++) letters.push(letter)
  }
  const why = new Map()
  for (const entry of progress.reasons ? progress.reasons.split(';') : []) {
    const [id, reason, a, b] = entry.split('.')
    why.set(+id, { reason: +reason, a: a ? +a : null, b: b ? +b : null })
  }
  const learnt = (progress.learned ? progress.learned.split(';') : []).map((entry) => {
    const [id, name, zone, level, letter] = entry.split('^')
    return { id: +id, name, zone, level: +level || null, status: LETTERS[letter] || 'available' }
  })
  const earned = new Map((progress.badges ? progress.badges.split(';') : []).map((entry) => {
    const [key, at] = entry.split(':')
    return [key, +at]
  }))
  return { ...progress, letters, why, learnt, earned }
}

// ---------------------------------------------------------------- the view: a list, a side, a character

// The quests as this character's side sees them (the Horde's differences: other zones, givers, places).
function questsFor(list, faction) {
  if (faction !== 2 || !list.horde) return list.quests
  list.hordeQuests = list.hordeQuests || Object.fromEntries(Object.entries(list.quests).map(([id, row]) => {
    const diff = list.horde[id]
    if (!diff) return [id, row]
    const copy = row.slice()
    for (const [field, value] of Object.entries(diff)) copy[+field] = value
    return [id, copy]
  }))
  return list.hordeQuests
}

function makeView(list, progress, base) {
  const quests = questsFor(list, progress ? progress.faction : side === 'horde' ? 2 : 0)
  const zones = list.zones.map((zone) => ({ name: zone[0], group: zone[1], map: zone[2], journal: zone[3] }))
  // Learned quests in zones the list hasn't got make new zones under Other, as in game (Lore.lua).
  for (const quest of progress ? progress.learnt : []) {
    if (!zones.some((zone) => zone.name === quest.zone)) zones.push({ name: quest.zone, group: OTHER_GROUP })
  }
  const view = { list, quests, zones, progress, base }
  view.counts = count(view)
  return view
}

const row = (id) => shown.quests[id]
const field = (quest, name) => (quest ? quest[shown.list.field[name]] : undefined)
const questName = (id) => field(row(id), 'name') || `Quest ${id}`

function statusOf(id, view = shown) {
  if (!view.progress) return null
  const i = view.list.order.get(id)
  return LETTERS[(i !== undefined && view.progress.letters[i]) || 'a']
}

// Whether a quest is shown: for a character, unless the game hides it from them; else by the side picked.
function visible(id, view = shown) {
  if (view.progress) return statusOf(id, view) !== 'hidden'
  if (side === 'both') return true
  const quest = sideOf(view.quests[id], view.list)
  return quest === 'both sides' || quest === (side === 'alliance' ? 'the Alliance' : 'the Horde')
}

function count(view) {
  const zones = view.zones.map(() => ({ done: 0, total: 0, locked: 0 }))
  const add = (zoneIndex, status) => {
    const tally = zones[zoneIndex]
    if (!tally || status === 'hidden') return
    if (status === 'locked') { tally.locked++; return }
    tally.total++
    if (status === 'done' || status === 'skip') tally.done++
  }
  for (const id of view.list.ids) if (visible(id, view)) add(view.quests[id][view.list.field.zone] - 1, statusOf(id, view))
  for (const quest of view.progress ? view.progress.learnt : []) add(view.zones.findIndex((tally) => tally.name === quest.zone), quest.status)
  const groups = view.list.groups.map(() => ({ done: 0, total: 0 }))
  const all = { done: 0, total: 0 }
  zones.forEach((tally, i) => {
    const group = view.zones[i].group
    groups[group - 1].done += tally.done
    groups[group - 1].total += tally.total
    if (IN_TOTAL.has(group)) { all.done += tally.done; all.total += tally.total }
  })
  return { zones, groups, all }
}

function levels(zoneIndex) {
  const found = shown.list.ids.map(row).filter((quest) => field(quest, 'zone') === zoneIndex + 1)
    .map((quest) => field(quest, 'level')).filter((level) => level > 0).sort((a, b) => a - b)
  if (!found.length) return ''
  const low = found[Math.floor(found.length * 0.1)]
  const high = found[Math.min(found.length - 1, Math.floor(found.length * 0.9))]
  return low === high ? `Level ${low}` : `Levels ${low} to ${high}`
}

// ---------------------------------------------------------------- art

function zoneArt(zone) {
  if (!zone) return null
  if (Array.isArray(zone.journal)) return `/art/screen-${zone.journal[5]}.webp` // a Forever dungeon's loading screen
  if (zone.journal) return `/art/ej-${zone.journal}.webp`
  if (zone.map) return `/art/map-${zone.map}.webp`
  return null
}
const artStyle = (url) => (url ? ` style="--art:url('${esc(url)}')"` : '')

// Rings, outermost first: [{ share, color }], color one of zone, group, total, gold.
function rings(list, size) {
  const width = size * 0.12
  const gap = size * 0.03
  let radius = size / 2 - width / 2
  const middle = size / 2
  const parts = list.map(({ share, color }) => {
    const length = 2 * Math.PI * radius
    const arc = Math.max(0, Math.min(1, share)) * length
    const circle = (cls, extra) => `<circle class="${cls} c-${color}" cx="${middle}" cy="${middle}" r="${radius}" stroke-width="${width}"${extra}/>`
    const svg = circle('ring-track', '') + (arc > 0.01
      ? circle('ring-fill', ` stroke-dasharray="${arc} ${length}" transform="rotate(-90 ${middle} ${middle})"`) : '')
    radius -= width + gap
    return svg
  })
  return `<svg class="ring" width="${size}" height="${size}" viewBox="0 0 ${size} ${size}" aria-hidden="true">${parts.join('')}</svg>`
}

// A badge in the journal's frame: kind zone (value: zone index), group (1 or 2) or seal.
function badge(kind, value, size) {
  let shape = 'crest'
  let art = null
  let look = 'map'
  let name = ''
  if (kind === 'zone') {
    const zone = shown.zones[value]
    shape = SHAPES[zone.group] || 'medal'
    name = zone.name
    art = zoneArt(zone)
    if (Object.hasOwn(icons, name)) { art = `/art/${icons[name]}`; look = 'icon' }
    else if (zone.journal) look = Array.isArray(zone.journal) ? 'map' : 'painting' // a wide loading screen fills like a map
  } else if (kind === 'group') {
    art = `/art/map-${GROUP_MAPS[value]}.webp`
  } else {
    art = `/art/${icons["Lorebound Seal"] || 'icon-inv-misc-book-09.webp'}`
    look = 'icon'
  }
  const { done, total } = badgeCount(kind, value)
  const earned = isEarned(kind, value)
  return `<span class="badge shape-${shape} ${look} ${earned ? 'earned' : ''}" style="--size:${size}px${art ? `;--art:url('${esc(art)}')` : ''}">
    <span class="art"></span><img class="rim" src="/art/badge-${shape}.png" alt="">
    ${earned ? '' : `<span class="pct">${percent(done, total)}</span>`}</span>`
}

function badgeCount(kind, value) {
  const counts = shown.counts
  if (kind === 'zone') return counts.zones[value]
  if (kind === 'group') return counts.groups[value - 1]
  return counts.all
}

function isEarned(kind, value) {
  const progress = shown.progress
  if (!progress) return false
  const { done, total } = badgeCount(kind, value)
  return progress.earned.has(badgeKey(kind, value)) || (total > 0 && done >= total)
}

// The code's badge keys (Export.lua): a list zone by its number, a zone only learned quests made by its name.
function badgeKey(kind, value) {
  if (kind === 'group') return 'g' + value
  if (kind !== 'zone') return 's'
  if (value < shown.list.zones.length) return String(value + 1)
  return 'z' + shown.zones[value].name.replace(/[~;^|\n<>`:]/g, ' ')
}

function badgeName(kind, value) {
  if (kind === 'zone') return shown.zones[value].name
  if (kind === 'group') return `${shown.list.groups[value - 1]} Crest`
  return "Lorebound Seal"
}

// ---------------------------------------------------------------- the zone list (the left side)

function drawSide() {
  const counts = shown.counts
  const mine = !!shown.progress
  let html = mine ? '' : `<div class="sides" role="group" aria-label="Whose quests">${[['alliance', 'Alliance'], ['horde', 'Horde'], ['both', 'Both']]
    .map(([key, label]) => `<button type="button" data-side="${key}" aria-pressed="${side === key}">${label}</button>`).join('')}</div>`
  shown.list.groups.forEach((groupName, groupIndex) => {
    const zones = shown.zones.map((zone, i) => [zone, i]).filter(([zone, i]) => zone.group === groupIndex + 1 && counts.zones[i].total > 0)
    if (!zones.length) return
    const groupCount = counts.groups[groupIndex]
    const open = !folded.has(groupName)
    html += `<button type="button" class="group" data-fold="${esc(groupName)}" aria-expanded="${open}">${esc(groupName)}<span class="count">${mine ? `${number(groupCount.done)} / ${number(groupCount.total)}` : number(groupCount.total)}</span></button>
      <div class="group-zones"${open ? '' : ' hidden'}>`
    for (const [zone, i] of zones) {
      const zoneCount = counts.zones[i]
      const closed = mine && zoneCount.done >= zoneCount.total
      html += `<a class="zone-row${closed ? ' closed' : ''}" href="${shown.base}/zone/${i + 1}" data-zone="${i + 1}"${artStyle(zoneArt(zone))}>
        ${mine ? rings([{ share: fraction(zoneCount.done, zoneCount.total), color: closed ? 'gold' : 'zone' }], 30) : ''}
        <span class="text"><span class="name">${esc(zone.name)}</span><br><span class="levels">${levels(i)}</span></span>
        <span class="tally">${mine ? `${zoneCount.done} / ${zoneCount.total}` : `${zoneCount.total} quest${zoneCount.total === 1 ? '' : 's'}`}</span></a>`
    }
    html += '</div>'
  })
  sidePane.innerHTML = html
}

// Continents and groups fold away in the zone list; which ones is remembered in this browser.
const folded = new Set(store.get('lm:folded') || [])
sidePane.addEventListener('click', (event) => {
  const pick = event.target.closest('[data-side]')
  if (pick) {
    side = pick.dataset.side
    store.set('lm:side', side)
    viewKey = null
    show(false)
    return
  }
  const button = event.target.closest('[data-fold]')
  if (!button) return
  const name = button.dataset.fold
  const open = folded.has(name)
  if (open) folded.delete(name); else folded.add(name)
  store.set('lm:folded', [...folded])
  button.setAttribute('aria-expanded', String(open))
  button.nextElementSibling.hidden = !open
})

// The search box sits above the page on a phone and above the zone list on a wider screen (index.html).
const search = document.getElementById('search')
search.addEventListener('input', () => {
  const text = search.value.trim().toLowerCase()
  if (!shown) return
  if (text.length >= 3) drawSearch(text)
  else if (page.dataset.search) show(false)
})

function markSide(zoneNumber) {
  sidePane.querySelectorAll('.zone-row').forEach((row) => row.classList.toggle('on', +row.dataset.zone === zoneNumber))
}

// ---------------------------------------------------------------- the overview

function banner({ art, title, sub, meta, ringList, legend }) {
  return `<section class="banner"${artStyle(art)}>
    ${ringList ? rings(ringList, 150) : ''}
    <div><h1>${title}</h1>${sub ? `<div class="sub">${sub}</div>` : ''}${meta ? `<div class="meta">${meta}</div>` : ''}
    ${legend ? `<ul class="legend">${legend.map(([color, text]) => `<li><i class="c-${color}"></i>${text}</li>`).join('')}</ul>` : ''}</div>
  </section>`
}

function drawOverview() {
  const counts = shown.counts
  const progress = shown.progress
  const total = shown.list.ids.length
  if (!progress) {
    const problem = shown.problem ? `<div class="section"><p class="bad">${esc(shown.problem)}</p></div>` : ''
    page.innerHTML = problem + banner({
      art: '/art/map-947.webp',
      title: 'Lorebound',
      sub: `Every WoW Forever quest by zone: ${number(total)} quests in ${shown.list.zones.length} zones and dungeons.`,
      meta: 'Pick a zone for its quests, who gives them and what each one needs first.',
    }) + `<div class="section"><h2>Your own rings and badges</h2>
      <p class="muted">With the Lorebound addon, type <code>/lb export</code> in game and paste the code under
      <a href="/me">My progress</a>. Each zone's ring and badge fills as you finish its quests, quests you're locked out of
      say why, and a private link puts it on your phone.</p></div>`
    return
  }
  const ek = counts.groups[0]
  const kal = counts.groups[1]
  const who = [progress.level && `Level ${progress.level}`, RACES[progress.race], CLASSES[progress.cls]].filter(Boolean).join(' ')
  const when = new Date(progress.time * 1000).toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' })
  let html = banner({
    art: '/art/map-947.webp',
    title: esc(progress.name || 'Your character'),
    sub: esc(who) + (progress.realm ? `, ${esc(progress.realm)}` : ''),
    meta: `Exported ${esc(when)}. ${progress.today} turned in that day, ${progress.week} that week.`,
    ringList: [{ share: fraction(ek.done, ek.total), color: 'zone' }, { share: fraction(kal.done, kal.total), color: 'group' },
      { share: fraction(counts.all.done, counts.all.total), color: 'total' }],
    legend: [['zone', `Eastern Kingdoms ${number(ek.done)} / ${number(ek.total)}`],
      ['group', `Kalimdor ${number(kal.done)} / ${number(kal.total)}`],
      ['total', `Lorebound ${number(counts.all.done)} / ${number(counts.all.total)}, ${percent(counts.all.done, counts.all.total)}`]],
  })
  // Each group's badges fold away on a phone, where the zone list follows the page.
  const open = window.matchMedia('(min-width: 901px)').matches ? ' open' : ''
  let earned = 0
  let all = 0
  let groupsHtml = ''
  shown.list.groups.forEach((groupName, groupIndex) => {
    const zones = shown.zones.map((zone, i) => i).filter((i) => shown.zones[i].group === groupIndex + 1 && (counts.zones[i].total > 0 || isEarned('zone', i)))
    if (!zones.length) return
    const got = zones.filter((i) => isEarned('zone', i)).length
    all += zones.length
    earned += got
    groupsHtml += `<details class="fold"${open}><summary>${esc(groupName)} <span class="muted">${got} of ${zones.length}</span></summary>
      <div class="case">${zones.map((i) => medal('zone', i, `${shown.base}/zone/${i + 1}`)).join('')}</div></details>`
  })
  html += `<div class="section"><h2>Badges <span class="muted">${earned} of ${all} zones</span></h2>
    <div class="case">${medal('group', 1)}${medal('group', 2)}${medal('seal')}</div>${groupsHtml}</div>`
  page.innerHTML = html
}

function medal(kind, value, href) {
  const earned = isEarned(kind, value)
  const tag = href ? 'a' : 'div'
  const { done, total } = badgeCount(kind, value)
  const title = earned ? 'Earned' : `${done} of ${total} quests`
  return `<${tag} class="medal${earned ? ' earned' : ''}"${href ? ` href="${href}"` : ''} title="${esc(title)}">
    ${badge(kind, value, 76)}<span class="label">${esc(badgeName(kind, value))}</span></${tag}>`
}

// ---------------------------------------------------------------- a zone

const STANDINGS = [[42000, 'Exalted'], [21000, 'Revered'], [9000, 'Honored'], [3000, 'Friendly'], [0, 'Neutral'],
  [-3000, 'Unfriendly'], [-6000, 'Hostile']] // Lore.lua's
const standing = (value) => (STANDINGS.find(([least]) => value >= least) || [0, 'Hated'])[1]
const FACTIONS = { 21: 'Booty Bay', 47: 'Ironforge', 54: 'Gnomeregan', 59: 'the Thorium Brotherhood', 68: 'Undercity',
  69: 'Darnassus', 72: 'Stormwind', 76: 'Orgrimmar', 81: 'Thunder Bluff', 87: 'the Bloodsail Buccaneers', 92: 'the Gelkis',
  93: 'the Magram', 270: 'the Zandalar Tribe', 349: 'Ravenholdt', 369: 'Gadgetzan', 470: 'Ratchet', 509: 'the League of Arathor',
  510: 'the Defilers', 529: 'the Argent Dawn', 530: 'the Darkspear Trolls', 576: 'the Timbermaw Hold', 577: 'Everlook',
  589: 'the Wintersaber Trainers', 609: 'the Cenarion Circle', 729: 'the Frostwolf Clan', 730: 'the Stormpike Guard',
  749: 'the Hydraxian Waterlords', 809: "the Shen'dralar", 889: 'the Warsong Outriders', 890: 'the Silverwing Sentinels',
  909: 'the Darkmoon Faire', 910: 'the Brood of Nozdormu' }
const faction = (id) => FACTIONS[id] || 'a faction'
const PROFESSIONS = { 164: 'Blacksmithing', 165: 'Leatherworking', 171: 'Alchemy', 182: 'Herbalism', 186: 'Mining',
  197: 'Tailoring', 202: 'Engineering', 333: 'Enchanting', 393: 'Skinning', 129: 'First Aid', 185: 'Cooking', 356: 'Fishing' }

// Why a quest is locked out, skipped or coming up: the journal's own reason (Lore.lua's Why codes), else
// worked out from the list (a code from before the addon sent reasons for quests coming up).
function reasonOf(id, status) {
  const why = shown.progress && shown.progress.why.get(id)
  if (why) {
    const other = why.a != null ? questName(why.a) : 'another quest'
    const count = Number.isFinite(why.a) ? why.a : '?'
    switch (why.reason) {
      case 1: return `Needs ${other}, which you can't get any more.`
      case 2: return `You did ${other} instead: only one of the two can be done. Counted as done.`
      case 3: return `${other} is in your quest log instead. Abandon it to get this one back.`
      case 4: return `It leads to ${other}, which you've picked up. Counted as done once you finish that.`
      case 5: return `You're past it: ${other} is in your quest log. Counted as done once you finish that.`
      case 7: return `Only up to level ${count}.`
      case 8: return `Only below ${standing(why.b)} with ${faction(why.a)}.`
      case 9: return `Only while ${other} is in your quest log.`
      case 10: return `After ${other}.`
      case 11: return `While ${other} is in your quest log.`
      case 12: return `From level ${count}.`
      case 13: return `Needs ${standing(why.b)} with ${faction(why.a)}.`
      case 14: return `Needs ${PROFESSIONS[why.a] || 'a profession'} ${Number.isFinite(why.b) ? why.b : ''}.`.replace(' .', '.')
      case 15: return `Skipped: you went straight to ${other}. Counted as done.`
      case 16: return `Skipped: you've done ${other}, which comes after it. Counted as done.`
      case 17: return `No longer needed: ${other} is done. Counted as done.`
    }
  }
  if (status !== 'later') return null
  const quest = row(id)
  const finished = (need) => ['done', 'skip'].includes(statusOf(Math.abs(need)))
  const all = (field(quest, 'needsAll') || []).filter((need) => !finished(need))
  if (all.length) return `After ${questName(Math.abs(all[0]))}.`
  const any = field(quest, 'needsAny') || []
  if (any.length && !any.some(finished)) {
    return `After ${any.slice(0, 2).map((need) => questName(Math.abs(need))).join(' or ')}${any.length > 2 ? ' or another' : ''}.`
  }
  const min = field(quest, 'minLevel')
  if (min && shown.progress.level < min) return `From level ${min}.`
  if (field(quest, 'minRep')) return 'Needs more reputation.'
  return 'Coming up.'
}

function questItem(id, { withZone, step } = {}) {
  const quest = row(id)
  const status = statusOf(id)
  const reason = status ? reasonOf(id, status) : null
  const objective = field(quest, 'objective')
  const giver = field(quest, 'starter')
  const from = field(quest, 'starterFrom')
  const finisher = field(quest, 'finisher')
  const place = field(quest, 'map') ? ` at ${field(quest, 'x')}, ${field(quest, 'y')}` : ''
  const needs = [...(field(quest, 'needsAll') || []), ...(field(quest, 'needsAny') || [])].map((need) => {
    const done = ['done', 'skip'].includes(statusOf(Math.abs(need)))
    return esc(questName(Math.abs(need))) + (done ? ' (done)' : '')
  })
  const zone = withZone ? ` <span class="zone-tag">in ${esc(shown.zones[field(quest, 'zone') - 1].name)}</span>` : ''
  return `<li class="quest st-${status || 'none'}"><details><summary>
      <span class="mark" aria-label="${esc(status || '')}">${status ? MARKS[status] || '' : ''}</span>
      <span class="lvl">${field(quest, 'level') > 0 ? field(quest, 'level') : ''}</span>
      <span class="qname">${step ? `<span class="part">Part ${step}</span>` : ''}${questLink(id)}${zone}</span>
      <span class="giver">${esc(giver || '')}</span>
      ${reason || objective ? `<span class="qline">${esc(reason || objective)}</span>` : ''}
    </summary><div class="more">
      ${objective && reason ? `<p>${esc(objective)}</p>` : ''}
      ${giver ? `<p>From ${esc(giver)}${from ? ` (${esc(from[0].toLowerCase() + from.slice(1))})` : ''}${esc(place)}${finisher && finisher !== giver ? `, handed in to ${esc(finisher)}` : ''}.</p>` : ''}
      ${needs.length ? `<p>Needs first: ${needs.join(', ')}.</p>` : ''}
      <p><a href="${shown.base}/quest/${id}">The whole quest</a> · <a href="https://www.wowhead.com/forever/quest=${id}" target="_blank" rel="noopener">On Wowhead</a></p>
    </div></details></li>`
}

// The quests in order, each chain's steps gathered at its first one: [id] for a quest alone, or
// { first, steps: [[id, step, of]] } for a chain (its steps here; others may be elsewhere or done).
function chained(ids) {
  const items = []
  const chains = new Map()
  for (const id of ids) {
    const chain = field(row(id), 'chain')
    if (!chain) { items.push([id]); continue }
    if (!chains.has(chain[0])) {
      const item = { first: chain[0], of: chain[2], steps: [] }
      chains.set(chain[0], item)
      items.push(item)
    }
    chains.get(chain[0]).steps.push([id, chain[1]])
  }
  return items.map((item) => (item.steps && item.steps.length === 1 ? [item.steps[0][0]] : item))
}

function questList(ids) {
  return `<ul class="quests">${chained(ids).map((item) => {
    if (Array.isArray(item)) return questItem(item[0])
    const steps = item.steps.sort((a, b) => a[1] - b[1])
    return `<li class="storyline"><div class="storyline-head">${esc(questName(steps[0][0]))}
      <span class="muted">a chain of ${item.of} quest${item.of === 1 ? '' : 's'}${steps.length < item.of ? `, ${steps.length} here` : ''}</span></div>
      <ol class="quests steps">${steps.map(([id, step]) => questItem(id, { step })).join('')}</ol></li>`
  }).join('')}</ul>`
}

function drawZone(number) {
  const zone = shown.zones[number - 1]
  if (!zone) return drawOverview()
  const counts = shown.counts
  const zoneCount = counts.zones[number - 1]
  const progress = shown.progress
  const byLevel = (a, b) => (field(row(a), 'level') || 0) - (field(row(b), 'level') || 0) || a - b
  const ids = shown.list.ids.filter((id) => field(row(id), 'zone') === number && visible(id)).sort(byLevel)
  const storylines = chained(ids).length
  const group = shown.list.groups[zone.group - 1] || 'Other'
  let ringList = null
  let meta = `${esc(group)}${levels(number - 1) ? `, ${levels(number - 1).toLowerCase()}` : ''}`
  if (progress) {
    const groupCount = counts.groups[zone.group - 1]
    ringList = [{ share: fraction(zoneCount.done, zoneCount.total), color: zoneCount.done >= zoneCount.total && zoneCount.total ? 'gold' : 'zone' },
      { share: fraction(groupCount.done, groupCount.total), color: 'group' }, { share: fraction(counts.all.done, counts.all.total), color: 'total' }]
    meta += `. ${zoneCount.done} of ${zoneCount.total} done${zoneCount.locked ? `, ${zoneCount.locked} locked out` : ''}.`
  } else {
    meta += `. ${ids.length} quest${ids.length === 1 ? '' : 's'}${storylines < ids.length ? ` in ${storylines} storylines` : ''}${side === 'both' ? ', both sides' : ''}.`
  }
  let html = `<a class="back" href="${shown.base || '/'}">All zones</a>` +
    banner({ art: zoneArt(zone), title: esc(zone.name), sub: meta, ringList })
  if (progress) {
    html += `<div class="filters" role="group" aria-label="Show">
      ${[['todo', 'To do'], ['done', 'Done'], ['all', 'All']].map(([key, label]) =>
        `<button type="button" data-filter="${key}" class="${filter === key ? 'on' : ''}" aria-pressed="${filter === key}">${label}</button>`).join('')}
      <label><input type="checkbox" id="locked" ${showLocked ? 'checked' : ''}> Locked out</label></div>`
    const wanted = new Set([...FILTERS[filter], ...(showLocked ? ['locked'] : [])])
    for (const [key, title] of SECTIONS) {
      if (!wanted.has(key)) continue
      const list = ids.filter((id) => statusOf(id) === key)
      if (list.length) html += `<div class="heading">${title} <span class="muted">${list.length}</span></div>${questList(list)}`
    }
    const learnt = progress.learnt.filter((quest) => quest.zone === zone.name && wanted.has(quest.status))
    if (learnt.length) {
      html += `<div class="heading">Met in game <span class="muted">not in the quest list yet</span></div><ul class="quests">${learnt.map((quest) =>
        `<li class="quest st-${quest.status}"><details><summary><span class="mark">${MARKS[quest.status] || ''}</span>
        <span class="lvl">${quest.level || ''}</span><span class="qname">${esc(quest.name)}</span></summary>
        <div class="more"><p>Lorebound learned this one in game. Sharing it from the journal adds it for everyone.</p></div></details></li>`).join('')}</ul>`
    }
    if (!html.includes('class="heading"')) html += '<div class="section"><p class="muted">Nothing here for this filter.</p></div>'
  } else {
    html += questList(ids)
  }
  page.innerHTML = html
  page.querySelectorAll('[data-filter]').forEach((button) => button.addEventListener('click', () => {
    filter = button.dataset.filter
    store.set('lm:filter', filter)
    drawZone(number)
  }))
  const locked = document.getElementById('locked')
  if (locked) locked.addEventListener('change', () => { showLocked = locked.checked; store.set('lm:locked', showLocked); drawZone(number) })
}

function drawSearch(text) {
  const found = shown.list.ids.filter((id) => questName(id).toLowerCase().includes(text) && visible(id))
  const list = found.slice(0, 100)
  page.dataset.search = '1'
  page.innerHTML = `<div class="section"><h2>Search <span class="muted">${found.length} quest${found.length === 1 ? '' : 's'} named "${esc(text)}"${found.length > 100 ? ', the first 100 shown' : ''}</span></h2></div>
    ${list.length ? `<ul class="quests" style="margin-top:14px">${list.map((id) => questItem(id, { withZone: true })).join('')}</ul>` : '<div class="section"><p class="muted">No quest has that in its name.</p></div>'}`
}

// ---------------------------------------------------------------- a quest's own page

const questPages = new Map() // id: its page data (data/q/<id>.json), fetched once
const ALLIANCE_RACES = 1 + 4 + 8 + 64 // Human, Dwarf, Night Elf, Gnome (Skyborne's bit 32 is checked apart)
const HORDE_RACES = 2 + 16 + 32 + 128 // Orc, Undead, Tauren, Troll

function questData(id) {
  if (!questPages.has(id)) questPages.set(id, getJson(`/data/q/${id}.json`).catch(() => null))
  return questPages.get(id)
}

function sideOf(quest, list = shown.list) {
  const get = (name) => (quest ? quest[list.field[name]] : undefined)
  const faction = get('faction')
  if (faction === 1) return 'the Alliance'
  if (faction === 2) return 'the Horde'
  const races = get('races')
  if (!races) return 'both sides'
  const classic = races % 256
  const alliance = (classic & ALLIANCE_RACES) || Math.floor(races / 2 ** 32) % 2
  const horde = (classic & HORDE_RACES) || Math.floor(races / 2 ** 33) % 2
  return alliance && !horde ? 'the Alliance' : horde && !alliance ? 'the Horde' : 'both sides'
}

function money(copper) {
  const parts = [[Math.floor(copper / 10000), 'g'], [Math.floor(copper / 100) % 100, 's'], [copper % 100, 'c']]
  return parts.filter(([amount]) => amount > 0).map(([amount, unit]) => `${amount}${unit}`).join(' ')
}

const paragraphs = (list) => (list || []).map((text) => `<p>${esc(text)}</p>`).join('')

// A reward as the quest window shows it (ItemButtonTemplate): the icon, its count in the corner, the name on
// its plate (in light text whatever its quality, as the game's window has it). Hovering shows Wowhead's Forever
// tooltip for the item.
function rewardSlot([id, count, name, , icon]) {
  const picture = icon ? `https://wow.zamimg.com/images/wow/icons/large/${encodeURIComponent(icon)}.jpg` : ''
  return `<li><a class="reward" href="https://www.wowhead.com/forever/item=${id}" target="_blank" rel="noopener">
    <span class="slot">${picture ? `<img src="${picture}" alt="" loading="lazy" width="40" height="40">` : ''}${count > 1 ? `<span class="count">${count}</span>` : ''}</span>
    <span class="plate">${esc(name || `Item ${id}`)}</span></a></li>`
}

// A link to a quest's page; hovering shows Wowhead's tooltip for it (Forever's objective and what it needs).
function questLink(id, text = questName(id)) {
  return `<a href="${shown.base}/quest/${id}" data-wowhead="quest=${id}&domain=forever">${esc(text)}</a>`
}

// Where the quest happens: the zone's map with the giver (!), who takes it in (?) and its objectives (dots).
function questMap(data, quest) {
  const maps = new Set(shown.zones.map((zone) => zone.map).filter(Boolean))
  const zoneMap = (shown.zones[field(quest, 'zone') - 1] || {}).map
  const order = [data.start[1], ...Object.keys(data.spots || {}).map(Number), data.end[1], zoneMap]
  const map = order.find((candidate) => candidate && maps.has(candidate))
  if (!map) return ''
  const pin = (x, y, cls, text) => `<span class="pin ${cls}" style="left:${x}%;top:${y}%">${text}</span>`
  let pins = (data.spots[String(map)] || []).map(([x, y]) => pin(x, y, 'spot', '')).join('')
  if (data.end[1] === map && data.end[2] != null) {
    const shared = data.start[1] === map && data.start[2] === data.end[2] && data.start[3] === data.end[3]
    pins += pin(data.end[2] + (shared ? 2.2 : 0), data.end[3], 'end', '?') // beside the ! when it's the same person
  }
  if (data.start[1] === map && data.start[2] != null) pins += pin(data.start[2], data.start[3], 'start', '!')
  const name = (shown.zones.find((zone) => zone.map === map) || {}).name || ''
  const figure = (cls) => `<div class="qmap ${cls}"><img src="/art/map-${map}.webp" alt="Map of ${esc(name)}">${pins}</div>`
  return `<button type="button" class="mapbutton" id="openmap" aria-label="Show the map larger">${figure('small')}</button>
    <p class="legend-line"><span class="pin-key start">!</span> Pick up <span class="pin-key end">?</span> Hand in
    ${Object.keys(data.spots || {}).length ? '<span class="pin-key spot"></span> Objectives' : ''}</p>
    <dialog id="bigmap" aria-label="Map of ${esc(name)}"><form method="dialog"><button class="mapbutton" aria-label="Close the map">${figure('big')}</button></form></dialog>`
}

function fact(label, value) {
  return value ? `<div class="fact"><dt>${label}</dt><dd>${value}</dd></div>` : ''
}

function placeText(name, map, x, y, from) {
  if (!name) return ''
  const zone = shown.zones.find((entry) => entry.map === map)
  return `${esc(name)}${from ? `<br>${esc(from)}` : ''}${zone && x != null ? `<br><span class="muted">${esc(zone.name)} ${x}, ${y}</span>` : ''}`
}

async function drawQuest(id) {
  const quest = row(id)
  const zoneNumber = field(quest, 'zone')
  const zone = shown.zones[zoneNumber - 1]
  page.innerHTML = '<p class="muted pad">Loading the quest...</p>'
  const nav = navSeq
  const data = await questData(id)
  if (nav !== navSeq) return // moved on meanwhile
  const level = field(quest, 'level')
  const min = field(quest, 'minLevel')
  const status = statusOf(id)
  const reason = status ? reasonOf(id, status) : null
  const STATUS_WORDS = { done: 'Done', skip: 'Done: you moved past it', active: 'In your quest log', available: 'Available now',
    later: 'Coming up', locked: 'Locked out', hidden: 'Not for this character' }
  let html = `<a class="back" href="${shown.base}/zone/${zoneNumber}">${esc(zone.name)}</a>
    <section class="qhead"><div class="crumb"><a href="${shown.base}/zone/${zoneNumber}">${esc(zone.name)}</a></div>
    <h1>${esc(questName(id))}</h1>
    <p class="sub">${level > 0 ? `Level ${level} quest` : 'A quest'} for ${sideOf(quest)}${min ? `, from level ${min}` : ''}.</p>
    ${status ? `<p class="state st-${status}"><span class="mark">${MARKS[status] || ''}</span> ${STATUS_WORDS[status]}${reason ? `: ${esc(reason)}` : ''}</p>` : ''}`
  if (!data) {
    page.innerHTML = html + `<p class="bad">Couldn't load this quest's page. Check your connection and try again.</p></section>`
    return
  }
  const fromJournal = data.rewardsFrom === 'journal' ? " Its rewards and notes are ForeverDungeonJournal's." : ''
  const fromPlayers = data.rewardsFrom === 'players' ? ' Its rewards are as players saw them in game.'
    : data.rewardsFrom === 'game' ? " Its rewards are the game's own, as Forever's servers give them."
      + (data.choicesUnknown ? " Any choice of rewards isn't known yet." : '')
    : data.rewardsFrom === 'gear' ?" The gear it gives is from OneForAll; any other rewards aren't known yet."
    : data.rewards && !data.rewardsFrom ? " Its rewards are Classic's." : ''
  const unknown = data.rewards ? 'Its full text isn\'t known yet.' : 'Its full text and rewards aren\'t known yet.'
  const note = (data.shared ? "Forever's own text, as players saw it in game."
    : data.same === true ? "Forever's objective is Classic's word for word, so the text below is Classic's."
    : data.same === false ? `Forever changed this quest. The objective is Forever's own. ${unknown}`
      : data.text ? "Classic's text, not yet checked against Forever."
        : `New in Forever. ${unknown}`) + fromJournal + fromPlayers
  html += `<p class="note">${note}</p></section><div class="qgrid"><article class="paper">
    <h2>Objectives</h2>${paragraphs(data.objective)}
    ${data.needs.length ? `<ul class="needs">${data.needs.map(([what, count]) => `<li>${esc(what)}<b>${status === 'done' || status === 'skip' ? `${count}/${count}` : `x${count}`}</b></li>`).join('')}</ul>` : ''}`
  if (data.text && data.text.description.length) html += `<h2>Description</h2>${paragraphs(data.text.description)}`
  const rewards = data.rewards
  if (rewards) {
    html += '<h2>Rewards</h2>'
    if (rewards.choose.length) html += `<p>You will be able to choose one of these:</p><ul class="rewards">${rewards.choose.map(rewardSlot).join('')}</ul>`
    if (rewards.items.length) html += `<p>You will receive:</p><ul class="rewards">${rewards.items.map(rewardSlot).join('')}</ul>`
    if (rewards.some && rewards.some.length) html += `<p>Rewards include:</p><ul class="rewards">${rewards.some.map(rewardSlot).join('')}</ul>`
    if (rewards.money) html += `<p>${money(rewards.money)}</p>`
    if (rewards.spell) html += `<p><a href="https://www.wowhead.com/forever/spell=${rewards.spell}" target="_blank" rel="noopener">A spell</a> is cast on you.</p>`
    if (rewards.xp) html += `<p>${number(rewards.xp)} experience</p>`
    for (const [who, value] of rewards.rep) html += `<p>${value > 0 ? '+' : ''}${value} reputation with ${esc(typeof who === 'string' ? who : faction(who))}</p>`
  }
  if (data.text && data.text.progress.length) html += `<details><summary>When you come back</summary>${paragraphs(data.text.progress)}</details>`
  if (data.text && data.text.completion.length) html += `<details><summary>On completion</summary>${paragraphs(data.text.completion)}</details>`
  if (data.note) html += `<h2>Notes</h2><p>${esc(data.note)}</p>`
  html += '</article><aside class="qside">'
  html += questMap(data, quest)
  html += `<dl class="facts">
    ${fact('<span class="pin-key start">!</span> Start', data.pickup ? esc(data.pickup) : placeText(data.start[0], data.start[1], data.start[2], data.start[3], data.start[4]))}
    ${fact('<span class="pin-key end">?</span> End', data.turnin ? esc(data.turnin) : placeText(data.end[0], data.end[1], data.end[2], data.end[3]))}
    ${fact('Level', level > 0 ? `${level}${min ? `, from level ${min}` : ''}` : '')}
    ${fact('Side', sideOf(quest).replace('the ', '').replace(/^b/, 'B'))}
    ${fact('Quest ID', `<a href="https://www.wowhead.com/forever/quest=${id}" target="_blank" rel="noopener">${id}</a>`)}</dl>`
  if (data.chain.length > 1) {
    html += `<h2 class="side-head">Quest chain <span class="muted">${data.chain.length} quests</span></h2><ol class="chain">${data.chain.map((step) => {
      const stepStatus = statusOf(step)
      const here = step === id
      return `<li class="${here ? 'here' : ''} st-${stepStatus || 'none'}"><span class="mark">${stepStatus ? MARKS[stepStatus] || '' : ''}</span>
        ${here ? `<b>${esc(questName(step))}</b>` : questLink(step)}
        <span class="muted">${field(row(step), 'level') > 0 ? field(row(step), 'level') : ''}</span></li>`
    }).join('')}</ol>`
  }
  page.innerHTML = html + '</aside></div>'
  const open = document.getElementById('openmap')
  if (open) {
    const big = document.getElementById('bigmap')
    open.addEventListener('click', () => big.showModal())
    big.addEventListener('click', (event) => { if (event.target === big) big.close() }) // around the map closes it too
  }
  wowheadTooltips()
}

// Wowhead's own tooltips on its links (reward items show their Forever stats on hover), loaded the first
// time a quest page needs them.
function wowheadTooltips() {
  if (window.$WowheadPower) { window.$WowheadPower.refreshLinks(); return }
  if (document.getElementById('wowhead')) return
  window.whTooltips = { colorLinks: false, iconizeLinks: false, renameLinks: false } // our own icons and names
  const script = document.createElement('script')
  script.id = 'wowhead'
  script.src = 'https://wow.zamimg.com/js/tooltips.js'
  document.head.appendChild(script)
}

// ---------------------------------------------------------------- your code and phone link (/me)

const linkKey = (progress) => `lm:link:${progress.name}-${progress.realm}`

// The link saved for this character; one saved before codes carried the surname moves to the full name.
function savedLink(progress) {
  const found = store.get(linkKey(progress))
  if (found) return found
  const before = `lm:link:${String(progress.name).split(' ')[0]}-${progress.realm}`
  const old = before !== linkKey(progress) && store.get(before)
  if (old) { store.set(linkKey(progress), old); store.drop(before) }
  return old || null
}
const SAVE_ERRORS = {
  rate_limited: "That's a lot of saves from here today. Try again tomorrow.",
  rate_limited_cooldown: 'Saved a moment ago. Wait a few seconds, then try again.',
  not_a_progress_code: "The site couldn't read that code. Export it again in game and paste the new one.",
  not_found: 'That link is gone already.',
}

async function drawMe(message) {
  const code = store.get('lm:last')
  let mine = null
  try { mine = code && !(shown && shown.problem) ? decode(code) : null } catch { mine = null }
  const link = mine && savedLink(mine)
  let html = '<div class="form"><h1>My progress</h1>'
  if (shown && shown.problem) html += `<p class="bad">${esc(shown.problem)}</p>`
  if (mine) {
    const when = new Date(mine.time * 1000).toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' })
    html += `<p>Showing <b>${esc(mine.name)}</b>, exported ${esc(when)}. <a href="/">See the rings and badges</a></p>
      <h2 style="margin-top:28px;font-size:17px">On your phone</h2>
      <p class="muted">A private link to this character's progress, with a QR code to scan. Pasting a newer code for
      ${esc(mine.name)} here updates the same link. Anyone with the link can see it.</p>
      <div class="actions"><button class="button" id="save">${link ? 'Update my link' : 'Save and get my link'}</button>
      ${link ? '<button class="button quiet" id="delete">Delete my link</button>' : ''}</div>
      <div class="say" id="saved" role="status"></div>`
  }
  html += `<h2 style="margin-top:28px;font-size:17px">${mine ? 'A newer code' : 'Paste your code'}</h2>
    <ol><li>In game, type <code>/lb export</code> (or open the journal with <code>/lb</code> and press Export to website).</li>
    <li>Copy the code with Ctrl+C and paste it here.</li></ol>
    <textarea id="code" placeholder="LMP1~..." spellcheck="false" autocomplete="off" aria-label="Progress code"></textarea>
    <div class="actions"><button class="button" id="use">Show my progress</button></div>
    <div class="say" role="status">${message || ''}</div></div>`
  page.innerHTML = html
  document.getElementById('use').addEventListener('click', () => usePaste(document.getElementById('code').value))
  if (mine) {
    document.getElementById('save').addEventListener('click', (event) => saveLink(mine, event.currentTarget))
    if (link) {
      document.getElementById('delete').addEventListener('click', (event) => deleteLink(mine, event.currentTarget))
      showLink(link.id)
    }
  }
}

async function usePaste(code) {
  try {
    const progress = decode(code)
    const list = await loadList(progress.version)
    if (!list) throw new Error("That code is from a Lorebound quest list this site hasn't got. Update the addon, then export again.")
    unpack(progress, list)
    store.set('lm:last', progress.code)
    mineCache = null
    go('/')
  } catch (error) {
    drawMe(`<span class="bad">${esc(error.message)}</span>`)
  }
}

function showLink(id) {
  const out = document.getElementById('saved')
  const url = `${location.origin}/p/${id}`
  let qr = ''
  if (window.qrcode) {
    const code = window.qrcode(0, 'M')
    code.addData(url)
    code.make()
    qr = `<div class="qr">${code.createSvgTag(4, 0)}</div>`
  }
  out.innerHTML = `<div class="link">${qr}<div><a class="url" href="/p/${esc(id)}">${esc(url)}</a>
    <p class="muted">Scan it or bookmark it on your phone.</p></div></div>`
}

async function callProgress(method, body) {
  const res = await fetch('/api/progress', { method, headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) })
  const answer = await res.json().catch(() => ({}))
  if (!res.ok) throw new Error(SAVE_ERRORS[answer.error] || `The site said no (${res.status}). Try again in a minute.`)
  return answer
}

async function saveLink(progress, button) {
  const key = linkKey(progress)
  const link = savedLink(progress) || {}
  const out = document.getElementById('saved')
  button.disabled = true
  out.textContent = 'Saving...'
  try {
    const answer = await callProgress('POST', { code: progress.code, id: link.id, token: link.token })
    store.set(key, { id: answer.id, token: answer.token || link.token })
    drawMe()
  } catch (error) {
    out.innerHTML = `<span class="bad">${esc(error.message)}</span>`
    button.disabled = false
  }
}

async function deleteLink(progress, button) {
  const key = linkKey(progress)
  const link = store.get(key)
  button.disabled = true
  try {
    await callProgress('DELETE', { id: link.id, token: link.token })
  } catch (error) {
    if (!/gone already/.test(error.message)) {
      document.getElementById('saved').innerHTML = `<span class="bad">${esc(error.message)}</span>`
      button.disabled = false
      return
    }
  }
  store.drop(key)
  drawMe('<span class="ok">Deleted. The link no longer works.</span>')
}

// ---------------------------------------------------------------- routing

let mineCache = null      // your own code (lm:last): { progress, list } or { problem }, read once
const linkCache = new Map() // saved links read this visit, by id

async function mine() {
  if (mineCache) return mineCache
  const code = store.get('lm:last')
  if (!code) return null
  let progress
  try { progress = decode(code) } catch { store.drop('lm:last'); return null } // not a code at all
  const list = await loadList(progress.version) // offline: this throws, and the code stays saved
  if (!list) {
    mineCache = { problem: "Your saved code is from a quest list this site no longer has. Export again in game and paste the new code under My progress." }
    return mineCache
  }
  try { mineCache = { progress: unpack(progress, list), list } } catch { store.drop('lm:last'); return null }
  return mineCache
}

async function linked(id) {
  if (linkCache.has(id)) return linkCache.get(id)
  const res = await fetch(`/api/progress?id=${encodeURIComponent(id)}`)
  const body = res.ok ? await res.json().catch(() => null) : null
  if (!body) return null
  const progress = decode(body.code)
  const list = await loadList(progress.version)
  if (!list) throw new Error("This link's progress is from a quest list the site no longer has. Export again in game and update the link.")
  const source = { progress: unpack(progress, list), list }
  linkCache.set(id, source)
  return source
}

let viewKey = null

async function use(key, source, base) {
  if (viewKey === key && shown) return
  const list = source ? source.list : await loadList(null)
  if (!list) throw new Error("Couldn't load the quest list. Check your connection and reload the page.")
  shown = makeView(list, source ? source.progress : null, base)
  viewKey = key
  drawSide()
}

function notFound(text) {
  shown = null
  viewKey = null
  sidePane.innerHTML = ''
  page.innerHTML = `<div class="form"><h1>Not found</h1><p class="muted">${text}</p></div>`
}

// Draws the page the address names. A newer navigation that starts meanwhile wins: this one stops at its
// next step (returns false), so a slow link can't paint over the page you moved on to.
let navSeq = 0

async function route() {
  const nav = ++navSeq
  const stale = () => nav !== navSeq
  const path = location.pathname.replace(/\/+$/, '') || '/'
  delete page.dataset.search
  document.querySelectorAll('[data-nav]').forEach((navLink) => navLink.classList.toggle('on', navLink.dataset.nav === (path === '/me' ? 'me' : 'quests')))
  if (path.startsWith('/p/') || path === '/p') {
    const link = path.match(/^\/p\/([A-Za-z0-9]{10})(?:\/(zone|quest)\/(\d+))?$/)
    if (!link) { document.body.classList.remove('at-zone'); notFound("That isn't a Lorebound link."); return true }
    const source = await linked(link[1])
    if (stale()) return false
    if (!source) { document.body.classList.remove('at-zone'); notFound("That link doesn't lead to any saved progress. It may have been deleted."); return true }
    await use('p:' + link[1] + ':' + source.progress.time, source, `/p/${link[1]}`)
    if (stale()) return false
    shown.problem = null
    return drawPage(path, link[2], link[3])
  }
  const own = await mine()
  if (stale()) return false
  const progress = own && own.progress ? own : null
  await use('mine:' + (progress ? progress.progress.code.length + ':' + progress.progress.time : 'none:' + side), progress, '')
  if (stale()) return false
  shown.problem = own && own.problem
  const [, kind, id] = path.match(/^\/(zone|quest)\/(\d+)$/) || []
  return drawPage(path, kind, id)
}

// kind: zone or quest (id its number), else the overview or /me.
function drawPage(path, kind, id) {
  const number = id ? +id : 0
  const quest = kind === 'quest' && row(number) ? number : 0
  const zone = kind === 'zone' && number <= shown.zones.length ? number : quest ? field(row(quest), 'zone') : 0
  document.body.classList.toggle('at-zone', zone > 0)
  markSide(zone)
  if (path === '/me') drawMe()
  else if (quest) drawQuest(quest)
  else if (zone) drawZone(zone)
  else drawOverview()
  return true
}

function go(path) {
  history.pushState(null, '', path)
  show()
}

function show(toTop = true) {
  route().then((drawn) => {
    if (drawn && toTop) window.scrollTo(0, 0)
    wowheadTooltips()
  }).catch((error) => {
    const offline = /Failed to fetch|NetworkError|Load failed/.test(error.message)
    const text = offline ? "Couldn't reach the site. Check your connection, then reload the page." : error.message
    page.innerHTML = `<div class="form"><p class="bad">${esc(text)}</p></div>`
  })
}

document.addEventListener('click', (event) => {
  const link = event.target.closest('a')
  if (!link || event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return
  if (link.target || link.origin !== location.origin || /^\/(report|api|art|data)/.test(link.pathname)) return
  event.preventDefault()
  go(link.pathname)
})
window.addEventListener('popstate', () => show())

filter = store.get('lm:filter') in FILTERS ? store.get('lm:filter') : 'todo'
showLocked = store.get('lm:locked') === true
side = ['alliance', 'horde', 'both'].includes(store.get('lm:side')) ? store.get('lm:side') : 'both'
getJson('/art/icons.json').catch(() => null).then((found) => { icons = found || {} }).finally(() => show())
