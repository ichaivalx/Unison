plugins { id("com.android.library") }
android {
    namespace = "io.github.ichaivalx.unison.capture"
    compileSdk = 36
    defaultConfig { minSdk = 33 }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}
