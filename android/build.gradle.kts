// Fails fast with a clear message instead of the cryptic AGP9 namespace
// error if android/patch_agora_aar.sh hasn't been run yet on this
// checkout — see that script's own header comment for the full story.
if (!File(rootDir, "local_repo/io/agora/rtc/agora-special-full/4.5.3.70/agora-special-full-4.5.3.70.aar").exists()) {
    throw GradleException(
        "Missing android/local_repo/ — run android/patch_agora_aar.sh once " +
        "before building (patches a namespace conflict in Agora's own " +
        "native AARs that otherwise breaks the build under AGP9)."
    )
}

allprojects {
    repositories {
        // Local override for io.agora.rtc:agora-special-full:4.5.3.70 —
        // the upstream AAR from Maven Central declares the same
        // AndroidManifest.xml package="io.agora.rtc" as
        // io.agora.rtc:iris-rtc (also pulled in by agora_rtc_engine),
        // which AGP 9's namespace-uniqueness check rejects outright
        // ("Namespace 'io.agora.rtc' is used in multiple modules").
        // agora-special-full has zero resources (confirmed: no res/
        // folder, empty R.txt) — a manifest-only package rename to
        // io.agora.rtc.specialfull is safe (no R-class references to
        // break) and doesn't touch the actual compiled classes/JNI.
        // Listed FIRST so Gradle resolves this exact coordinate here
        // before ever reaching Maven Central for it.
        maven {
            url = uri("$rootDir/local_repo")
        }
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// Sets this directly on rootProject.ext (this file IS the root project's
// build script, so a bare top-level assignment here is exactly that) —
// NOT inside subprojects{}, which sets extra on each individual subproject
// instead. agora_rtc_engine's own build.gradle checks specifically
// rootProject.ext.has(prop) via its safeExtGet() helper, so a
// per-subproject value never reaches it — confirmed by tracing that
// exact helper's source after the subprojects{} version silently failed
// to fix anything.
extra["compileSdkVersion"] = 36

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
