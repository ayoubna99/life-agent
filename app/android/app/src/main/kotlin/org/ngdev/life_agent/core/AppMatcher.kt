package org.ngdev.life_agent.core

data class InstalledApp(val label: String, val pkg: String)

/** The agent says "Instagram"; the phone knows package names. Matches by what the user sees under the icon. */
object AppMatcher {
    private fun norm(s: String) = s.lowercase().filter { it.isLetterOrDigit() }

    fun resolve(name: String, apps: List<InstalledApp>): InstalledApp? {
        val wanted = name.trim()
        if (wanted.isEmpty()) return null
        apps.firstOrNull { it.label.equals(wanted, ignoreCase = true) }?.let { return it }
        val n = norm(wanted)
        if (n.isEmpty()) return null
        apps.filter { norm(it.label) == n }.let { if (it.size == 1) return it[0] }
        // "Insta" or "YouTube Music" vs "YouTube": accept only a single clear partial match.
        val partial = apps.filter { val l = norm(it.label); l.contains(n) || (l.length >= 4 && n.contains(l)) }
        return partial.singleOrNull()
    }
}
