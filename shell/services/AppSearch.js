function entryName(entry) {
  return String((entry && entry.name) || (entry && entry.id) || "")
}

function entrySubtext(entry) {
  return String((entry && entry.genericName) || "")
}

function entrySortKey(entry) {
  return entryName(entry).toLowerCase()
}

function keywordText(entry) {
  try {
    if (entry && entry.keywords && typeof entry.keywords.join === "function") return entry.keywords.join(" ")
  } catch (e) {
  }
  return ""
}

function entrySearchText(entry) {
  if (!entry) return ""
  return [entry.name, entry.genericName, entry.comment, keywordText(entry), entry.id].join(" ").toLowerCase()
}

function wordText(value) {
  return String(value || "")
    .replace(/([a-z0-9])([A-Z])/g, "$1 $2")
    .replace(/[._:/\\-]+/g, " ")
    .toLowerCase()
}

function words(value) {
  var values = wordText(value).split(/[^a-z0-9]+/)
  var result = []
  for (var i = 0; i < values.length; i++) {
    if (values[i]) result.push(values[i])
  }
  return result
}

function entryAcronym(entry) {
  var values = words([entry && entry.name, entry && entry.genericName, keywordText(entry), entry && entry.id].join(" "))
  var result = ""
  for (var i = 0; i < values.length; i++) result += values[i].charAt(0)
  return result
}

function termMatches(entry, term) {
  if (!term) return true

  var name = entryName(entry).toLowerCase()
  var id = String((entry && entry.id) || "").toLowerCase()
  var haystack = entrySearchText(entry)

  if (name.indexOf(term) >= 0) return true
  if (id.indexOf(term) >= 0) return true
  if (haystack.indexOf(term) >= 0) return true

  return term.length <= 5 && entryAcronym(entry).indexOf(term) >= 0
}

function allTermsMatch(entry, query) {
  var terms = String(query || "").toLowerCase().trim().split(/\s+/)
  for (var i = 0; i < terms.length; i++) {
    if (terms[i] && !termMatches(entry, terms[i])) return false
  }
  return true
}

function fuzzyScore(entry, query) {
  var q = String(query || "").trim().toLowerCase()
  if (!q) return 0
  if (!allTermsMatch(entry, q)) return -1

  var name = entryName(entry).toLowerCase()
  var id = String((entry && entry.id) || "").toLowerCase()
  var haystack = entrySearchText(entry)
  var directName = name.indexOf(q)
  var directId = id.indexOf(q)
  if (directName === 0) return 10000 - name.length
  if (directId === 0) return 9500 - id.length
  if (directName > 0) return 8000 - directName * 10 - name.length
  if (directId > 0) return 7600 - directId * 10 - id.length

  var hayIndex = haystack.indexOf(q)
  if (hayIndex >= 0) return 6000 - hayIndex

  var acronym = entryAcronym(entry)
  var acronymIndex = acronym.indexOf(q)
  if (acronymIndex === 0) return 5000 - acronym.length
  if (acronymIndex > 0) return 4600 - acronymIndex * 10 - acronym.length

  return 4000 - name.length
}

// These clients use Categories=Game too, but belong with the tools that open
// and manage games. Match desktop IDs rather than translated display names.
var gameClients = [
  "steam", "steam-native", "com.valvesoftware.steam",
  "heroic", "com.heroicgameslauncher.hgl",
  "lutris", "net.lutris.lutris", "battlenet",
  "retroarch", "org.libretro.retroarch",
  "moonlight", "com.moonlight_stream.moonlight"
]

function entryCategory(entry) {
  var id = String((entry && entry.id) || "").replace(/\.desktop$/, "").toLowerCase()
  if (gameClients.indexOf(id) >= 0) return "apps"
  var categories = (entry && entry.categories) || []
  for (var i = 0; i < categories.length; i++) {
    if (categories[i] === "Game") return "games"
  }
  return "apps"
}

function gameIdentity(entry) {
  var command = String((entry && entry.execString) || "") || ((entry && entry.command) || []).join(" ")
  command = command.replace(/%%/g, "%")
  var steam = command.match(/\bsteam:\/\/(?:rungameid|run)\/(\d+)(?:[\/\s"']|$)/i) || command.match(/(?:^|\s)-applaunch\s+(\d+)(?:\s|$)/)
  if (steam) return "steam:" + steam[1]
  var heroic = command.match(/\bheroic:\/\/launch(?:\?([^\s"']+)|\/([^\/\s"']+)\/([^\s"']+))/i)
  if (!heroic) return ""
  try {
    if (heroic[2]) return "heroic:" + heroic[2] + ":" + decodeURIComponent(heroic[3])
    var query = ({})
    heroic[1].split("&").forEach(function(pair) {
      var equal = pair.indexOf("=")
      if (equal >= 0) query[pair.slice(0, equal)] = decodeURIComponent(pair.slice(equal + 1).replace(/\+/g, " "))
    })
    return query.runner && query.appName ? "heroic:" + query.runner + ":" + query.appName : ""
  } catch (e) {
    return ""
  }
}

// Imported IDs remain resolvable after a client adds its own shortcut. Prefer
// the client entry in lists and resolve old dock pins to the same visible ID.
function clientGameIds(values) {
  var clients = ({})
  for (var i = 0; i < values.length; i++) {
    var entry = values[i]
    if (!entry) continue
    var id = String(entry.id || "")
    if (id.indexOf("omarchy-game-") === 0) continue
    var key = gameIdentity(entry)
    if (key && (!clients[key] || id < clients[key])) clients[key] = id
  }
  return clients
}

function gameAliases(values) {
  var clients = clientGameIds(values)
  var aliases = ({})
  for (var i = 0; i < values.length; i++) {
    var entry = values[i]
    var id = String((entry && entry.id) || "")
    if (id.indexOf("omarchy-game-") !== 0) continue
    var clientId = clients[gameIdentity(entry)]
    if (clientId) aliases[id] = clientId
  }
  return aliases
}

function sortedEntries(values, query, hiddenCallback) {
  var q = String(query || "").trim()
  var rows = []
  var aliases = gameAliases(values)

  for (var i = 0; i < values.length; i++) {
    var entry = values[i]
    if (!entry || entry.noDisplay) continue
    if (aliases[String(entry.id || "")]) continue
    if (hiddenCallback && hiddenCallback(entry)) continue
    var name = entryName(entry)
    if (!name) continue
    var score = fuzzyScore(entry, q)
    if (score < 0) continue
    rows.push({ entry: entry, category: entryCategory(entry), score: score, key: entrySortKey(entry), name: name.toLowerCase() })
  }

  rows.sort(function(a, b) {
    if (q && a.score !== b.score) return b.score - a.score
    if (a.key < b.key) return -1
    if (a.key > b.key) return 1
    if (a.name < b.name) return -1
    if (a.name > b.name) return 1
    return 0
  })

  return rows
}

if (typeof module !== "undefined") {
  module.exports = {
    entryName: entryName,
    entrySubtext: entrySubtext,
    entrySortKey: entrySortKey,
    entrySearchText: entrySearchText,
    entryAcronym: entryAcronym,
    fuzzyScore: fuzzyScore,
    entryCategory: entryCategory,
    gameIdentity: gameIdentity,
    clientGameIds: clientGameIds,
    gameAliases: gameAliases,
    sortedEntries: sortedEntries
  }
}
