plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
}

android {
    namespace = "dev.myremote.app"
    compileSdk = 36

    defaultConfig {
        applicationId = "dev.myremote.app"
        minSdk = 28
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        compose = true
    }

    androidResources {
        localeFilters += listOf("en", "uk")
    }

    lint {
        abortOnError = true
        warningsAsErrors = false
    }

    testOptions {
        unitTests.all { test ->
            // Shared contract fixtures live outside android/ and are owned by the protocol,
            // not by this module. Declared as an input so edits there rerun the tests.
            val fixtures = rootProject.layout.projectDirectory.dir("../protocol/fixtures")
            test.inputs.dir(fixtures).withPropertyName("protocolFixtures")
                .withPathSensitivity(PathSensitivity.RELATIVE)
            test.systemProperty("myremote.fixturesDir", fixtures.asFile.path)
            // For the test that keeps the core package free of Android imports.
            test.systemProperty(
                "myremote.coreSourceDir",
                layout.projectDirectory.dir("src/main/kotlin/dev/myremote/app/core").asFile.path,
            )

            // LiveAgentE2ETest is driven by this variable. It is passed to the test JVM explicitly
            // and registered as an input, so changing or unsetting it reruns the tests. While it
            // is set the task is never up to date and never cached: a test against a live agent
            // has to really run every time, even with an unchanged URI.
            val e2eUri = providers.environmentVariable("MYREMOTE_E2E_URI")
            test.inputs.property("myremoteE2eUri", e2eUri.orElse(""))
            if (e2eUri.isPresent) test.environment("MYREMOTE_E2E_URI", e2eUri.get())
            test.outputs.upToDateWhen { !e2eUri.isPresent }
            test.outputs.cacheIf { !e2eUri.isPresent }

            test.testLogging {
                events("failed", "skipped")
                showStandardStreams = false
                exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL
            }
        }
    }
}

dependencies {
    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.foundation)
    implementation(libs.compose.material3)
    implementation(libs.compose.ui.tooling.preview)
    debugImplementation(libs.compose.ui.tooling)

    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.datastore.preferences)

    implementation(libs.kotlinx.coroutines.core)
    implementation(libs.kotlinx.coroutines.android)
    implementation(libs.kotlinx.serialization.json)
    implementation(libs.okhttp)
    implementation(libs.play.services.code.scanner)

    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)
    testImplementation(libs.okhttp.mockwebserver)
    testImplementation(libs.okhttp.tls)
}
