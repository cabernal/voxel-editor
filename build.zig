const std = @import("std");

const APP_NAME = "voxel-editor";

const C_SOURCES = [_][]const u8{
    "sokol_log.c",
    "sokol_app.c",
    "sokol_gfx.c",
    "sokol_time.c",
    "sokol_gl.c",
    "sokol_glue.c",
    "sokol_imgui.c",
    "sokol_audio.c",
};

const CPP_SOURCES = [_][]const u8{
    "third_party/cimgui/cimgui.cpp",
    "third_party/cimgui/imgui/imgui.cpp",
    "third_party/cimgui/imgui/imgui_demo.cpp",
    "third_party/cimgui/imgui/imgui_draw.cpp",
    "third_party/cimgui/imgui/imgui_tables.cpp",
    "third_party/cimgui/imgui/imgui_widgets.cpp",
};

const Backend = enum {
    metal,
    gl,
    d3d11,
    gles3,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const emsdk_root_opt = b.option(
        []const u8,
        "emsdk",
        "Path to emsdk root (required for `zig build web`)",
    );
    const android_ndk_opt = b.option(
        []const u8,
        "android_ndk",
        "Path to Android NDK root (required for `zig build android`)",
    );
    const ios_sdk_opt = b.option(
        []const u8,
        "ios_sdk",
        "Path to iPhoneOS or iPhoneSimulator SDK root (required for `zig build ios`)",
    );
    const ios_simulator_opt = b.option(
        bool,
        "ios_simulator",
        "Build for iOS simulator ABI when true",
    ) orelse false;
    const ios_arch_opt = b.option(
        []const u8,
        "ios_arch",
        "iOS architecture (aarch64 or x86_64)",
    ) orelse "aarch64";

    const native_sokol_mod = b.createModule(.{
        .root_source_file = b.path("third_party/sokol/sokol.zig"),
        .target = target,
        .optimize = optimize,
    });
    const native_sokol_clib = buildLibSokol(
        b,
        "sokol_clib_native",
        target,
        optimize,
        null,
        null,
        null,
    );
    const native_module = createAppModule(b, target, optimize, native_sokol_mod, null, null, null);
    native_module.linkLibrary(native_sokol_clib);

    const exe = b.addExecutable(.{
        .name = APP_NAME,
        .root_module = native_module,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.setCwd(b.path("."));
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    b.step("run", "Run native build").dependOn(&run_cmd.step);

    const web_step = b.step("web", "Build browser bundle in zig-out/web (requires emsdk + emcc)");
    if (emsdk_root_opt) |emsdk_root| {
        const web_target = b.resolveTargetQuery(.{
            .cpu_arch = .wasm32,
            .os_tag = .emscripten,
        });

        const web_sokol_mod = b.createModule(.{
            .root_source_file = b.path("third_party/sokol/sokol.zig"),
            .target = web_target,
            .optimize = optimize,
        });
        const web_sokol_clib = buildLibSokol(
            b,
            "sokol_clib_web",
            web_target,
            optimize,
            emsdk_root,
            null,
            null,
        );
        const web_module = createAppModule(
            b,
            web_target,
            optimize,
            web_sokol_mod,
            emsdk_root,
            null,
            null,
        );
        web_module.linkLibrary(web_sokol_clib);

        const web_lib = b.addLibrary(.{
            .name = "voxel_editor_web",
            .root_module = web_module,
        });

        const web_install = makeWebLinkStep(b, .{
            .name = APP_NAME,
            .optimize = optimize,
            .lib_main = web_lib,
            .emsdk_root = emsdk_root,
        });
        web_step.dependOn(&web_install.step);
    } else {
        web_step.dependOn(&b.addFail("`zig build web` requires `-Demsdk=/path/to/emsdk`").step);
    }

    const android_step = b.step("android", "Build Android arm64 shared library in zig-out/lib");
    if (android_ndk_opt) |android_ndk| {
        const android_target = b.resolveTargetQuery(.{
            .cpu_arch = .aarch64,
            .os_tag = .linux,
            .abi = .android,
        });
        const android_sokol_mod = b.createModule(.{
            .root_source_file = b.path("third_party/sokol/sokol.zig"),
            .target = android_target,
            .optimize = optimize,
        });
        const android_sokol_clib = buildLibSokol(
            b,
            "sokol_clib_android",
            android_target,
            optimize,
            null,
            android_ndk,
            null,
        );
        const android_module = createAppModule(
            b,
            android_target,
            optimize,
            android_sokol_mod,
            null,
            android_ndk,
            null,
        );
        android_module.linkLibrary(android_sokol_clib);

        const android_lib = b.addLibrary(.{
            .name = "voxel_editor_android",
            .root_module = android_module,
            .linkage = .dynamic,
        });
        const install_android = b.addInstallArtifact(android_lib, .{});
        android_step.dependOn(&install_android.step);
    } else {
        android_step.dependOn(&b.addFail("`zig build android` requires `-Dandroid_ndk=/path/to/android-ndk`").step);
    }

    const ios_step = b.step("ios", "Build iOS static library in zig-out/lib");
    if (ios_sdk_opt) |ios_sdk| {
        var ios_query: std.Target.Query = .{
            .cpu_arch = parseIosArch(ios_arch_opt),
            .os_tag = .ios,
            .os_version_min = .{ .semver = .{ .major = 17, .minor = 0, .patch = 0 } },
        };
        if (ios_simulator_opt) {
            ios_query.abi = .simulator;
        }
        const ios_target = b.resolveTargetQuery(ios_query);
        const ios_sokol_mod = b.createModule(.{
            .root_source_file = b.path("third_party/sokol/sokol.zig"),
            .target = ios_target,
            .optimize = optimize,
        });
        const ios_sokol_clib = buildLibSokol(
            b,
            "sokol_clib_ios",
            ios_target,
            optimize,
            null,
            null,
            ios_sdk,
        );
        const ios_module = createAppModule(
            b,
            ios_target,
            optimize,
            ios_sokol_mod,
            null,
            null,
            ios_sdk,
        );
        ios_module.linkLibrary(ios_sokol_clib);

        const ios_lib = b.addLibrary(.{
            .name = "voxel_editor_ios",
            .root_module = ios_module,
            .linkage = .static,
        });
        const install_ios = b.addInstallArtifact(ios_lib, .{});
        const install_ios_sokol = b.addInstallArtifact(ios_sokol_clib, .{});
        ios_step.dependOn(&install_ios.step);
        ios_step.dependOn(&install_ios_sokol.step);
    } else {
        ios_step.dependOn(&b.addFail("`zig build ios` requires `-Dios_sdk=/path/to/iOS.sdk`").step);
    }
}

fn createAppModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    mod_sokol: *std.Build.Module,
    emsdk_root: ?[]const u8,
    android_ndk_root: ?[]const u8,
    ios_sdk_root: ?[]const u8,
) *std.Build.Module {
    var cpp_flags_buf: [12][]const u8 = undefined;
    var cpp_flags = std.ArrayListUnmanaged([]const u8).initBuffer(&cpp_flags_buf);
    cpp_flags.appendAssumeCapacity("-std=c++17");
    cpp_flags.appendAssumeCapacity("-fno-sanitize=undefined");

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
        .imports = &.{
            .{ .name = "sokol", .module = mod_sokol },
        },
    });

    mod.addIncludePath(b.path("third_party/cimgui"));
    mod.addIncludePath(b.path("third_party/cimgui/imgui"));

    if (target.result.os.tag == .emscripten) {
        if (emsdk_root) |root| {
            mod.addSystemIncludePath(.{
                .cwd_relative = b.pathJoin(&.{ root, "upstream", "emscripten", "cache", "sysroot", "include" }),
            });
        }
    }

    if (target.result.abi.isAndroid()) {
        if (android_ndk_root) |root| {
            applyAndroidNdkPaths(b, mod, root);
            const sysroot = androidSysrootPath(b, root);
            cpp_flags.appendAssumeCapacity("--sysroot");
            cpp_flags.appendAssumeCapacity(sysroot);
        }
    }

    if (target.result.os.tag == .ios) {
        if (ios_sdk_root) |root| {
            applyIosSdkPaths(b, mod, root);
            cpp_flags.appendAssumeCapacity("-isysroot");
            cpp_flags.appendAssumeCapacity(root);
        }
    }

    inline for (CPP_SOURCES) |src| {
        mod.addCSourceFile(.{
            .file = b.path(src),
            .flags = cpp_flags.items,
        });
    }

    return mod;
}

fn buildLibSokol(
    b: *std.Build,
    name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    emsdk_root: ?[]const u8,
    android_ndk_root: ?[]const u8,
    ios_sdk_root: ?[]const u8,
) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const lib = b.addLibrary(.{
        .name = name,
        .root_module = mod,
        .linkage = .static,
    });

    const backend = resolveBackend(target.result);

    var cflags_buf: [20][]const u8 = undefined;
    var cflags = std.ArrayListUnmanaged([]const u8).initBuffer(&cflags_buf);
    cflags.appendAssumeCapacity("-DIMPL");
    cflags.appendAssumeCapacity(backendDefine(backend));
    cflags.appendAssumeCapacity("-fno-sanitize=undefined");

    if (optimize != .Debug) {
        cflags.appendAssumeCapacity("-DNDEBUG");
    }
    if (target.result.os.tag.isDarwin()) {
        cflags.appendAssumeCapacity("-ObjC");
    }
    if (target.result.os.tag == .emscripten) {
        if (emsdk_root) |root| {
            mod.addSystemIncludePath(.{
                .cwd_relative = b.pathJoin(&.{ root, "upstream", "emscripten", "cache", "sysroot", "include" }),
            });
        }
    }
    if (target.result.abi.isAndroid()) {
        if (android_ndk_root) |root| {
            applyAndroidNdkPaths(b, mod, root);
            cflags.appendAssumeCapacity("--sysroot");
            cflags.appendAssumeCapacity(androidSysrootPath(b, root));
        }
    }
    if (target.result.os.tag == .ios) {
        if (ios_sdk_root) |root| {
            applyIosSdkPaths(b, mod, root);
            cflags.appendAssumeCapacity("-DSOKOL_NO_ENTRY");
            cflags.appendAssumeCapacity("-isysroot");
            cflags.appendAssumeCapacity(root);
        }
    }

    mod.addIncludePath(b.path("third_party/sokol/c"));
    mod.addIncludePath(b.path("third_party/cimgui"));

    inline for (C_SOURCES) |src| {
        mod.addCSourceFile(.{
            .file = b.path("third_party/sokol/c/" ++ src),
            .flags = cflags.items,
        });
    }

    linkSystemLibs(mod, target.result, backend);
    return lib;
}

fn resolveBackend(target: std.Target) Backend {
    if (target.os.tag.isDarwin()) return .metal;
    if (target.os.tag == .windows) return .d3d11;
    if (target.abi.isAndroid() or target.os.tag == .emscripten) return .gles3;
    return .gl;
}

fn parseIosArch(arch: []const u8) std.Target.Cpu.Arch {
    if (std.mem.eql(u8, arch, "aarch64") or std.mem.eql(u8, arch, "arm64")) {
        return .aarch64;
    }
    if (std.mem.eql(u8, arch, "x86_64")) {
        return .x86_64;
    }
    @panic("Unsupported -Dios_arch value. Use aarch64 or x86_64.");
}

fn backendDefine(backend: Backend) []const u8 {
    return switch (backend) {
        .metal => "-DSOKOL_METAL",
        .gl => "-DSOKOL_GLCORE",
        .d3d11 => "-DSOKOL_D3D11",
        .gles3 => "-DSOKOL_GLES3",
    };
}

fn linkSystemLibs(mod: *std.Build.Module, target: std.Target, backend: Backend) void {
    if (target.abi.isAndroid()) {
        mod.linkSystemLibrary("EGL", .{});
        mod.linkSystemLibrary("GLESv3", .{});
        mod.linkSystemLibrary("android", .{});
        mod.linkSystemLibrary("log", .{});
        mod.linkSystemLibrary("aaudio", .{});
        mod.linkSystemLibrary("c++_shared", .{});
        return;
    }

    switch (target.os.tag) {
        .macos => {
            mod.linkFramework("Foundation", .{});
            mod.linkFramework("Cocoa", .{});
            mod.linkFramework("QuartzCore", .{});
            mod.linkFramework("AudioToolbox", .{});
            switch (backend) {
                .metal => mod.linkFramework("Metal", .{}),
                .gl => mod.linkFramework("OpenGL", .{}),
                else => {},
            }
            mod.linkSystemLibrary("c++", .{});
        },
        .ios => {
            mod.linkFramework("Foundation", .{});
            mod.linkFramework("UIKit", .{});
            mod.linkFramework("QuartzCore", .{});
            mod.linkFramework("AudioToolbox", .{});
            mod.linkFramework("AVFoundation", .{});
            mod.linkFramework("Metal", .{});
            mod.linkSystemLibrary("c++", .{});
        },
        .linux => {
            mod.linkSystemLibrary("GL", .{});
            mod.linkSystemLibrary("X11", .{});
            mod.linkSystemLibrary("Xi", .{});
            mod.linkSystemLibrary("Xcursor", .{});
            mod.linkSystemLibrary("asound", .{});
            mod.linkSystemLibrary("pthread", .{});
            mod.linkSystemLibrary("m", .{});
            mod.linkSystemLibrary("stdc++", .{});
        },
        .windows => {
            mod.linkSystemLibrary("kernel32", .{});
            mod.linkSystemLibrary("user32", .{});
            mod.linkSystemLibrary("gdi32", .{});
            mod.linkSystemLibrary("ole32", .{});
            mod.linkSystemLibrary("d3d11", .{});
            mod.linkSystemLibrary("dxgi", .{});
            mod.linkSystemLibrary("winmm", .{});
        },
        else => {},
    }
}

fn applyAndroidNdkPaths(b: *std.Build, mod: *std.Build.Module, ndk_root: []const u8) void {
    const sysroot = androidSysrootPath(b, ndk_root);
    const arch_lib_root = b.pathJoin(&.{ sysroot, "usr", "lib", "aarch64-linux-android" });

    mod.addSystemIncludePath(.{
        .cwd_relative = b.pathJoin(&.{ sysroot, "usr", "include" }),
    });
    mod.addSystemIncludePath(.{
        .cwd_relative = b.pathJoin(&.{ sysroot, "usr", "include", "aarch64-linux-android" }),
    });
    mod.addLibraryPath(.{
        .cwd_relative = arch_lib_root,
    });
    mod.addLibraryPath(.{
        .cwd_relative = b.pathJoin(&.{ arch_lib_root, "29" }),
    });
}

fn applyIosSdkPaths(b: *std.Build, mod: *std.Build.Module, ios_sdk_root: []const u8) void {
    mod.addIncludePath(b.path("third_party/ios_shims"));
    mod.addSystemIncludePath(.{
        .cwd_relative = b.pathJoin(&.{ ios_sdk_root, "usr", "include" }),
    });
    mod.addLibraryPath(.{
        .cwd_relative = b.pathJoin(&.{ ios_sdk_root, "usr", "lib" }),
    });
    mod.addFrameworkPath(.{
        .cwd_relative = b.pathJoin(&.{ ios_sdk_root, "System", "Library", "Frameworks" }),
    });
}

fn androidSysrootPath(b: *std.Build, ndk_root: []const u8) []const u8 {
    const prebuilt_root = b.pathJoin(&.{ ndk_root, "toolchains", "llvm", "prebuilt" });
    var dir = std.fs.cwd().openDir(prebuilt_root, .{ .iterate = true }) catch {
        return b.pathJoin(&.{ prebuilt_root, "darwin-x86_64", "sysroot" });
    };
    defer dir.close();

    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind != .directory) continue;
        return b.pathJoin(&.{ prebuilt_root, entry.name, "sysroot" });
    }
    return b.pathJoin(&.{ prebuilt_root, "darwin-x86_64", "sysroot" });
}

const WebLinkOptions = struct {
    name: []const u8,
    optimize: std.builtin.OptimizeMode,
    lib_main: *std.Build.Step.Compile,
    emsdk_root: []const u8,
};

fn makeWebLinkStep(b: *std.Build, options: WebLinkOptions) *std.Build.Step.InstallDir {
    const emcc_py = b.pathJoin(&.{ options.emsdk_root, "upstream", "emscripten", "emcc.py" });
    const emsdk_python = findEmsdkPython(b, options.emsdk_root);
    const emcc = b.addSystemCommand(&.{ emsdk_python, emcc_py });
    emcc.setName("emcc");
    emcc.setEnvironmentVariable("EMSDK", options.emsdk_root);
    emcc.setEnvironmentVariable("EMSDK_PYTHON", emsdk_python);

    if (options.optimize == .Debug) {
        emcc.addArgs(&.{ "-Og", "-sSAFE_HEAP=1", "-sSTACK_OVERFLOW_CHECK=1" });
    } else {
        emcc.addArgs(&.{ "-O3", "-sASSERTIONS=0", "-flto" });
    }

    emcc.addArgs(&.{
        "-sUSE_WEBGL2=1",
        "-sWASM=1",
        "-sALLOW_MEMORY_GROWTH=1",
        "-sSTACK_SIZE=2MB",
        "--shell-file",
    });
    _ = emcc.addFileArg(b.path("web/shell.html"));

    emcc.addArtifactArg(options.lib_main);
    for (options.lib_main.getCompileDependencies(false)) |item| {
        if (item.kind == .lib) {
            emcc.addArtifactArg(item);
        }
    }

    emcc.addArg("-o");
    const out_file = emcc.addOutputFileArg(b.fmt("{s}.html", .{options.name}));

    const install = b.addInstallDirectory(.{
        .source_dir = out_file.dirname(),
        .install_dir = .prefix,
        .install_subdir = "web",
    });
    install.step.dependOn(&emcc.step);
    return install;
}

fn findEmsdkPython(b: *std.Build, emsdk_root: []const u8) []const u8 {
    const python_root = b.pathJoin(&.{ emsdk_root, "python" });
    var dir = std.fs.cwd().openDir(python_root, .{ .iterate = true }) catch {
        return b.pathJoin(&.{ emsdk_root, "python", "3.13.3_64bit", "bin", "python3" });
    };
    defer dir.close();

    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind != .directory) continue;
        const candidate = b.pathJoin(&.{ python_root, entry.name, "bin", "python3" });
        if (std.fs.cwd().access(candidate, .{})) {
            return candidate;
        } else |_| {}
    }
    return b.pathJoin(&.{ emsdk_root, "python", "3.13.3_64bit", "bin", "python3" });
}
