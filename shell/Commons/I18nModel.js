function parseLocale(lang) {
  var raw = String(lang || "").trim()
  if (!raw) return "en"
  // Handles values like tr_TR.UTF-8, tr-TR, tr_TR, tr
  var code = raw.split(".")[0].split("@")[0].replace("_", "-").toLowerCase()
  if (code.indexOf("tr") === 0) return "tr"
  return "en"
}

function resolveTranslation(catalog, key) {
  if (!catalog || typeof catalog !== "object" || !key) return null
  var parts = String(key).split(".")
  var current = catalog
  for (var i = 0; i < parts.length; i++) {
    if (current && typeof current === "object" && parts[i] in current) {
      current = current[parts[i]]
    } else {
      return null
    }
  }
  return typeof current === "string" ? current : null
}

function translate(catalogs, locale, key, fallback) {
  var defaultText = fallback !== undefined ? fallback : key
  var loc = locale || "en"
  var cat = (catalogs && catalogs[loc]) ? catalogs[loc] : null
  var text = resolveTranslation(cat, key)
  if (text !== null) return text

  // Fallback to English if current locale is not English
  if (loc !== "en" && catalogs && catalogs["en"]) {
    var enText = resolveTranslation(catalogs["en"], key)
    if (enText !== null) return enText
  }

  return defaultText
}

if (typeof module !== "undefined") {
  module.exports = {
    parseLocale: parseLocale,
    resolveTranslation: resolveTranslation,
    translate: translate
  }
}
