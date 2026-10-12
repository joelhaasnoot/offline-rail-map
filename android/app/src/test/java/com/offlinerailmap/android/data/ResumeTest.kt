// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Joel Haasnoot

package com.offlinerailmap.android.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ResumeTest {
    @Test
    fun continuesWhenTheServerSendsTheRequestedRange() {
        assertEquals(1000L, Resume.writeOffset(206, "bytes 1000-53616/53617", 1000))
    }

    @Test
    fun startsOverWhenTheServerSendsTheWholeFile() {
        // A changed file fails If-Range, so the server answers with all of it.
        assertEquals(0L, Resume.writeOffset(200, null, 1000))
        assertEquals(0L, Resume.writeOffset(200, null, 0))
    }

    @Test
    fun dropsTheFileWhenTheRangeDoesNotFit() {
        assertNull(Resume.writeOffset(206, "bytes 0-99/53617", 1000))
        assertNull(Resume.writeOffset(206, null, 1000))
        assertNull(Resume.writeOffset(206, "items 1000-2000/3000", 1000))
        assertNull(Resume.writeOffset(404, null, 1000))
    }

    @Test
    fun prefersAStrongEtag() {
        assertEquals("\"6ac98e2a-d171\"", Resume.validator("\"6ac98e2a-d171\"", "Sat, 10 Oct 2026 01:00:26 GMT"))
        // If-Range only accepts strong validators.
        assertEquals("Sat, 10 Oct 2026 01:00:26 GMT", Resume.validator("W/\"6ac98e2a\"", "Sat, 10 Oct 2026 01:00:26 GMT"))
        assertNull(Resume.validator("W/\"6ac98e2a\"", null))
        assertNull(Resume.validator(null, null))
    }

    @Test
    fun retriesServerTrouble() {
        assertTrue(Resume.isRetryable(503))
        assertTrue(Resume.isRetryable(429))
        assertFalse(Resume.isRetryable(404))
        assertFalse(Resume.isRetryable(403))
    }
}
