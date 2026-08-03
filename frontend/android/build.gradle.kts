import com.android.build.api.dsl.LibraryExtension

// Banuba SDK version required by the banuba_sdk plugin (see its integration guide).
extra["bnb_sdk_version"] = "1.18.+"

allprojects {
    repositories {
        google()
        mavenCentral()
        maven { url = uri("https://maven.img.ly/maven") }
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
    if (name == "video_thumbnail" || name == "banuba_sdk") {
        afterEvaluate {
            extensions.configure<LibraryExtension> {
                compileSdk = 36
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
