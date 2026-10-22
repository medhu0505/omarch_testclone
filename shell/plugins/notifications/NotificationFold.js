// Collapse repeated chat, mail, and CI toasts into one line.
// A single notification stays as it arrived.

function notificationText(row) {
  var e = row || {}
  return String(e.app || "") + " " + String(e.summary || "") + " " + String(e.body || "")
}

function parseRules(text) {
  if (!text) return null
  try {
    var data = JSON.parse(text)
  } catch (error) {
    return null
  }
  if (!data || typeof data !== "object") return null
  return data
}

function wordHit(text, word) {
  var escaped = String(word || "").replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
  if (!escaped) return false
  return new RegExp("\\b" + escaped + "\\b", "i").test(text)
}

function rulesOf(rules) {
  return rules || { disabled: [], groups: [] }
}

function isDisabled(rules, id) {
  var list = rulesOf(rules).disabled || []
  return list.indexOf(id) >= 0
}

function extraKind(text, rules) {
  var groups = rulesOf(rules).groups || []
  var i
  for (i = 0; i < groups.length; i++) {
    var group = groups[i] || {}
    var words = group.words || []
    var w
    for (w = 0; w < words.length; w++) {
      if (wordHit(text, words[w])) return String(group.id || "")
    }
  }
  return ""
}

function classifyNotification(text, rules) {
  var t = String(text || "").toLowerCase()
  var extra = extraKind(t, rules)
  if (extra) return extra
  if (!isDisabled(rules, "ci") && (/\b(failed|failure|build|pipeline|workflow)\b/.test(t) || t.indexOf("github actions") >= 0 || /\bci\b/.test(t))) return "ci"
  if (!isDisabled(rules, "mail") && /\b(mail|email|inbox|gmail|thunderbird)\b/.test(t)) return "mail"
  if (!isDisabled(rules, "chat") && (/\b(slack|discord|signal|matrix|telegram)\b/.test(t) || /#[a-z0-9][a-z0-9_-]*/.test(t))) return "chat"
  return "other"
}

function channelNames(text) {
  var found = []
  var re = /#([a-z0-9][a-z0-9_-]*)/g
  var match
  var t = String(text || "").toLowerCase()
  while ((match = re.exec(t))) {
    if (found.indexOf(match[1]) < 0) found.push(match[1])
  }
  return found
}

function groupLabel(rules, id) {
  var groups = rulesOf(rules).groups || []
  var i
  for (i = 0; i < groups.length; i++) {
    if (String((groups[i] || {}).id || "") === id) return String(groups[i].label || id)
  }
  return id
}

function digestLine(rows, rules) {
  var groups = { ci: [], mail: [], chat: [] }
  var extra = {}
  var i
  for (i = 0; i < rows.length; i++) {
    var kind = classifyNotification(notificationText(rows[i]), rules)
    if (groups[kind]) groups[kind].push(rows[i])
    else if (kind && kind !== "other") {
      if (!extra[kind]) extra[kind] = []
      extra[kind].push(rows[i])
    }
  }

  var parts = []
  if (groups.ci.length >= 2) {
    var failed = false
    for (i = 0; i < groups.ci.length; i++) {
      if (/fail/i.test(notificationText(groups.ci[i]))) failed = true
    }
    parts.push(String(groups.ci.length) + (failed ? " failed builds" : " builds"))
  }
  if (groups.mail.length >= 2) parts.push(String(groups.mail.length) + " emails")
  if (groups.chat.length >= 2) {
    var names = []
    for (i = 0; i < groups.chat.length; i++) {
      var channels = channelNames(notificationText(groups.chat[i]))
      var c
      for (c = 0; c < channels.length; c++) {
        if (names.indexOf(channels[c]) < 0) names.push(channels[c])
      }
    }
    var chat = String(groups.chat.length) + " messages"
    if (names.length > 0) chat += " from #" + names.join(", #")
    parts.push(chat)
  }
  var defined = rulesOf(rules).groups || []
  for (i = 0; i < defined.length; i++) {
    var id = String((defined[i] || {}).id || "")
    if (!id || !extra[id] || extra[id].length < 2) continue
    parts.push(String(extra[id].length) + " " + groupLabel(rules, id))
  }
  return parts.join(", ")
}

function rowTime(row) {
  var e = row || {}
  if (typeof e.ts === "number") return e.ts
  return e.timestamp || 0
}

function copyRow(row) {
  var e = row || {}
  var out = {}
  var k
  for (k in e) {
    if (Object.prototype.hasOwnProperty.call(e, k)) out[k] = e[k]
  }
  return out
}

function fold(rows, rules) {
  var list = Array.isArray(rows) ? rows : []
  var line = digestLine(list, rules)
  if (!line) return list.map(copyRow)

  var counts = {}
  var i
  for (i = 0; i < list.length; i++) {
    var kind = classifyNotification(notificationText(list[i]), rules)
    if (!kind || kind === "other") continue
    counts[kind] = (counts[kind] || 0) + 1
  }

  var newest = null
  var kept = []
  for (i = 0; i < list.length; i++) {
    var rowKind = classifyNotification(notificationText(list[i]), rules)
    if (rowKind && rowKind !== "other" && counts[rowKind] >= 2) {
      if (!newest || rowTime(list[i]) >= rowTime(newest)) newest = list[i]
      continue
    }
    kept.push(copyRow(list[i]))
  }

  var digest = copyRow(newest || {})
  digest.key = "ml-fold"
  digest.app = "omarchy"
  digest.summary = line
  digest.body = ""
  digest.bodyLine = ""
  digest.glyph = "󰂛"
  kept.unshift(digest)
  return kept
}

if (typeof module !== "undefined") {
  module.exports = {
    classifyNotification: classifyNotification,
    digestLine: digestLine,
    fold: fold,
    parseRules: parseRules
  }
}
