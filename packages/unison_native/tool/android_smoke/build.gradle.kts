plugins { id("com.android.test") }
android {
    namespace = "io.github.ichaivalx.unison.nativebridge.test"
    compileSdk = 36
    targetProjectPath = ":app"
    defaultConfig {
        minSdk = 33
        targetSdk = 36
        testInstrumentationRunner = "io.github.ichaivalx.unison.nativebridge.NativeSmokeInstrumentation"
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}
