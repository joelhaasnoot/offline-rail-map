// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Joel Haasnoot

package app.offlinerailwaymap.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PackDirsTest {
    private data class Copy(val id: String, val version: Int, val folder: String)

    private fun choose(vararg copies: Copy) = PackDirs.choose(copies.toList(), { it.id }, { it.version }, { it.folder })

    @Test
    fun stagingFoldersBecomeInstalledFolders() {
        val staging = PackDirs.stagingName("netherlands", 1789400000000)
        assertEquals("netherlands@1789400000000.download", staging)
        assertTrue(PackDirs.isStaging(staging))
        assertEquals("netherlands@1789400000000", PackDirs.installedName(staging))
        assertFalse(PackDirs.isStaging(PackDirs.installedName(staging)))
    }

    @Test
    fun foldersBelongToTheirPackOnly() {
        assertTrue(PackDirs.belongsTo("netherlands", "netherlands"))
        assertTrue(PackDirs.belongsTo("netherlands@12", "netherlands"))
        assertTrue(PackDirs.belongsTo("netherlands@12.download", "netherlands"))
        assertFalse(PackDirs.belongsTo("netherlands-antilles@12", "netherlands"))
        assertFalse(PackDirs.belongsTo("ireland-and-northern-ireland", "ireland"))
    }

    @Test
    fun highestVersionWins() {
        val old = Copy("belgium", 1, "belgium")
        val new = Copy("belgium", 3, "belgium@200")
        val (chosen, superseded) = choose(old, new)
        assertEquals(listOf(new), chosen)
        assertEquals(listOf(old), superseded)
    }

    @Test
    fun newestFolderWinsForTheSameVersion() {
        val first = Copy("spain", 3, "spain@100")
        val second = Copy("spain", 3, "spain@200")
        val legacy = Copy("spain", 3, "spain")
        val (chosen, superseded) = choose(first, legacy, second)
        assertEquals(listOf(second), chosen)
        assertEquals(setOf(first, legacy), superseded.toSet())
    }

    @Test
    fun packsAreChosenIndependently() {
        val nl = Copy("netherlands", 1, "netherlands")
        val be = Copy("belgium", 2, "belgium@5")
        val (chosen, superseded) = choose(nl, be)
        assertEquals(setOf(nl, be), chosen.toSet())
        assertTrue(superseded.isEmpty())
    }
}
