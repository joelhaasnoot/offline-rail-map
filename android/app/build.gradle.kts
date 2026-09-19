import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
}

// Release signing comes from android/keystore.properties (never committed) or RELEASE_* environment
// variables, which scripts/package-android-release.sh can fill from 1Password. Without either,
// release builds come out unsigned.
val keystoreProperties = Properties().apply {
    val file = rootProject.file("keystore.properties")
    if (file.exists()) {
        file.inputStream().use { load(it) }
    }
}

fun signingValue(key: String, env: String): String? = keystoreProperties.getProperty(key) ?: System.getenv(env)

android {
    namespace = "com.offlinerailmap.android"
    compileSdk = 37

    defaultConfig {
        applicationId = "com.offlinerailmap.android"
        minSdk = 26
        targetSdk = 36
        versionCode = 2
        versionName = "0.1.1"

        // Where the app looks for the list of downloadable country packs.
        // Override with -PmanifestUrl=... when building.
        val manifestUrl = (project.findProperty("manifestUrl") as String?)
            ?: "https://data.offlinerailmap.com/manifest.json"
        buildConfigField("String", "MANIFEST_URL", "\"$manifestUrl\"")
    }

    val releaseStoreFile = signingValue("storeFile", "RELEASE_STORE_FILE")
    signingConfigs {
        if (releaseStoreFile != null) {
            create("release") {
                storeFile = rootProject.file(releaseStoreFile)
                storePassword = signingValue("storePassword", "RELEASE_STORE_PASSWORD")
                keyAlias = signingValue("keyAlias", "RELEASE_KEY_ALIAS")
                keyPassword = signingValue("keyPassword", "RELEASE_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            signingConfig = signingConfigs.findByName("release")
            buildConfigField("boolean", "FRAME_STATS", "false")
        }
        debug {
            buildConfigField("boolean", "FRAME_STATS", "true")
        }
        // Release code with frame timing logs, signed with the debug key so it installs over a
        // debug build and keeps its packs. For measuring map performance on real phones.
        create("benchmark") {
            initWith(getByName("release"))
            signingConfig = signingConfigs.getByName("debug")
            matchingFallbacks += "release"
            buildConfigField("boolean", "FRAME_STATS", "true")
        }
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    packaging {
        resources.excludes += setOf("META-INF/AL2.0", "META-INF/LGPL2.1")
    }

    androidResources {
        // Lets the app read the bundled world map's size without decompressing it.
        noCompress += "pmtiles"
    }

    testOptions {
        unitTests.isReturnDefaultValues = true
    }
}

dependencies {
    implementation(platform("androidx.compose:compose-bom:2026.09.00"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-core")
    implementation("androidx.activity:activity-compose:1.13.0")
    debugImplementation("androidx.compose.ui:ui-tooling")

    implementation("org.maplibre.gl:android-sdk-opengl:13.6.1")
    implementation("com.squareup.okhttp3:okhttp:5.5.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.11.0")

    testImplementation("junit:junit:4.13.2")
    // Real org.json for JVM tests; the Android stub throws for every method.
    testImplementation("org.json:json:20240303")
}
