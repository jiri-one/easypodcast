import com.android.build.api.dsl.LibraryExtension
import com.android.build.api.variant.LibraryAndroidComponentsExtension
import org.gradle.process.ExecOperations

plugins {
    id("com.android.application") apply false
}

abstract class PatchAudioServiceSources @Inject constructor(
    private val fileSystem: FileSystemOperations,
    private val commands: ExecOperations,
) : DefaultTask() {
    @get:InputDirectory
    @get:PathSensitive(PathSensitivity.RELATIVE)
    abstract val originalSources: DirectoryProperty

    @get:InputFile
    @get:PathSensitive(PathSensitivity.RELATIVE)
    abstract val sourcePatch: RegularFileProperty

    @get:OutputDirectory
    abstract val generatedSources: DirectoryProperty

    @TaskAction
    fun patch() {
        fileSystem.sync {
            from(originalSources)
            into(generatedSources)
        }
        commands.exec {
            workingDir(generatedSources.get().asFile)
            commandLine("patch", "--batch", "--forward", "--fuzz=0", "-p1", "-i", sourcePatch.get().asFile)
        }
    }
}

allprojects {
    repositories {
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

project(":audio_service") {
    val upstream = layout.projectDirectory.dir("src/main/java")
    val patch = rootProject.layout.projectDirectory.file("audio_service.patch")
    pluginManager.withPlugin("com.android.library") {
        // The generated sources keep the shared Flutter package cache untouched.
        extensions.configure<LibraryExtension> {
            sourceSets.getByName("main").java.directories.clear()
        }
        extensions.configure<LibraryAndroidComponentsExtension> {
            onVariants { variant ->
                val taskName = "patch${variant.name.replaceFirstChar { it.uppercase() }}AudioService"
                val patched = tasks.register<PatchAudioServiceSources>(taskName) {
                    originalSources.set(upstream)
                    sourcePatch.set(patch)
                }
                variant.sources.java?.addGeneratedSourceDirectory(
                    patched, PatchAudioServiceSources::generatedSources,
                )
            }
        }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
