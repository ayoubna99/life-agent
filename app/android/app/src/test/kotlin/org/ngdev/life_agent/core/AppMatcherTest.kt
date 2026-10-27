package org.ngdev.life_agent.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class AppMatcherTest {
    private val apps = listOf(
        InstalledApp("Instagram", "com.instagram.android"),
        InstalledApp("TikTok", "com.zhiliaoapp.musically"),
        InstalledApp("YouTube", "com.google.android.youtube"),
        InstalledApp("YouTube Music", "com.google.android.apps.youtube.music"),
        InstalledApp("X", "com.twitter.android"),
    )

    @Test fun exactNameIgnoringCase() {
        assertEquals("com.instagram.android", AppMatcher.resolve("instagram", apps)?.pkg)
        assertEquals("com.zhiliaoapp.musically", AppMatcher.resolve("  TIKTOK ", apps)?.pkg)
    }

    @Test fun spacesAndPunctuationDoNotMatter() {
        assertEquals("com.zhiliaoapp.musically", AppMatcher.resolve("Tik Tok", apps)?.pkg)
        assertEquals("com.google.android.apps.youtube.music", AppMatcher.resolve("youtube-music", apps)?.pkg)
    }

    @Test fun anExactMatchBeatsALongerName() {
        assertEquals("com.google.android.youtube", AppMatcher.resolve("YouTube", apps)?.pkg)
    }

    @Test fun aClearPartialNameWorksButAnAmbiguousOneDoesNot() {
        assertEquals("com.instagram.android", AppMatcher.resolve("Insta", apps)?.pkg)
        assertNull(AppMatcher.resolve("You", apps)) // YouTube and YouTube Music
    }

    @Test fun unknownOrEmptyIsNull() {
        assertNull(AppMatcher.resolve("Snapchat", apps))
        assertNull(AppMatcher.resolve("", apps))
        assertNull(AppMatcher.resolve("!!!", apps))
    }

    @Test fun aShortLabelIsNotMatchedInsideALongName() {
        assertNull(AppMatcher.resolve("Twitter X Premium", apps)) // "x" is too short to match inside a longer name
    }
}
